import AppKit
import Combine
import Foundation
import os

/// Flags the event-tap thread reads on every keystroke. Kept behind a lock of
/// their own so the tap never has to touch main-actor state.
private struct TapOptions {
    var enabled = true
    var playOnKeyUp = true
    var ignoreRepeats = true
    /// Only true while the menu is open. Reporting every keystroke to the UI
    /// costs a hop to the main thread, so it stays off the rest of the time.
    var monitoring = false
}

@MainActor
final class AppState: ObservableObject {

    // MARK: Settings

    @Published var isEnabled = true {
        didSet { defaults.set(isEnabled, forKey: Keys.enabled); syncTapOptions() }
    }
    @Published var volume: Float = 0.8 {
        didSet { defaults.set(volume, forKey: Keys.volume); applyVolume() }
    }

    /// Drop to silence whenever anything is plugged in or paired -- AirPods,
    /// Bluetooth speakers, wired earphones, a USB headset.
    ///
    /// If you are listening through headphones, clicks coming out of the laptop
    /// speakers are just noise for the room, not feedback for you.
    @Published var silenceWithExternalAudio = true {
        didSet {
            defaults.set(silenceWithExternalAudio, forKey: Keys.silenceExternal)
            applyVolume()
        }
    }
    /// Go quiet while a microphone is live: calls, recordings, dictation.
    @Published var silenceWhenMicActive = true {
        didSet {
            defaults.set(silenceWhenMicActive, forKey: Keys.silenceMic)
            applyVolume()
        }
    }

    @Published var pitchVariance: Float = 0.04 {
        didSet { defaults.set(pitchVariance, forKey: Keys.pitch); audio.pitchVariance = pitchVariance }
    }
    @Published var playOnKeyUp = true {
        didSet { defaults.set(playOnKeyUp, forKey: Keys.keyUp); syncTapOptions() }
    }
    @Published var ignoreRepeats = true {
        didSet { defaults.set(ignoreRepeats, forKey: Keys.repeats); syncTapOptions() }
    }
    @Published var selectedPackID: String = "" {
        didSet {
            guard selectedPackID != oldValue else { return }
            defaults.set(selectedPackID, forKey: Keys.pack)
            // Switching is fast enough (about 10ms) to double as previewing:
            // pick a pack, hear it immediately, move on to the next.
            pendingDemo = !oldValue.isEmpty
            loadSelectedPack()
        }
    }

    /// Shrinking the render quantum is the biggest single latency win, but it is
    /// a device-wide setting, so it is exposed rather than forced.
    @Published var lowLatencyBuffer = true {
        didSet {
            guard lowLatencyBuffer != oldValue else { return }
            defaults.set(lowLatencyBuffer, forKey: Keys.lowLatency)
            audio.setLowLatency(lowLatencyBuffer)
            refreshLatency()
        }
    }

    /// A real keyboard is heard in the room, not inside your headphones. With
    /// this on, Klik keeps playing through the laptop speakers no matter where
    /// the rest of the system's audio goes.
    @Published var builtInOutput = true {
        didSet {
            guard builtInOutput != oldValue else { return }
            defaults.set(builtInOutput, forKey: Keys.builtInOutput)
            audio.setBuiltInOutput(builtInOutput)
            refreshLatency()
        }
    }

    /// Types a word to itself when Klik starts, as a sign of life. Useful as
    /// well as decorative: at login it confirms, out loud, that the app came up
    /// and the listener is armed before you have touched anything.
    @Published var welcomeEnabled = true {
        didSet { defaults.set(welcomeEnabled, forKey: Keys.welcome) }
    }
    @Published var welcomeText = "wilson" {
        didSet { defaults.set(welcomeText, forKey: Keys.welcomeText) }
    }

