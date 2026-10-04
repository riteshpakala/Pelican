import Foundation

/// Reverse-DNS cache. Failures are cached as `nil` — "no PTR record" is itself
/// a signal the analysis presets use (malware often skips DNS).
actor DNSResolver {
    /// ip → resolved name (or nil if lookup failed). Absent key = never tried.
    private var cache: [String: String?] = [:]
    private var inFlight: Set<String> = []

    /// Cached name for an IP, if a lookup has completed. Outer nil = not yet
    /// attempted; inner nil = attempted, no name.
    func cachedName(for ip: String) -> String?? {
        cache[ip]
    }

    /// Kick off a lookup if one isn't cached or already running.
    func requestResolve(_ ip: String) {
        guard !ip.isEmpty, cache.index(forKey: ip) == nil, !inFlight.contains(ip) else { return }
        inFlight.insert(ip)
        Task.detached(priority: .utility) { [weak self] in
            let name = Self.reverseLookup(ip)
            await self?.store(ip: ip, name: name)
        }
    }

    private func store(ip: String, name: String?) {
        cache[ip] = name
        inFlight.remove(ip)
    }

    /// Blocking getnameinfo PTR lookup; runs on a detached task.
    private static func reverseLookup(_ ip: String) -> String? {
        var hints = addrinfo(
            ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM, ai_protocol: 0,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, nil, &hints, &info) == 0, let addr = info else { return nil }
        defer { freeaddrinfo(info) }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(
            addr.pointee.ai_addr, addr.pointee.ai_addrlen,
            &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
        guard status == 0 else { return nil }
        return String(cString: host)
    }
}
