import Foundation
import os

/// Everything Klik remembers between launches, as one value.
///
/// It used to be twelve independent `didSet` blocks, each poking a single key
/// into `UserDefaults`. That had two failure modes and both of them bit.
///
///  1. A setting could simply be forgotten. "Silence during calls" was written
///     but never read back, so it reset to on at every launch and no amount of
///     turning it off would stick.
///  2. `UserDefaults` writes go into an in-process cache first and reach the
///     preferences daemon a moment later. When macOS terminated Klik on its own
///     -- which it was doing, see `AppLifecycle` -- anything still in that cache
///     was lost. Picking a sound pack and getting the old one back after a
///     restart is exactly what that looks like.
///
/// So: one struct, written and read as a whole, with an explicit flush. If a
/// field exists here it is saved and restored, and there is no third place to
/// forget to update.
struct Settings: Equatable {

    var isEnabled = true
    var volume: Float = 0.8
    var pitchVariance: Float = 0.04
    var playOnKeyUp = true
    var ignoreRepeats = true
    var selectedPackID = ""
    var lowLatencyBuffer = true
    var builtInOutput = true
    var welcomeEnabled = true
    var welcomeText = "wilson"
    var silenceWithExternalAudio = true
    var silenceWhenMicActive = true

    /// The stored names. They match what earlier versions wrote, so upgrading
    /// keeps the settings you already have.
    private enum Key {
        static let isEnabled = "isEnabled"
        static let volume = "volume"
        static let pitchVariance = "pitchVariance"
        static let playOnKeyUp = "playOnKeyUp"
        static let ignoreRepeats = "ignoreRepeats"
        static let selectedPackID = "selectedPackID"
        static let lowLatencyBuffer = "lowLatencyBuffer"
        static let builtInOutput = "builtInOutput"
        static let welcomeEnabled = "welcomeEnabled"
        static let welcomeText = "welcomeText"
        static let silenceWithExternalAudio = "silenceWithExternalAudio"
        static let silenceWhenMicActive = "silenceWhenMicActive"
    }

    private static let log = Logger(subsystem: "com.klik.Klik", category: "settings")
    private static let defaults = UserDefaults.standard

    // MARK: - Reading

    /// Reads what is on disk, leaving anything that was never saved at its
    /// default. Missing is not the same as false, which is why every lookup
    /// checks for the key first.
    static func load() -> Settings {
        var settings = Settings()
        let store = defaults

        if store.object(forKey: Key.isEnabled) != nil { settings.isEnabled = store.bool(forKey: Key.isEnabled) }
        if store.object(forKey: Key.volume) != nil { settings.volume = store.float(forKey: Key.volume) }
        if store.object(forKey: Key.pitchVariance) != nil { settings.pitchVariance = store.float(forKey: Key.pitchVariance) }
        if store.object(forKey: Key.playOnKeyUp) != nil { settings.playOnKeyUp = store.bool(forKey: Key.playOnKeyUp) }
        if store.object(forKey: Key.ignoreRepeats) != nil { settings.ignoreRepeats = store.bool(forKey: Key.ignoreRepeats) }
        if store.object(forKey: Key.lowLatencyBuffer) != nil { settings.lowLatencyBuffer = store.bool(forKey: Key.lowLatencyBuffer) }
        if store.object(forKey: Key.builtInOutput) != nil { settings.builtInOutput = store.bool(forKey: Key.builtInOutput) }
        if store.object(forKey: Key.welcomeEnabled) != nil { settings.welcomeEnabled = store.bool(forKey: Key.welcomeEnabled) }
        if store.object(forKey: Key.silenceWithExternalAudio) != nil { settings.silenceWithExternalAudio = store.bool(forKey: Key.silenceWithExternalAudio) }
        if store.object(forKey: Key.silenceWhenMicActive) != nil { settings.silenceWhenMicActive = store.bool(forKey: Key.silenceWhenMicActive) }
        if let text = store.string(forKey: Key.welcomeText) { settings.welcomeText = text }
        if let pack = store.string(forKey: Key.selectedPackID) { settings.selectedPackID = pack }

        // Values from an older build, or from a hand-edited plist, should not be
        // able to leave the app in a state its own UI cannot express.
        settings.volume = min(max(settings.volume, 0), 1)
        settings.pitchVariance = min(max(settings.pitchVariance, 0), 0.12)

        log.notice("Restored settings, pack \(settings.selectedPackID, privacy: .public)")
        return settings
    }

    // MARK: - Writing

    /// Writes every field. Cheap, and called whenever anything changes -- a
    /// whole-snapshot write cannot leave one setting behind the way twelve
    /// separate writes could.
    func save() {
        let store = Self.defaults
        store.set(isEnabled, forKey: Key.isEnabled)
        store.set(volume, forKey: Key.volume)
        store.set(pitchVariance, forKey: Key.pitchVariance)
        store.set(playOnKeyUp, forKey: Key.playOnKeyUp)
        store.set(ignoreRepeats, forKey: Key.ignoreRepeats)
        store.set(selectedPackID, forKey: Key.selectedPackID)
        store.set(lowLatencyBuffer, forKey: Key.lowLatencyBuffer)
        store.set(builtInOutput, forKey: Key.builtInOutput)
        store.set(welcomeEnabled, forKey: Key.welcomeEnabled)
        store.set(welcomeText, forKey: Key.welcomeText)
        store.set(silenceWithExternalAudio, forKey: Key.silenceWithExternalAudio)
        store.set(silenceWhenMicActive, forKey: Key.silenceWhenMicActive)
    }

    /// Pushes the cached writes out to the preferences daemon now rather than
    /// whenever it next gets round to it.
    ///
    /// This is the line that makes a sound pack survive the app being killed.
    /// Without it the choice lives in this process's memory, and a process that
    /// is killed takes it along.
    static func flush() {
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
    }

    /// Saves and flushes in one step, for the changes worth not losing: which
    /// pack is selected, and whatever state the app is in as it quits.
    func saveNow() {
        save()
        Self.flush()
    }

    /// Reads the settings straight back out of the store, for `--settings`.
    /// Answers "what would the next launch actually see?" without guessing.
    static func describeStored() -> String {
        let settings = load()
        return """
        Klik settings (\(defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.klik.Klik")?.count ?? 0) keys stored)

          sound pack .................. \(settings.selectedPackID.isEmpty ? "(none saved)" : settings.selectedPackID)
          enabled ..................... \(settings.isEnabled)
          volume ...................... \(Int(settings.volume * 100))%
          variation ................... \(String(format: "%.2f", settings.pitchVariance))
          sound on key release ........ \(settings.playOnKeyUp)
          ignore key repeats .......... \(settings.ignoreRepeats)
          silence during calls ........ \(settings.silenceWhenMicActive)
          silence with headphones ..... \(settings.silenceWithExternalAudio)
          always use built-in speakers  \(settings.builtInOutput)
          low-latency buffer .......... \(settings.lowLatencyBuffer)
          greeting .................... \(settings.welcomeEnabled ? "\"\(settings.welcomeText)\"" : "off")
        """
    }
}
