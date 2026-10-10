import AppKit
import WebKit
import AVFoundation
import CoreAudio
import AudioToolbox
import CoreMedia

struct MacError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func checked(_ code: OSStatus, _ operation: String) throws {
    if code != noErr { throw MacError(message: "\(operation) failed (\(code)).") }
}
func devices(input: Bool) -> [(AudioDeviceID, String)] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var nameSize = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr else { return nil }
        return (id, name as String)
    }
}

final class Processor: NSObject {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 5)
    private let reverb = AVAudioUnitReverb()
    private var currentRoom = "Nothing"
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var physicalInputChannels = 0
    private var callbacks = 0
    private let queue = DispatchQueue(label: "Rapoo.capture")
    private let lock = NSLock()
    private var pending = 0
    private var generation = 0
    private var active = false
    private var spatialEnabled = false
    private var stereoWidth: Float = 1.5
    private var binaural: OpaquePointer?
    private var binauralEnabled = false
    private var surround: OpaquePointer?
    private var surroundEnabled = false
    private var surroundStrength: Float = 0.6
    private var surroundRotation: Float = 0
    var status: ((String) -> Void)?
    override init() {
        super.init()
        engine.attach(player); engine.attach(eq); engine.attach(reverb)
        for (i, hz) in [60.0, 300.0, 1200.0, 3600.0, 12000.0].enumerated() {
            eq.bands[i].filterType = .parametric
            eq.bands[i].frequency = Float(hz)
            eq.bands[i].bandwidth = 1
            eq.bands[i].bypass = false
        }
        eq.bypass = true
        reverb.wetDryMix = 0
        // Fixed headroom prevents five boosted bands from immediately clipping.
        eq.globalGain = -12
    }
    func setBand(_ index: Int, gain: Float) {
        guard eq.bands.indices.contains(index) else { return }
        eq.bands[index].gain = min(12, max(-12, gain))
    }
    func enableEQ(_ enabled: Bool) { eq.bypass = !enabled }
    func virtualSpeakers(_ enabled: Bool) {
        lock.withLock { binauralEnabled = enabled }
    }
    func spatial(_ enabled: Bool, width: Float) {
        guard width.isFinite else { return }
        lock.withLock { spatialEnabled = enabled; stereoWidth = min(2, max(0, width)) }
    }
    func surroundSettings(enabled: Bool, strength: Float, rotation: Float) {
        guard strength.isFinite, rotation.isFinite else { return }
        lock.withLock {
            surroundEnabled = enabled
            surroundStrength = min(1, max(0, strength)); surroundRotation = rotation.truncatingRemainder(dividingBy: 360)
        }
    }
    func room(_ value: String, enabled: Bool, amount: Float) {
        guard amount.isFinite else { return }
        if currentRoom != value {
        currentRoom = value
        switch value {
        case "Theater": reverb.loadFactoryPreset(.largeHall)
        case "Bathroom": reverb.loadFactoryPreset(.mediumChamber)
        case "Living room": reverb.loadFactoryPreset(.smallRoom)
        case "StoneGallery": reverb.loadFactoryPreset(.largeChamber)
        default: reverb.wetDryMix = 0; return
        }
        }
        guard value != "Nothing" else { reverb.wetDryMix = 0; return }
        reverb.wetDryMix = enabled ? min(70, max(0, amount)) : 0
    }
    func start() async throws {
        guard tapID == 0 else { return }
        guard let target = devices(input: false).first(where: { $0.1.localizedCaseInsensitiveContains("rapoo") }) else {
            throw MacError(message: "Connect the Rapoo headset, then try Start again.")
        }
        // Translate this process's PID to a Core Audio process object. Excluding
        // that object prevents processed output from feeding back into capture.
        var pid = getpid()
        var ownProcess: AudioObjectID = 0
        var bytes = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try checked(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &bytes, &ownProcess), "Identify this audio process")
        guard ownProcess != 0 else { throw MacError(message: "Cannot exclude this app from capture.") }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.uuid = UUID()
        description.name = "Rapoo Mac processing"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        do {
            try checked(AudioHardwareCreateProcessTap(description, &tapID), "Create system audio tap; allow Audio Capture in System Settings")
            var asbd = AudioStreamBasicDescription()
            address.mSelector = kAudioTapPropertyFormat
            bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checked(AudioObjectGetPropertyData(tapID, &address, 0, nil, &bytes, &asbd), "Read tap format")
            guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32,
                  asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mChannelsPerFrame == 2,
                  let captureFormat = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate, channels: 2) else {
                throw MacError(message: "The tap did not provide stereo Float32 audio.")
            }
            format = captureFormat
            surround = surround_create(asbd.mSampleRate)
            guard surround != nil else { throw MacError(message: "Surround supports 44.1, 48, 88.2 or 96 kHz. Set Rapoo to 48 kHz in Audio MIDI Setup.") }
            binaural = binaural_create(asbd.mSampleRate)
            guard binaural != nil else { throw MacError(message: "Virtual speakers support 44.1, 48, 88.2 or 96 kHz. Set Rapoo to 48 kHz in Audio MIDI Setup.") }
            // Use the Rapoo output as the clock. Physical inputs precede the tap
            // in the aggregate, so compute their count instead of reading mic data.
            address.mSelector = kAudioDevicePropertyStreamConfiguration
            address.mScope = kAudioDevicePropertyScopeInput
            var listBytes: UInt32 = 0
            try checked(AudioObjectGetPropertyDataSize(target.0, &address, 0, nil, &listBytes), "Read device inputs")
            let raw = UnsafeMutableRawPointer.allocate(byteCount: max(Int(listBytes), MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            physicalInputChannels = 0
            if listBytes > 0 {
                try checked(AudioObjectGetPropertyData(target.0, &address, 0, nil, &listBytes, raw), "Read input channels")
                let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
                physicalInputChannels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
            }
            address.mSelector = kAudioDevicePropertyDeviceUID
            address.mScope = kAudioObjectPropertyScopeGlobal
            var uid: CFString = "" as CFString
            bytes = UInt32(MemoryLayout<CFString>.size)
            try checked(AudioObjectGetPropertyData(target.0, &address, 0, nil, &bytes, &uid), "Read output UID")
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Rapoo Mac private tap",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: uid as String,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid as String]],
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try checked(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Create capture device")
            var alive: UInt32 = 0
            address.mSelector = kAudioDevicePropertyDeviceIsAlive
            for _ in 0..<30 {
                bytes = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(aggregateID, &address, 0, nil, &bytes, &alive) == noErr, alive != 0 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard alive != 0 else { throw MacError(message: "Capture device did not become ready.") }
            guard let unit = engine.outputNode.audioUnit else { throw MacError(message: "No Core Audio output unit.") }
            var device = target.0
            try checked(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "Select Rapoo output")
            engine.connect(player, to: eq, format: captureFormat)
            engine.connect(eq, to: reverb, format: captureFormat)
            engine.connect(reverb, to: engine.mainMixerNode, format: captureFormat)
            try engine.start(); player.play()
            lock.withLock { generation += 1; pending = 0; callbacks = 0; active = true }
            try checked(AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, queue) { [weak self] _, input, _, output, _ in
                let outputs = UnsafeMutableAudioBufferListPointer(output)
                for out in outputs { if let data = out.mData { memset(data, 0, Int(out.mDataByteSize)) } }
                self?.receive(input)
            }, "Create capture callback")
            try checked(AudioDeviceStart(aggregateID, ioProc), "Start muted capture")
            status?("Processing → \(target.1). Original playback is muted while processing. Play audio to check the input meter.")
            let token = lock.withLock { generation }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self = self else { return }
                let stalled = self.lock.withLock { self.active && self.generation == token && self.callbacks == 0 }
                if stalled { self.stopNow(); self.status?("No capture callbacks received. Processing stopped and original playback restored.") }
            }
        } catch { stopNow(); throw error }
    }
    func stopNow() {
        lock.withLock { active = false; generation += 1; pending = 0 }
        if aggregateID != 0 {
            if let proc = ioProc { AudioDeviceStop(aggregateID, proc); AudioDeviceDestroyIOProcID(aggregateID, proc) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        ioProc = nil; aggregateID = 0
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        tapID = 0
        player.stop(); engine.stop()
        // Drain the capture callback queue before releasing FIR state.
        queue.sync {
            format = nil
            if let processor = binaural { binaural_destroy(processor) }
            binaural = nil
            if let processor = surround { surround_destroy(processor) }; surround = nil
        }
    }
    func stop() async { stopNow() }
    deinit { stopNow() }
    var meter: ((Float) -> Void)?
    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        guard let captureFormat = format else { return }
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var offset = 0
        var sources: [(UnsafePointer<Float>, Int, Int)] = []
        for part in list {
            let channels = Int(part.mNumberChannels)
            if let data = part.mData, channels > 0 {
                for channel in 0..<channels where offset + channel >= physicalInputChannels && sources.count < 2 {
                    sources.append((UnsafePointer(data.assumingMemoryBound(to: Float.self)).advanced(by: channel), channels, Int(part.mDataByteSize) / (4 * channels)))
                }
            }
            offset += channels
        }
        guard sources.count == 2 else { return }
        let n = min(sources[0].2, sources[1].2)
        guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: captureFormat, frameCapacity: AVAudioFrameCount(n)), let dst = buffer.floatChannelData else { return }
        var peak: Float = 0
        for channel in 0..<2 {
            let (src, stride, _) = sources[channel]
            for frame in 0..<n { let v = src[frame * stride]; dst[channel][frame] = v; peak = max(peak, abs(v)) }
        }
        let surroundState = lock.withLock { (surroundEnabled, surroundStrength, surroundRotation) }
        if let surround = surround {
            surround_settings(surround, surroundState.1, surroundState.2)
            // The seven-speaker renderer replaces the two-speaker HRTF/width
            // stage to avoid applying two spatial renderers to one signal.
            surround_stereo(surround, dst[0], dst[1], n, surroundState.0 ? 1 : 0)
        }
        if !surroundState.0 {
        let spatialState = lock.withLock { (spatialEnabled, stereoWidth) }
        if spatialState.0 {
            let width = spatialState.1
            // Mid/side stereo width. Normalization bounds the output peak by
            // the largest input peak; this is not a directional HRTF renderer.
            let normalization = max(1, width)
            for frame in 0..<n {
                let left = dst[0][frame], right = dst[1][frame]
                let mid = (left + right) * 0.5
                let side = (left - right) * 0.5 * width
                dst[0][frame] = (mid + side) / normalization
                dst[1][frame] = (mid - side) / normalization
            }
        }
        if let processor = binaural {
            let enabled = lock.withLock { binauralEnabled }
            binaural_process(processor, dst[0], dst[1], n, enabled ? 1 : 0)
        }
        }
        buffer.frameLength = AVAudioFrameCount(n)
        let token: Int? = lock.withLock {
            guard active, pending < 8 else { return nil }
            pending += 1; callbacks += 1
            return generation
        }
        guard let token = token else { return }
        if lock.withLock({ callbacks % 20 == 0 }) { meter?(peak) }
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self = self else { return }
            self.lock.withLock { if self.generation == token { self.pending = max(0, self.pending - 1) } }
        }
    }
}

