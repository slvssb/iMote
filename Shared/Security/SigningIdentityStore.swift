import CryptoKit
import Foundation
import Security

public struct StoredSigningKey: Sendable {
    public let key: Curve25519.Signing.PrivateKey
    public let didDiscardLegacyKey: Bool
}

public enum SigningIdentityStore {
    private static let service = "com.slvssb.imote.signing-key"

    /// Loads the this-device-only keychain key. A legacy UserDefaults value is deleted and never copied in.
    public static func loadOrCreate(account: String, legacyDefaultsKey: String) -> StoredSigningKey {
        let hadLegacyKey = UserDefaults.standard.object(forKey: legacyDefaultsKey) != nil
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)

        if let existing = read(account: account) {
            return StoredSigningKey(key: existing, didDiscardLegacyKey: hadLegacyKey)
        }

        let created = Curve25519.Signing.PrivateKey()
        write(account: account, keyData: created.rawRepresentation)
        return StoredSigningKey(key: created, didDiscardLegacyKey: hadLegacyKey)
    }

    private static func read(account: String) -> Curve25519.Signing.PrivateKey? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }

    private static func write(account: String, keyData: Data) {
        let deleteQuery = baseQuery(account: account)
        SecItemDelete(deleteQuery as CFDictionary)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}
