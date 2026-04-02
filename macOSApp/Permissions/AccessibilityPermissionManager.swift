import ApplicationServices
import Foundation

final class AccessibilityPermissionManager {
    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    func request(prompt: Bool) -> Bool {
        let options: CFDictionary = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
