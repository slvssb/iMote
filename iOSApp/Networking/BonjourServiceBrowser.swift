import Darwin
import Foundation

struct DiscoveredService: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let host: String
    let port: Int
}

final class BonjourServiceBrowser: NSObject, ObservableObject {
    @Published private(set) var services: [DiscoveredService] = []

    private let browser = NetServiceBrowser()
    private var resolving: [NetService] = []

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_rkbd._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        resolving.forEach { service in
            service.stop()
        }
        resolving.removeAll()
    }

    private func upsert(_ service: DiscoveredService) {
        if let idx = services.firstIndex(where: { $0.host == service.host && $0.port == service.port }) {
            services[idx] = service
            return
        }
        services.append(service)
        services.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension BonjourServiceBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0.name == service.name }
        resolving.removeAll { $0 == service }
    }
}

extension BonjourServiceBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { resolving.removeAll { $0 == sender } }
        let host = Self.connectableHost(from: sender)
        guard host.isEmpty == false, sender.port > 0 else { return }

        let discovered = DiscoveredService(name: sender.name, host: host, port: sender.port)
        upsert(discovered)
    }

    /// Prefer a resolved numeric address. `.local` names fail when multicast DNS does not,
    /// and an IPv6 literal is bracketed later by `RemoteHostAddress.webSocketURL`.
    private static func connectableHost(from service: NetService) -> String {
        if let address = numericAddress(from: service) {
            return address
        }
        return (service.hostName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private static func numericAddress(from service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        var ipv4: String?
        var ipv6: String?
        for data in addresses {
            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress, rawBuffer.count >= MemoryLayout<sockaddr>.size else { return }
                let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                if family == sa_family_t(AF_INET), rawBuffer.count >= MemoryLayout<sockaddr_in>.size {
                    var address = base.assumingMemoryBound(to: sockaddr_in.self).pointee
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &address.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                        ipv4 = Self.addressString(buffer)
                    }
                } else if family == sa_family_t(AF_INET6), rawBuffer.count >= MemoryLayout<sockaddr_in6>.size {
                    var address = base.assumingMemoryBound(to: sockaddr_in6.self).pointee
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    guard inet_ntop(AF_INET6, &address.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                        return
                    }
                    let text = Self.addressString(buffer)
                    if text.hasPrefix("fe80") == false, ipv6 == nil {
                        ipv6 = text
                    }
                }
            }
        }
        return ipv4 ?? ipv6
    }

    private static func addressString(_ buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 == sender }
    }
}
