import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// Read standard WAVE 7.1 order explicitly, avoiding an implicit channel-layout
// remap by a media decoder. Supported: PCM16/24/32 or Float32, eight channels.
private final class SurroundWAV {
    let handle: FileHandle
    let rate: Double
    private let bits: Int
    private let isFloat: Bool
    private let stride: Int
    private var remaining: Int
    init(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        func bytes(_ count: Int) throws -> Data {
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw MacError(message: "Truncated WAV file.") }; return data
        }
        func u16(_ data: Data, _ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset+1]) << 8 }
        func u32(_ data: Data, _ offset: Int) -> UInt32 { UInt32(data[offset]) | UInt32(data[offset+1]) << 8 | UInt32(data[offset+2]) << 16 | UInt32(data[offset+3]) << 24 }
        do {
            let header = try bytes(12)
            guard String(data: header.prefix(4), encoding: .ascii) == "RIFF", String(data: header.suffix(4), encoding: .ascii) == "WAVE" else { throw MacError(message: "Choose an uncompressed 8-channel WAV (RIFF/WAVE).") }
            let fileSize = try handle.seekToEnd(); try handle.seek(toOffset: 12)
            var fmt: Data?, dataStart: UInt64?, dataSize: Int = 0
            var offset: UInt64 = 12
            while offset + 8 <= fileSize {
                try handle.seek(toOffset: offset)
                let chunk = try bytes(8), length = UInt64(u32(chunk, 4))
                guard length <= fileSize - offset - 8 else { throw MacError(message: "Invalid WAV chunk length.") }
                let tag = String(data: chunk.prefix(4), encoding: .ascii)
                if tag == "fmt " {
                    guard length >= 16, length <= 4096 else { throw MacError(message: "Unsupported WAV format header.") }
                    fmt = try bytes(Int(length))
                } else if tag == "data" { dataStart = offset + 8; dataSize = Int(length) }
                if fmt != nil && dataStart != nil { break }
                offset += 8 + length + (length & 1)
            }
            guard let f = fmt, let start = dataStart else { throw MacError(message: "WAV format or audio chunk is missing.") }
            var code = u16(f, 0)
            let channels = u16(f, 2), rate = Double(u32(f, 4)), bits = Int(u16(f, 14)), stride = Int(u16(f, 12))
            if code == 0xfffe {
                guard f.count >= 40, u16(f, 16) >= 22, u16(f, 18) == UInt16(bits), u32(f, 20) == 0x63f else { throw MacError(message: "Use standard 7.1 WAV layout: FL FR C LFE BL BR SL SR (mask 0x63f), with full PCM precision.") }
                let guidTail: [UInt8] = [0,0,0,0,16,0,128,0,0,170,0,56,155,113]
                guard Array(f[26..<40]) == guidTail else { throw MacError(message: "Unsupported WAV subformat.") }
                code = u16(f, 24)
            }
            guard channels == 8, [44100.0,48000.0,88200.0,96000.0].contains(rate),
                  (code == 1 && [16,24,32].contains(bits) || code == 3 && bits == 32), stride == 8 * bits / 8, dataSize % stride == 0 else {
                throw MacError(message: "Use an 8-channel PCM16/24/32 or Float32 WAV at 44.1, 48, 88.2 or 96 kHz. Order: FL FR C LFE BL BR SL SR.")
            }
            try handle.seek(toOffset: start)
            self.handle = handle; self.rate = rate; self.bits = bits; self.isFloat = code == 3; self.stride = stride; self.remaining = dataSize
        } catch { try? handle.close(); throw error }
    }
    deinit { try? handle.close() }
    func readFrames(_ capacity: Int) throws -> [Float] {
        let count = min(remaining, capacity * stride)
        guard count > 0 else { return [] }
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw MacError(message: "WAV audio ended unexpectedly.") }
        remaining -= count
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var result = [Float](repeating: 0, count: count / (bits/8))
            for i in result.indices {
                let o = i * (bits/8)
                switch bits {
                case 16:
                    result[i] = Float(Int16(bitPattern: UInt16(raw[o]) | UInt16(raw[o+1]) << 8)) / 32768
                case 24:
                    var value = Int32(raw[o]) | Int32(raw[o+1]) << 8 | Int32(raw[o+2]) << 16
                    if value & 0x800000 != 0 { value |= ~0xffffff }
                    result[i] = Float(value) / 8388608
                default:
                    let word = UInt32(raw[o]) | UInt32(raw[o+1]) << 8 | UInt32(raw[o+2]) << 16 | UInt32(raw[o+3]) << 24
                    result[i] = isFloat ? Float(bitPattern: word) : Float(Int32(bitPattern: word)) / 2147483648
                }
            }
            return result
        }
    }
}

