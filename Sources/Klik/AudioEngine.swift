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

/// One sounding keystroke.
///
/// Deliberately made of nothing but numbers and raw pointers. The render
/// callback walks this on the audio thread, where retaining an object or
/// touching a dictionary would be a dropped buffer waiting to happen. The
/// samples it points at belong to the `LoadedBuffers` held in `PlaybackState`,
/// and every voice is cleared before that object is ever let go.
private struct Voice {
    var left: UnsafePointer<Float>?
    var right: UnsafePointer<Float>?
    var frames: Int = 0
    var position: Double = 0
    var rate: Double = 1
    var gain: Float = 0
    var active: Bool = false
    /// Play order, so the oldest voice is the one stolen when all are busy.
    var sequence: UInt64 = 0
}

private struct PlaybackState: @unchecked Sendable {
    var buffers: LoadedBuffers?
    var volume: Float = 0.8
    var pitchVariance: Float = 0.04
    var voices: [Voice]
    var sequence: UInt64 = 0
    /// Mirror of the engine's running flag, kept here so the key tap can read it
    /// without racing the main thread.
    var engineRunning = false
}

/// Where the limiter starts working. Packs are levelled so that a single
/// keystroke never reaches this, which means one key at a time is passed through
/// untouched and only genuine overlap is ever shaped.
private let limiterKnee: Float = 0.7

/// Saturates instead of clipping. Overlapping keystrokes add up, and a hard clip
/// on a click turns it into a crunch.
///
/// Linear below the knee, then a smooth curve that approaches 1 and never
/// exceeds it. The curve is the usual rational stand-in for `tanh` -- this runs
/// on the audio thread for every sample, so it is arithmetic, not a call into
/// libm.
@inline(__always)
private func softClip(_ x: Float) -> Float {
    let magnitude = abs(x)
    if magnitude <= limiterKnee { return x }
    let over = min((magnitude - limiterKnee) / (1 - limiterKnee), 3)
    let shaped = limiterKnee + (1 - limiterKnee) * (over * (27 + over * over) / (27 + 9 * over * over))
    return x < 0 ? -shaped : shaped
}

/// The audio side of Klik.
///
/// The whole design is in service of one number: the gap between a key going
/// down and sound coming out. Three things follow from that.
///
///  1. Every sample is decoded to PCM at load time and sliced into a ready-made
///     buffer per key. Nothing touches the disk or a decoder while typing.
///  2. There is exactly one node between the samples and the mixer: a source
///     node whose render callback mixes a fixed set of voices by hand. A
///     keystroke costs a lock, a dictionary lookup and a struct write.
///  3. The hardware buffer is shrunk as far as the output device allows, which
///     is the single biggest remaining term.
///
/// Point 2 replaced a bank of `AVAudioPlayerNode`s, and not for speed. Those
/// nodes have to be told to `play()` again every time the graph is rebuilt,
/// `play()` raises an Objective-C exception when the output device has not
/// delivered its first render cycle yet, and an exception raised out of
/// AVFoundation into Swift cannot be caught -- it takes the whole app with it.
/// That is what was quitting Klik in the middle of the day, with no crash
/// report and nothing on screen. Mixing the voices here means there is no
/// `play()` to fail, and no audio node for the key tap and the main thread to
/// fight over during a device change.
final class AudioEngine {

    /// Everything is converted to this at load time so the graph can be built
    /// once with a fixed format regardless of what the packs contain.
    static let canonicalFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    /// Enough voices that overlapping keystrokes never steal each other's slot.
    /// Typing tops out around 15 keys/second against samples of ~100ms.
    private static let voiceCount = 32

    private let log = Logger(subsystem: "com.klik.Klik", category: "audio")

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?

    private let state = OSAllocatedUnfairLock(
        initialState: PlaybackState(voices: Array(repeating: Voice(), count: AudioEngine.voiceCount))
    )

    /// Whether the engine is producing audio right now.
    private(set) var isRunning = false
    /// Whether the graph has been attached. Separate from `isRunning` on
    /// purpose: a failed restart leaves the graph built but not running, and
    /// recovery has to stay possible from there.
    private var hasBuiltGraph = false
    /// Frames per render cycle actually granted by the output device.
    private(set) var ioBufferFrames: UInt32 = 0
    /// What each device's buffer was set to before Klik touched it, so the
    /// setting can be put back rather than left changed for every other app.
    private var originalIOBufferFrames: [AudioDeviceID: UInt32] = [:]

    /// A restart waiting for the device changes to stop arriving.
    private var pendingRestart: DispatchWorkItem?
    /// How long to wait for a burst of device changes to finish. Bluetooth
    /// devices announce themselves several times over about a second as they
    /// settle, and restarting on each one stops the sound mid-play.
    private static let restartDelay: TimeInterval = 0.35
    /// How many restarts in a row have failed, used to space out the retries.
    private var failedRestarts = 0

