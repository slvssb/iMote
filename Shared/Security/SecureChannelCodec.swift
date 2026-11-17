import CryptoKit
import Foundation

public enum SecureChannelDirection: UInt8, Sendable {
    case clientToHost = 1
    case hostToClient = 2
}

public enum SecureChannelKind: UInt8, Sendable {
    case control = 1
    case media = 2
}

public enum SecureChannelCodec {
    public static func associatedData(
        kind: SecureChannelKind,
        direction: SecureChannelDirection,
        counter: UInt64
    ) -> Data {
        var data = Data([kind.rawValue, direction.rawValue])
        var counterBE = counter.bigEndian
        withUnsafeBytes(of: &counterBE) { bytes in
            data.append(contentsOf: bytes)
        }
        return data
    }

    public static func seal(
        _ plaintext: Data,
        using key: SymmetricKey,
        kind: SecureChannelKind,
        direction: SecureChannelDirection,
        counter: UInt64
    ) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: key,
            authenticating: associatedData(kind: kind, direction: direction, counter: counter)
        )
        return box.combined
    }

    public static func open(
        combined: Data,
        using key: SymmetricKey,
        kind: SecureChannelKind,
        direction: SecureChannelDirection,
        counter: UInt64
    ) throws -> Data {
        let box = try ChaChaPoly.SealedBox(combined: combined)
        return try ChaChaPoly.open(
            box,
            using: key,
            authenticating: associatedData(kind: kind, direction: direction, counter: counter)
        )
    }
}
