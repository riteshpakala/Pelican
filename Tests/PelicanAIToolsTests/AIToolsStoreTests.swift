import Foundation
import Testing
@testable import PelicanAITools
@testable import PelicanKit

// MARK: - Fixtures

private func sample(pid: Int32, remote: String, out: UInt64, in bytesIn: UInt64 = 0,
                    process: String = "claude") -> FlowSample {
    FlowSample(processName: process, pid: pid, proto: .tcp4,
               local: "10.0.0.2:50000", remote: remote, interface: "en0",
               state: "Established", bytesIn: bytesIn, bytesOut: out, origin: .nstat)
}

private func flow(pid: Int32, remote: String, out: UInt64, in bytesIn: UInt64 = 0,
                  opened: Date = Date(), process: String = "claude") -> Flow {
    let sample = sample(pid: pid, remote: remote, out: out, in: bytesIn, process: process)
    let key = NetworkMonitor.key(for: sample)
    let parts = remote.split(separator: ":")
    return Flow(id: key, processName: process, pid: pid, proto: .tcp4,
                localAddress: "10.0.0.2", localPort: 50000,
                remoteAddress: String(parts[0]), remotePort: UInt16(parts[1]),
                interface: "en0", state: .established, direction: .outbound,
                bytesIn: bytesIn, bytesOut: out, deltaIn: 0, deltaOut: 0,
                firstSeen: opened, lastSeen: opened, resolvedHost: nil, verdict: nil,
                effectivePid: nil, scope: .external, seenBy: [.nstat])
}

private func snapshot(_ flows: [Flow], closed: [Flow] = []) -> NetworkMonitor.Snapshot {
    NetworkMonitor.Snapshot(flows: flows, recentClosed: closed,
                            newEvents: flows.map { .opened($0, at: $0.firstSeen) },
                            parseSkips: 0, sourceStatus: [.nstat: .running])
}

// MARK: - Tests

@Suite @MainActor struct ToolDayTests {

    /// Build a day directly, the way the store does, to check the arithmetic the UI reads.
    private func dayWithTraffic() -> ToolDay {
        var day = ToolDay(day: "2026-10-04", pelicanBuild: "test")
        day.rollups = [
            EndpointRollup(id: "claude|api.anthropic.com|inference", toolID: "claude",
                           display: "api.anthropic.com", purpose: .inference, candidates: ["api.anthropic.com"],
                           connections: 3, bytesIn: 500, bytesOut: 60_000, lastSeen: Date()),
            EndpointRollup(id: "claude|datadog|telemetry", toolID: "claude",
                           display: "http-intake.logs.us5.datadoghq.com", purpose: .telemetry,
                           candidates: ["http-intake.logs.us5.datadoghq.com"],
                           connections: 1, bytesIn: 10, bytesOut: 4_000, lastSeen: Date()),
            EndpointRollup(id: "cursor|api2|inference", toolID: "cursor", display: "api2.cursor.sh",
                           purpose: .inference, candidates: ["api2.cursor.sh"],
                           connections: 2, bytesIn: 20, bytesOut: 900, lastSeen: Date()),
        ]
        return day
    }

    @Test func bytesOutIsGroupedByPurposeAndFilteredByTool() {
        let day = dayWithTraffic()
        let claude = day.bytesOut(forTool: "claude")
        #expect(claude.first?.purpose == .inference)
        #expect(claude.first?.bytes == 60_000)
        #expect(claude.contains { $0.purpose == .telemetry && $0.bytes == 4_000 })
        // Another tool's traffic is not mixed in.
        #expect(!claude.contains { $0.bytes == 900 })
        let everything = day.bytesOut(forTool: nil)
        #expect(everything.first { $0.purpose == .inference }?.bytes == 60_900)
    }

    @Test func telemetryIsMarkedAsTrafficTheUserDidNotAskFor() {
        #expect(HostPurpose.telemetry.isIncidental)
        #expect(HostPurpose.errorReporting.isIncidental)
        #expect(!HostPurpose.inference.isIncidental)
    }

    @Test func anAmbiguousAddressSaysSoRatherThanGuessing() {
        // Four Anthropic services answer on one address; Pelican must not pick one.
        let evidence = HostEvidence(
            address: "160.79.104.10",
            candidates: ["api.anthropic.com", "claude.ai", "claude.com", "mcp-proxy.anthropic.com"],
            source: .resolved)
        #expect(evidence.isAmbiguous)
        let note = evidence.ambiguityNote
        #expect(note?.contains("cannot tell them apart") == true)
        #expect(note?.contains("160.79.104.10") == true)
    }

