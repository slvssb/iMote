import Darwin
import Foundation

struct HostEndpoint: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, Hashable {
        case tailscaleName
        case tailscale
        case localName
        case lan
        case vpn
    }

    let kind: Kind
    let host: String
    let port: UInt16
    let interfaceName: String?

    var id: String { "\(kind.rawValue)|\(host.lowercased())|\(port)" }

    var pasteboardValue: String {
        if host.contains(":") {
            "[\(host)]:\(port)"
        } else {
            "\(host):\(port)"
        }
    }

    var title: String {
        switch kind {
        case .tailscaleName: "Tailscale name"
        case .tailscale: "Tailscale"
        case .localName: "Local name"
        case .lan: "LAN"
        case .vpn: "VPN"
        }
    }

    var systemImage: String {
        switch kind {
        case .tailscaleName, .tailscale: "point.3.connected.trianglepath.dotted"
        case .localName: "desktopcomputer"
        case .lan: "wifi"
        case .vpn: "network"
        }
    }

    var sortRank: Int {
        switch kind {
        case .tailscaleName: 0
        case .tailscale: host.contains(":") ? 2 : 1
        case .localName: 3
        case .lan: host.contains(":") ? 5 : 4
        case .vpn: 6
        }
    }
}

enum TailscalePresence: Equatable, Sendable {
    case online
    case notRunning
    case notDetected

    var guidance: String {
        switch self {
        case .online:
            "On the iPhone, choose Remote and enter the Tailscale name or 100.x address. Pairing and end-to-end encryption stay the same. Tailscale encrypts the network path."
        case .notRunning:
            "Tailscale is installed, but this Mac has no tailnet address yet. Connect Tailscale, then refresh. Same-Wi-Fi discovery still works."
        case .notDetected:
            "No Tailscale address is available. Same-Wi-Fi discovery still works. Start Tailscale on this Mac and the iPhone to connect remotely."
        }
    }
}

enum HostEndpointCatalog {
    struct Snapshot: Equatable, Sendable {
        var endpoints: [HostEndpoint]
        var tailscale: TailscalePresence

        var menuHighlights: [HostEndpoint] {
            var picked: [HostEndpoint] = []
            func append(kind: HostEndpoint.Kind, ipv4Only: Bool = false) {
                guard let match = endpoints.first(where: { endpoint in
                    endpoint.kind == kind && (ipv4Only == false || endpoint.host.contains(":") == false)
                }) else { return }
                picked.append(match)
            }
            append(kind: .tailscaleName)
            append(kind: .tailscale, ipv4Only: true)
            append(kind: .lan, ipv4Only: true)
            if picked.isEmpty {
                append(kind: .localName)
            }
            return picked
        }

        static let empty = Snapshot(endpoints: [], tailscale: .notDetected)
    }

    nonisolated static func snapshot(port: UInt16) -> Snapshot {
        let probe = tailscaleProbe()
        var endpoints: [HostEndpoint] = []
        var seenHosts = Set<String>()

        func append(_ endpoint: HostEndpoint) {
            let key = endpoint.host.lowercased()
            guard key.isEmpty == false, seenHosts.insert(key).inserted else { return }
            endpoints.append(endpoint)
        }

        if let dnsName = probe.dnsName {
            append(HostEndpoint(kind: .tailscaleName, host: dnsName, port: port, interfaceName: nil))
        }

        for address in numericAddresses() {
            let kind: HostEndpoint.Kind
            if isTailscaleIPv4(address.host) || isTailscaleIPv6(address.host) {
                kind = .tailscale
            } else if address.interfaceName.hasPrefix("utun") {
                kind = .vpn
            } else {
                kind = .lan
            }
            append(HostEndpoint(kind: kind, host: address.host, port: port, interfaceName: address.interfaceName))
        }

        for address in probe.addresses {
            let normalized = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
            guard isTailscaleIPv4(normalized) || isTailscaleIPv6(normalized) else { continue }
            append(HostEndpoint(kind: .tailscale, host: normalized, port: port, interfaceName: nil))
        }

        if let localName = localHostnameEndpoint(port: port) {
            append(localName)
        }

        endpoints.sort { lhs, rhs in
            if lhs.sortRank != rhs.sortRank {
                return lhs.sortRank < rhs.sortRank
            }
            return lhs.host.localizedCaseInsensitiveCompare(rhs.host) == .orderedAscending
        }

        let tailscale: TailscalePresence
        if endpoints.contains(where: { $0.kind == .tailscale || $0.kind == .tailscaleName }) {
            tailscale = .online
        } else if probe.cliFound {
            tailscale = .notRunning
        } else {
            tailscale = .notDetected
        }

        return Snapshot(endpoints: endpoints, tailscale: tailscale)
    }

