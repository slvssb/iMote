import Foundation

struct TrustedDeviceRecord: Identifiable, Equatable, Sendable {
    var id: String
    var name: String?

    var displayName: String {
        if let name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false {
                return trimmed
            }
        }
        let suffix = id.prefix(8)
        return suffix.isEmpty ? "iPhone" : "iPhone \(suffix)"
    }
}

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
    private var trustedDeviceNames: [String: String] = [:]
    private var provisionalDeviceIDs: [String: String] = [:]
    private var failedAttempts = 0
    private var nextAttemptAllowedAt = Date.distantPast
    private let trustedDevicesKey = "remoteKeyboard.trustedDeviceIDs"
    private let trustedSigningKeysKey = "remoteKeyboard.trustedDeviceSigningKeys"
    private let trustedDeviceNamesKey = "remoteKeyboard.trustedDeviceNames"
    private let lock = NSLock()
    private let maxFailuresBeforeCodeRotation = 5

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
            failedAttempts = 0
            nextAttemptAllowedAt = .distantPast
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
            let now = Date()
            if now < nextAttemptAllowedAt {
                let wait = max(1, Int(ceil(nextAttemptAllowedAt.timeIntervalSince(now))))
                return PairingResult(
                    success: false,
                    token: nil,
                    reason: "Too many pairing attempts. Wait \(wait)s and use the code shown on the Mac."
                )
            }

            let normalizedID = deviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasDeviceID = normalizedID?.isEmpty == false
            if hasDeviceID,
               let normalizedID,
               trustedDeviceIDs.contains(normalizedID),
               trustedDeviceSigningKeys[normalizedID] != nil {
                return issueToken(deviceID: normalizedID)
            }

            ensureActiveCode()
            guard code == currentCode else {
                registerFailure(now: now)
                return PairingResult(success: false, token: nil, reason: "Invalid pairing code.")
            }

            // A matching code is single-use. The device id is not trusted until the handshake signature verifies.
            currentCode = PairingManager.makeCode()
            expiresAt = now.addingTimeInterval(codeValiditySeconds)
            failedAttempts = 0
            nextAttemptAllowedAt = .distantPast
            return issueToken(deviceID: hasDeviceID ? normalizedID : nil)
        }
    }

    func provisionalDeviceID(for token: String) -> String? {
        withLock {
            provisionalDeviceIDs[token]
        }
    }

    func confirmTrustedDeviceAfterHandshake(token: String, deviceID: String) -> Bool {
        withLock {
            let normalizedID = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedID.isEmpty == false else { return false }
            guard activeTokens[token] != nil else { return false }
            if let bound = provisionalDeviceIDs[token], bound != normalizedID {
                return false
            }
            trustedDeviceIDs.insert(normalizedID)
            provisionalDeviceIDs.removeValue(forKey: token)
            persistTrustedDevices()
            return true
        }
    }

    func validate(token: String?) -> Bool {
        withLock {
            guard let token else { return false }
            guard let expiration = activeTokens[token] else { return false }
            if expiration < Date() {
                activeTokens.removeValue(forKey: token)
                provisionalDeviceIDs.removeValue(forKey: token)
                return false
            }
            return true
        }
    }

    func revoke(token: String?) {
        withLock {
            guard let token else { return }
            activeTokens.removeValue(forKey: token)
            provisionalDeviceIDs.removeValue(forKey: token)
        }
    }

    func trustedDevicesCount() -> Int {
        withLock {
            trustedDeviceIDs.count
        }
    }

    func trustedDevices() -> [TrustedDeviceRecord] {
        withLock {
            trustedDeviceIDs.map { id in
                TrustedDeviceRecord(id: id, name: trustedDeviceNames[id])
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    func noteTrustedDevice(deviceID: String, name: String?) {
        withLock {
            guard deviceID.isEmpty == false, trustedDeviceIDs.contains(deviceID) else { return }
            let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard trimmed.isEmpty == false else { return }
            guard trustedDeviceNames[deviceID] != trimmed else { return }
            trustedDeviceNames[deviceID] = trimmed
            persistTrustedDeviceNames()
        }
    }

    func clearTrustedDevices() {
        withLock {
            trustedDeviceIDs.removeAll()
            trustedDeviceNames.removeAll()
            persistTrustedDevices()
            persistTrustedDeviceNames()
        }
    }

    func removeTrustedDevice(deviceID: String) {
        withLock {
            trustedDeviceIDs.remove(deviceID)
            trustedDeviceSigningKeys.removeValue(forKey: deviceID)
            trustedDeviceNames.removeValue(forKey: deviceID)
            persistTrustedDevices()
            persistTrustedSigningKeys()
            persistTrustedDeviceNames()
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

    private func issueToken(deviceID: String?) -> PairingResult {
        let token = UUID().uuidString.lowercased()
        activeTokens[token] = Date().addingTimeInterval(60 * 60)
        if let deviceID, deviceID.isEmpty == false {
            provisionalDeviceIDs[token] = deviceID
        }
        return PairingResult(success: true, token: token, reason: nil)
    }

    private func registerFailure(now: Date) {
        failedAttempts += 1
        let exponent = min(failedAttempts, 5)
        let delay = min(pow(2.0, Double(exponent - 1)), 30)
        nextAttemptAllowedAt = now.addingTimeInterval(delay)
        if failedAttempts >= maxFailuresBeforeCodeRotation {
            currentCode = PairingManager.makeCode()
            expiresAt = now.addingTimeInterval(codeValiditySeconds)
            failedAttempts = 0
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
        let storedNames = UserDefaults.standard.dictionary(forKey: trustedDeviceNamesKey) as? [String: String] ?? [:]
        // An id saved before a verified handshake cannot skip the code.
        let unverified = trustedDeviceIDs.filter { trustedDeviceSigningKeys[$0] == nil }
        if unverified.isEmpty == false {
            trustedDeviceIDs.subtract(unverified)
            persistTrustedDevices()
        }
        trustedDeviceNames = storedNames.filter { trustedDeviceIDs.contains($0.key) }
        if trustedDeviceNames.count != storedNames.count {
            persistTrustedDeviceNames()
        }
    }

    private func persistTrustedDevices() {
        UserDefaults.standard.set(Array(trustedDeviceIDs).sorted(), forKey: trustedDevicesKey)
    }

    private func persistTrustedSigningKeys() {
        UserDefaults.standard.set(trustedDeviceSigningKeys, forKey: trustedSigningKeysKey)
    }

    private func persistTrustedDeviceNames() {
        UserDefaults.standard.set(trustedDeviceNames, forKey: trustedDeviceNamesKey)
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
