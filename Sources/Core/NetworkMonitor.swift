import Foundation

/// Polls `nettop` on an interval, diffs the flow table between ticks, and
/// publishes snapshots. Observe-only and unprivileged — this is the userspace
/// stand-in for a NetworkExtension content filter.
actor NetworkMonitor {

    struct Snapshot: Sendable {
        var flows: [Flow]         // active flows, most recent first
        var recentClosed: [Flow]  // bounded history of closed flows
        var newEvents: [FlowEvent]
        var parseSkips: Int
    }

    static let closedHistoryLimit = 500

    private let resolver = DNSResolver()
    private var table: [FlowKey: Flow] = [:]
    private var closedHistory: [Flow] = []
    private var parseSkips = 0
    private var pollTask: Task<Void, Never>?
    private var continuation: AsyncStream<Snapshot>.Continuation?

    var isRunning: Bool { pollTask != nil }

    /// Single-consumer snapshot stream (AppState is the only subscriber).
    func snapshots() -> AsyncStream<Snapshot> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    func start(interval: Duration = .seconds(4)) {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Record a model verdict on the flow table so it survives later ticks.
    func applyVerdict(_ verdict: Verdict, to key: FlowKey) {
        if var flow = table[key] {
            flow.verdict = verdict
            table[key] = flow
            emitSnapshot(newEvents: [
                .verdictAssigned(key, processName: flow.processName, remote: flow.remoteAddress, verdict)
            ])
        } else if let idx = closedHistory.firstIndex(where: { $0.id == key }) {
            closedHistory[idx].verdict = verdict
            emitSnapshot(newEvents: [
                .verdictAssigned(
                    key, processName: closedHistory[idx].processName,
                    remote: closedHistory[idx].remoteAddress, verdict)
            ])
        }
    }

    // MARK: - Polling

    private func tick() async {
        guard let csv = try? await Self.runNettop() else { return }
        let parsed = NettopParser.parse(csv)
        parseSkips = parsed.skippedLines
        let now = Date()
        var events: [FlowEvent] = []

        // Local ports a pid is listening on — established flows landing on one
        // of these are inbound.
        var listenPorts: Set<String> = []
        for sample in parsed.flows where sample.state == FlowState.listen.rawValue {
            let (_, port) = NettopParser.splitEndpoint(sample.local, proto: sample.proto)
            if let port { listenPorts.insert("\(sample.pid):\(port)") }
        }

        var next: [FlowKey: Flow] = [:]
        for sample in parsed.flows {
            let key = FlowKey(pid: sample.pid, proto: sample.proto, local: sample.local, remote: sample.remote)
            let (localAddr, localPort) = NettopParser.splitEndpoint(sample.local, proto: sample.proto)
            let (remoteAddr, remotePort) = NettopParser.splitEndpoint(sample.remote, proto: sample.proto)
            let state = FlowState(rawValue: sample.state) ?? .other

            let direction: FlowDirection
            if state == .listen || remoteAddr.isEmpty {
                direction = .listening
            } else if let localPort, listenPorts.contains("\(sample.pid):\(localPort)") {
                direction = .inbound
            } else {
                direction = .outbound
            }

            if var existing = table[key] {
                existing.state = state
                existing.direction = direction
                // Clamp negative deltas — counters reset when a 4-tuple is reused.
                existing.deltaIn = sample.bytesIn >= existing.bytesIn ? sample.bytesIn - existing.bytesIn : 0
                existing.deltaOut = sample.bytesOut >= existing.bytesOut ? sample.bytesOut - existing.bytesOut : 0
                existing.bytesIn = sample.bytesIn
                existing.bytesOut = sample.bytesOut
                existing.lastSeen = now
                next[key] = existing
            } else {
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
                    firstSeen: now,
                    lastSeen: now,
                    resolvedHost: nil,
                    verdict: nil
                )
                next[key] = flow
                events.append(.opened(flow, at: now))
                if flow.hasConcreteRemote {
                    await resolver.requestResolve(remoteAddr)
                }
            }
        }

        // Flows gone this tick → closed, kept in bounded history.
        for (key, var flow) in table where next[key] == nil {
            flow.state = .closed
            flow.lastSeen = now
            closedHistory.insert(flow, at: 0)
            events.append(.closed(key, processName: flow.processName, remote: flow.remoteAddress, at: now))
        }
        if closedHistory.count > Self.closedHistoryLimit {
            closedHistory.removeLast(closedHistory.count - Self.closedHistoryLimit)
        }

        // Fill in any reverse-DNS results that have landed since last tick.
        for (key, var flow) in next where flow.resolvedHost == nil && flow.hasConcreteRemote {
            if case .some(let name?) = await resolver.cachedName(for: flow.remoteAddress) {
                flow.resolvedHost = name
                next[key] = flow
            }
        }

        table = next
        emitSnapshot(newEvents: events)
    }

    private func emitSnapshot(newEvents: [FlowEvent]) {
        continuation?.yield(Snapshot(
            flows: table.values.sorted { $0.firstSeen > $1.firstSeen },
            recentClosed: closedHistory,
            newEvents: newEvents,
            parseSkips: parseSkips
        ))
    }

    private static func runNettop() async throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        proc.arguments = ["-x", "-L", "1", "-t", "external", "-J", "bytes_in,bytes_out,state,interface"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        // Drain the pipe off-actor before waiting — nettop's output can exceed
        // the 64KB pipe buffer, and waitUntilExit first would deadlock.
        let data = await Task.detached(priority: .utility) {
            pipe.fileHandleForReading.readDataToEndOfFile()
        }.value
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
