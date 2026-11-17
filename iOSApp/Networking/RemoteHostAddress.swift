import Foundation

struct RemoteHostAddress: Equatable, Sendable {
    var host: String
    var port: Int

    enum ParseFailure: Equatable, Error, Sendable {
        case missingHost
        case invalidHost
        case invalidPort

        var message: String {
            switch self {
            case .missingHost:
                "Enter a Tailscale name or IP address."
            case .invalidHost:
                "That address is not a valid host."
            case .invalidPort:
                "Port must be between 1 and 65535."
            }
        }
    }

    static func parse(hostField: String, portField: String) -> Result<RemoteHostAddress, ParseFailure> {
        var raw = hostField.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty {
            return .failure(.missingHost)
        }
        if raw.contains(where: \.isWhitespace) {
            return .failure(.invalidHost)
        }

        let lowered = raw.lowercased()
        if lowered.hasPrefix("ws://") {
            raw.removeFirst(5)
        } else if lowered.hasPrefix("wss://") {
            raw.removeFirst(6)
        }
        if let slash = raw.firstIndex(of: "/") {
            raw = String(raw[..<slash])
        }
        while raw.hasSuffix(".") {
            raw.removeLast()
        }
        guard raw.isEmpty == false else { return .failure(.missingHost) }

        let host: String
        let embeddedPort: Int?
        if raw.hasPrefix("[") {
            guard let end = raw.firstIndex(of: "]") else { return .failure(.invalidHost) }
            let inside = String(raw[raw.index(after: raw.startIndex)..<end])
            let rest = raw[raw.index(after: end)...]
            if rest.isEmpty {
                embeddedPort = nil
            } else if rest.hasPrefix(":"), let port = portNumber(String(rest.dropFirst())) {
                embeddedPort = port
            } else {
                return .failure(.invalidHost)
            }
            host = inside
        } else if let colon = raw.lastIndex(of: ":"),
                  raw[..<colon].contains(":") == false,
                  let port = portNumber(String(raw[raw.index(after: colon)...])) {
            host = String(raw[..<colon])
            embeddedPort = port
        } else {
            host = raw
            embeddedPort = nil
        }

        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAcceptableHost(normalizedHost) else { return .failure(.invalidHost) }

        let port: Int
        if let embeddedPort {
            port = embeddedPort
        } else if let parsed = portNumber(portField.trimmingCharacters(in: .whitespacesAndNewlines)) {
            port = parsed
        } else {
            return .failure(.invalidPort)
        }

        return .success(RemoteHostAddress(host: normalizedHost, port: port))
    }

    static func webSocketURL(host: String, port: Int) -> URL? {
        guard (1...65_535).contains(port) else { return nil }
        if host.contains(":") {
            return URL(string: "ws://[\(host)]:\(port)")
        }
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        return components.url
    }

    private static func portNumber(_ value: String) -> Int? {
        guard let port = Int(value), (1...65_535).contains(port) else { return nil }
        return port
    }

    private static func isAcceptableHost(_ host: String) -> Bool {
        guard host.isEmpty == false else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:")
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        if host.contains(":") {
            return true
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.contains(where: \.isEmpty) == false else { return false }
        return true
    }
}

struct SavedRemoteHost: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var host: String
    var port: Int
    var lastUsedAt: Date

    var endpointText: String {
        host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

enum SavedRemoteHostStore {
    static let storageKey = "remoteKeyboard.savedRemoteHosts"
    static let limit = 12

    static func load() -> [SavedRemoteHost] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let hosts = try? JSONDecoder().decode([SavedRemoteHost].self, from: data) else {
            return []
        }
        return hosts.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    static func save(_ hosts: [SavedRemoteHost]) {
        let trimmed = Array(hosts.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit))
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
