import Foundation

/// Merges the capture sources into one flow table and publishes snapshots.
/// Observe-only and unprivileged.
///
/// Merge rule: NetworkStatistics owns the lifecycle of every flow it has reported — a nettop
/// poll that no longer lists such a flow does not close it; the NStat removal does. nettop
/// opens and closes the flows NStat never reported (all of them, when NStat is unavailable).
/// A flow is opened once, by whichever source reports its key first.
package actor NetworkMonitor {

    package struct Snapshot: Sendable {
        package var flows: [Flow]         // active flows, most recent first
        package var recentClosed: [Flow]  // bounded history of closed flows
        package var newEvents: [FlowEvent]
        package var parseSkips: Int
        package var sourceStatus: [FlowSourceKind: FlowSourceStatus]
    }

    static let closedHistoryLimit = 500
    static let emitDebounce: Duration = .milliseconds(500)
    /// After NStat (re)starts it re-reports every live socket at once; flows it still owned
    /// from before and did not re-report within this window died while it was stopped.
    static let nstatResyncWindow: Duration = .seconds(3)

    private let resolver = DNSResolver()
    private var table: [FlowKey: Flow] = [:]
    private var closedHistory: [Flow] = []
    private var parseSkips = 0
    private var sourceStatus: [FlowSourceKind: FlowSourceStatus] = [:]

    private var tokenToKey: [UInt64: FlowKey] = [:]
    private var nstatConfirmed: [FlowKey: Date] = [:]
    private var recentlyClosedByNStat: [FlowKey: Date] = [:]
    private var lastNettopKeys: Set<FlowKey> = []

    private var pendingEvents: [FlowEvent] = []
    private var pendingResolve: Set<String> = []
    private var emitScheduled = false

    private var sources: [any FlowSource] = []
    private var sourceContinuation: AsyncStream<FlowSourceEvent>.Continuation?
    private var consumer: Task<Void, Never>?
    private var generation = 0
    private var snapshotContinuation: AsyncStream<Snapshot>.Continuation?
    private var cadence: Double = 4

    package private(set) var isRunning = false

    package init() {}

    /// Single-consumer snapshot stream (AppState is the only subscriber).
    package func snapshots() -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            self.snapshotContinuation = continuation
        }
    }

    package func start(cadence: Double) {
        guard !isRunning else { return }
        isRunning = true
        self.cadence = cadence
        if sources.isEmpty {
            let made = FlowSourceFactory.make()
            sources = made.sources
            for (kind, reason) in made.unavailable {
                sourceStatus[kind] = .unavailable(reason)
            }
        }
        generation += 1
        let current = generation
        let (stream, continuation) = AsyncStream<FlowSourceEvent>.makeStream()
        sourceContinuation = continuation
        consumer = Task {
            for await event in stream {
                self.handle(event, generation: current)
            }
        }
        for source in sources {
            source.setCadence(cadence)
            source.start(into: continuation)
        }
    }

    package func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        for source in sources {
            source.stop()
            if case .running = sourceStatus[source.kind] { sourceStatus[source.kind] = .stopped }
        }
        sourceContinuation?.finish()
        sourceContinuation = nil
        consumer = nil
        scheduleEmit()
    }

    package func setCadence(_ seconds: Double) {
        cadence = seconds
        for source in sources { source.setCadence(seconds) }
    }

    /// Record a model verdict on the flow table so it survives later updates.
    package func applyVerdict(_ verdict: Verdict, to key: FlowKey) {
        if var flow = table[key] {
            flow.verdict = verdict
            table[key] = flow
            pendingEvents.append(.verdictAssigned(key, processName: flow.processName, remote: flow.remoteAddress, verdict))
        } else if let index = closedHistory.firstIndex(where: { $0.id == key }) {
            closedHistory[index].verdict = verdict
            pendingEvents.append(.verdictAssigned(
                key, processName: closedHistory[index].processName,
                remote: closedHistory[index].remoteAddress, verdict))
        }
        scheduleEmit()
    }

    // MARK: - Test seams (internal; used by the tests through @testable import)

    /// Feed one source event as if a capture source had sent it.
    func inject(_ event: FlowSourceEvent) {
        handle(event, generation: generation)
    }

    var activeFlowsForTesting: [Flow] { Array(table.values) }

    /// The events queued since the last snapshot, cleared.
    func takeEventsForTesting() -> [FlowEvent] {
        defer { pendingEvents = [] }
        return pendingEvents
    }

    // MARK: - Source events

    private func handle(_ event: FlowSourceEvent, generation: Int) {
        guard generation == self.generation else { return }  // a stopped run's leftovers
        switch event {
        case .snapshot(let samples, let skipped, let at):
            applyNettop(samples, skipped: skipped, at: at)
        case .upsert(let sample, let token, let at):
            applyUpsert(sample, token: token, at: at)
        case .removed(let token, let at):
            applyRemoved(token: token, at: at)
        case .status(let kind, let status):
            sourceStatus[kind] = status
            if kind == .nstat, status == .running {
                tokenToKey = [:]
                let startedAt = Date()
                Task {
                    try? await Task.sleep(for: Self.nstatResyncWindow)
                    self.sweepAfterNStatStart(startedAt, generation: generation)
                }
            }
        }
        scheduleEmit()
    }

    private func applyNettop(_ samples: [FlowSample], skipped: Int, at: Date) {
        parseSkips = skipped
        // Local ports a pid is listening on — established flows landing on one are inbound.
        var listenPorts: Set<String> = []
        for sample in samples where FlowState(label: sample.state) == .listen {
            if let port = NettopParser.splitEndpoint(sample.local, proto: sample.proto).port {
                listenPorts.insert("\(sample.pid):\(port)")
            }
        }
        recentlyClosedByNStat = recentlyClosedByNStat.filter { at.timeIntervalSince($0.value) < 15 }

        var seen: Set<FlowKey> = []
        for sample in samples {
            let key = Self.key(for: sample)
            seen.insert(key)
            // NStat already reported this socket gone; nettop's poll is just late.
            if recentlyClosedByNStat[key] != nil { continue }
            upsert(key: key, sample: sample, at: at, source: .nettop, listenPorts: listenPorts)
        }
        lastNettopKeys = seen
        for (key, flow) in table where !seen.contains(key) && !flow.seenBy.contains(.nstat) {
            close(key, at: at)
        }
    }

    private func applyUpsert(_ sample: FlowSample, token: UInt64, at: Date) {
        let key = Self.key(for: sample)
        if let previous = tokenToKey[token], previous != key {
            // The socket's endpoints changed under the same source: a new flow.
            nstatConfirmed.removeValue(forKey: previous)
            close(previous, at: at)
        }
        tokenToKey[token] = key
        recentlyClosedByNStat.removeValue(forKey: key)
        upsert(key: key, sample: sample, at: at, source: .nstat, listenPorts: nil)
        nstatConfirmed[key] = at
    }

    private func applyRemoved(token: UInt64, at: Date) {
        guard let key = tokenToKey.removeValue(forKey: token) else { return }
        nstatConfirmed.removeValue(forKey: key)
        recentlyClosedByNStat[key] = at
        close(key, at: at)
    }

    private func sweepAfterNStatStart(_ startedAt: Date, generation: Int) {
        guard generation == self.generation else { return }
        let now = Date()
        for (key, flow) in table where flow.seenBy.contains(.nstat)
            && (nstatConfirmed[key] ?? .distantPast) < startedAt {
            if lastNettopKeys.contains(key) {
                table[key]?.seenBy.remove(.nstat)   // hand it back to nettop
            } else {
                close(key, at: now)
            }
        }
        scheduleEmit()
    }

    // MARK: - Table

    static func key(for sample: FlowSample) -> FlowKey {
        FlowKey(pid: sample.pid, proto: sample.proto, local: sample.local, remote: sample.remote)
    }

    private func upsert(key: FlowKey, sample: FlowSample, at: Date, source: FlowSourceKind, listenPorts: Set<String>?) {
        let (localAddr, localPort) = NettopParser.splitEndpoint(sample.local, proto: sample.proto)
        let (remoteAddr, remotePort) = NettopParser.splitEndpoint(sample.remote, proto: sample.proto)
        let state = FlowState(label: sample.state)

        // Listening means no peer. A socket reported in Listen state *with* a peer is a
        // connection still being accepted — inbound.
        let direction: FlowDirection
        if remoteAddr.isEmpty {
            direction = .listening
        } else if state == .listen {
            direction = .inbound
        } else if let localPort, isListening(pid: sample.pid, port: localPort, listenPorts: listenPorts) {
            direction = .inbound
        } else {
            direction = .outbound
        }

        if var existing = table[key] {
            // Two sources, one socket: cumulative counters never go backwards.
            let bytesIn = max(existing.bytesIn, sample.bytesIn)
            let bytesOut = max(existing.bytesOut, sample.bytesOut)
            existing.deltaIn = bytesIn - existing.bytesIn
            existing.deltaOut = bytesOut - existing.bytesOut
            existing.bytesIn = bytesIn
            existing.bytesOut = bytesOut
            existing.state = state
            existing.direction = direction
            if !sample.interface.isEmpty { existing.interface = sample.interface }
            if let effective = sample.effectivePid { existing.effectivePid = effective }
            existing.lastSeen = at
            existing.seenBy.insert(source)
            table[key] = existing
        } else {
            let scope = FlowScope.of(interface: sample.interface, local: localAddr, remote: remoteAddr)
            let flow = Flow(
                id: key,
                processName: sample.processName,
                pid: sample.pid,
                proto: sample.proto,
                localAddress: localAddr,
                localPort: localPort,
                remoteAddress: remoteAddr,
                remotePort: remotePort,
                interface: sample.interface,
                state: state,
                direction: direction,
                bytesIn: sample.bytesIn,
                bytesOut: sample.bytesOut,
                deltaIn: 0,
                deltaOut: 0,
                firstSeen: at,
                lastSeen: at,
                resolvedHost: nil,
                verdict: nil,
                effectivePid: sample.effectivePid,
                scope: scope,
                seenBy: [source]
            )
            table[key] = flow
            pendingEvents.append(.opened(flow, at: at))
            if flow.hasConcreteRemote && scope == .external {
                pendingResolve.insert(remoteAddr)
            }
        }
    }

    private func isListening(pid: Int32, port: UInt16, listenPorts: Set<String>?) -> Bool {
        if listenPorts?.contains("\(pid):\(port)") == true { return true }
        return table.values.contains { $0.pid == pid && $0.state == .listen && $0.localPort == port }
    }

    private func close(_ key: FlowKey, at: Date) {
        guard var flow = table.removeValue(forKey: key) else { return }
        flow.state = .closed
        flow.lastSeen = at
        closedHistory.insert(flow, at: 0)
        if closedHistory.count > Self.closedHistoryLimit {
            closedHistory.removeLast(closedHistory.count - Self.closedHistoryLimit)
        }
        pendingEvents.append(.closed(flow, at: at))
    }

    // MARK: - Publishing

    private func scheduleEmit() {
        guard !emitScheduled else { return }
        emitScheduled = true
        Task {
            try? await Task.sleep(for: Self.emitDebounce)
            await self.flush()
        }
    }

    private func flush() async {
        emitScheduled = false
        let toResolve = pendingResolve
        pendingResolve = []
        for ip in toResolve {
            await resolver.requestResolve(ip)
        }
        // Fill in reverse-DNS names that have landed, on live flows and recent history. Names
        // are gathered first and applied without suspending, so indices stay valid.
        func needsName(_ flow: Flow) -> Bool {
            flow.resolvedHost == nil && flow.hasConcreteRemote && flow.scope == .external
        }
        var ips: Set<String> = []
        for flow in table.values where needsName(flow) { ips.insert(flow.remoteAddress) }
        for flow in closedHistory.prefix(100) where needsName(flow) { ips.insert(flow.remoteAddress) }
        var names: [String: String] = [:]
        for ip in ips {
            if case .some(let name?) = await resolver.cachedName(for: ip) { names[ip] = name }
        }
        if !names.isEmpty {
            for (key, flow) in table where needsName(flow) {
                if let name = names[flow.remoteAddress] { table[key]?.resolvedHost = name }
            }
            for index in closedHistory.indices.prefix(100) where needsName(closedHistory[index]) {
                if let name = names[closedHistory[index].remoteAddress] { closedHistory[index].resolvedHost = name }
            }
        }
        let events = pendingEvents
        pendingEvents = []
        snapshotContinuation?.yield(Snapshot(
            flows: table.values.sorted { $0.firstSeen > $1.firstSeen },
            recentClosed: closedHistory,
            newEvents: events,
            parseSkips: parseSkips,
            sourceStatus: sourceStatus
        ))
    }
}