    private struct InterfaceAddress {
        var interfaceName: String
        var host: String
        var family: Int32
    }

    private struct TailscaleProbe {
        var cliFound: Bool
        var dnsName: String?
        var addresses: [String]
    }

    private nonisolated static func localHostnameEndpoint(port: UInt16) -> HostEndpoint? {
        var name = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix(".") {
            name.removeLast()
        }
        let lower = name.lowercased()
        guard name.isEmpty == false, lower != "localhost", lower != "localhost.localdomain" else {
            return nil
        }
        if lower.hasSuffix(".ts.net") {
            return HostEndpoint(kind: .tailscaleName, host: name, port: port, interfaceName: nil)
        }
        if lower.contains(".") == false {
            name += ".local"
        }
        return HostEndpoint(kind: .localName, host: name, port: port, interfaceName: nil)
    }

    private nonisolated static func numericAddresses() -> [InterfaceAddress] {
        var results: [InterfaceAddress] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return [] }
        defer { freeifaddrs(pointer) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            cursor = current.pointee.ifa_next
            let flags = current.pointee.ifa_flags
            let isUp = (flags & UInt32(IFF_UP)) != 0
            let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            guard isUp, isLoopback == false, let addressPointer = current.pointee.ifa_addr else { continue }

            let family = Int32(addressPointer.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }

            let interfaceName = String(cString: current.pointee.ifa_name)
            guard ignoredInterface(interfaceName) == false else { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(addressPointer.pointee.sa_len)
            let resolution = getnameinfo(
                addressPointer,
                length,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard resolution == 0 else { continue }

            let raw = decodeCString(hostBuffer)
            let host = raw.split(separator: "%", maxSplits: 1).first.map(String.init) ?? raw
            guard isUsableHost(host, family: family) else { continue }
            if family == AF_INET6, isTailscaleIPv6(host) == false {
                continue
            }
            results.append(InterfaceAddress(interfaceName: interfaceName, host: host, family: family))
        }
        return results
    }

    private nonisolated static func decodeCString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private nonisolated static func ignoredInterface(_ name: String) -> Bool {
        let prefixes = ["awdl", "llw", "bridge", "gif", "stf", "ap", "pktap", "ipsec", "anpi", "lo", "p2p", "vmnet"]
        return prefixes.contains { name.hasPrefix($0) }
    }

    private nonisolated static func isUsableHost(_ host: String, family: Int32) -> Bool {
        if host.isEmpty || host == "0.0.0.0" || host == "::" || host == "::1" {
            return false
        }
        if family == AF_INET, host.hasPrefix("127.") || host.hasPrefix("169.254.") {
            return false
        }
        if family == AF_INET6, host.lowercased().hasPrefix("fe80:") {
            return false
        }
        return true
    }

    private nonisolated static func isTailscaleIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".")
        guard parts.count == 4, let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
        return first == 100 && (64...127).contains(second)
    }

    private nonisolated static func isTailscaleIPv6(_ host: String) -> Bool {
        host.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    private nonisolated static func tailscaleProbe() -> TailscaleProbe {
        guard let binary = tailscaleBinary() else {
            return TailscaleProbe(cliFound: false, dnsName: nil, addresses: [])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status", "--json"]
        process.qualityOfService = .utility
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let collected = LockedData()
        let reader = DispatchSemaphore(value: 0)
        DispatchQueue(label: "imote.tailscale.stdout").async {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            collected.set(data)
            reader.signal()
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return TailscaleProbe(cliFound: true, dnsName: nil, addresses: [])
        }

        if finished.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            _ = reader.wait(timeout: .now() + 0.5)
            return TailscaleProbe(cliFound: true, dnsName: nil, addresses: [])
        }
        _ = reader.wait(timeout: .now() + 1)

        guard process.terminationStatus == 0 else {
            return TailscaleProbe(cliFound: true, dnsName: nil, addresses: [])
        }
        return parseTailscaleStatus(collected.value())
    }

    private nonisolated static func parseTailscaleStatus(_ data: Data) -> TailscaleProbe {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfNode = object["Self"] as? [String: Any] else {
            return TailscaleProbe(cliFound: true, dnsName: nil, addresses: [])
        }

        var dnsName = (selfNode["DNSName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while dnsName.hasSuffix(".") {
            dnsName.removeLast()
        }
        let addresses = selfNode["TailscaleIPs"] as? [String] ?? []
        return TailscaleProbe(
            cliFound: true,
            dnsName: dnsName.isEmpty ? nil : dnsName,
            addresses: addresses
        )
    }

    private nonisolated static func tailscaleBinary() -> String? {
        let explicit = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            "/opt/homebrew/bin/tailscale",
            "/usr/local/bin/tailscale"
        ]
        if let found = explicit.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = "\(directory)/tailscale"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
