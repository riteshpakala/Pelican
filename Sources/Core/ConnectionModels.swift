import Foundation

enum FlowProto: String, Sendable {
    case tcp4, tcp6, udp4, udp6, quic4, quic6, other

    var isIPv6: Bool { self == .tcp6 || self == .udp6 || self == .quic6 }
}

enum FlowDirection: String, Sendable {
    case outbound = "out"
    case inbound = "in"
    case listening = "listen"
}

enum FlowState: String, Sendable {
    case established = "Established"
    case listen = "Listen"
    case other = ""
    case closed = "Closed"
}

/// Stable identity of a flow across polls.
struct FlowKey: Hashable, Sendable {
    let pid: Int32
    let proto: FlowProto
    let local: String   // endpoint as printed by nettop, e.g. "10.0.0.132:49188"
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
    let interface: String
    var state: FlowState
    var direction: FlowDirection
    var bytesIn: UInt64    // cumulative, from nettop
    var bytesOut: UInt64
    var deltaIn: UInt64    // since previous poll (rate signal)
    var deltaOut: UInt64
    let firstSeen: Date
    var lastSeen: Date
    var resolvedHost: String?
    var verdict: Verdict?

    /// True when the remote endpoint is a wildcard (unbound UDP / listener).
    var hasConcreteRemote: Bool {
        !remoteAddress.isEmpty && !remoteAddress.contains("*")
    }
}

enum FlowEvent: Identifiable, Sendable {
    case opened(Flow, at: Date)
    case closed(FlowKey, processName: String, remote: String, at: Date)
    case verdictAssigned(FlowKey, processName: String, remote: String, Verdict)

    var id: String {
        switch self {
        case .opened(let flow, let at):
            return "open-\(flow.id.hashValue)-\(at.timeIntervalSince1970)"
        case .closed(let key, _, _, let at):
            return "close-\(key.hashValue)-\(at.timeIntervalSince1970)"
        case .verdictAssigned(let key, _, _, let verdict):
            return "verdict-\(key.hashValue)-\(verdict.at.timeIntervalSince1970)"
        }
    }

    var at: Date {
        switch self {
        case .opened(_, let at): return at
        case .closed(_, _, _, let at): return at
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