    @Test func aReverseDNSNameIsNotAnotherService() {
        // Datadog's intake has a cloud provider's reverse name; that is the address's own
        // label, so the address is not "shared".
        let evidence = HostEvidence(
            address: "34.149.66.165",
            candidates: ["http-intake.logs.us5.datadoghq.com"],
            reverseName: "165.66.149.34.bc.googleusercontent.com",
            source: .resolved)
        #expect(!evidence.isAmbiguous)
        #expect(evidence.display == "http-intake.logs.us5.datadoghq.com")
        #expect(evidence.allNames.count == 2)
        // With no catalog name, the reverse name is what's shown.
        let unnamed = HostEvidence(address: "1.2.3.4", reverseName: "host.example.net", source: .reverse)
        #expect(unnamed.display == "host.example.net")
    }

    @Test func anAddressWithNoNameShowsTheAddress() {
        let evidence = HostEvidence(address: "203.0.113.9")
        #expect(!evidence.isAmbiguous)
        #expect(evidence.display == "203.0.113.9")
        #expect(evidence.ambiguityNote == nil)
        #expect(evidence.source == .none)
    }
}

@Suite @MainActor struct AIToolsStoreTests {

    private func store() -> AIToolsStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pelican-tests-\(UUID().uuidString)")
        let store = AIToolsStore(store: DayFileStore(folder: "ai-tools", root: root))
        store.setObserving(true)
        return store
    }

    @Test func flowsWithNoToolAreIgnoredRatherThanGuessedAt() {
        let store = store()
        store.ingest(snapshot([flow(pid: 1, remote: "93.184.216.34:443", out: 1000, process: "Safari")]))
        #expect(store.day.flows.isEmpty)
        #expect(store.day.rollups.isEmpty)
    }

    @Test func captureStatusIsRecordedEvenWhilePaused() {
        let store = store()
        store.setObserving(false)
        store.ingest(snapshot([]))
        #expect(store.day.capture["nstat"] == "running")
    }

    @Test func aDayStartsEmptyAndKnowsItsDate() {
        let store = store()
        #expect(store.day.flows.isEmpty)
        #expect(store.day.day == DayFileStore<ToolDay>.dayKey(for: Date()))
        #expect(store.day.formatVersion == ToolDay.formatVersion)
    }
}

@Suite struct DayFileStoreTests {

    private func temporaryStore() -> DayFileStore<ToolDay> {
        DayFileStore(folder: "ai-tools", root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pelican-tests-\(UUID().uuidString)"))
    }

    @Test func savesListsAndPrunes() async {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        for day in ["2026-10-01", "2026-10-02", "2026-10-03"] {
            var document = ToolDay(day: day, pelicanBuild: "test")
            document.toolsSeen = ["claude"]
            store.saveNow(document)
        }
        #expect(await store.days() == ["2026-10-03", "2026-10-02", "2026-10-01"])
        let loaded = store.loadNow(day: "2026-10-02")
        #expect(loaded?.toolsSeen == ["claude"])
        await store.prune(keep: 2)
        #expect(await store.days() == ["2026-10-03", "2026-10-02"])
    }

    @Test func aDayRoundTripsThroughJSON() throws {
        var document = ToolDay(day: "2026-10-04", pelicanBuild: "test")
        document.flows = [ToolFlow(
            id: "f1", toolID: "claude", surfaceID: "claude-code", origin: .subprocess("curl"),
            basis: .lineage, evidence: "curl ← zsh ← claude", chain: ["curl", "zsh", "claude"],
            hostAppName: "Visual Studio Code", processName: "curl", pid: 70521, proto: .tcp4,
            direction: .outbound, scope: .external,
            host: HostEvidence(address: "160.79.104.10", candidates: ["api.anthropic.com"],
                               matched: "api.anthropic.com", source: .resolved),
            remotePort: 443, purpose: .inference, claims: [], openedAt: Date(), closedAt: nil,
            bytesIn: 10, bytesOut: 20, seenBy: [.nstat])]
        let data = try DayFileStore<ToolDay>.encoder.encode(document)
        let back = try DayFileStore<ToolDay>.decoder.decode(ToolDay.self, from: data)
        #expect(back.flows.first?.origin == .subprocess("curl"))
        #expect(back.flows.first?.basis == .lineage)
        #expect(back.flows.first?.host.matched == "api.anthropic.com")
        #expect(back.day == "2026-10-04")
    }

    @Test func theDayKeyIsALocalCalendarDate() {
        let key = DayFileStore<ToolDay>.dayKey(for: Date(timeIntervalSince1970: 1_767_225_600))
        #expect(key.count == 10)
        #expect(key.hasPrefix("20"))
    }
}
