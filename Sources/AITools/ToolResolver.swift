import Foundation
import PelicanKit

/// Turns a pid into an attribution: walks the process tree, reads signatures (cached per
/// incarnation), and asks the attributor. Blocking — call it off the main thread.
package final class ToolResolver: @unchecked Sendable {

    package let table: ProcessTable
    private let inspector: any ProcessInspecting
    private let catalog: [AITool]
    private let lock = NSLock()
    private var signatures: [ProcessStamp: CodeSignature?] = [:]
    private var mcpServers: [MCPServerRef] = []
    /// pids already known not to belong to any tool, so the common case costs one lookup.
    private var misses: Set<ProcessStamp> = []

    package init(table: ProcessTable = ProcessTable(),
                 inspector: any ProcessInspecting = LiveProcessInspector(),
                 catalog: [AITool] = AITool.all) {
        self.table = table
        self.inspector = inspector
        self.catalog = catalog
    }

    package func setMCPServers(_ servers: [MCPServerRef]) {
        lock.lock(); defer { lock.unlock() }
        mcpServers = servers
    }

    package var knownMCPServers: [MCPServerRef] {
        lock.lock(); defer { lock.unlock() }
        return mcpServers
    }

    /// Everything the attributor needs about one pid's chain, nearest first.
    package func facts(forPid pid: Int32, at time: Date = Date()) -> [ProcessFacts] {
        guard let lineage = table.snapshot().lineage(pid: pid, at: time) else { return [] }
        return lineage.nodes.map { node in
            ProcessFacts(node: node,
                         signature: signature(for: node.stamp),
                         arguments: inspector.arguments(pid: node.stamp.pid))
        }
    }

    package func resolve(pid: Int32, at time: Date = Date()) -> ToolAttribution? {
        let chain = facts(forPid: pid, at: time)
        guard let leaf = chain.first else { return nil }
        lock.lock()
        let alreadyMissed = misses.contains(leaf.node.stamp)
        let servers = mcpServers
        lock.unlock()
        if alreadyMissed { return nil }

        let attribution = ToolAttributor.attribute(chain: chain, mcpServers: servers, catalog: catalog)
        if attribution == nil {
            lock.lock()
            if misses.count > 4096 { misses.removeAll() }
            misses.insert(leaf.node.stamp)
            lock.unlock()
        }
        return attribution
    }

    /// Signature of a process, read once per incarnation.
    package func signature(for stamp: ProcessStamp) -> CodeSignature? {
        lock.lock()
        if let cached = signatures[stamp] { lock.unlock(); return cached }
        lock.unlock()
        let signature = CodeSignature.read(pid: stamp.pid)
        lock.lock()
        if signatures.count > 2048 { signatures.removeAll() }
        signatures[stamp] = signature
        lock.unlock()
        return signature
    }

    /// Every running process that belongs to a tool. Used to decide what to watch and how
    /// closely capture must poll.
    package func runningToolProcesses() -> [(pid: Int32, attribution: ToolAttribution)] {
        var out: [(Int32, ToolAttribution)] = []
        for pid in inspector.allPids() {
            table.sight(pid: pid)
            if let attribution = resolve(pid: pid) { out.append((pid, attribution)) }
        }
        return out
    }

    /// How closely capture must watch, from the surfaces currently running.
    package func captureDemand(for running: [ToolAttribution]) -> CaptureDemand {
        var demand = CaptureDemand.idle
        for attribution in running {
            guard let tool = catalog.first(where: { $0.id == attribution.toolID }),
                  let surfaceID = attribution.surfaceID,
                  let surface = tool.surface(id: surfaceID) else { continue }
            switch surface.networking {
            case .userSpace, .unknown: demand = max(demand, .userSpace)
            case .kernelSockets: demand = max(demand, .active)
            }
        }
        return demand
    }
}
