import Foundation
import PelicanKit

/// What a destination is for. Pelican can only tell these apart once it can read the traffic;
/// until then several may share one address, and the UI says so.
package enum HostPurpose: String, Sendable, Codable, CaseIterable {
    case inference      // the model itself: prompts and replies
    case auth           // sign-in and tokens
    case telemetry      // usage and operational metrics
    case errorReporting // crash and error reports
    case update         // version checks and downloads
    case mcp            // a gateway to MCP servers
    case content        // documentation, marketplaces, CDNs
    case code           // repositories and package registries
    case agent          // not in the catalog: somewhere the agent itself went

    package var label: String {
        switch self {
        case .inference: return "model"
        case .auth: return "sign-in"
        case .telemetry: return "telemetry"
        case .errorReporting: return "error reports"
        case .update: return "updates"
        case .mcp: return "MCP gateway"
        case .content: return "content"
        case .code: return "code"
        case .agent: return "reached by the agent"
        }
    }

    /// Traffic the user did not ask for, shown separately from the work they did ask for.
    package var isIncidental: Bool { self == .telemetry || self == .errorReporting }
}

/// A host an AI tool is known to contact.
package struct HostRule: Sendable, Hashable, Identifiable, Codable {
    package let pattern: HostPattern
    package let purpose: HostPurpose
    /// What the vendor says this endpoint is for, in their words where possible.
    package let note: String
    /// Hostnames to forward-resolve, so connections to their addresses are recognised.
    package let resolve: [String]
    /// The vendor publishes this range as its own, so an address alone identifies the tool.
    package let dedicated: Bool
    /// A rotating cloud pool: addresses change, so misses are expected rather than suspicious.
    package let rotating: Bool
    /// What the vendor documents this endpoint carries — checkable once traffic is readable.
    package let claims: [String]
    package let verification: Verification

    package var id: String { pattern.display + "|" + purpose.rawValue }

    package init(
        _ pattern: HostPattern, purpose: HostPurpose, note: String, resolve: [String] = [],
        dedicated: Bool = false, rotating: Bool = false, claims: [String] = [],
        verification: Verification
    ) {
        self.pattern = pattern
        self.purpose = purpose
        self.note = note
        self.resolve = resolve
        self.dedicated = dedicated
        self.rotating = rotating
        self.claims = claims
        self.verification = verification
    }
}

/// How a running process is recognised as part of a tool.
package struct ProcessMatcher: Sendable, Hashable, Codable {
    package enum Rule: Sendable, Hashable, Codable {
        /// The code signature's identifier, exactly. Requires the team to match too.
        case signingIdentifier(String)
        /// The code signature's identifier by prefix, for families of helpers.
        case signingIdentifierPrefix(String)
        /// The bundle identifier of the OUTERMOST enclosing .app.
        case outerBundle(String)
        /// A path, `~/` allowed, `*` matching any run of characters.
        case path(String)
        /// An interpreter (node, python3, bun…) whose arguments contain a marker.
        case interpreter(names: Set<String>, argument: String)
    }
    package let rule: Rule
    package let verification: Verification

    package init(_ rule: Rule, verification: Verification) {
        self.rule = rule
        self.verification = verification
    }
}

/// Where a tool keeps its MCP server list.
package struct MCPConfigLocation: Sendable, Hashable, Codable {
    package enum Format: Sendable, Hashable, Codable {
        case claudeJSON   // ~/.claude.json, .mcp.json, claude_desktop_config.json
        case mcpJSON      // ~/.cursor/mcp.json and the per-project form
        case codexTOML    // ~/.codex/config.toml, [mcp_servers.*]
    }
    /// `~/` allowed. A project-scoped path is relative to a repository root.
    package let path: String
    package let format: Format
    package let projectScoped: Bool

    package init(path: String, format: Format, projectScoped: Bool = false) {
        self.path = path
        self.format = format
        self.projectScoped = projectScoped
    }
}

/// One way a tool shows up on a Mac: a CLI, a desktop app, an editor extension.
package struct ToolSurface: Sendable, Hashable, Identifiable, Codable {
    package enum Kind: String, Sendable, Codable {
        case cli, desktopApp, editorExtension
        package var label: String {
            switch self {
            case .cli: return "command line"
            case .desktopApp: return "app"
            case .editorExtension: return "editor extension"
            }
        }
    }
    /// How this surface reaches the network, which decides how closely capture must watch.
    package enum Networking: String, Sendable, Codable {
        /// BSD sockets: socket events report them as they open.
        case kernelSockets
        /// URLSession / Network.framework: only nettop sees these, so polling must be quick.
        case userSpace
        case unknown
    }

    package let id: String
    package let name: String
    package let kind: Kind
    package let matchers: [ProcessMatcher]
    package let networking: Networking
    /// User-Agent prefixes this surface sends — only visible once traffic is readable.
    package let agents: [String]

    package init(id: String, name: String, kind: Kind, matchers: [ProcessMatcher],
                 networking: Networking = .unknown, agents: [String] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.matchers = matchers
        self.networking = networking
        self.agents = agents
    }
}

/// An AI tool Pelican knows how to watch. Everything here is a product fact: identifiers a
/// vendor signs with and hosts they publish. Nothing about Rao or about this Mac.
package struct AITool: Sendable, Hashable, Identifiable, Codable {
    package let id: String
    package let name: String
    package let vendor: String
    package let siteURL: URL
    /// Apple team identifiers the vendor signs with, as macOS reports them.
    package let teams: Set<String>
    package let surfaces: [ToolSurface]
    package let hosts: [HostRule]
    package let mcpConfigs: [MCPConfigLocation]

    package init(id: String, name: String, vendor: String, siteURL: URL, teams: Set<String>,
                 surfaces: [ToolSurface], hosts: [HostRule], mcpConfigs: [MCPConfigLocation] = []) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.siteURL = siteURL
        self.teams = teams
        self.surfaces = surfaces
        self.hosts = hosts
        self.mcpConfigs = mcpConfigs
    }

    /// Nothing about this tool has been seen on a real Mac yet, so it is shown as awaiting a
    /// fingerprint and nothing is attributed to it.
    package var awaitingFingerprint: Bool {
        !surfaces.contains { surface in surface.matchers.contains { $0.verification.isObserved } }
    }

    package func surface(id: String) -> ToolSurface? { surfaces.first { $0.id == id } }

    /// Every hostname worth forward-resolving for this tool.
    package var hostnamesToResolve: [String] {
        Array(Set(hosts.flatMap(\.resolve))).sorted()
    }

    package func rule(matching candidates: [String]) -> (rule: HostRule, host: String)? {
        for rule in hosts {
            if let host = rule.pattern.firstMatch(in: candidates) { return (rule, host) }
        }
        return nil
    }
}
