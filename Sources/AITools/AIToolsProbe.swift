import Foundation
import PelicanKit

/// `Pelican --ai-probe [seconds]`
///
/// Prints what Pelican can see of the AI tools on this Mac: which surfaces are installed, what
/// macOS says about their processes, how each connection is sourced back to a tool, and which
/// destinations no catalog rule recognises. This is how an entry in the catalog is checked —
/// on this Mac, or on anyone else's.
package enum AIToolsProbe {

    package static func run(seconds: Double, catalog: [AITool] = AITool.all) async {
        print("Pelican AI tools probe · \(BuildInfo.current.line)")
        print(String(repeating: "─", count: 78))

        let resolver = ToolResolver(catalog: catalog)
        resolver.table.start(scanInterval: 1)
        defer { resolver.table.stop() }

        installed(catalog)
        runningProcesses(resolver, catalog: catalog)
        let servers = mcpServers(catalog)
        resolver.setMCPServers(servers)
        await flows(seconds: seconds, resolver: resolver, catalog: catalog)
        awaiting(catalog)
    }

    // MARK: - Installed

    private static func installed(_ catalog: [AITool]) {
        print("\nINSTALLED")
        var found = false
        for tool in catalog {
            for surface in tool.surfaces {
                for matcher in surface.matchers {
                    guard case .path(let glob) = matcher.rule else { continue }
                    let paths = expand(glob)
                    guard let newest = paths.last else { continue }
                    found = true
                    let signature = CodeSignature.read(path: newest)
                    print("  \(tool.name) · \(surface.name)")
                    print("    path        \(tilde(newest))")
                    if paths.count > 1 {
                        print("                and \(paths.count - 1) older cop\(paths.count == 2 ? "y" : "ies") beside it")
                    }
                    print("    signed as   \(signature?.identifier ?? "—")")
                    print("    team        \(signature?.teamIdentifier ?? "—")")
                    print("    certificate \(signature?.leafSubject ?? "—")")
                    print("    valid \(signature?.isValid == true)  notarized \(signature?.notarized.map(String.init) ?? "?")")
                    print("    catalog     \(matcher.verification.note)")
                }
                for matcher in surface.matchers {
                    guard case .outerBundle(let bundle) = matcher.rule,
                          let url = appURL(forBundleID: bundle) else { continue }
                    found = true
                    let signature = CodeSignature.read(path: url.path)
                    let info = ProcessIdentity.bundleInfo(bundlePath: url.path)
                    print("  \(tool.name) · \(surface.name)")
                    print("    bundle      \(bundle)  \(info?["CFBundleShortVersionString"] as? String ?? "?")")
                    print("    path        \(tilde(url.path))")
                    print("    team        \(signature?.teamIdentifier ?? "—")")
                    print("    certificate \(signature?.leafSubject ?? "—")")
                    print("    catalog     \(matcher.verification.note)")
                }
            }
        }
        if !found { print("  none of the catalog's tools are installed here") }
    }

    // MARK: - Running

    @discardableResult
    private static func runningProcesses(_ resolver: ToolResolver, catalog: [AITool]) -> [ToolAttribution] {
        print("\nRUNNING")
        let found = resolver.runningToolProcesses()
        if found.isEmpty { print("  no tool processes running") }
        var byTool: [String: [(Int32, ToolAttribution)]] = [:]
        for entry in found { byTool[entry.attribution.toolID, default: []].append(entry) }
        for (toolID, entries) in byTool.sorted(by: { $0.key < $1.key }) {
            let name = catalog.first { $0.id == toolID }?.name ?? toolID
            print("  \(name) — \(entries.count) process\(entries.count == 1 ? "" : "es")")
            for (pid, attribution) in entries.sorted(by: { $0.0 < $1.0 }).prefix(12) {
                print("    [\(pid)] \(attribution.chainDisplay)")
                print("          \(attribution.basis.label): \(attribution.evidence)")
                if let arguments = LiveProcessInspector.processArguments(pid: pid), arguments.count > 1 {
                    let shown = ArgumentRedactor.redact(arguments).joined(separator: " ")
                    print("          args: \(String(shown.prefix(150)))")
                }
            }
        }
        let demand = resolver.captureDemand(for: found.map(\.attribution))
        print("  capture demand: \(demand) (nettop every \(Int(demand.pollInterval))s)")
        return found.map(\.attribution)
    }

    // MARK: - MCP

    @discardableResult
    private static func mcpServers(_ catalog: [AITool]) -> [MCPServerRef] {
        print("\nMCP SERVERS CONFIGURED")
        let servers = MCPConfigReader.readAll(catalog: catalog)
        if servers.isEmpty { print("  none found in the catalog's config locations") }
        for server in servers.sorted(by: { $0.id < $1.id }) {
            let where_ = server.host.map { "remote \($0)" } ?? "\(server.command) \(server.marker ?? "")"
            print("  \(server.toolID): \(server.name) — \(where_.trimmingCharacters(in: .whitespaces))")
        }
        return servers
    }

    // MARK: - Flows

    private static func flows(seconds: Double, resolver: ToolResolver, catalog: [AITool]) async {
        print("\nCONNECTIONS (watching \(Int(seconds))s)")
        let monitor = NetworkMonitor()
        let hosts = HostTable(hostnames: AITool.allHostnamesToResolve)
        async let resolved = hosts.refresh()
        let hostMap = await resolved

        await monitor.onSighting { pid, time in resolver.table.sight(pid: pid, at: time) }
        let stream = await monitor.snapshots()
        await monitor.start(cadence: 1)

        var rows: [String: (tool: String, purpose: String, out: UInt64, count: Int, evidence: String)] = [:]
        var unlisted: [String: (process: String, bytes: UInt64)] = [:]
        let reader = Task {
            for await snapshot in stream {
                for flow in snapshot.flows where flow.scope == .external && flow.hasConcreteRemote {
                    guard let attribution = resolver.resolve(pid: flow.pid, at: flow.firstSeen) else { continue }
                    let tool = catalog.first { $0.id == attribution.toolID }
                    var candidates = Array(hostMap[flow.remoteAddress] ?? [])
                    if let reverse = flow.resolvedHost { candidates.append(reverse) }
                    let match = tool?.rule(matching: candidates)
                    let key = "\(attribution.toolID)|\(match?.host ?? flow.remoteAddress)|\(match?.rule.purpose.label ?? "unlisted")"
                    let display = match?.host ?? flow.remoteAddress
                    var entry = rows[key] ?? (tool?.name ?? attribution.toolID,
                                              match?.rule.purpose.label ?? HostPurpose.agent.label,
                                              0, 0, attribution.evidence)
                    entry.out = max(entry.out, flow.bytesOut)
                    entry.count += 1
                    rows[key] = entry
                    if match == nil {
                        unlisted[display] = (flow.processName, max(unlisted[display]?.bytes ?? 0, flow.bytesOut))
                    }
                    _ = display
                }
            }
        }
        try? await Task.sleep(for: .seconds(seconds))
        reader.cancel()
        await monitor.stop()

        if rows.isEmpty {
            print("  nothing attributed — are the tools running and talking?")
        }
        for (key, row) in rows.sorted(by: { $0.value.out > $1.value.out }).prefix(30) {
            let host = key.split(separator: "|").dropFirst().first.map(String.init) ?? "?"
            print("  \(row.tool.padding(toLength: min(10, max(row.tool.count, 10)), withPad: " ", startingAt: 0))  \(formatBytes(row.out).padding(toLength: 9, withPad: " ", startingAt: 0)) out  \(host)  [\(row.purpose)]")
            print("        \(row.evidence)")
        }
        if !unlisted.isEmpty {
            print("\n  destinations no catalog rule names (candidates for the catalog, or places the agent went):")
            for (host, info) in unlisted.sorted(by: { $0.value.bytes > $1.value.bytes }).prefix(15) {
                print("    \(host)  from \(info.process)  \(formatBytes(info.bytes)) out")
            }
        }
    }

    // MARK: - Awaiting

    private static func awaiting(_ catalog: [AITool]) {
        let pending = catalog.filter(\.awaitingFingerprint)
        guard !pending.isEmpty else { return }
        print("\nAWAITING A FINGERPRINT")
        for tool in pending {
            print("  \(tool.name) (\(tool.vendor)) — install it and run this probe again to confirm its")
            print("    identifiers. Until then Pelican attributes nothing to it.")
        }
    }

    // MARK: - Helpers

    /// Expand a catalog glob to the executables that actually exist here. Directories are not
    /// installs: a broad glob like `/Applications/Cursor.app/*` is for matching a running
    /// process's path, not for listing one.
    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static func expand(_ glob: String) -> [String] {
        var pattern = glob
        if pattern.hasPrefix("~/") {
            pattern = FileManager.default.homeDirectoryForCurrentUser.path + pattern.dropFirst(1)
        }
        guard pattern.contains("*") else {
            return isExecutableFile(pattern) ? [pattern] : []
        }
        // Walk the fixed prefix, then match the rest.
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: false)
        guard let wildcard = parts.firstIndex(where: { $0.contains("*") }) else { return [] }
        let base = parts[..<wildcard].joined(separator: "/")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base.isEmpty ? "/" : base)
        else { return [] }
        var out: [String] = []
        let tail = parts[(wildcard + 1)...].map(String.init)
        for entry in entries {
            let candidate = ([base, entry] + tail).joined(separator: "/")
            if ToolAttributor.matches(glob: pattern, path: candidate), isExecutableFile(candidate) {
                out.append(candidate)
            }
        }
        return out.sorted()
    }

    private static func appURL(forBundleID bundle: String) -> URL? {
        for directory in ["/Applications", NSString(string: "~/Applications").expandingTildeInPath] {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = directory + "/" + entry
                if ProcessIdentity.bundleInfo(bundlePath: path)?["CFBundleIdentifier"] as? String == bundle {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    /// Never print the user's home directory.
    private static func tilde(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
