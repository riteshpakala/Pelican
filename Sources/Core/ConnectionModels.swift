import Foundation

enum FlowProto: String, Sendable, Codable {
    case tcp4, tcp6, udp4, udp6, quic4, quic6, other

    var isIPv6: Bool { self == .tcp6 || self == .udp6 || self == .quic6 }
    var isUDP: Bool { self == .udp4 || self == .udp6 || self == .quic4 || self == .quic6 }
}

enum FlowDirection: String, Sendable, Codable {
    case outbound = "out"
    case inbound = "in"
    case listening = "listen"
}

/// TCP state as nettop and NetworkStatistics spell it ("Established", "CloseWait", …).
/// Unknown spellings are kept verbatim rather than dropped.
enum FlowState: Sendable, Hashable, Codable {
    case established, listen, synSent, synReceived, finWait1, finWait2
    case closeWait, closing, lastAck, timeWait
    case none          // UDP, or nettop's empty state column
    case closed        // reported by the source, or synthesized when a flow disappears
    case unknown(String)

    init(label raw: String) {
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
    var label: String {
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
    var displayLabel: String { self == .none ? "—" : label }

    /// The connection is shutting down or gone.
    var isTerminal: Bool {
        switch self {
        case .finWait1, .finWait2, .closeWait, .closing, .lastAck, .timeWait, .closed: return true
        default: return false
        }
    }

    init(from decoder: Decoder) throws {
        self.init(label: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(label)
    }
}

/// Whether a flow stays on this Mac.
enum FlowScope: String, Sendable, Codable {
    case loopback, external

    static func of(interface: String, local: String, remote: String) -> FlowScope {
        if interface == "lo0" { return .loopback }
        if isLoopbackAddress(remote) || (remote.isEmpty && isLoopbackAddress(local)) { return .loopback }
        return .external
    }

    static func isLoopbackAddress(_ address: String) -> Bool {
        address.hasPrefix("127.") || address == "::1" || address == "localhost"
            || address.hasPrefix("::ffff:127.")
    }
}

/// Which capture backend reported a flow.
enum FlowSourceKind: String, Sendable, Codable, CaseIterable {
    case nstat, nettop

    var displayName: String {
        switch self {
        case .nstat: return "NetworkStatistics events"
        case .nettop: return "nettop polling"
        }
    }
}

/// Stable identity of a flow across polls and sources. Endpoints are spelled the way nettop
/// prints them with `-n` (see `EndpointFormat`), so both sources produce the same key.
struct FlowKey: Hashable, Sendable, Codable {
    let pid: Int32
    let proto: FlowProto
    let local: String   // e.g. "10.0.0.132:49188", IPv6 "fe80::1%en0.49188", wildcard "*:*"
    let remote: String  // e.g. "17.57.144.23:5223"
}

struct Verdict: Sendable, Equatable {
    enum Label: String, Sendable {
        case ok, suspicious, unknown
    }
    let label: Label
    let score: Int        // 0–10
    let reason: String
    let presetName: String
    let at: Date
}

struct Flow: Identifiable, Sendable {
    let id: FlowKey
    let processName: String
    let pid: Int32
    let proto: FlowProto
    let localAddress: String
    let localPort: UInt16?
    let remoteAddress: String
    let remotePort: UInt16?
    var interface: String
    var state: FlowState
    var direction: FlowDirection
    var bytesIn: UInt64    // cumulative
    var bytesOut: UInt64
    var deltaIn: UInt64    // since the previous sample (rate signal)
    var deltaOut: UInt64
    let firstSeen: Date
    var lastSeen: Date
    var resolvedHost: String?
    var verdict: Verdict?
    /// The process a socket was opened on behalf of, when the OS reports one that differs
    /// from `pid` (e.g. a daemon fetching for an app). NetworkStatistics only.
    var effectivePid: Int32?
    var scope: FlowScope
    var seenBy: Set<FlowSourceKind>

    /// True when the remote endpoint is a wildcard (unbound UDP / listener).
    var hasConcreteRemote: Bool {
        !remoteAddress.isEmpty && !remoteAddress.contains("*")
    }
}

enum FlowEvent: Identifiable, Sendable {
    case opened(Flow, at: Date)
    case closed(Flow, at: Date)
    case verdictAssigned(FlowKey, processName: String, remote: String, Verdict)

    var id: String {
        switch self {
        case .opened(let flow, let at):
            return "open-\(flow.id.hashValue)-\(at.timeIntervalSince1970)"
        case .closed(let flow, let at):
            return "close-\(flow.id.hashValue)-\(at.timeIntervalSince1970)"
        case .verdictAssigned(let key, _, _, let verdict):
            return "verdict-\(key.hashValue)-\(verdict.at.timeIntervalSince1970)"
        }
    }

    var at: Date {
        switch self {
        case .opened(_, let at): return at
        case .closed(_, let at): return at
        case .verdictAssigned(_, _, _, let verdict): return verdict.at
        }
    }
}

/// Per-process grouping for the Processes screen.
struct ProcessRollup: Identifiable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    var flows: [Flow]
    var totalIn: UInt64 { flows.reduce(0) { $0 + $1.bytesIn } }
    var totalOut: UInt64 { flows.reduce(0) { $0 + $1.bytesOut } }
    var worstVerdict: Verdict? {
        flows.compactMap(\.verdict)
            .max { a, b in
                (a.label == .suspicious ? a.score : -1) < (b.label == .suspicious ? b.score : -1)
            }
    }
}
