import Foundation

final class PairingManager {
    struct PairingResult {
        let success: Bool
        let token: String?
        let reason: String?
    }

    private var currentCode: String
    private var expiresAt: Date

    private let codeValiditySeconds: TimeInterval
    private var activeTokens: [String: Date] = [:]
    private var trustedDeviceIDs: Set<String> = []
    private var trustedDeviceSigningKeys: [String: String] = [:]
    private let trustedDevicesKey = "remoteKeyboard.trustedDeviceIDs"
    private let trustedSigningKeysKey = "remoteKeyboard.trustedDeviceSigningKeys"
    private let lock = NSLock()

    init(codeValiditySeconds: TimeInterval = 60) {
        self.codeValiditySeconds = codeValiditySeconds
        let code = PairingManager.makeCode()
        self.currentCode = code
        self.expiresAt = Date().addingTimeInterval(codeValiditySeconds)
        loadTrustedDevices()
    }

    @discardableResult
    func regenerateCode() -> String {
        withLock {
            let next = PairingManager.makeCode()
            currentCode = next
            expiresAt = Date().addingTimeInterval(codeValiditySeconds)
            return next
        }
    }

    func snapshot() -> (code: String, expiresAt: Date) {
        withLock {
            ensureActiveCode()
            return (currentCode, expiresAt)
        }
    }

    func pair(code: String, deviceID: String?) -> PairingResult {
        withLock {
            if let deviceID, trustedDeviceIDs.contains(deviceID) {
                let token = UUID().uuidString.lowercased()
                activeTokens[token] = Date().addingTimeInterval(60 * 60)
                return PairingResult(success: true, token: token, reason: nil)
            }

            ensureActiveCode()
            guard code == currentCode else {
                return PairingResult(success: false, token: nil, reason: "Invalid pairing code.")
            }

            if let deviceID, deviceID.isEmpty == false {
                trustedDeviceIDs.insert(deviceID)
                persistTrustedDevices()
            }

            let token = UUID().uuidString.lowercased()
            activeTokens[token] = Date().addingTimeInterval(60 * 60)
            return PairingResult(success: true, token: token, reason: nil)
        }
    }

    func validate(token: String?) -> Bool {
        withLock {
            guard let token else { return false }
            guard let expiration = activeTokens[token] else { return false }
            if expiration < Date() {
                activeTokens.removeValue(forKey: token)
                return false
            }
            return true
        }
    }

    func revoke(token: String?) {
        withLock {
            guard let token else { return }
            activeTokens.removeValue(forKey: token)
        }
    }

    func trustedDevicesCount() -> Int {
        withLock {
            trustedDeviceIDs.count
        }
    }

    func clearTrustedDevices() {
        withLock {
            trustedDeviceIDs.removeAll()
            persistTrustedDevices()
        }
    }

    func removeTrustedDevice(deviceID: String) {
        withLock {
            trustedDeviceIDs.remove(deviceID)
            trustedDeviceSigningKeys.removeValue(forKey: deviceID)
            persistTrustedDevices()
            persistTrustedSigningKeys()
        }
    }

    func verifyOrPinSigningKey(deviceID: String, signingPublicKeyBase64: String) -> Bool {
        withLock {
            if let existing = trustedDeviceSigningKeys[deviceID] {
                return existing == signingPublicKeyBase64
            }
            trustedDeviceSigningKeys[deviceID] = signingPublicKeyBase64
            persistTrustedSigningKeys()
            return true
        }
    }

    func pinnedSigningKey(deviceID: String) -> String? {
        withLock {
            trustedDeviceSigningKeys[deviceID]
        }
    }

    private func ensureActiveCode() {
        if Date() > expiresAt {
            currentCode = PairingManager.makeCode()
            expiresAt = Date().addingTimeInterval(codeValiditySeconds)
        }
    }

    private func loadTrustedDevices() {
        let stored = UserDefaults.standard.stringArray(forKey: trustedDevicesKey) ?? []
        trustedDeviceIDs = Set(stored)
        trustedDeviceSigningKeys = UserDefaults.standard.dictionary(forKey: trustedSigningKeysKey) as? [String: String] ?? [:]
    }

    private func persistTrustedDevices() {
        UserDefaults.standard.set(Array(trustedDeviceIDs).sorted(), forKey: trustedDevicesKey)
    }

    private func persistTrustedSigningKeys() {
        UserDefaults.standard.set(trustedDeviceSigningKeys, forKey: trustedSigningKeysKey)
    }

    private static func makeCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    private func withLock<T>(_ block: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return block()
    }
}
