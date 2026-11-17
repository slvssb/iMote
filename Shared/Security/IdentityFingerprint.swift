import CryptoKit
import Foundation

public enum IdentityFingerprint {
    /// Short display form of a Curve25519 signing public key. Both apps use this so a first pair can be compared by eye.
    public static func displayString(forPublicKey rawKey: Data) -> String {
        let digest = Array(SHA256.hash(data: rawKey).prefix(8))
        let hex = digest.map { String(format: "%02X", $0) }
        return stride(from: 0, to: hex.count, by: 2).map { index in
            hex[index] + hex[index + 1]
        }.joined(separator: " ")
    }
}
