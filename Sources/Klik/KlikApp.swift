import SwiftUI

@main
enum KlikMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest") || arguments.contains("--demo") {
            let packPath = arguments.dropFirst().first { !$0.hasPrefix("--") }
            exit(SelfTest.run(audible: arguments.contains("--demo"), packPath: packPath))
        }
        KlikApp.main()
    }
}

struct KlikApp: App {
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
