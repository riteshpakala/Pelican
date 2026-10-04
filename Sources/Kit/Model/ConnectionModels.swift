import Foundation

package enum FlowProto: String, Sendable, Codable {
    case tcp4, tcp6, udp4, udp6, quic4, quic6, other

    package var isIPv6: Bool { self == .tcp6 || self == .udp6 || self == .quic6 }
    package var isUDP: Bool { self == .udp4 || self == .udp6 || self == .quic4 || self == .quic6 }
}

package enum FlowDirection: String, Sendable, Codable {
    case outbound = "out"
    case inbound = "in"
    case listening = "listen"
}

/// TCP state as nettop and NetworkStatistics spell it ("Established", "CloseWait", …).
/// Unknown spellings are kept verbatim rather than dropped.
package enum FlowState: Sendable, Hashable, Codable {
    case established, listen, synSent, synReceived, finWait1, finWait2
    case closeWait, closing, lastAck, timeWait
    case none          // UDP, or nettop's empty state column
    case closed        // reported by the source, or synthesized when a flow disappears
    case unknown(String)

    package init(label raw: String) {
        switch raw {
        case "Established": self = .established
        case "Listen": self = .listen
        case "SynSent": self = .synSent
        case "SynReceived": self = .synReceived
        case "FinWait1": self = .finWait1
        case "FinWait2": self = .finWait2
        case "CloseWait": self = .closeWait
        case "Closing": self = .closing
        case "LastAck": self = .lastAck
        case "TimeWait": self = .timeWait
        case "Closed": self = .closed
        case "": self = .none
        default: self = .unknown(raw)
        }
    }

    /// The source's own spelling ("" for none).
    package var label: String {
        switch self {
        case .established: return "Established"
        case .listen: return "Listen"
        case .synSent: return "SynSent"
        case .synReceived: return "SynReceived"
        case .finWait1: return "FinWait1"
        case .finWait2: return "FinWait2"
        case .closeWait: return "CloseWait"
        case .closing: return "Closing"
        case .lastAck: return "LastAck"
        case .timeWait: return "TimeWait"
        case .none: return ""
        case .closed: return "Closed"
        case .unknown(let raw): return raw
        }
    }

    /// For tables: "—" instead of an empty cell.
    package var displayLabel: String { self == .none ? "—" : label }

    /// The connection is shutting down or gone.
    package var isTerminal: Bool {
        switch self {
        case .finWait1, .finWait2, .closeWait, .closing, .lastAck, .timeWait, .closed: return true
        default: return false
        }
    }

    package init(from decoder: Decoder) throws {
        self.init(label: try decoder.singleValueContainer().decode(String.self))
    }

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }
}

/// Whether a flow stays on this Mac.
package enum FlowScope: String, Sendable, Codable {
    case loopback, external

    package static func of(interface: String, local: String, remote: String) -> FlowScope {
        if interface == "lo0" { return .loopback }
        if isLoopbackAddress(remote) || (remote.isEmpty && isLoopbackAddress(local)) { return .loopback }
        return .external
    }

    package static func isLoopbackAddress(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "::1" || address == "localhost"
            || address.hasPrefix("::ffff:127.")
    }
}

/// Which capture backend reported a flow.
package enum FlowSourceKind: String, Sendable, Codable, CaseIterable {
    case nstat, nettop

    package var displayName: String {
        switch self {
        case .nstat: return "NetworkStatistics events"
        case .nettop: return "nettop polling"
        }
    }
}

/// Stable identity of a flow across polls and sources. Endpoints are spelled the way nettop
/// prints them with `-n` (see `EndpointFormat`), so both sources produce the same key.
package struct FlowKey: Hashable, Sendable, Codable {
    package let pid: Int32
    package let proto: FlowProto
    package let local: String   // e.g. "10.0.0.132:49188", IPv6 "fe80::1%en0.49188", wildcard "*:*"
    package let remote: String  // e.g. "17.57.144.23:5223"

    package init(pid: Int32, proto: FlowProto, local: String, remote: String) {
        self.pid = pid
        self.proto = proto
        self.local = local
        self.remote = remote
    }
}

package struct Verdict: Sendable, Equatable {
    package enum Label: String, Sendable {
        case ok, suspicious, unknown
    }
    package let label: Label
    package let score: Int        // 0–10
    package let reason: String
    package let presetName: String
    package let at: Date

    package init(label: Label, score: Int, reason: String, presetName: String, at: Date) {
        self.label = label
        self.score = score
        self.reason = reason
        self.presetName = presetName
        self.at = at
    }
}

package struct Flow: Identifiable, Sendable {
    package let id: FlowKey
    package let processName: String
    package let pid: Int32
    package let proto: FlowProto
    package let localAddress: String
    package let localPort: UInt16?
    package let remoteAddress: String
    package let remotePort: UInt16?
    package var interface: String
    package var state: FlowState
    package var direction: FlowDirection
    package var bytesIn: UInt64    // cumulative
    package var bytesOut: UInt64
    package var deltaIn: UInt64    // since the previous sample (rate signal)
    package var deltaOut: UInt64
    package let firstSeen: Date
    package var lastSeen: Date
    package var resolvedHost: String?
    package var verdict: Verdict?
    /// The process a socket was opened on behalf of, when the OS reports one that differs
    /// from `pid` (e.g. a daemon fetching for an app). NetworkStatistics only.
    package var effectivePid: Int32?
    package var scope: FlowScope
    package var seenBy: Set<FlowSourceKind>

    package init(
        id: FlowKey, processName: String, pid: Int32, proto: FlowProto,
        localAddress: String, localPort: UInt16?, remoteAddress: String, remotePort: UInt16?,
        interface: String, state: FlowState, direction: FlowDirection,
        bytesIn: UInt64, bytesOut: UInt64, deltaIn: UInt64, deltaOut: UInt64,
        firstSeen: Date, lastSeen: Date, resolvedHost: String?, verdict: Verdict?,
        effectivePid: Int32?, scope: FlowScope, seenBy: Set<FlowSourceKind>
    ) {
        self.id = id
        self.processName = processName
        self.pid = pid
        self.proto = proto
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.interface = interface
        self.state = state
        self.direction = direction
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
        self.deltaIn = deltaIn
        self.deltaOut = deltaOut
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.resolvedHost = resolvedHost
        self.verdict = verdict
        self.effectivePid = effectivePid
        self.scope = scope
        self.seenBy = seenBy
    }

    /// True when the remote endpoint is a wildcard (unbound UDP / listener).
    package var hasConcreteRemote: Bool {
        !remoteAddress.isEmpty && !remoteAddress.contains("*")
    }
}

package enum FlowEvent: Identifiable, Sendable {
    case opened(Flow, at: Date)
    case closed(Flow, at: Date)
    case verdictAssigned(FlowKey, processName: String, remote: String, Verdict)

    package var id: String {
        switch self {
        case .opened(let flow, let at):
            return "open-\(flow.id.hashValue)-\(at.timeIntervalSince1970)"
        case .closed(let flow, let at):
            return "close-\(flow.id.hashValue)-\(at.timeIntervalSince1970)"
        case .verdictAssigned(let key, _, _, let verdict):
            return "verdict-\(key.hashValue)-\(verdict.at.timeIntervalSince1970)"
        }
    }

    package var at: Date {
        switch self {
        case .opened(_, let at): return at
        case .closed(_, let at): return at
        case .verdictAssigned(_, _, _, let verdict): return verdict.at
        }
    }
}