    /// Called on the main thread when the sound output starts or stops working.
    /// nil means it is fine. The app shows this in the menu, because a silent
    /// app with no explanation is the thing this whole fix is about.
    var onOutputProblem: ((String?) -> Void)?

    private var lowLatencyEnabled = true
    /// Pin playback to the laptop's own speakers regardless of where the rest of
    /// the system's audio is going.
    private var forceBuiltInOutput = false
    private(set) var isUsingBuiltInOutput = false

    // MARK: - Lifecycle

    func start(lowLatencyBuffer: Bool, builtInOutput: Bool) {
        guard !hasBuiltGraph else { return }

        lowLatencyEnabled = lowLatencyBuffer
        forceBuiltInOutput = builtInOutput
        applyOutputDevice()
        applyIOBuffer()

        let node = makeSourceNode()
        engine.attach(node)
        source = node
        hasBuiltGraph = true
        connectGraph()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
        OutputDevices.startMonitoring { [weak self] in
            self?.outputDevicesChanged()
        }

        startEngine(reason: "launch")
    }

    /// Builds the one node that turns key presses into samples.
    ///
    /// The block runs on the audio thread, so it allocates nothing, retains
    /// nothing and never calls into Swift runtime machinery that might.
    private func makeSourceNode() -> AVAudioSourceNode {
        AVAudioSourceNode(format: Self.canonicalFormat) { [state] isSilence, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let leftData = buffers.first?.mData else {
                isSilence.pointee = true
                return noErr
            }
            for buffer in buffers {
                memset(buffer.mData, 0, Int(buffer.mDataByteSize))
            }

            let frames = Int(frameCount)
            let outLeft = leftData.assumingMemoryBound(to: Float.self)
            let outRight = buffers.count > 1
                ? buffers[1].mData!.assumingMemoryBound(to: Float.self)
                : outLeft

            let sounded = state.withLock { playback -> Bool in
                var mixed = false
                let master = playback.volume

                for index in playback.voices.indices where playback.voices[index].active {
                    var voice = playback.voices[index]
                    guard let left = voice.left, voice.frames > 1 else {
                        playback.voices[index].active = false
                        continue
                    }

                    // Muted is not paused. A voice still has to run out in real
                    // time while the volume is at zero, or every keystroke typed
                    // on headphones sits there waiting, and unplugging fires all
                    // thirty-two of them at once.
                    if master <= 0 {
                        voice.position += Double(frames) * voice.rate
                        voice.active = voice.position < Double(voice.frames - 1)
                        playback.voices[index] = voice
                        continue
                    }

                    let right = voice.right ?? left
                    let gain = voice.gain * master
                    let last = Double(voice.frames - 1)
                    var position = voice.position
                    var frame = 0

                    while frame < frames && position < last {
                        let whole = Int(position)
                        let fraction = Float(position - Double(whole))
                        outLeft[frame] += (left[whole] + (left[whole + 1] - left[whole]) * fraction) * gain
                        outRight[frame] += (right[whole] + (right[whole + 1] - right[whole]) * fraction) * gain
                        position += voice.rate
                        frame += 1
                    }

                    voice.position = position
                    voice.active = position < last
                    playback.voices[index] = voice
                    mixed = true
                }
                return mixed
            }

            if sounded {
                for frame in 0..<frames {
                    outLeft[frame] = softClip(outLeft[frame])
                }
                if outRight != outLeft {
                    for frame in 0..<frames {
                        outRight[frame] = softClip(outRight[frame])
                    }
                }
            }
            isSilence.pointee = ObjCBool(!sounded)
            return noErr
        }
    }

