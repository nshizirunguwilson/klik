import ServiceManagement
import os

/// Launch at login, through the modern API -- no helper bundle, no login item
/// plist, macOS keeps the registration itself.
enum LoginItem {

    private static let log = Logger(subsystem: "com.klik.Klik", category: "login")

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// Registered, but switched off on the System Settings side -- which macOS
    /// does silently, including when the app moves. Without surfacing this the
    /// menu would show a happy toggle for something that will not actually run.
    static var needsApproval: Bool {
        status == .requiresApproval
    }

    static var explanation: String? {
        switch status {
        case .requiresApproval:
            return "Klik is registered but switched off in System Settings → General → Login Items."
        case .notFound:
            return "macOS cannot find this copy of Klik. Run ./build.sh install and try again."
        default:
            return nil
        }
    }

    /// Registration records the app's current location, so moving the app breaks
    /// it until this is switched off and on again.
    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        log.notice("Launch at login \(enabled ? "enabled" : "disabled")")
    }
}
