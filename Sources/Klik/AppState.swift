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

    /// Each of these mirrors one field of `Settings`. Changing one writes the
    /// whole snapshot back out through `persist()`, so no setting can be saved
    /// by one code path and forgotten by another.
    ///
    /// `restoring` is what makes that safe during launch: the properties are
    /// filled in from disk before anything is wired up, and writing what we just
    /// read would be pointless at best.
    private var restoring = false

    @Published var isEnabled = true {
        didSet { persist(); syncTapOptions() }
    }
    @Published var volume: Float = 0.8 {
        didSet { persist(); applyVolume() }
    }

    /// Drop to silence whenever anything is plugged in or paired -- AirPods,
    /// Bluetooth speakers, wired earphones, a USB headset.
    ///
    /// If you are listening through headphones, clicks coming out of the laptop
    /// speakers are just noise for the room, not feedback for you.
    @Published var silenceWithExternalAudio = true {
        didSet { persist(); applyVolume() }
    }
    /// Go quiet while a microphone is live: calls, recordings, dictation.
    @Published var silenceWhenMicActive = true {
        didSet { persist(); applyVolume() }
    }

    @Published var pitchVariance: Float = 0.04 {
        didSet { persist(); audio.pitchVariance = pitchVariance }
    }
    @Published var playOnKeyUp = true {
        didSet { persist(); syncTapOptions() }
    }
    @Published var ignoreRepeats = true {
        didSet { persist(); syncTapOptions() }
    }
    @Published var selectedPackID: String = "" {
        didSet {
            guard selectedPackID != oldValue else { return }
            // Written and flushed on the spot rather than left in the cache.
            // This is the one setting whose loss is unmistakable, and it was
            // being lost every time macOS terminated the app on its own.
            persist(immediately: true)
            guard !restoring else { return }
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
            persist()
            guard !restoring else { return }
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
            persist()
            guard !restoring else { return }
            audio.setBuiltInOutput(builtInOutput)
            refreshLatency()
        }
    }

    /// Types a word to itself when Klik starts, as a sign of life. Useful as
    /// well as decorative: at login it confirms, out loud, that the app came up
    /// and the listener is armed before you have touched anything.
    @Published var welcomeEnabled = true {
        didSet { persist() }
    }
    @Published var welcomeText = "wilson" {
        didSet { persist() }
    }

    @Published var launchAtLogin = false {
        didSet {
            guard launchAtLogin != oldValue, !restoring else { return }
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
    /// Set when sound output itself has stopped working, as opposed to being
    /// deliberately held quiet.
    @Published private(set) var audioProblem: String?

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
        if let audioProblem { return audioProblem }
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
    private let log = Logger(subsystem: "com.klik.Klik", category: "app")
    private var permissionTimer: Timer?
    private var watchdogTimer: Timer?
    private var flushTimer: Timer?
    private var pendingWelcome = false
    private var pendingDemo = false

    init() {
        restoreSettings()

        packs = SoundPackLoader.discover()
        if packs.isEmpty {
            status = "No sound packs found."
        } else if !packs.contains(where: { $0.id == selectedPackID }) {
            // The saved pack is gone, or nothing has ever been saved. Whichever
            // it is, the replacement has to be written down -- otherwise this
            // same fallback runs again at every launch and the choice the user
            // makes afterwards has nothing to overwrite.
            log.notice("Saved pack \(self.selectedPackID, privacy: .public) not found, falling back")
            // Still restoring: the single `loadSelectedPack()` below does the
            // loading, and a fallback is not a choice the user just made, so it
            // should not play the preview burst that picking a pack does. The
            // write is covered by the `persist` at the end of init.
            restoring = true
            selectedPackID = packs[0].id
            restoring = false
        }

        audio.pitchVariance = pitchVariance
        audio.onOutputProblem = { [weak self] problem in
            Task { @MainActor in self?.audioProblem = problem }
        }
        audio.start(lowLatencyBuffer: lowLatencyBuffer, builtInOutput: builtInOutput)

        startWatchingAudioDevices()
        applyVolume()

        wireTap()
        setUpHotKey()
        pendingWelcome = welcomeEnabled
        loadSelectedPack()

        restoring = true
        launchAtLogin = LoginItem.isEnabled
        restoring = false
        if LoginItem.needsApproval { status = LoginItem.explanation }

        isTrusted = Accessibility.isTrusted
        if isTrusted {
            startTap()
        } else {
            watchForPermission()
        }

        // Whatever the launch settled on -- the restored pack, or the fallback --
        // reaches disk before the first keystroke, rather than whenever the app
        // next happens to be asked to save something.
        persist(immediately: true)

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    // MARK: Saved settings

    /// Fills every published property from disk without setting any of the
    /// machinery in motion. Nothing is wired up yet at this point, and the
    /// `didSet` side effects would be either useless or actively wrong.
    private func restoreSettings() {
        let saved = Settings.load()
        restoring = true
        isEnabled = saved.isEnabled
        volume = saved.volume
        pitchVariance = saved.pitchVariance
        playOnKeyUp = saved.playOnKeyUp
        ignoreRepeats = saved.ignoreRepeats
        lowLatencyBuffer = saved.lowLatencyBuffer
        builtInOutput = saved.builtInOutput
        welcomeEnabled = saved.welcomeEnabled
        welcomeText = saved.welcomeText
        silenceWithExternalAudio = saved.silenceWithExternalAudio
        silenceWhenMicActive = saved.silenceWhenMicActive
        selectedPackID = saved.selectedPackID
        restoring = false
        syncTapOptions()
    }

    /// The current state of every setting, ready to be written.
    private var currentSettings: Settings {
        Settings(
            isEnabled: isEnabled,
            volume: volume,
            pitchVariance: pitchVariance,
            playOnKeyUp: playOnKeyUp,
            ignoreRepeats: ignoreRepeats,
            selectedPackID: selectedPackID,
            lowLatencyBuffer: lowLatencyBuffer,
            builtInOutput: builtInOutput,
            welcomeEnabled: welcomeEnabled,
            welcomeText: welcomeText,
            silenceWithExternalAudio: silenceWithExternalAudio,
            silenceWhenMicActive: silenceWhenMicActive
        )
    }

    /// Saves everything, every time anything changes.
    ///
    /// The write itself goes into an in-process cache and costs nothing, so
    /// there is no reason to be clever about which setting moved. Pushing that
    /// cache out to the preferences daemon does cost something, and a slider
    /// being dragged would ask for it a hundred times a second, so that part is
    /// either coalesced into a moment's quiet or -- for a change worth never
    /// losing -- done on the spot.
    private func persist(immediately: Bool = false) {
        guard !restoring else { return }
        currentSettings.save()

        flushTimer?.invalidate()
        flushTimer = nil
        if immediately {
            Settings.flush()
            return
        }
        flushTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
            Settings.flush()
        }
    }

    /// Called when the menu closes, and on the way out. Anything still sitting
    /// in the cache goes to disk now.
    func flushSettings() {
        flushTimer?.invalidate()
        flushTimer = nil
        Settings.flush()
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

    /// Puts the output device's buffer size back before the app goes away, and
    /// makes sure nothing the user changed in the last half second is still
    /// sitting in a cache that dies with the process.
    func shutdown() {
        flushSettings()
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
        audio.verifyHealth()
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
