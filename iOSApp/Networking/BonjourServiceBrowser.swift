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
        if let host = service.hostName {
            let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            services.removeAll { $0.host == normalizedHost }
        }
        resolving.removeAll { $0 == service }
    }
}

extension BonjourServiceBrowser: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let host = (sender.hostName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !host.isEmpty, sender.port > 0 else { return }

        let discovered = DiscoveredService(name: sender.name, host: host, port: sender.port)
        upsert(discovered)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 == sender }
    }
}
