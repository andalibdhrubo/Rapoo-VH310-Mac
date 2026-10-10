import AppKit
import AVFoundation
import CoreAudio
import AudioToolbox
import CoreMedia

// Capture is independent of the system-audio tap. This app is excluded from
// that tap, so monitored microphone audio cannot loop through the output DSP.
final class Microphone: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let queue = DispatchQueue(label: "Rapoo.microphone")
    private var session: AVCaptureSession?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    private var gain: Float = 0
    private var boost = false
    private var muted = false
    private var monitor = false
    private var pending = 0
    private var generation = 0
    private var callbacks = 0
    private var previousInput: Float = 0
    private var highpassOutput: Float = 0
    private var observer: NSObjectProtocol?
    var status: ((String) -> Void)?
    var update: (([String: Any]) -> Void)?

    func settings(gain: Float, boost: Bool, mute: Bool, monitor: Bool) {
        guard gain.isFinite else { return }
        queue.async {
            self.gain = min(12, max(-24, gain)); self.boost = boost; self.muted = mute
            self.monitor = monitor
            if !monitor { self.stopMonitor() }
            else if self.session?.isRunning == true {
                do { try self.startMonitor() }
                catch { self.monitor = false; self.publish(); self.status?(error.localizedDescription) }
            }
            self.publish()
        }
    }
    func start() async throws {
        let allowed = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { continuation.resume(returning: $0) }
        }
        guard allowed else { throw MacError(message: "Allow Rapoo Microphone access in System Settings → Privacy & Security → Microphone.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    guard self.session == nil else { continuation.resume(); return }
                    // Device discovery selects the headset, never the default mic.
                    guard let device = AVCaptureDevice.devices(for: .audio).first(where: { $0.localizedName.localizedCaseInsensitiveContains("rapoo") }) else {
                        throw MacError(message: "No Rapoo microphone found. Check the headset connection and Check devices.")
                    }
                    let session = AVCaptureSession()
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    guard session.canAddInput(input), session.canAddOutput(output) else { throw MacError(message: "Cannot open the Rapoo microphone.") }
                    session.addInput(input); session.addOutput(output)
                    // Native PCM is converted below, including different headset
                    // input/output sample rates and interleaved PCM16 input.
                    output.audioSettings = nil
                    output.setSampleBufferDelegate(self, queue: self.queue)
                    self.session = session
                    self.observer = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
                        let text = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Microphone capture interrupted."
                        self?.queue.async { self?.stopOnQueue(); self?.status?(text) }
                    }
                    session.startRunning()
                    guard session.isRunning else { throw MacError(message: "Microphone capture did not start.") }
                    if self.monitor { try self.startMonitor() }
                    self.publish()
                    self.queue.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
                        guard let self = self, let session = session, self.session === session, self.callbacks == 0 else { return }
                        self.stopOnQueue(); self.status?("No mic samples received. Check Microphone permission and reconnect Rapoo.")
                    }
                    self.status?("Mic ready: \(device.localizedName). Gain, boost and mute affect this app’s monitor. Device input controls affect other apps.")
                    continuation.resume()
                } catch { self.stopOnQueue(); continuation.resume(throwing: error) }
            }
        }
    }
    func stop() { queue.async { self.stopOnQueue() } }
    func shutdown() { queue.sync { stopOnQueue() } }
    private func stopOnQueue() {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        session?.stopRunning(); session = nil
        previousInput = 0; highpassOutput = 0; monitor = false; stopMonitor(); converter = nil; sourceFormat = nil; callbacks = 0
        publish(); update?(["peak": 0])
    }
    private func publish() { update?(["active": session?.isRunning ?? false, "monitor": monitor && engine != nil]) }
    private func startMonitor() throws {
        guard engine == nil else { return }
        guard let target = devices(input: false).first(where: { $0.1.localizedCaseInsensitiveContains("rapoo") }) else { throw MacError(message: "Connect the Rapoo output to use Mic Monitor.") }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        guard let unit = engine.outputNode.audioUnit else { throw MacError(message: "No microphone monitor output unit.") }
        var id = target.0
        try checked(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size)), "Select monitor output")
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        // Keep headphone sidetone modest to avoid excessive feedback.
        engine.mainMixerNode.outputVolume = 0.35
        try engine.start(); player.play()
        self.engine = engine; self.player = player
    }
    private func stopMonitor() {
        generation += 1; pending = 0
        player?.stop(); engine?.stop(); player = nil; engine = nil
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard session?.isRunning == true, let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let incoming = AVAudioFormat(streamDescription: asbd), incoming.commonFormat != .otherFormat else { return }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat: incoming, frameCapacity: AVAudioFrameCount(frames)) else { return }
        source.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: source.mutableAudioBufferList) == noErr else { return }
        if sourceFormat == nil || !sourceFormat!.isEqual(incoming) {
            sourceFormat = incoming; converter = AVAudioConverter(from: incoming, to: format)
        }
        guard let converter = converter, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(Double(frames) * 48000 / incoming.sampleRate) + 64)) else { return }
        var consumed = false, error: NSError?
        let result = converter.convert(to: buffer, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true; inputStatus.pointee = .haveData; return source
        }
        guard result != .error, error == nil, buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else {
            if let error = error { status?(error.localizedDescription) }; return
        }
        // Gentle 70 Hz high-pass removes DC and handling rumble.
        let coefficient: Float = 0.990878
        for index in 0..<Int(buffer.frameLength) {
            let input = samples[index].isFinite ? samples[index] : 0
            highpassOutput = coefficient * (highpassOutput + input - previousInput)
            previousInput = input
            samples[index] = highpassOutput
        }
        // Shared portable DSP is tested independently of the macOS capture path.
        let peak = mic_process(samples, Int(buffer.frameLength), gain, boost ? 1 : 0, muted ? 1 : 0)
        callbacks += 1
        if callbacks % 5 == 0 { update?(["peak": peak]) }
        if monitor, let player = player, pending < 4 {
            pending += 1; let token = generation
            player.scheduleBuffer(buffer) { [weak self] in
                self?.queue.async { guard let self = self, self.generation == token else { return }; self.pending = max(0, self.pending - 1) }
            }
        }
    }
}

