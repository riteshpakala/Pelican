import Combine
import Foundation
import PelicanKit

/// Watches the AI tools on this Mac: sources every connection to the tool that caused it,
/// classifies where it went, and keeps the day's record.
///
/// Fed from the app's snapshot fan-out, because `NetworkMonitor` has a single consumer.
/// Attribution needs syscalls, so it happens off the main actor and lands back here.
@MainActor
package final class AIToolsStore: ObservableObject {

    @Published package private(set) var day: ToolDay
    @Published package private(set) var running: [String: [ToolAttribution]] = [:]
    @Published package private(set) var observing = false
    @Published package private(set) var captureStatus: [FlowSourceKind: FlowSourceStatus] = [:]
    @Published package private(set) var mcpServers: [MCPServerRef] = []

    package let catalog: [AITool]
    private let resolver: ToolResolver
    private let inspector: any ProcessInspecting
    private let store: DayFileStore<ToolDay>
    private let hosts: HostTable

    /// Attributions already decided, so a flow is resolved once.
    private var attributions: [FlowKey: ToolAttribution] = [:]
    private var resolving: Set<FlowKey> = []
    /// Flows that belong to no tool; remembered so they are not retried every snapshot.
    private var notATool: Set<FlowKey> = []
    private var index: [String: Int] = [:]      // ToolFlow.id → position in day.flows
    private var active: [FlowKey: String] = [:] // live flow → record id
    /// Bytes already added to a rollup for each record, so growth is added as a delta rather
    /// than counted twice.
    private var counted: [String: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
    private var hostMap: [String: Set<String>] = [:]
    private var saveScheduled = false
    private var lastHostRefresh: Date?
    private var started = false

    /// Told about each external tool flow as it is recorded or grows, so Leak Guard can predict
    /// what an encrypted connection carries without the store knowing about the guard. For a
    /// subprocess or MCP flow, the raw command line is passed for the guard to scan and discard;
    /// it is never kept here.
    package var onToolFlow: (@MainActor (_ flow: ToolFlow, _ claims: [String], _ rawCommand: [String]?) -> Void)?

    private let demandSubject = CurrentValueSubject<CaptureDemand, Never>(.idle)
    /// How closely capture must watch for the tools currently running.
    package var captureDemand: AnyPublisher<CaptureDemand, Never> {
        demandSubject.removeDuplicates().eraseToAnyPublisher()
    }

    package init(catalog: [AITool] = AITool.all,
                 resolver: ToolResolver? = nil,
                 store: DayFileStore<ToolDay> = DayFileStore(folder: "ai-tools"),
                 inspector: any ProcessInspecting = LiveProcessInspector()) {
        self.catalog = catalog
        self.resolver = resolver ?? ToolResolver(catalog: catalog)
        self.inspector = inspector
        self.store = store
        self.hosts = HostTable(hostnames: AITool.allHostnamesToResolve)
        self.day = ToolDay(day: DayFileStore<ToolDay>.dayKey(for: Date()),
                           pelicanBuild: BuildInfo.current.line)
    }

    // MARK: - Lifecycle

    package func start() {
        guard !started else { return }
        started = true
        if let saved = store.loadNow(day: day.day) { adopt(saved) }
        resolver.table.start()
        Task {
            await refreshHosts()
            await store.prune()
            await scanRunning()
        }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scanRunning() }
        }
    }

    /// Report a new flow's process the moment it appears (see `ProcessTable.sight`). Called
    /// from the network monitor's actor, so it must not touch main-actor state.
    nonisolated package func sight(pid: Int32, at time: Date) {
        resolver.table.sight(pid: pid, at: time)
    }

    package func setObserving(_ on: Bool) {
        observing = on
    }

    /// Write the day synchronously, before quitting.
    package func flushNow() {
        day.lastSeen = Date()
        store.saveNow(day)
    }

    // MARK: - Ingest

    package func ingest(_ snapshot: NetworkMonitor.Snapshot) {
        if captureStatus != snapshot.sourceStatus {
            for (kind, status) in snapshot.sourceStatus { day.capture[kind.rawValue] = status.description }
            captureStatus = snapshot.sourceStatus
        }
        guard observing else { return }
        rolloverIfNeeded()

        var pending: [(FlowKey, Int32, Date)] = []
        for flow in snapshot.flows where flow.scope == .external && flow.hasConcreteRemote {
            if let attribution = attributions[flow.id] {
                upsert(flow, attribution: attribution)
            } else if !notATool.contains(flow.id), !resolving.contains(flow.id) {
                resolving.insert(flow.id)
                pending.append((flow.id, flow.pid, flow.firstSeen))
            }
        }
        for flow in snapshot.recentClosed where active[flow.id] != nil {
            close(flow)
        }
        if !pending.isEmpty { resolve(pending) }
        if !snapshot.newEvents.isEmpty { scheduleSave() }
    }

    /// Attribution reads process state, so it runs off the main actor.
    private func resolve(_ pending: [(key: FlowKey, pid: Int32, at: Date)]) {
        let resolver = self.resolver
        Task.detached(priority: .utility) {
            var found: [(FlowKey, ToolAttribution?)] = []
            for item in pending {
                found.append((item.key, resolver.resolve(pid: item.pid, at: item.at)))
            }
            await MainActor.run { [found] in
                for (key, attribution) in found {
                    self.resolving.remove(key)
                    if let attribution {
                        self.attributions[key] = attribution
                    } else {
                        if self.notATool.count > 8192 { self.notATool.removeAll() }
                        self.notATool.insert(key)
                    }
                }
            }
        }
    }

    // MARK: - Records

    private func upsert(_ flow: Flow, attribution: ToolAttribution) {
        let tool = catalog.first { $0.id == attribution.toolID }
        let evidence = hostEvidence(for: flow, tool: tool)
        let match = tool?.rule(matching: evidence.allNames)
        var resolved = evidence
        resolved.matched = match?.host

        if let id = active[flow.id], let position = index[id] {
            day.flows[position].bytesIn = max(day.flows[position].bytesIn, flow.bytesIn)
            day.flows[position].bytesOut = max(day.flows[position].bytesOut, flow.bytesOut)
            day.flows[position].host = resolved
            day.flows[position].seenBy = flow.seenBy.sorted { $0.rawValue < $1.rawValue }
            rollUp(day.flows[position])
            return
        }

        let record = ToolFlow(
            id: "\(flow.pid)|\(flow.proto.rawValue)|\(flow.id.local)|\(flow.id.remote)|\(Int(flow.firstSeen.timeIntervalSince1970 * 1000))",
            toolID: attribution.toolID,
            surfaceID: attribution.surfaceID,
            origin: attribution.origin,
            basis: attribution.basis,
            evidence: attribution.evidence,
            chain: attribution.chain,
            hostAppName: attribution.hostAppName,
            processName: flow.processName,
            pid: flow.pid,
            proto: flow.proto,
            direction: flow.direction,
            scope: flow.scope,
            host: resolved,
            remotePort: flow.remotePort,
            purpose: match?.rule.purpose ?? .agent,
            claims: match?.rule.claims ?? [],
            openedAt: flow.firstSeen,
            closedAt: nil,
            bytesIn: flow.bytesIn,
            bytesOut: flow.bytesOut,
            seenBy: flow.seenBy.sorted { $0.rawValue < $1.rawValue })

        if day.flows.count >= ToolDay.flowCap {
            day.overflow += 1
        } else {
            day.flows.append(record)
            index[record.id] = day.flows.count - 1
            active[flow.id] = record.id
        }
        if !day.toolsSeen.contains(attribution.toolID) { day.toolsSeen.append(attribution.toolID) }
        rollUp(record)
        notify(record)
        scheduleSave()
    }

    /// Hand a flow to whoever is listening (Leak Guard), with the raw command line for a
    /// subprocess so it can be scanned and dropped. Nothing of it is kept here.
    private func notify(_ record: ToolFlow) {
        guard let onToolFlow else { return }
        let command = record.origin == .tool ? nil : inspector.arguments(pid: record.pid)
        onToolFlow(record, record.claims, command)
    }

    private func close(_ flow: Flow) {
        guard let id = active.removeValue(forKey: flow.id), let position = index[id] else { return }
        day.flows[position].closedAt = flow.lastSeen
        day.flows[position].bytesIn = max(day.flows[position].bytesIn, flow.bytesIn)
        day.flows[position].bytesOut = max(day.flows[position].bytesOut, flow.bytesOut)
        rollUp(day.flows[position])
        notify(day.flows[position])
        scheduleSave()
    }

    /// Add a record's traffic to its endpoint's running totals. A flow's counters are
    /// cumulative, so only the growth since last time is added — and the totals stay complete
    /// even for flows dropped at the day's cap.
    private func rollUp(_ record: ToolFlow) {
        let id = "\(record.toolID)|\(record.host.display)|\(record.purpose.rawValue)"
        let already = counted[record.id] ?? (0, 0)
        let addedIn = record.bytesIn >= already.bytesIn ? record.bytesIn - already.bytesIn : 0
        let addedOut = record.bytesOut >= already.bytesOut ? record.bytesOut - already.bytesOut : 0
        let isNew = counted[record.id] == nil
        if counted.count > 2 * ToolDay.flowCap { counted.removeAll() }
        counted[record.id] = (record.bytesIn, record.bytesOut)

        if let position = day.rollups.firstIndex(where: { $0.id == id }) {
            day.rollups[position].bytesIn += addedIn
            day.rollups[position].bytesOut += addedOut
            day.rollups[position].lastSeen = max(day.rollups[position].lastSeen, record.closedAt ?? record.openedAt)
            day.rollups[position].candidates = Array(
                Set(day.rollups[position].candidates).union(record.host.candidates)).sorted()
            if isNew { day.rollups[position].connections += 1 }
        } else {
            day.rollups.append(EndpointRollup(
                id: id, toolID: record.toolID, display: record.host.display,
                purpose: record.purpose, candidates: record.host.candidates,
                connections: 1, bytesIn: addedIn, bytesOut: addedOut,
                lastSeen: record.openedAt))
        }
    }

    private func hostEvidence(for flow: Flow, tool: AITool?) -> HostEvidence {
        let candidates = Array(hostMap[flow.remoteAddress] ?? [])
        let source: HostEvidence.Source = !candidates.isEmpty ? .resolved
            : (flow.resolvedHost != nil ? .reverse : .none)
        return HostEvidence(address: flow.remoteAddress, candidates: candidates,
                            reverseName: flow.resolvedHost, source: source)
    }

    // MARK: - Running tools

    private func scanRunning() async {
        let resolver = self.resolver
        let found = await Task.detached(priority: .utility) { resolver.runningToolProcesses() }.value
        var grouped: [String: [ToolAttribution]] = [:]
        for entry in found { grouped[entry.attribution.toolID, default: []].append(entry.attribution) }
        running = grouped
        demandSubject.send(resolver.captureDemand(for: found.map(\.attribution)))
        for (toolID, _) in grouped where !day.toolsSeen.contains(toolID) {
            day.toolsSeen.append(toolID)
        }
        // Watch the tools' own processes so their children are caught as they fork.
        for entry in found where entry.attribution.origin == .tool {
            resolver.table.watchDescendants(of: entry.pid)
        }
        if mcpServers.isEmpty {
            let servers = await Task.detached(priority: .utility) {
                MCPConfigReader.readAll(catalog: AITool.all)
            }.value
            mcpServers = servers
            resolver.setMCPServers(servers)
        }
        if lastHostRefresh.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
            await refreshHosts()
        }
    }

    private func refreshHosts() async {
        hostMap = await hosts.refresh()
        lastHostRefresh = Date()
    }

    // MARK: - Day

    private func adopt(_ saved: ToolDay) {
        day = saved
        index = [:]
        for (position, flow) in saved.flows.enumerated() { index[flow.id] = position }
        active = [:]
    }

    private func rolloverIfNeeded() {
        let today = DayFileStore<ToolDay>.dayKey(for: Date())
        guard today != day.day else { return }
        day.lastSeen = Date()
        store.saveNow(day)
        day = ToolDay(day: today, pelicanBuild: BuildInfo.current.line)
        index = [:]
        active = [:]
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(5))
            saveScheduled = false
            day.lastSeen = Date()
            await store.save(day)
        }
    }
}
