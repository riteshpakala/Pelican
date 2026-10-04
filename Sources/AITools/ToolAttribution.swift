import Darwin
import Foundation
import PelicanKit

/// What a process is, relative to the tool it belongs to.
package enum ToolOrigin: Sendable, Hashable, Codable {
    /// One of the tool's own processes.
    case tool
    /// Something the tool ran: a shell, a build, a `curl`.
    case subprocess(String)
    /// A configured MCP server the tool started.
    case mcpServer(String)

    package var label: String {
        switch self {
        case .tool: return "the tool itself"
        case .subprocess(let name): return name
        case .mcpServer(let name): return "MCP server \(name)"
        }
    }
}

/// Why Pelican believes a flow belongs to a tool. Strongest last, so attributions compare.
package enum AttributionBasis: Int, Sendable, Codable, Comparable, CaseIterable {
    /// Only the destination says so: a shared process talking to an address one vendor owns.
    case destination = 0
    /// An orphan whose process group leads back to the tool.
    case processGroup
    /// macOS holds the tool's app responsible for this process.
    case responsible
    /// A descendant of the tool, with the chain recorded.
    case lineage
    /// Runs from where the tool installs.
    case path
    /// Inside an app bundle that is the tool's.
    case bundle
    /// Signed with the vendor's team and the tool's identifier.
    case signature

    package static func < (a: AttributionBasis, b: AttributionBasis) -> Bool { a.rawValue < b.rawValue }

    package var label: String {
        switch self {
        case .destination: return "by destination only"
        case .processGroup: return "process group"
        case .responsible: return "responsible process"
        case .lineage: return "started by the tool"
        case .path: return "install path"
        case .bundle: return "inside the app"
        case .signature: return "code signature"
        }
    }
}

/// A flow's process, resolved to a tool.
package struct ToolAttribution: Sendable, Hashable, Codable {
    package let toolID: String
    package let surfaceID: String?
    package let origin: ToolOrigin
    package let basis: AttributionBasis
    /// One sentence saying how Pelican knows, shown on every row.
    package let evidence: String
    /// Process names nearest-first: ["curl", "zsh", "claude"].
    package let chain: [String]
    /// The app the tool runs inside, when it is hosted by one ("Visual Studio Code").
    package let hostAppName: String?

    package init(toolID: String, surfaceID: String?, origin: ToolOrigin, basis: AttributionBasis,
                 evidence: String, chain: [String], hostAppName: String? = nil) {
        self.toolID = toolID
        self.surfaceID = surfaceID
        self.origin = origin
        self.basis = basis
        self.evidence = evidence
        self.chain = chain
        self.hostAppName = hostAppName
    }

    package var chainDisplay: String { chain.joined(separator: " ← ") }
}

/// Everything known about one process in a chain, as the attributor needs it.
package struct ProcessFacts: Sendable {
    package var node: ProcessNode
    package var signature: CodeSignature?
    /// Matched in memory only; never stored by the caller.
    package var arguments: [String]?

    package init(node: ProcessNode, signature: CodeSignature? = nil, arguments: [String]? = nil) {
        self.node = node
        self.signature = signature
        self.arguments = arguments
    }
}

