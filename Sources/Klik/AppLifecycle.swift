import AppKit
import Foundation
import os

/// Keeps Klik running, and leaves a note behind if it ever does not.
///
/// Klik disappearing on its own had two causes, and neither of them left
/// anything on screen to notice.
///
/// The first was an Objective-C exception raised out of AVFoundation. Swift
/// cannot catch those, so the process aborts where it stands. That one is fixed
/// where it was raised, in `AudioEngine`; the handler here is so that any
/// *future* exception is written to the log with its stack instead of vanishing.
///
/// The second was macOS itself. An `LSUIElement` app with no windows is a prime
/// candidate for automatic termination: the system decides the app is idle,
/// quits it, and files no report because nothing went wrong as far as it is
/// concerned. The Info.plist says Klik does not support that; these assertions
/// say so again at runtime, which is the part that actually holds when some
/// framework enables it on the app's behalf.
@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {

    private static let log = Logger(subsystem: "com.klik.Klik", category: "lifecycle")

    /// Held for the life of the process. Releasing them is what would let macOS
    /// terminate Klik quietly, so nothing ever releases them.
    private var terminationAssertions = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        installExceptionLogger()
        holdProcessOpen()
        Self.log.notice("Klik launched, build \(Self.version, privacy: .public)")
    }

    /// A menu bar app has no windows to close, so this should never be asked --
    /// but if AppKit ever does ask, the answer is no.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.log.notice("Klik is terminating")
        Settings.flush()
    }

    private func holdProcessOpen() {
        guard !terminationAssertions else { return }
        terminationAssertions = true
        let info = ProcessInfo.processInfo
        // Automatic termination: the system quitting an idle app to save
        // resources. Sudden termination: the system killing it without running
        // `applicationWillTerminate`, which is also how unwritten preferences
        // were being lost.
        info.disableAutomaticTermination("Klik listens for keystrokes in the background")
        info.disableSuddenTermination()
        // Read back rather than assumed. `NSSupportsAutomaticTermination` in the
        // Info.plist is the authoritative opt-out and this is where it shows up,
        // so a build that lost the key, or a framework that turned it back on,
        // says so in the log instead of being discovered months later.
        Self.log.notice("Sudden termination disabled; automatic termination support: \(info.automaticTerminationSupportEnabled)")
    }

    /// Writes the exception and its stack to the unified log before the process
    /// goes down, so "it just disappeared" becomes something readable:
    ///
    ///     log show --last 1d --predicate 'subsystem == "com.klik.Klik"'
    private func installExceptionLogger() {
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "no reason given"
            let stack = exception.callStackSymbols.joined(separator: "\n")
            AppLifecycle.log.fault("Uncaught exception \(name, privacy: .public): \(reason, privacy: .public)\n\(stack, privacy: .public)")
        }
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
