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
        if let idx = services.firstIndex(where: { $0.name == service.name && $0.port == service.port }) {
            services[idx] = service
            return
        }
        services.append(service)
        services.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func connectHost(for service: NetService) -> String? {
        if let address = routableAddress(in: service) {
            return address
        }
        let host = (service.hostName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host.isEmpty ? nil : host
    }

    private func routableAddress(in service: NetService) -> String? {
        guard let addresses = service.addresses else { return nil }
        var ipv4: String?
        var ipv6: String?
        for addressData in addresses {
            guard let parsed = Self.presentationAddress(addressData) else { continue }
            if parsed.family == sa_family_t(AF_INET), parsed.text != "127.0.0.1", ipv4 == nil {
                ipv4 = parsed.text
            } else if parsed.family == sa_family_t(AF_INET6),
                      parsed.text != "::1",
                      parsed.text.hasPrefix("fe80") == false,
                      ipv6 == nil {
                ipv6 = parsed.text
            }
        }
        return ipv4 ?? ipv6
    }

    private static func presentationAddress(_ data: Data) -> (family: sa_family_t, text: String)? {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress, rawBuffer.count >= MemoryLayout<sockaddr>.size else {
                return nil
            }
            let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
            if family == AF_INET, rawBuffer.count >= MemoryLayout<sockaddr_in>.size {
                var address = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return (family, String(cString: buffer))
            }
            if family == AF_INET6, rawBuffer.count >= MemoryLayout<sockaddr_in6>.size {
                var address = base.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                    return nil
                }
                return (family, String(cString: buffer))
            }
            return nil
        }
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
        guard sender.port > 0, let host = connectHost(for: sender) else { return }
        let discovered = DiscoveredService(name: sender.name, host: host, port: sender.port)
        upsert(discovered)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 == sender }
    }
}
