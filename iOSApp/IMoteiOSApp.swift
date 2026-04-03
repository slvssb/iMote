import SwiftUI
import UIKit

final class IMoteAppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

enum IMoteOrientationController {
    static func setImmersiveModeEnabled(_ isEnabled: Bool) {
        let mask: UIInterfaceOrientationMask = isEnabled ? [.landscapeLeft, .landscapeRight] : .portrait
        IMoteAppDelegate.orientationLock = mask

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        if #available(iOS 16.0, *) {
            let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            scene.requestGeometryUpdate(preferences) { _ in }
        } else {
            let orientation: UIInterfaceOrientation = isEnabled ? .landscapeRight : .portrait
            UIDevice.current.setValue(orientation.rawValue, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
        }
    }
}

@main
struct IMoteiOSApp: App {
    @UIApplicationDelegateAdaptor(IMoteAppDelegate.self) private var appDelegate
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