/// Decides which AI tool a flow belongs to. Pure: the live reads belong to the store.
package enum ToolAttributor {

    /// Attribute a flow from its process chain, nearest process first.
    ///
    /// The nearest process in the chain that is itself a tool wins, so a `curl` run by Claude
    /// Code inside VS Code is Claude Code's, not VS Code's. The app around the tool is recorded
    /// separately rather than competing with it.
    package static func attribute(
        chain: [ProcessFacts],
        mcpServers: [MCPServerRef] = [],
        catalog: [AITool] = AITool.all
    ) -> ToolAttribution? {
        guard let leaf = chain.first else { return nil }
        let names = chain.map(\.node.name)

        for (depth, facts) in chain.enumerated() {
            guard let hit = match(facts: facts, catalog: catalog) else { continue }
            let hostApp = hostAppName(above: depth, in: chain, tool: hit.tool)

            if depth == 0 {
                return ToolAttribution(
                    toolID: hit.tool.id, surfaceID: hit.surface.id, origin: .tool, basis: hit.basis,
                    evidence: evidence(for: hit, facts: facts, hostApp: hostApp),
                    chain: names, hostAppName: hostApp)
            }

            // A descendant. Say what it is, and how it ties back.
            let origin = mcpOrigin(for: leaf, servers: mcpServers, tool: hit.tool)
                ?? .subprocess(leaf.node.name)
            let via = names.prefix(depth + 1).joined(separator: " ← ")
            return ToolAttribution(
                tool: hit, origin: origin, basis: .lineage,
                evidence: "\(via) — \(hit.surface.name) started it",
                chain: names, hostAppName: hostApp)
        }

        // Nothing in the chain is a tool. Fall back to what macOS says is responsible, then to
        // the process group, for orphans whose parent is already gone.
        if let fallback = fallback(chain: chain, catalog: catalog) { return fallback }
        return nil
    }

    /// A flow whose process belongs to no tool, but whose destination is a range one vendor
    /// publishes as its own. Weakest basis, and only ever used where a rule says `dedicated`.
    package static func attributeByDestination(
        tool: AITool, host: String, processName: String, chain: [String]
    ) -> ToolAttribution {
        ToolAttribution(
            toolID: tool.id, surfaceID: nil, origin: .subprocess(processName), basis: .destination,
            evidence: "\(processName) reached \(host), an address only \(tool.vendor) uses — Pelican cannot tell which process inside it made the request",
            chain: chain)
    }

    // MARK: - Matching

    package struct Hit: Sendable {
        package let tool: AITool
        package let surface: ToolSurface
        package let basis: AttributionBasis
        package let detail: String
    }

    /// The strongest matcher this process satisfies, across the catalog.
    package static func match(facts: ProcessFacts, catalog: [AITool] = AITool.all) -> Hit? {
        var best: Hit?
        for tool in catalog {
            for surface in tool.surfaces {
                for matcher in surface.matchers {
                    // A fact nobody has confirmed never attributes anything.
                    if case .unverified = matcher.verification { continue }
                    guard let (basis, detail) = satisfies(matcher.rule, facts: facts, tool: tool) else { continue }
                    if best == nil || basis > best!.basis {
                        best = Hit(tool: tool, surface: surface, basis: basis, detail: detail)
                    }
                }
            }
        }
        return best
    }

    private static func satisfies(_ rule: ProcessMatcher.Rule, facts: ProcessFacts, tool: AITool)
        -> (AttributionBasis, String)? {
        switch rule {
        case .signingIdentifier(let identifier):
            guard facts.signature?.identifier == identifier, signedByVendor(facts, tool) else { return nil }
            return (.signature, "signed \(identifier)")

        case .signingIdentifierPrefix(let prefix):
            guard let identifier = facts.signature?.identifier, identifier.hasPrefix(prefix),
                  signedByVendor(facts, tool) else { return nil }
            return (.signature, "signed \(identifier)")

        case .outerBundle(let bundle):
            guard facts.node.outerBundleID == bundle else { return nil }
            return (.bundle, "inside \(bundle)")

        case .path(let glob):
            guard let path = facts.node.executablePath, matches(glob: glob, path: path) else { return nil }
            // Signed by someone else — true of a vendor's bundled interpreter, and worth saying.
            if let team = facts.signature?.teamIdentifier, !tool.teams.isEmpty, !tool.teams.contains(team) {
                return (.path, "runs from \(path), though signed by team \(team)")
            }
            return (.path, "runs from \(path)")

        case .interpreter(let names, let argument):
            guard names.contains(facts.node.name),
                  let arguments = facts.arguments,
                  arguments.contains(where: { $0.contains(argument) }) else { return nil }
            return (.path, "\(facts.node.name) running \(argument)")
        }
    }

    /// A signature only counts when the vendor's own team signed it.
    private static func signedByVendor(_ facts: ProcessFacts, _ tool: AITool) -> Bool {
        guard !tool.teams.isEmpty else { return true }
        guard let team = facts.signature?.teamIdentifier else { return false }
        return tool.teams.contains(team)
    }

    /// `~` expands; `*` matches any run of characters, path separators included.
    package static func matches(glob: String, path: String) -> Bool {
        var pattern = glob
        if pattern.hasPrefix("~/") {
            pattern = FileManager.default.homeDirectoryForCurrentUser.path + pattern.dropFirst(1)
        }
        return fnmatch(pattern, path, 0) == 0
    }

    // MARK: - Context

    /// The app the tool runs inside, read from the first ancestor above it that lives in a
    /// different app bundle: Claude Code's extension host is Visual Studio Code.
    private static func hostAppName(above depth: Int, in chain: [ProcessFacts], tool: AITool) -> String? {
        for facts in chain.dropFirst(depth + 1) {
            guard let bundle = facts.node.outerBundleID,
                  !tool.surfaces.contains(where: { $0.matchers.contains { matcher in
                      if case .outerBundle(let own) = matcher.rule { return own == bundle }
                      return false
                  } }) else { continue }
            if let path = facts.node.executablePath,
               let app = LiveProcessInspector.outermostApp(of: path) {
                return (app as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            }
            return bundle
        }
        return nil
    }

    private static func mcpOrigin(for leaf: ProcessFacts, servers: [MCPServerRef], tool: AITool) -> ToolOrigin? {
        guard let arguments = leaf.arguments else { return nil }
        for server in servers where server.toolID == tool.id {
            if server.matches(name: leaf.node.name, arguments: arguments) {
                return .mcpServer(server.name)
            }
        }
        return nil
    }

    private static func evidence(for hit: Hit, facts: ProcessFacts, hostApp: String?) -> String {
        var text = hit.detail
        if let hostApp { text += ", hosted in \(hostApp)" }
        return text
    }

    /// macOS's responsible process, then the process group: both reach a tool whose parent link
    /// is already gone.
    private static func fallback(chain: [ProcessFacts], catalog: [AITool]) -> ToolAttribution? {
        guard let leaf = chain.first else { return nil }
        let names = chain.map(\.node.name)
        for facts in chain {
            guard let responsible = facts.node.responsible else { continue }
            // The responsible process is identified by the caller before it reaches here; when
            // it is in the chain, use it.
            guard let owner = chain.first(where: { $0.node.stamp == responsible }),
                  let hit = match(facts: owner, catalog: catalog) else { continue }
            return ToolAttribution(
                tool: hit, origin: .subprocess(leaf.node.name), basis: .responsible,
                evidence: "macOS holds \(hit.surface.name) responsible for \(leaf.node.name)",
                chain: names)
        }
        return nil
    }
}

private extension ToolAttribution {
    init(tool hit: ToolAttributor.Hit, origin: ToolOrigin, basis: AttributionBasis,
         evidence: String, chain: [String], hostAppName: String? = nil) {
        self.init(toolID: hit.tool.id, surfaceID: hit.surface.id, origin: origin, basis: basis,
                  evidence: evidence, chain: chain, hostAppName: hostAppName)
    }
}

/// A configured MCP server, as read from a tool's own config. Enough to recognise the process
/// that runs it; never its environment or arguments.
package struct MCPServerRef: Sendable, Hashable, Codable, Identifiable {
    package let toolID: String
    package let name: String
    /// The command's basename ("npx", "uvx", "node", "python3").
    package let command: String
    /// The distinguishing argument: a package or script name.
    package let marker: String?
    /// For a remote server, its host.
    package let host: String?

    package var id: String { toolID + "|" + name }

    package init(toolID: String, name: String, command: String, marker: String? = nil, host: String? = nil) {
        self.toolID = toolID
        self.name = name
        self.command = command
        self.marker = marker
        self.host = host
    }

    package func matches(name processName: String, arguments: [String]) -> Bool {
        guard processName == command || arguments.first.map({ ($0 as NSString).lastPathComponent == command }) == true
        else { return false }
        guard let marker else { return true }
        return arguments.contains { $0.contains(marker) }
    }
}