// Hardware input controls are separate from the app's software processing.
// Only writable Core Audio properties are exposed; unsupported controls are
// disabled instead of showing successful changes that do nothing.
final class MicHardware {
    private func target() -> AudioDeviceID? { devices(input: true).first(where: { $0.1.localizedCaseInsensitiveContains("rapoo") })?.0 }
    private func addresses(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> [AudioObjectPropertyAddress] {
        var controls: [AudioObjectPropertyAddress] = []
        for element in [UInt32(0), 1, 2] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: element)
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(device, &address), AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue {
                controls.append(address)
                if element == 0 { break }
            }
        }
        return controls
    }
    func snapshot() -> [String: Any] {
        guard let device = target() else { return ["hardwareGain": false, "hardwareMute": false] }
        var value: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
        let gains = addresses(device, selector: kAudioDevicePropertyVolumeScalar)
        if var address = gains.first { AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) }
        let mutes = addresses(device, selector: kAudioDevicePropertyMute)
        var mute: UInt32 = 0; size = UInt32(MemoryLayout<UInt32>.size)
        if var address = mutes.first { AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mute) }
        return ["hardwareGain": !gains.isEmpty, "hardwareMute": !mutes.isEmpty, "hardwareLevel": Double(value), "hardwareMuted": mute != 0]
    }
    func setGain(_ value: Float) throws {
        guard value.isFinite, let device = target() else { throw MacError(message: "No Rapoo microphone.") }
        let controls = addresses(device, selector: kAudioDevicePropertyVolumeScalar)
        guard !controls.isEmpty else { throw MacError(message: "This headset does not expose writable input gain to macOS.") }
        var level = min(1, max(0, value))
        for var address in controls { try checked(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &level), "Set hardware mic level") }
    }
    func setMute(_ enabled: Bool) throws {
        guard let device = target() else { throw MacError(message: "No Rapoo microphone.") }
        let controls = addresses(device, selector: kAudioDevicePropertyMute)
        guard !controls.isEmpty else { throw MacError(message: "This headset does not expose writable input mute to macOS.") }
        var value: UInt32 = enabled ? 1 : 0
        for var address in controls { try checked(AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value), "Set hardware mic mute") }
    }
}
