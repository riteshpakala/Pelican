import Darwin
import Foundation

/// Renders socket endpoints exactly the way `nettop -n` prints them, so a flow reported by
/// NetworkStatistics and by nettop gets the same `FlowKey`:
///   IPv4  "10.0.0.132:49188", wildcard "*:*", bound-any "*:5353"
///   IPv6  "fe80::1%en0.49188", wildcard "*.*", bound-any "*.5353"
/// The inverse is `NettopParser.splitEndpoint`.
enum EndpointFormat {

    static func string(address: String?, port: UInt16?, ipv6: Bool) -> String {
        let addr = (address?.isEmpty ?? true) ? "*" : address!
        let portText = port.map(String.init) ?? "*"
        return addr + (ipv6 ? "." : ":") + portText
    }

    /// Decode a `sockaddr` held in CFData (NetworkStatistics' localAddress / remoteAddress).
    /// Unspecified addresses (0.0.0.0, ::) and port 0 come back as nil — nettop's wildcards.
    static func decode(_ data: Data) -> (address: String?, port: UInt16?, ipv6: Bool)? {
        guard data.count >= MemoryLayout<sockaddr>.size else { return nil }
        return data.withUnsafeBytes { raw -> (String?, UInt16?, Bool)? in
            guard let base = raw.baseAddress else { return nil }
            let family = Int32(raw.load(fromByteOffset: 1, as: UInt8.self))
            switch family {
            case AF_INET:
                guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                var sin = sockaddr_in()
                memcpy(&sin, base, MemoryLayout<sockaddr_in>.size)
                let port = UInt16(bigEndian: sin.sin_port)
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addr = sin.sin_addr
                inet_ntop(AF_INET, &addr, &buffer, socklen_t(buffer.count))
                let text = String(cString: buffer)
                return (text == "0.0.0.0" ? nil : text, port == 0 ? nil : port, false)
            case AF_INET6:
                guard data.count >= MemoryLayout<sockaddr_in6>.size else { return nil }
                var sin6 = sockaddr_in6()
                memcpy(&sin6, base, MemoryLayout<sockaddr_in6>.size)
                let port = UInt16(bigEndian: sin6.sin6_port)
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = withUnsafePointer(to: &sin6) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in6>.size),
                                    &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                    }
                }
                guard status == 0 else { return nil }
                let text = String(cString: host)
                return (text == "::" ? nil : text, port == 0 ? nil : port, true)
            default:
                return nil
            }
        }
    }
}
