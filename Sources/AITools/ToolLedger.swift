import Foundation
import PelicanKit

/// What Pelican knows about the name behind an address. Until traffic can be read, an address
/// is often all there is, and several of a vendor's services can share one — so the candidates
/// are carried and shown rather than a single name being guessed.
package struct HostEvidence: Sendable, Hashable, Codable {
    package enum Source: String, Sendable, Codable {
        case resolved   // a catalog hostname forward-resolved to this address
        case reverse    // the address's own reverse-DNS name
        case none       // nothing but the address

        package var label: String {
            switch self {
            case .resolved: return "matched by resolving the vendor's hostnames"
            case .reverse: return "from the address's reverse DNS"
            case .none: return "no name for this address"
            }
        }
    }

    package var address: String
    /// Every catalog hostname that resolves to this address. Only these count toward "shared":
    /// a reverse-DNS name is the address's own label, not another service.
    package var candidates: [String]
    /// The address's reverse-DNS name, when it has one.
    package var reverseName: String?
    /// The name a rule matched, when one did.
    package var matched: String?
    package var source: Source

    package init(address: String, candidates: [String] = [], reverseName: String? = nil,
                 matched: String? = nil, source: Source = .none) {
        self.address = address
        self.candidates = candidates.sorted()
        self.reverseName = reverseName
        self.matched = matched
        self.source = source
    }

    /// Several catalog services answer here, so Pelican cannot say which one this was.
    package var isAmbiguous: Bool { candidates.count > 1 }

    /// Names a rule may match: the catalog's, then the reverse-DNS name.
    package var allNames: [String] { candidates + (reverseName.map { [$0] } ?? []) }

    package var display: String { matched ?? candidates.first ?? reverseName ?? address }

    /// What to say when the address could be any of several services.
    package var ambiguityNote: String? {
        guard isAmbiguous else { return nil }
        return "\(candidates.joined(separator: ", ")) all answer at \(address); Pelican cannot tell them apart without reading the traffic"
    }
}

/// One connection an AI tool made, as the day's record keeps it.
package struct ToolFlow: Sendable, Hashable, Codable, Identifiable {
    package var id: String
    package var toolID: String
    package var surfaceID: String?
    package var origin: ToolOrigin
    package var basis: AttributionBasis
    package var evidence: String
    package var chain: [String]
    package var hostAppName: String?
    package var processName: String
    package var pid: Int32
    package var proto: FlowProto
    package var direction: FlowDirection
    package var scope: FlowScope
    package var host: HostEvidence
    package var remotePort: UInt16?
    package var purpose: HostPurpose
    /// What the vendor says this endpoint carries — checkable once traffic can be read.
    package var claims: [String]
    package var openedAt: Date
    package var closedAt: Date?
    package var bytesIn: UInt64
    package var bytesOut: UInt64
    package var seenBy: [FlowSourceKind]

    package var remoteDisplay: String {
        host.display + (remotePort.map { ":\($0)" } ?? "")
    }

    package var originLabel: String {
        switch origin {
        case .tool: return processName
        case .subprocess(let name): return name
        case .mcpServer(let name): return "MCP · \(name)"
        }
    }
}

/// Everything one tool sent to one kind of destination today.
package struct EndpointRollup: Sendable, Hashable, Codable, Identifiable {
    package var id: String
    package var toolID: String
    package var display: String
    package var purpose: HostPurpose
    package var candidates: [String]
    package var connections: Int
    package var bytesIn: UInt64
    package var bytesOut: UInt64
    package var lastSeen: Date

    package var isAmbiguous: Bool { candidates.count > 1 }
}

/// A day of AI-tool activity.
package struct ToolDay: DayDocument, Sendable, Hashable {
    package static let formatVersion = 1

    package var formatVersion: Int
    package var day: String
    package var pelicanBuild: String
    package var startedAt: Date
    package var lastSeen: Date
    package var flows: [ToolFlow]
    package var rollups: [EndpointRollup]
    /// Tool ids seen running today.
    package var toolsSeen: [String]
    package var capture: [String: String]
    /// Connections past the day's cap. They are counted in the rollups when they open, but are
    /// not kept individually, so their later growth is not followed.
    package var overflow: Int

    /// How many individual connections a day keeps. The rollups are not capped.
    package static let flowCap = 3_000

    package init(day: String, pelicanBuild: String, now: Date = Date()) {
        self.formatVersion = Self.formatVersion
        self.day = day
        self.pelicanBuild = pelicanBuild
        self.startedAt = now
        self.lastSeen = now
        self.flows = []
        self.rollups = []
        self.toolsSeen = []
        self.capture = [:]
        self.overflow = 0
    }

    package func flows(forTool toolID: String?) -> [ToolFlow] {
        guard let toolID else { return flows }
        return flows.filter { $0.toolID == toolID }
    }

    package func rollups(forTool toolID: String?) -> [EndpointRollup] {
        let chosen = toolID.map { id in rollups.filter { $0.toolID == id } } ?? rollups
        return chosen.sorted { $0.bytesOut > $1.bytesOut }
    }

    /// Bytes that left this Mac today, per purpose, for one tool or all of them.
    package func bytesOut(forTool toolID: String?) -> [(purpose: HostPurpose, bytes: UInt64)] {
        var totals: [HostPurpose: UInt64] = [:]
        for rollup in rollups where toolID == nil || rollup.toolID == toolID {
            totals[rollup.purpose, default: 0] += rollup.bytesOut
        }
        return totals.sorted { $0.value > $1.value }.map { (purpose: $0.key, bytes: $0.value) }
    }
}