final class App: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    let processor = Processor()
    let microphone = Microphone()
    let micHardware = MicHardware()
    let surroundPlayer = SurroundPlayer()
    var hardwareTimer: Timer?
    var lastHardwareSnapshot: NSDictionary?
    var uiReady = false
    var micBusy = false
    var busy = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let item = NSMenuItem(); menu.addItem(item)
        let submenu = NSMenu(); submenu.addItem(withTitle: "Quit Rapoo Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = submenu
        NSApp.mainMenu = menu
        let controller = WKUserContentController(); controller.add(self, name: "rapoo")
        let configuration = WKWebViewConfiguration(); configuration.userContentController = controller
        web = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 650, height: 500)
        window.collectionBehavior = [.fullScreenPrimary]
        window.title = "Rapoo VH310 • Audio Control"
        window.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.12, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        if let icon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = icon }
        window.contentView = web; window.center(); window.makeKeyAndOrderFront(nil)
        let root = Bundle.main.resourceURL!
        web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        processor.status = { [weak self] text in self?.show(text) }
        processor.meter = { [weak self] peak in
            DispatchQueue.main.async { self?.web.evaluateJavaScript("setMeter(\(peak))", completionHandler: nil) }
        }
        microphone.status = { [weak self] text in self?.show(text) }
        microphone.update = { [weak self] values in self?.micUpdate(values) }
        surroundPlayer.status = { [weak self] text in self?.show(text) }
        surroundPlayer.update = { [weak self] values in
            DispatchQueue.main.async {
                guard let self = self, let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) else { return }
                self.web.evaluateJavaScript("setSurroundStatus(\(json))", completionHandler: nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func refreshMicHardware(force: Bool = false) {
        let snapshot = micHardware.snapshot()
        let current = snapshot as NSDictionary
        if force || lastHardwareSnapshot == nil || !current.isEqual(lastHardwareSnapshot!) {
            lastHardwareSnapshot = current
            micUpdate(snapshot)
        }
    }
    func startMicrophone() {
        guard !micBusy else { return }; micBusy = true
        Task { @MainActor in
            defer { micBusy = false; refreshMicHardware(force: true) }
            do { try await microphone.start() } catch { show(error.localizedDescription) }
        }
    }
    func micUpdate(_ values: [String: Any]) {
        DispatchQueue.main.async {
            guard let data = try? JSONSerialization.data(withJSONObject: values), let json = String(data: data, encoding: .utf8) else { return }
            self.web.evaluateJavaScript("setMicStatus(\(json))", completionHandler: nil)
        }
    }
    func show(_ text: String) {
        DispatchQueue.main.async {
            guard let data = try? JSONSerialization.data(withJSONObject: [text]), let json = String(data: data, encoding: .utf8) else { return }
            self.web.evaluateJavaScript("setStatus(\(json)[0])", completionHandler: nil)
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let command = body["command"] as? String else { return }
        switch command {
        case "ready":
            guard !uiReady else { return }; uiReady = true
            refreshMicHardware()
            hardwareTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshMicHardware() }
            startMicrophone()
        case "band": if let i = body["index"] as? Int, let gain = body["value"] as? Double { processor.setBand(i, gain: Float(gain)) }
        case "eq": processor.enableEQ(body["value"] as? Bool ?? false)
        case "room": processor.room(body["value"] as? String ?? "Nothing", enabled: body["enabled"] as? Bool ?? false, amount: Float(body["amount"] as? Double ?? 25))
        case "micSettings":
            microphone.settings(gain: Float(body["gain"] as? Double ?? 0), boost: body["boost"] as? Bool ?? false, mute: body["mute"] as? Bool ?? false, monitor: body["monitor"] as? Bool ?? false)
        case "micStart":
            startMicrophone()
        case "micStop":
            guard !micBusy else { return }
            microphone.stop(); show("Microphone stopped.")
        case "micCheck": refreshMicHardware(force: true)
        case "micHardwareGain":
            do { try micHardware.setGain(Float(body["value"] as? Double ?? 0)) } catch { show(error.localizedDescription) }
            micUpdate(micHardware.snapshot())
        case "micHardwareMute":
            do { try micHardware.setMute(body["value"] as? Bool ?? false) } catch { show(error.localizedDescription) }
            micUpdate(micHardware.snapshot())
        case "surround":
            let enabled = body["enabled"] as? Bool ?? false
            let strength = Float(body["strength"] as? Double ?? 0.6), rotation = Float(body["rotation"] as? Double ?? 0)
            processor.surroundSettings(enabled: enabled, strength: strength, rotation: rotation)
            surroundPlayer.settings(strength: strength, rotation: rotation)
        case "speakerTest":
            guard !busy, let channel = body["channel"] as? Int, (0..<8).contains(channel) else { return }
            processor.stopNow(); surroundPlayer.test(channel: channel)
        case "surroundFile":
            guard !busy else { return }
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false; panel.allowedFileTypes = ["wav"]
            if panel.runModal() == .OK, let url = panel.url { processor.stopNow(); surroundPlayer.play(url: url) }
        case "surroundDemo":
            guard !busy, let url = Bundle.main.url(forResource: "Discrete-7.1-Test", withExtension: "wav") else { return }
            processor.stopNow(); surroundPlayer.play(url: url)
        case "surroundStop": surroundPlayer.stop()
        case "binaural": processor.virtualSpeakers(body["enabled"] as? Bool ?? false)
        case "spatial":
            if let width = body["width"] as? Double { processor.spatial(body["enabled"] as? Bool ?? false, width: Float(width)) }
        case "start":
            guard !busy else { return }; busy = true
            surroundPlayer.stop()
            Task {
                do { try await processor.start() } catch { show(error.localizedDescription) }
                await MainActor.run { self.busy = false }
            }
        case "stop":
            guard !busy else { return }; busy = true
            surroundPlayer.stop()
            Task { await processor.stop(); await MainActor.run { self.busy = false }; show("Processing stopped.") }
        case "save":
            guard let profile = body["profile"], JSONSerialization.isValidJSONObject(profile) else { return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Rapoo-Mac-Profile.json"
            if panel.runModal() == .OK, let url = panel.url {
                do { try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted]).write(to: url, options: .atomic); show("Mac profile saved.") }
                catch { show(error.localizedDescription) }
            }
        case "load":
            let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
            if panel.runModal() == .OK, let url = panel.url {
                do {
                    let data = try Data(contentsOf: url)
                    guard data.count <= 65536 else { throw MacError(message: "Profile is too large.") }
                    let profile = try JSONSerialization.jsonObject(with: data)
                    let encoded = try JSONSerialization.data(withJSONObject: [profile])
                    guard let json = String(data: encoded, encoding: .utf8) else { return }
                    web.evaluateJavaScript("loadProfile(\(json)[0])", completionHandler: nil)
                } catch { show(error.localizedDescription) }
            }
        case "devices": show((devices(input: false).map { "Output: \($0.1)" } + devices(input: true).map { "Input: \($0.1)" }).joined(separator: " | "))
        default: break
        }
    }
    func applicationWillTerminate(_ notification: Notification) { hardwareTimer?.invalidate(); processor.stopNow(); microphone.shutdown(); surroundPlayer.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
