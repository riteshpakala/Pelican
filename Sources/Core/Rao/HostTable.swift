import Darwin
import Foundation

/// Forward-resolves the hostnames in an app profile so connections to their addresses can be
/// recognised — reverse DNS on a CDN address rarely names the service. Addresses accumulate
/// over the day (CDNs rotate them). These lookups are Pelican's own DNS traffic.
actor HostTable {
    private let hostnames: [String]
    private var ipToHosts: [String: Set<String>] = [:]
    private var lastRefresh: Date?

    init(hostnames: [String]) {
        self.hostnames = hostnames
    }

    func refreshIfStale(maxAge: TimeInterval) async -> [String: Set<String>]? {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return nil }
        return await refresh()
    }

    /// Resolve every hostname now; returns the updated map.
    @discardableResult
    func refresh() async -> [String: Set<String>] {
        lastRefresh = Date()
        let names = hostnames
        let resolved = await withTaskGroup(of: (String, [String]).self) { group in
            for name in names {
                group.addTask { (name, await Task.detached(priority: .utility) { Self.addresses(of: name) }.value) }
            }
            var out: [(String, [String])] = []
            for await pair in group { out.append(pair) }
            return out
        }
        for (name, addresses) in resolved {
            for address in addresses { ipToHosts[address, default: []].insert(name) }
        }
        return ipToHosts
    }

    func map() -> [String: Set<String>] { ipToHosts }

    /// Blocking getaddrinfo → numeric addresses.
    static func addresses(of host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0 else { return [] }
        defer { freeaddrinfo(result) }
        var out: [String] = []
        var cursor = result
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: buffer))
            }
            cursor = info.pointee.ai_next
        }
        return Array(Set(out))
    }
}
