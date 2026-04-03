import SwiftUI

@main
struct IMoteiOSApp: App {
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
