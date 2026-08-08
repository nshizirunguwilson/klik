import ApplicationServices
import AppKit

/// Klik cannot see a single keystroke without Accessibility permission, and the
/// permission can only be granted by the user in System Settings.
enum Accessibility {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt. Returns the current state, which will be false
    /// the first time -- the user still has to go and flip the switch.
    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