    /// Wires the source node into the mixer and the mixer into the output device.
    ///
    /// This has to be redone after every output device change, and that is the
    /// whole reason the silence bug existed. Changing the device gives the
    /// output node a new format, but the mixer is still connected to it through
    /// a connection shaped for the device that just left. Nothing complains. The
    /// engine keeps saying it is running and the mixer renders pure silence into
    /// the stale connection.
    ///
    /// Reconnecting is what makes the engine notice the new device at all.
    private func connectGraph() {
        guard let source else { return }
        // The mixer talks to the hardware in the hardware's own format and
        // converts for us. The source node stays on the canonical format, which
        // is what every pack was decoded into.
        let hardware = engine.outputNode.outputFormat(forBus: 0)
        let outputFormat = hardware.sampleRate > 0 && hardware.channelCount > 0
            ? hardware
            : Self.canonicalFormat
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: outputFormat)
        engine.connect(source, to: engine.mainMixerNode, format: Self.canonicalFormat)
    }

    /// Brings the graph up and records whether it worked. The only place the
    /// engine is ever started, so there is one story about what a failure means.
    @discardableResult
    private func startEngine(reason: String) -> Bool {
        engine.prepare()
        do {
            try engine.start()
        } catch {
            setRunning(false)
            log.error("Engine failed to start (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return false
        }
        setRunning(true)
        readBackIOBuffer()
        failedRestarts = 0
        report(problem: nil)
        log.notice("Engine running (\(reason, privacy: .public)), built-in: \(self.isUsingBuiltInOutput), IO buffer \(self.ioBufferFrames) frames")
        return true
    }

    private func setRunning(_ running: Bool) {
        isRunning = running
        state.withLock { $0.engineRunning = running }
    }

    /// The engine stops itself when the output device changes -- headphones in,
    /// AirPods connecting, a display unplugged. Restarting also re-pins the
    /// built-in speakers, which is exactly the moment that matters.
    ///
    /// This notification arrives on whatever thread CoreAudio felt like using,
    /// so it hops to the main thread before touching any of the restart state.
    @objc private func handleConfigurationChange() {
        DispatchQueue.main.async { [weak self] in
            self?.scheduleRestart(reason: "output device changed")
        }
    }

    /// Called whenever an audio device appears, disappears, or becomes the
    /// system's default.
    ///
    /// The engine does not raise a configuration change for a plain switch of
    /// the default output device, and pinning to the built-in speakers does not
    /// stop macOS from idling that device once everything else has moved to
    /// headphones. In both cases the engine goes on reporting itself as running
    /// and renders nothing at all.
    ///
    /// There is no reliable flag for that state, so any device change is treated
    /// as a reason to rebuild. A restart is a few milliseconds and is silent.
    func outputDevicesChanged() {
        guard hasBuiltGraph else { return }
        scheduleRestart(reason: "audio devices changed")
    }

    /// Backstop for anything the notifications miss: restarts if the engine has
    /// stopped, or has drifted onto a device other than the one it should be on.
    /// Cheap enough to call on a timer.
    func verifyHealth() {
        guard hasBuiltGraph, pendingRestart == nil else { return }
        let wanted = activeOutputDevice
        let actual = engine.outputNode.auAudioUnit.deviceID
        guard !engine.isRunning || (wanted != nil && wanted != actual) else { return }
        log.notice("Engine drifted (running \(self.engine.isRunning), device \(actual), wanted \(wanted ?? 0))")
        scheduleRestart(reason: "engine drifted", after: 0)
    }

    private func report(problem: String?) {
        guard let onOutputProblem else { return }
        DispatchQueue.main.async { onOutputProblem(problem) }
    }

    /// Queues a restart, replacing any restart already waiting.
    ///
    /// Connecting one pair of AirPods raises several changes in a row. Acting on
    /// each one restarts the engine repeatedly, and a restart that lands while a
    /// key is sounding cuts it off. Waiting for the changes to stop means one
    /// restart per real event.
    private func scheduleRestart(reason: String, after delay: TimeInterval? = nil) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.scheduleRestart(reason: reason, after: delay) }
            return
        }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hasBuiltGraph else { return }
            self.pendingRestart = nil
            self.restart(reason: reason)
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (delay ?? Self.restartDelay), execute: work)
    }

    /// True once no restart is waiting and the engine is producing audio.
    var isSettled: Bool { pendingRestart == nil && isRunning }

    private func restart(reason: String) {
        engine.stop()
        setRunning(false)
        applyOutputDevice()
        applyIOBuffer()
        connectGraph()

        if startEngine(reason: reason) { return }

        failedRestarts += 1
        // A device that is still settling refuses to start, and a moment later
        // it is ready. Backing off rather than giving up is the difference
        // between sound returning on its own and never.
        let wait = min(8, 0.25 * pow(2, Double(failedRestarts - 1)))
        log.error("Restart failed (attempt \(self.failedRestarts)), retrying in \(wait)s")
        // Say nothing about the first stumble. Devices routinely refuse the
        // first attempt and are ready by the second, and a warning that appears
        // and vanishes is worse than none.
        if failedRestarts > 1 {
            report(problem: "Sound output is not responding, keeping trying")
        }
        scheduleRestart(reason: "retry after a failed restart", after: wait)
    }

    /// Points the engine's output at the laptop speakers, or back at whatever
    /// the system is using.
    ///
    /// This has to happen while the engine is stopped -- the output unit will not
    /// change device underneath a running graph.
    private func applyOutputDevice() {
        if forceBuiltInOutput, let device = builtInOutputDevice {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(device)
                isUsingBuiltInOutput = true
                return
            } catch {
                log.error("Could not pin built-in output: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Follow the system again. Without this the output unit keeps whichever
        // device it was last pinned to, which after a disconnect can be a device
        // that is no longer there. That is a silent engine with nothing to say
        // for itself.
        isUsingBuiltInOutput = false
        guard let device = defaultOutputDevice else { return }
        do {
            try engine.outputNode.auAudioUnit.setDeviceID(device)
        } catch {
            log.error("Could not follow system output: \(error.localizedDescription, privacy: .public)")
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
        guard hasBuiltGraph, enabled != forceBuiltInOutput else {
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
        guard hasBuiltGraph else { return }
        restart(reason: enabled ? "low latency on" : "low latency off")
    }

    /// Puts the device's buffer size back on the way out, so quitting Klik does
    /// not leave the setting changed for everything else.
    func shutdown() {
        guard hasBuiltGraph else { return }
        pendingRestart?.cancel()
        pendingRestart = nil
        state.withLock { playback in
            for index in playback.voices.indices { playback.voices[index] = Voice() }
        }
        engine.stop()
        for (device, frames) in originalIOBufferFrames {
            setIOBuffer(frames: frames, on: device)
        }
        setRunning(false)
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
        state.withLock { playback -> Bool in
            guard playback.engineRunning, let buffers = playback.buffers else { return false }
            let table = isDown ? buffers.down : buffers.up
            let generic = isDown ? buffers.genericDown : buffers.genericUp
            guard let buffer = table[virtualKey] ?? generic,
                  let channels = buffer.floatChannelData,
                  buffer.frameLength > 1 else { return false }

            var slot = -1
            for index in playback.voices.indices where !playback.voices[index].active {
                slot = index
                break
            }
            if slot < 0 {
                // Everything is busy, so the oldest sound is the one to cut off.
                var oldest = playback.voices[0].sequence
                slot = 0
                for index in playback.voices.indices where playback.voices[index].sequence < oldest {
                    oldest = playback.voices[index].sequence
                    slot = index
                }
            }

            // Per-keystroke pitch and gain jitter. Without this a dozen samples
            // played back identically read as a loop rather than as a keyboard.
            let variance = playback.pitchVariance
            let rate = variance > 0 ? 1.0 + Double(Float.random(in: -variance...variance)) : 1.0

            playback.sequence &+= 1
            playback.voices[slot] = Voice(
                left: UnsafePointer(channels[0]),
                right: UnsafePointer(channels[buffer.format.channelCount > 1 ? 1 : 0]),
                frames: Int(buffer.frameLength),
                position: 0,
                rate: rate,
                gain: Float.random(in: 0.85...1.0),
                active: true,
                sequence: playback.sequence
            )
            return true
        }
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

        // Packs arrive at wildly different levels -- the quietest recording in
        // the set is about 24 dB below the loudest. Applied here, once, while
        // every buffer is still its own object: `fillGaps` hands the same buffer
        // to several keys, so scaling afterwards would scale some of them twice.
        if pack.recommendedVolume != 1 {
            for buffer in down.values { scale(buffer, by: pack.recommendedVolume) }
            for buffer in up.values { scale(buffer, by: pack.recommendedVolume) }
        }

        let loaded = LoadedBuffers(down: fillGaps(in: down), up: fillGaps(in: up))

        // Silence every voice before the samples it points at can go away, then
        // let the old pack go outside the lock so the audio thread is never
        // waiting on a few hundred deallocations.
        let retired = state.withLock { playback -> LoadedBuffers? in
            for index in playback.voices.indices { playback.voices[index] = Voice() }
            let previous = playback.buffers
            playback.buffers = loaded
            return previous
        }
        withExtendedLifetime(retired) {}

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

    /// Brings one pack up or down to the level of the rest of them, so that
    /// choosing between packs is a choice about how they sound rather than how
    /// loud they are. `tools/level_packs.py` works out the number.
    private func scale(_ buffer: AVAudioPCMBuffer, by factor: Float) {
        guard let data = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = data[channel]
            for frame in 0..<Int(buffer.frameLength) {
                samples[frame] *= factor
            }
        }
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

    /// The laptop's own speakers.
    ///
    /// This asks `OutputDevices`, which also checks that nothing is plugged into
    /// the headphone jack. The jack shares the built-in device, so when
    /// earphones are in it that device routes to the earphones and pinning to it
    /// would not keep the sound in the room the way the setting promises.
    private var builtInOutputDevice: AudioDeviceID? {
        OutputDevices.builtInSpeakers
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

    /// How many voices are sounding, for the device test.
    var playingVoiceCount: Int {
        state.withLock { $0.voices.reduce(0) { $0 + ($1.active ? 1 : 0) } }
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
