import AVFoundation
import CoreAudio
import os

/// Decoded audio for one pack. Immutable once built, so the audio thread can
/// read it without coordinating with whoever loaded it.
private final class LoadedBuffers: @unchecked Sendable {
    let down: [UInt16: AVAudioPCMBuffer]
    let up: [UInt16: AVAudioPCMBuffer]
    /// Last resort for a key that arrives with a code Klik has never seen.
    /// Keyboards vary and macOS invents new media keys; without this, an
    /// unrecognised key is silent, which always reads as a bug.
    let genericDown: AVAudioPCMBuffer?
    let genericUp: AVAudioPCMBuffer?

    init(down: [UInt16: AVAudioPCMBuffer], up: [UInt16: AVAudioPCMBuffer]) {
        self.down = down
        self.up = up
        self.genericDown = down[KeyCodes.genericFallback] ?? down.values.first
        self.genericUp = up[KeyCodes.genericFallback] ?? up.values.first
    }
}

private struct PlaybackState: @unchecked Sendable {
    var buffers: LoadedBuffers?
    var volume: Float = 0.8
    var pitchVariance: Float = 0.04
}

/// The audio side of Klik.
///
/// The whole design is in service of one number: the gap between a key going
/// down and sound coming out. Three things follow from that.
///
///  1. Every sample is decoded to PCM at load time and sliced into a ready-made
///     buffer per key. Nothing touches the disk or a decoder while typing.
///  2. The node graph is built once at startup and never rewired. Player nodes
///     are started immediately and left running -- an idle player renders
///     silence, so a keystroke costs one `scheduleBuffer` call and nothing else.
///  3. The hardware buffer is shrunk as far as the output device allows, which
///     is the single biggest remaining term.
final class AudioEngine {

    /// Everything is converted to this at load time so the graph can be built
    /// once with a fixed format regardless of what the packs contain.
    static let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    /// Enough voices that overlapping keystrokes never steal each other's node.
    /// Typing tops out around 15 keys/second against samples of ~100ms.
    private static let voiceCount = 24

    private let log = Logger(subsystem: "com.klik.Klik", category: "audio")

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var varispeeds: [AVAudioUnitVarispeed] = []
    private var nextVoice = 0

    private let state = OSAllocatedUnfairLock(initialState: PlaybackState())

    private(set) var isRunning = false
    /// Frames per render cycle actually granted by the output device.
    private(set) var ioBufferFrames: UInt32 = 0
    /// What each device's buffer was set to before Klik touched it, so the
    /// setting can be put back rather than left changed for every other app.
    private var originalIOBufferFrames: [AudioDeviceID: UInt32] = [:]

    private var lowLatencyEnabled = true
    /// Pin playback to the laptop's own speakers regardless of where the rest of
    /// the system's audio is going.
    private var forceBuiltInOutput = false
    private(set) var isUsingBuiltInOutput = false

    // MARK: - Lifecycle