    @Published var launchAtLogin = false {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                try LoginItem.set(launchAtLogin)
                // Registering is not the same as being switched on: macOS can
                // register an item and leave it disabled, so report what it
                // actually did rather than what was asked for.
                status = launchAtLogin ? LoginItem.explanation : nil
            } catch {
                status = "Could not change launch at login: \(error.localizedDescription)"
                launchAtLogin = oldValue
            }
        }
    }

    // MARK: Observed state

    @Published private(set) var packs: [SoundPack] = []
    @Published private(set) var isTrusted = false
    @Published private(set) var status: String?
    @Published private(set) var latencyEstimate: Double = 0
    /// The last key the tap saw, shown in the menu so it is obvious whether
    /// Klik is receiving a key at all -- and separately, whether it had a sound.
    @Published private(set) var lastKey: String?
    @Published private(set) var hotKeyRegistered = false
    @Published private(set) var isOnBuiltInSpeakers = false
    @Published private(set) var tapIsAlive = false
    /// Name of the connected external listening device, if any.
    @Published private(set) var externalAudio: String?
    /// Name of a microphone currently recording, if any.
    @Published private(set) var activeMicrophone: String?

    /// True when external audio is holding Klik at zero.
    var isSilencedByExternalAudio: Bool {
        silenceWithExternalAudio && externalAudio != nil
    }

    var isSilencedByMicrophone: Bool {
        silenceWhenMicActive && activeMicrophone != nil
    }

    /// Everything that can be holding Klik quiet, in the order it is reported.
    /// Having one place that answers "why is it silent?" beats hunting through
    /// four separate switches.
    var silenceReason: String? {
        if !isTrusted { return "Waiting for permission" }
        if !tapIsAlive { return "Listener stopped, reconnecting" }
        if !isEnabled { return "Muted, press \(GlobalHotKey.muteDescription) to unmute" }
        if isSilencedByMicrophone { return "Silent, \(activeMicrophone ?? "microphone") in use" }
        if isSilencedByExternalAudio { return "Silent, \(externalAudio ?? "headphones") connected" }
        if volume < 0.01 { return "Silent, volume is at 0%" }
        return nil
    }

    /// What the volume actually is right now, which is not the slider's value
    /// when something is plugged in or a call is running.
    var effectiveVolume: Float {
        (isSilencedByExternalAudio || isSilencedByMicrophone) ? 0 : volume
    }

    // MARK: Internals

    private let audio = AudioEngine()
    private let keyTap = KeyTap()
    private let muteHotKey = GlobalHotKey()
    private let tapOptions = OSAllocatedUnfairLock(initialState: TapOptions())
    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "com.klik.Klik", category: "app")
    private var permissionTimer: Timer?
    private var watchdogTimer: Timer?
    private var pendingWelcome = false
    private var pendingDemo = false

    private enum Keys {
        static let enabled = "isEnabled"
        static let volume = "volume"
        static let pitch = "pitchVariance"
        static let keyUp = "playOnKeyUp"
        static let repeats = "ignoreRepeats"
        static let pack = "selectedPackID"
        static let lowLatency = "lowLatencyBuffer"
        static let builtInOutput = "builtInOutput"
        static let welcome = "welcomeEnabled"
        static let welcomeText = "welcomeText"
        static let silenceExternal = "silenceWithExternalAudio"
        static let silenceMic = "silenceWhenMicActive"
    }

    init() {
        restoreSettings()

        packs = SoundPackLoader.discover()
        if packs.isEmpty {
            status = "No sound packs found."
        } else if !packs.contains(where: { $0.id == selectedPackID }) {
            selectedPackID = packs[0].id
        }

        audio.pitchVariance = pitchVariance
        audio.start(lowLatencyBuffer: lowLatencyBuffer, builtInOutput: builtInOutput)

        startWatchingAudioDevices()
        applyVolume()

        wireTap()
        setUpHotKey()
        pendingWelcome = welcomeEnabled
        loadSelectedPack()

        launchAtLogin = LoginItem.isEnabled
        if LoginItem.needsApproval { status = LoginItem.explanation }

        isTrusted = Accessibility.isTrusted
        if isTrusted {
            startTap()
        } else {
            watchForPermission()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    private func restoreSettings() {
        if defaults.object(forKey: Keys.enabled) != nil { isEnabled = defaults.bool(forKey: Keys.enabled) }
        if defaults.object(forKey: Keys.volume) != nil { volume = defaults.float(forKey: Keys.volume) }
        if defaults.object(forKey: Keys.pitch) != nil { pitchVariance = defaults.float(forKey: Keys.pitch) }
        if defaults.object(forKey: Keys.keyUp) != nil { playOnKeyUp = defaults.bool(forKey: Keys.keyUp) }
        if defaults.object(forKey: Keys.repeats) != nil { ignoreRepeats = defaults.bool(forKey: Keys.repeats) }
        if defaults.object(forKey: Keys.lowLatency) != nil { lowLatencyBuffer = defaults.bool(forKey: Keys.lowLatency) }
        if defaults.object(forKey: Keys.builtInOutput) != nil { builtInOutput = defaults.bool(forKey: Keys.builtInOutput) }
        if defaults.object(forKey: Keys.welcome) != nil { welcomeEnabled = defaults.bool(forKey: Keys.welcome) }
        if defaults.object(forKey: Keys.silenceExternal) != nil { silenceWithExternalAudio = defaults.bool(forKey: Keys.silenceExternal) }
        if let saved = defaults.string(forKey: Keys.welcomeText) { welcomeText = saved }
        selectedPackID = defaults.string(forKey: Keys.pack) ?? ""
        syncTapOptions()
    }

    private func syncTapOptions() {
        let enabled = isEnabled
        let keyUp = playOnKeyUp
        let repeats = ignoreRepeats
        tapOptions.withLock {
            $0.enabled = enabled
            $0.playOnKeyUp = keyUp
            $0.ignoreRepeats = repeats
        }
    }

    /// The whole hot path: read the flags, play a buffer. No main-actor hop, no
    /// allocation, no dispatch -- unless the menu is open and watching.
    private func wireTap() {
        keyTap.onKey = { [audio, tapOptions, weak self] virtualKey, isDown, isRepeat in
            let options = tapOptions.withLock { $0 }

            var played = false
            let suppressed = (isRepeat && options.ignoreRepeats) || (!isDown && !options.playOnKeyUp)
            if options.enabled && !suppressed {
                played = audio.play(virtualKey: virtualKey, isDown: isDown)
            }

            guard options.monitoring else { return }
            let name = KeyCodes.displayName(for: virtualKey)
            let arrow = isDown ? "down" : "up"
            let outcome = played ? "played" : (options.enabled ? "no sound" : "muted")
            DispatchQueue.main.async {
                self?.lastKey = "\(name) \(arrow): \(outcome)"
            }
        }
    }

    func setMonitoring(_ on: Bool) {
        tapOptions.withLock { $0.monitoring = on }
        if !on { lastKey = nil }
    }

    private func setUpHotKey() {
        muteHotKey.onPress = { [weak self] in
            guard let self else { return }
            self.isEnabled.toggle()
        }
        hotKeyRegistered = muteHotKey.register(
            keyCode: GlobalHotKey.muteKeyCode,
            modifiers: GlobalHotKey.muteModifiers
        )
    }

    /// Pushes the real volume into the engine. The slider keeps the level you
    /// chose; external audio overrides it to zero without overwriting it, so
    /// unplugging restores exactly what you had.
    private func applyVolume() {
        audio.volume = effectiveVolume
    }

    private func startWatchingAudioDevices() {
        refreshExternalAudio()
        refreshMicrophone()
        OutputDevices.startMonitoring { [weak self] in
            Task { @MainActor in self?.refreshExternalAudio() }
        }
        Microphone.startMonitoring { [weak self] in
            Task { @MainActor in self?.refreshMicrophone() }
        }
    }

    func refreshExternalAudio() {
        let found = OutputDevices.externalOutput()
        guard found != externalAudio else { return }
        externalAudio = found
        applyVolume()
        log.notice("External audio: \(found ?? "none", privacy: .public)")
    }

    func refreshMicrophone() {
        let found = Microphone.activeInput()
        guard found != activeMicrophone else { return }
        activeMicrophone = found
        applyVolume()
        log.notice("Microphone in use: \(found ?? "none", privacy: .public)")
    }

    /// A short burst for auditioning a pack. Uses a mix of a small key, a large
    /// key and a modifier, because packs differ most on the big keys.
    func playDemo() {
        playSequence([0, 1, 36, 49, 56], gapRange: 55...95)
    }

    /// Types `welcomeText` to itself, at a human typing rhythm.
    ///
    /// The gaps are randomised because evenly spaced keystrokes sound like a
    /// machine rather than someone typing their own name.
    func playWelcome(afterDelay delay: Duration = .zero) {
        playSequence(KeyCodes.virtualKeys(for: welcomeText), gapRange: 60...125, delay: delay)
    }

    private func playSequence(
        _ keys: [UInt16],
        gapRange: ClosedRange<Int>,
        delay: Duration = .zero
    ) {
        guard isEnabled, !keys.isEmpty else { return }
        let engine = audio
        Task.detached(priority: .userInitiated) {
            try? await Task.sleep(for: delay)
            for key in keys {
                engine.play(virtualKey: key, isDown: true)
                try? await Task.sleep(for: .milliseconds(Int.random(in: 45...80)))
                engine.play(virtualKey: key, isDown: false)
                try? await Task.sleep(for: .milliseconds(Int.random(in: gapRange)))
            }
        }
    }

    /// Puts the output device's buffer size back before the app goes away.
    func shutdown() {
        audio.shutdown()
    }

    // MARK: Permission

    private func startTap() {
        guard keyTap.start() else {
            status = "Could not install the keyboard listener."
            return
        }
        status = nil
        tapIsAlive = true
        refreshLatency()
        startTapWatchdog()
    }

    /// Keeps the listener alive across sleep, screen lock and user switching.
    ///
    /// The wake notification covers the common case immediately; the timer is
    /// the backstop, because macOS can disable a tap without any notification at
    /// all and the app would otherwise sit there silently doing nothing.
    private func startTapWatchdog() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reviveTap() }
        }

        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reviveTap() }
        }
    }

    private func reviveTap() {
        guard isTrusted else { return }
        // Backstop for the device notifications, in case one is ever missed.
        refreshExternalAudio()
        refreshMicrophone()
        let alive = keyTap.ensureAlive()
        tapIsAlive = alive
        if !alive {
            status = "The keyboard listener stopped. Check Accessibility permission."
        } else if status?.hasPrefix("The keyboard listener") == true {
            status = nil
        }
    }

    func requestPermission() {
        Accessibility.requestTrust()
        Accessibility.openSettings()
        watchForPermission()
    }

    /// There is no notification for an Accessibility grant, so poll until it
    /// lands and then bring the tap up without a relaunch.
    private func watchForPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                guard Accessibility.isTrusted else { return }
                timer.invalidate()
                self.permissionTimer = nil
                self.isTrusted = true
                self.startTap()
            }
        }
    }

    // MARK: Packs

    var selectedPack: SoundPack? {
        packs.first { $0.id == selectedPackID }
    }

    private func loadSelectedPack() {
        guard let pack = selectedPack else { return }
        let engine = audio
        Task.detached(priority: .userInitiated) {
            do {
                try engine.load(pack: pack)
                await MainActor.run {
                    self.status = nil
                    // Only after the first pack is in memory -- a welcome played
                    // before that would be silent.
                    if self.pendingWelcome {
                        self.pendingWelcome = false
                        self.playWelcome(afterDelay: .milliseconds(700))
                    } else if self.pendingDemo {
                        self.pendingDemo = false
                        self.playDemo()
                    }
                }
            } catch {
                await MainActor.run {
                    self.status = error.localizedDescription
                }
            }
        }
    }

    func reloadPacks() {
        packs = SoundPackLoader.discover()
        if !packs.contains(where: { $0.id == selectedPackID }), let first = packs.first {
            selectedPackID = first.id
        } else {
            loadSelectedPack()
        }
    }

    func revealUserPacksFolder() {
        let url = SoundPackLoader.userPacksDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    func refreshLatency() {
        latencyEstimate = audio.estimatedLatencyMilliseconds
        isOnBuiltInSpeakers = audio.isUsingBuiltInOutput
    }

    /// One line covering the three things worth knowing at a glance: is the
    /// listener alive, how fast is it, and where is the sound going.
    var statusLine: String {
        if let reason = silenceReason { return reason }
        let route = isOnBuiltInSpeakers ? "speakers" : "system output"
        return String(format: "Listening · ~%.1f ms · %@", latencyEstimate, route)
    }
}
