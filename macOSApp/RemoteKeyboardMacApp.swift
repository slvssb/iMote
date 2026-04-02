import SwiftUI

@main
struct RemoteKeyboardMacApp: App {
    @StateObject private var appState = MacAppState()

    var body: some Scene {
        MenuBarExtra("iPhone Keyboard Host", systemImage: "keyboard") {
            MenuBarMenuView(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            VStack {
                Text("iPhone Keyboard Host runs in the menu bar.")
                    .padding()
            }
            .frame(width: 320, height: 100)
        }
    }
}
