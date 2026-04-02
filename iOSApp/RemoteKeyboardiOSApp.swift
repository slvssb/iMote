import SwiftUI

@main
struct RemoteKeyboardiOSApp: App {
    @StateObject private var viewModel = IOSKeyboardViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onAppear {
                    viewModel.start()
                }
        }
    }
}