final class SurroundPlayer {
    private let queue = DispatchQueue(label: "Rapoo.surroundPlayback")
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var renderer: OpaquePointer?
    private var reader: SurroundWAV?
    private var pending = 0
    private var generation = 0
    private var eof = false
    private var rotation: Float = 0
    private var strength: Float = 0.6
    var status: ((String) -> Void)?
    var update: (([String: Any]) -> Void)?
    func settings(strength: Float, rotation: Float) {
        guard strength.isFinite, rotation.isFinite else { return }
        queue.async {
            self.strength = strength; self.rotation = rotation
            if let renderer = self.renderer { surround_settings(renderer, strength, rotation) }
        }
    }
    private func setup(rate: Double) throws {
        guard let target = devices(input: false).first(where: { $0.1.localizedCaseInsensitiveContains("rapoo") }),
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { throw MacError(message: "Connect Rapoo before the surround test.") }
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        guard let unit = engine.outputNode.audioUnit else { throw MacError(message: "No surround output unit.") }
        var device = target.0
        try checked(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "Select surround output")
        guard let renderer = surround_create(rate) else { throw MacError(message: "Unsupported surround sample rate.") }
        self.renderer = renderer; surround_settings(renderer, strength, rotation)
        self.engine = engine; self.player = player; self.format = format
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.start(); player.play()
    }
    func test(channel: Int) {
        guard (0..<8).contains(channel) else { return }
        queue.async {
            self.stopOnQueue()
            do {
                try self.setup(rate: 48000)
                guard let format = self.format, let renderer = self.renderer, let player = self.player,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000), let dst = buffer.floatChannelData else { throw MacError(message: "Cannot create speaker test.") }
                surround_test(renderer, Int32(channel), dst[0], dst[1], 48000); buffer.frameLength = 48000
                let names = ["Front left", "Front right", "Center", "Bass (LFE)", "Back left", "Back right", "Side left", "Side right"]
                self.status?("Testing \(names[channel]). Pause other audio; tests bypass EQ, room and width. Rotation applies.")
                self.update?(["playing": true, "testChannel": channel]); let token = self.generation
                player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.queue.async { guard let self = self, self.generation == token else { return }; self.stopOnQueue(); self.status?("Speaker test finished. Click Start audio to resume playback processing.") }
                }
            } catch { self.stopOnQueue(); self.status?(error.localizedDescription) }
        }
    }
    func play(url: URL) {
        queue.async {
            self.stopOnQueue()
            do {
                let reader = try SurroundWAV(url); try self.setup(rate: reader.rate)
                self.reader = reader; self.eof = false
                self.update?(["playing": true, "testChannel": -1])
                self.status?("Discrete 7.1 WAV → Rapoo headphones: \(url.lastPathComponent). EQ/room/width are bypassed. Pause other audio.")
                try self.pump()
            } catch { self.stopOnQueue(); self.status?(error.localizedDescription) }
        }
    }
    private func pump() throws {
        guard let reader = reader, let player = player, let format = format, let renderer = renderer else { return }
        while pending < 3 && !eof {
            var samples = try reader.readFrames(2048)
            if samples.isEmpty { eof = true; samples = [Float](repeating: 0, count: Int(format.sampleRate * 0.1) * 8) }
            let n = samples.count / 8
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)), let dst = buffer.floatChannelData else { throw MacError(message: "Cannot create surround playback buffer.") }
            samples.withUnsafeBufferPointer { data in surround_interleaved(renderer, data.baseAddress!, dst[0], dst[1], n) }
            buffer.frameLength = AVAudioFrameCount(n); pending += 1; let token = generation
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    guard let self = self, self.generation == token else { return }
                    self.pending -= 1
                    if self.eof && self.pending == 0 { self.stopOnQueue(); self.status?("Discrete 7.1 WAV finished. Click Start audio to resume playback processing.") }
                    else { do { try self.pump() } catch { self.stopOnQueue(); self.status?(error.localizedDescription) } }
                }
            }
        }
    }
    func stop() { queue.async { self.stopOnQueue() } }
    func shutdown() { queue.sync { stopOnQueue() } }
    private func stopOnQueue() {
        generation += 1; player?.stop(); engine?.stop(); player = nil; engine = nil
        if let renderer = renderer { surround_destroy(renderer) }; renderer = nil
        reader = nil; format = nil; pending = 0; eof = false
        update?(["playing": false, "testChannel": -1])
    }
}
