import SwiftUI

@main
enum KlikMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--devicetest") {
            exit(DeviceTest.run(packPath: arguments.dropFirst().first { !$0.hasPrefix("--") }))
        }
        if arguments.contains("--settings") {
            print(Settings.describeStored())
            exit(0)
        }
        if arguments.contains("--selftest") || arguments.contains("--demo") {
            let packPath = arguments.dropFirst().first { !$0.hasPrefix("--") }
            exit(SelfTest.run(audible: arguments.contains("--demo"), packPath: packPath))
        }
        KlikApp.main()
    }
}

struct KlikApp: App {
    /// The delegate is what stops macOS quitting a windowless background app
    /// whenever it decides the app looks idle. See `AppLifecycle`.
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView(state: state)
        } label: {
            Image(systemName: state.isEnabled ? "keyboard.fill" : "keyboard")
        }
        .menuBarExtraStyle(.window)
    }
}