    func start(lowLatencyBuffer: Bool, builtInOutput: Bool) {
        guard !isRunning else { return }

        lowLatencyEnabled = lowLatencyBuffer
        forceBuiltInOutput = builtInOutput
        applyOutputDevice()
        applyIOBuffer()

        for _ in 0..<Self.voiceCount {
            let player = AVAudioPlayerNode()
            let varispeed = AVAudioUnitVarispeed()
            engine.attach(player)
            engine.attach(varispeed)
            engine.connect(player, to: varispeed, format: Self.canonicalFormat)
            engine.connect(varispeed, to: engine.mainMixerNode, format: Self.canonicalFormat)
            players.append(player)
            varispeeds.append(varispeed)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )

        engine.prepare()
        do {
            try engine.start()
            // Start every player once. From here a keystroke is a single
            // scheduleBuffer with no state transition behind it.
            players.forEach { $0.play() }
            isRunning = true
            log.notice("Engine started, \(Self.voiceCount) voices, IO buffer \(self.ioBufferFrames) frames")
        } catch {
            log.error("Engine failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The engine stops itself when the output device changes -- headphones in,
    /// AirPods connecting, a display unplugged. Restarting also re-pins the
    /// built-in speakers, which is exactly the moment that matters.
    @objc private func handleConfigurationChange() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.restart(reason: "output device changed")
        }
    }

    private func restart(reason: String) {
        engine.stop()
        applyOutputDevice()
        applyIOBuffer()
        do {
            engine.prepare()
            try engine.start()
            players.forEach { $0.play() }
            log.notice("Restarted (\(reason, privacy: .public)), built-in: \(self.isUsingBuiltInOutput), IO buffer \(self.ioBufferFrames) frames")
        } catch {
            isRunning = false
            log.error("Restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Points the engine's output at the laptop speakers, or back at whatever
    /// the system is using.
    ///
    /// This has to happen while the engine is stopped -- the output unit will not
    /// change device underneath a running graph.
    private func applyOutputDevice() {
        guard forceBuiltInOutput, let device = builtInOutputDevice else {
            isUsingBuiltInOutput = false
            return
        }
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(device)
            isUsingBuiltInOutput = true
        } catch {
            isUsingBuiltInOutput = false
            log.error("Could not pin built-in output: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyIOBuffer() {
        guard let device = activeOutputDevice else { return }
        if originalIOBufferFrames[device] == nil {
            readBackIOBuffer()
            originalIOBufferFrames[device] = ioBufferFrames
        }
        if lowLatencyEnabled {
            requestSmallIOBuffer()
        } else if let original = originalIOBufferFrames[device] {
            setIOBuffer(frames: original)
        }
        readBackIOBuffer()
    }

    func setBuiltInOutput(_ enabled: Bool) {
        guard isRunning, enabled != forceBuiltInOutput else {
            forceBuiltInOutput = enabled
            return
        }
        forceBuiltInOutput = enabled
        restart(reason: enabled ? "pinning built-in speakers" : "following system output")
    }

    /// Changes the render quantum and brings the graph back up around it.
    ///
    /// The device will not change buffer size underneath a running engine, so
    /// this stops and restarts it. That takes a few milliseconds and is silent,
    /// which is why the setting can be a live toggle rather than a relaunch.
    func setLowLatency(_ enabled: Bool) {
        lowLatencyEnabled = enabled
        guard isRunning else { return }
        restart(reason: enabled ? "low latency on" : "low latency off")
    }

    /// Puts the device's buffer size back on the way out, so quitting Klik does
    /// not leave the setting changed for everything else.
    func shutdown() {
        guard isRunning else { return }
        players.forEach { $0.stop() }
        engine.stop()
        for (device, frames) in originalIOBufferFrames {
            setIOBuffer(frames: frames, on: device)
        }
        isRunning = false
    }

    // MARK: - Settings

    var volume: Float {
        get { state.withLock { $0.volume } }
        set { state.withLock { $0.volume = newValue } }
    }

    var pitchVariance: Float {
        get { state.withLock { $0.pitchVariance } }
        set { state.withLock { $0.pitchVariance = newValue } }
    }

    // MARK: - Playback

    /// Called straight from the event tap thread. Must stay allocation-free.
    /// Returns whether a sound was actually found for the key.
    @discardableResult
    func play(virtualKey: UInt16, isDown: Bool) -> Bool {
        let snapshot = state.withLock { $0 }
        guard let buffers = snapshot.buffers else { return false }
        let table = isDown ? buffers.down : buffers.up
        let generic = isDown ? buffers.genericDown : buffers.genericUp
        guard let buffer = table[virtualKey] ?? generic else { return false }

        let voice = nextVoice
        nextVoice = (nextVoice + 1) % players.count

        // Per-keystroke pitch and gain jitter. Without this a dozen samples
        // played back identically read as a loop rather than as a keyboard.
        let variance = snapshot.pitchVariance
        varispeeds[voice].rate = variance > 0
            ? 1.0 + Float.random(in: -variance...variance)
            : 1.0
        players[voice].volume = snapshot.volume * Float.random(in: 0.85...1.0)

        players[voice].scheduleBuffer(buffer, at: nil, options: [.interrupts], completionHandler: nil)
        return true
    }

    // MARK: - Loading

    /// Decodes a pack into per-key buffers. Slow, and deliberately kept off the
    /// typing path -- call it from a background queue at launch or on a switch.
    func load(pack: SoundPack) throws {
        var down: [UInt16: AVAudioPCMBuffer] = [:]
        var up: [UInt16: AVAudioPCMBuffer] = [:]

        if let audioURL = pack.audioURL {
            let sprite = try decode(url: audioURL)
            let rate = Self.canonicalFormat.sampleRate
            for (vk, key) in pack.keys {
                if let slice = key.down, let buffer = extract(slice, from: sprite, sampleRate: rate) {
                    down[vk] = buffer
                }
                if let slice = key.up, let buffer = extract(slice, from: sprite, sampleRate: rate) {
                    up[vk] = buffer
                }
            }
        } else {
            // Multi-file pack: one file per key, no slicing.
            for (vk, key) in pack.keys {
                guard let url = key.downFile, let buffer = try? decode(url: url) else { continue }
                applyFades(to: buffer)
                down[vk] = buffer
            }
        }

        guard !down.isEmpty || !up.isEmpty else { throw SoundPackError.noDefinitions }

        let filledDown = fillGaps(in: down)
        let filledUp = fillGaps(in: up)

        let loaded = LoadedBuffers(down: filledDown, up: filledUp)
        state.withLock { $0.buffers = loaded }
        log.notice("Loaded \(pack.name, privacy: .public): \(down.count) down, \(up.count) up")
    }

    /// Gives every key on the keyboard a sound, borrowing one for the keys the
    /// pack never recorded.
    ///
    /// Substitutes are resolved against the pack's original contents, not against
    /// each other, so a borrowed sound is never itself borrowed second-hand.
    private func fillGaps(in map: [UInt16: AVAudioPCMBuffer]) -> [UInt16: AVAudioPCMBuffer] {
        // An empty direction means the pack has no sounds of that kind at all --
        // most v1 packs have no release sounds. Leave it empty rather than
        // inventing releases the author never recorded.
        guard !map.isEmpty else { return map }

        let original = map
        let generic = original[KeyCodes.genericFallback] ?? original.values.first!
        var filled = map
        var borrowed = 0

        for virtualKey in KeyCodes.toW3C.keys where original[virtualKey] == nil {
            let substitute = KeyCodes.fallbacks[virtualKey]?
                .lazy
                .compactMap { original[$0] }
                .first
            filled[virtualKey] = substitute ?? generic
            borrowed += 1
        }

        if borrowed > 0 { log.notice("Filled \(borrowed) keys the pack does not define") }
        return filled
    }

    /// Reads a file fully into memory, converting to the canonical format if the
    /// pack was recorded at some other rate or channel count.
    private func decode(url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw SoundPackError.unreadable(url)
        }
        try file.read(into: sourceBuffer)

        if sourceFormat == Self.canonicalFormat { return sourceBuffer }
        return try convert(sourceBuffer, to: Self.canonicalFormat)
    }

    private func convert(_ input: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let converter = AVAudioConverter(from: input.format, to: format) else {
            throw SoundPackError.unreadable(URL(fileURLWithPath: "/"))
        }
        let ratio = format.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw SoundPackError.unreadable(URL(fileURLWithPath: "/"))
        }

        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        return output
    }

    /// Copies one slice of the sprite into its own buffer.
    private func extract(_ slice: Slice, from sprite: AVAudioPCMBuffer, sampleRate: Double) -> AVAudioPCMBuffer? {
        let startFrame = AVAudioFramePosition(slice.start * sampleRate)
        let endFrame = AVAudioFramePosition(slice.end * sampleRate)
        guard startFrame >= 0, endFrame > startFrame, startFrame < AVAudioFramePosition(sprite.frameLength) else {
            return nil
        }

        let available = AVAudioFramePosition(sprite.frameLength) - startFrame
        let frames = AVAudioFrameCount(min(endFrame - startFrame, available))
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: sprite.format, frameCapacity: frames),
              let source = sprite.floatChannelData,
              let destination = out.floatChannelData else { return nil }

        let channels = Int(sprite.format.channelCount)
        for channel in 0..<channels {
            memcpy(destination[channel],
                   source[channel].advanced(by: Int(startFrame)),
                   Int(frames) * MemoryLayout<Float>.size)
        }
        out.frameLength = frames
        applyFades(to: out)
        return out
    }

    /// Slice boundaries land wherever the pack author put them, often mid-waveform.
    /// A hard cut there is an audible click on top of the intended click.
    private func applyFades(to buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let fadeIn = min(Int(0.001 * rate), frames / 2)
        let fadeOut = min(Int(0.004 * rate), frames / 2)
        guard frames > 0 else { return }

        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = data[channel]
            for i in 0..<fadeIn {
                samples[i] *= Float(i) / Float(fadeIn)
            }
            for i in 0..<fadeOut {
                samples[frames - 1 - i] *= Float(i) / Float(fadeOut)
            }
        }
    }

    // MARK: - Hardware buffer

    private var defaultOutputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    /// Whichever device Klik is actually playing through right now.
    private var activeOutputDevice: AudioDeviceID? {
        if forceBuiltInOutput, let builtIn = builtInOutputDevice { return builtIn }
        return defaultOutputDevice
    }

    /// The laptop's own speakers, found by transport type rather than by name,
    /// which would break on non-English systems and across models.
    private var builtInOutputDevice: AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return nil }
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }

        for device in devices where hasOutputStreams(device) {
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport = UInt32(0)
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(
                device, &transportAddress, 0, nil, &transportSize, &transport) == noErr else { continue }
            if transport == kAudioDeviceTransportTypeBuiltIn { return device }
        }
        return nil
    }

    private func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    /// Asks the output device for a smaller render quantum. The default of 512
    /// frames is ~11ms of latency on its own; 128 is ~3ms.
    ///
    /// This is a device-wide setting, so it affects other apps using the same
    /// output. It is also only a request -- devices are free to clamp it, which
    /// is why the granted value is read back rather than assumed.
    private func requestSmallIOBuffer() {
        guard let device = activeOutputDevice else { return }

        var rangeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange()
        var rangeSize = UInt32(MemoryLayout<AudioValueRange>.size)
        var desired: UInt32 = 128
        if AudioObjectGetPropertyData(device, &rangeAddress, 0, nil, &rangeSize, &range) == noErr {
            desired = UInt32(max(range.mMinimum, min(Double(desired), range.mMaximum)))
        }

        setIOBuffer(frames: desired)
    }

    private func setIOBuffer(frames: UInt32) {
        guard let device = activeOutputDevice else { return }
        setIOBuffer(frames: frames, on: device)
    }

    private func setIOBuffer(frames: UInt32, on device: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = frames
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            log.notice("Output device kept its buffer size (status \(status))")
        }
    }

    private func readBackIOBuffer() {
        guard let device = activeOutputDevice else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &frames) == noErr {
            ioBufferFrames = frames
        }
    }

    /// Measures what the graph is actually rendering, by listening to the mixer
    /// itself. This separates two failures that both sound like silence: nothing
    /// being produced, versus something being produced but sent to the wrong
    /// device.
    func measureOutputPeak(seconds: Double, action: () -> Void) -> Float {
        let peak = OSAllocatedUnfairLock(initialState: Float(0))
        let mixer = engine.mainMixerNode

        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            var local: Float = 0
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    local = max(local, abs(data[channel][frame]))
                }
            }
            let measured = local
            peak.withLock { $0 = max($0, measured) }
        }

        action()
        Thread.sleep(forTimeInterval: seconds)
        mixer.removeTap(onBus: 0)
        return peak.withLock { $0 }
    }

    /// Name of the device the engine is currently rendering to.
    var currentOutputDeviceName: String {
        guard let device = activeOutputDevice else { return "unknown" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else {
            return "device \(device)"
        }
        return value as String
    }

    /// Frame count and peak amplitude of a loaded key, for the self-test.
    /// A slice that decodes but is silent means the offsets are wrong.
    func inspect(virtualKey: UInt16, isDown: Bool) -> (frames: Int, peak: Float)? {
        let buffers = state.withLock { $0.buffers }
        guard let buffer = (isDown ? buffers?.down : buffers?.up)?[virtualKey],
              let data = buffer.floatChannelData else { return nil }

        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(data[channel][frame]))
            }
        }
        return (Int(buffer.frameLength), peak)
    }

    /// Round-trip estimate for the menu's latency readout: the render quantum
    /// plus the device's own reported output latency.
    var estimatedLatencyMilliseconds: Double {
        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard rate > 0 else { return 0 }
        let bufferSeconds = Double(ioBufferFrames) / rate
        let deviceSeconds = engine.outputNode.presentationLatency
        return (bufferSeconds + deviceSeconds) * 1000
    }
}
