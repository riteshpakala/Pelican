import Foundation
import Testing
@testable import PelicanKit
@testable import PelicanRadio

// MARK: - A scripted Mac

final class ScriptedSystem: RadioSystem, @unchecked Sendable {
    private let lock = NSLock()
    private var current: RadioPosture
    /// Packets sent, per interface, so a test can move one without moving the others.
    private var sent: [String: UInt64] = ["en0": 100, "en8": 100]
    /// Cumulative driver counters by link and direction; nil means no counters published.
    private var transport: [String: Int64]?

    init(_ posture: RadioPosture, transports: Bool = false) {
        current = posture
        if transports {
            transport = Dictionary(uniqueKeysWithValues: [TransportLink.hci, .acl, .bluetoothInterrupts, .wifiBus, .wifiAirtime]
                .flatMap { link in [transportKey(link, .out), transportKey(link, .in)].map { ($0, Int64(1_000)) } })
        }
    }

    func set(_ posture: RadioPosture) { lock.withLock { current = posture } }
    func send(_ packets: UInt64, on interface: String = "en0") {
        lock.withLock { sent[interface, default: 0] += packets }
    }
    func move(_ link: TransportLink, _ direction: TransportDirection, by count: Int64) {
        lock.withLock { transport?[transportKey(link, direction), default: 0] += count }
    }

    func posture() -> RadioPosture { lock.withLock { current } }
    func counters(named names: Set<String>) -> [String: InterfaceCounter] {
        lock.withLock {
            var out: [String: InterfaceCounter] = [:]
            for name in names {
                guard let packets = sent[name] else { continue }
                out[name] = InterfaceCounter(name: name, packetsOut: packets, packetsIn: 0, isUp: true)
            }
            return out
        }
    }
    func transports() -> TransportSnapshot {
        lock.withLock {
            guard let transport else { return TransportSnapshot(counters: [], status: .stopped) }
            let counters = transport.map { key, value -> TransportCounter in
                let parts = key.split(separator: ".")
                return TransportCounter(key: "driver|\(key)", link: TransportLink(rawValue: String(parts[0]))!,
                                        direction: TransportDirection(rawValue: String(parts[1]))!, value: value)
            }
            return TransportSnapshot(counters: counters, status: .running)
        }
    }
}

final class ScriptedSource: RadioLogSource, @unchecked Sendable {
    private let lock = NSLock()
    private var queued = RadioBatch()
    private(set) var started = false
    private(set) var stopped = false

    func start() async { lock.withLock { started = true } }
    func stop() async { lock.withLock { stopped = true } }
    func stopNow() { lock.withLock { stopped = true } }
    func drain() async -> RadioBatch {
        lock.withLock {
            defer { queued = RadioBatch() }
            return queued
        }
    }

    func status(_ status: FlowSourceStatus, at time: Date) {
        lock.withLock { queued.status.append(.init(status: status, at: time)) }
    }

    func events(_ events: [BluetoothEvent], at time: Date) {
        lock.withLock {
            queued.events += events.map { TimedEvent($0, at: time) }
            queued.linesRead += events.count
        }
    }
}

/// A Mac whose switches can be scripted to succeed, be cancelled, or fail — and which remembers
/// what it was asked to do.
final class ScriptedSwitch: NetworkSwitching, @unchecked Sendable {
    private let lock = NSLock()
    private var state: [String: Bool] = ["USB 10/100/1000 LAN": true, "Thunderbolt Bridge": true, "Wi-Fi": true]
    private var wifiOn = true
    var wifiOutcome: SwitchOutcome = .done
    var servicesOutcome: SwitchOutcome = .done
    private(set) var asked: [(names: [String], on: Bool)] = []

    /// Something outside Pelican switches a service back on.
    func reenable(_ name: String) { lock.withLock { state[name] = true } }
    var isWiFiOn: Bool { lock.withLock { wifiOn } }

    func services() -> [NetworkService] {
        lock.withLock {
            state.map { name, enabled in
                NetworkService(name: name, interface: name == "Wi-Fi" ? "en0" : "en8",
                               enabled: enabled, isWiFi: name == "Wi-Fi")
            }.sorted { $0.name < $1.name }
        }
    }

    func setWiFi(on: Bool) -> SwitchOutcome {
        guard wifiOutcome.isDone else { return wifiOutcome }
        lock.withLock { wifiOn = on }
        return .done
    }

    func setServices(_ names: [String], on: Bool) -> SwitchOutcome {
        lock.withLock { asked.append((names, on)) }
        guard servicesOutcome.isDone else { return servicesOutcome }
        lock.withLock { for name in names { state[name] = on } }
        return .done
    }
}

private func temporaryRoot() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pelican-radio-\(UUID().uuidString)")
}

/// Noon on 4 October 2026, local time.
private let noon = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!

private let normal = RadioPosture(wifi: .on, bluetooth: .on, lockdown: .off)
private let lockedDownBluetoothOn = RadioPosture(wifi: .off, bluetooth: .on, lockdown: .on)
private let lockedDownUnknown = RadioPosture(wifi: .off, bluetooth: .unknown, lockdown: .on)
private let everythingOff = RadioPosture(wifi: .off, bluetooth: .off, lockdown: .on)

@MainActor
private func makeStore(_ posture: RadioPosture, at start: Date = noon, transports: Bool = false)
-> (RadioStore, ScriptedSystem, ScriptedSource, DayFileStore<RadioDay>) {
    let system = ScriptedSystem(posture, transports: transports)
    let source = ScriptedSource()
    let days = DayFileStore<RadioDay>(folder: "radio", root: temporaryRoot())
    let store = RadioStore(system: system, source: source, store: days, now: start)
    return (store, system, source, days)
}

/// Tick every five seconds through `end`: less often than the timer, but never a gap that reads
/// as sleep.
@MainActor
private func run(_ store: RadioStore, from start: Date, through end: Date) async {
    var now = start
    while now <= end {
        await store.tick(now: now)
        now += 5
    }
}

// MARK: - Tests

@Suite @MainActor struct RadioStoreTests {

    @Test func watchingStartsWhenLinesArriveAndSleepIsNotCounted() async {
        let (store, _, source, _) = makeStore(normal)
        store.setObserving(true, at: noon)
        source.status(.running, at: noon)
        for second in stride(from: 0.0, through: 10, by: 1) { await store.tick(now: noon + second) }
        // The Mac sleeps for a minute and a half.
        await store.tick(now: noon + 100)
        await store.tick(now: noon + 110)

        let coverage = store.day.coverage
        #expect(coverage.count == 2)
        #expect(coverage.first == TimeSpan(start: noon, end: noon + 10))
        #expect(coverage.last == TimeSpan(start: noon + 100, end: noon + 110))
        #expect(store.day.watched == 20)
        #expect(store.standing == .nothingReported)
        #expect(source.started)
    }

    @Test func pausingClosesWhatIsOpenAndStopsTheLog() async {
        let (store, _, source, _) = makeStore(normal)
        store.setObserving(true, at: noon)
        source.status(.running, at: noon)
        await store.tick(now: noon)
        await store.tick(now: noon + 5)
        store.setObserving(false, at: noon + 6)
        await store.tick(now: noon + 7)
        #expect(store.day.coverage == [TimeSpan(start: noon, end: noon + 6)])
        #expect(store.day.postures.last?.span.end == noon + 6)
        #expect(store.standing == .paused)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(source.stopped)
    }

    @Test func everyTransmissionIsItemisedWhileLockedDownAndListeningIsNot() async {
        let (store, _, source, _) = makeStore(lockedDownBluetoothOn)
        store.setObserving(true, at: noon)
        source.status(.running, at: noon)
        await store.tick(now: noon)
        source.events([.audioReport(txPackets: 63, retransmitted: 24)], at: noon + 1)
        source.events([.scanStarted(active: false)], at: noon + 2)
        source.events([.scanRequested(.process(name: "sharingd", pid: 666), active: true)], at: noon + 3)
        source.events([.audioReport(txPackets: 12, retransmitted: 0)], at: noon + 4)
        await store.tick(now: noon + 5)

        let findings = store.day.findings.filter { $0.kind == .transmittedWhileLockedDown }
        #expect(Set(findings.map(\.subject)) == ["audio link", "sharingd (pid 666)"])
        #expect(findings.first { $0.subject == "audio link" }?.count == 2)
        #expect(findings.allSatisfy { $0.evidence == .reported(source: "bluetoothd's log") })
        let minute = store.day.minute(EpochMinute.of(noon))
        #expect(minute?.transmissions == 3)
        #expect(minute?.packets == 75)
        #expect(minute?.listening == 1)
        #expect(minute?.lockedDown == true)
        #expect(store.standing == .lockedDown(minutes: 1))
        #expect(store.day.contradictions.isEmpty)
    }

    @Test func unknownBluetoothIsNeverJudgedOff() async {
        let (store, _, source, _) = makeStore(lockedDownUnknown)
        store.setObserving(true, at: noon)
        source.status(.running, at: noon)
        await run(store, from: noon, through: noon + 25)
        source.events([.audioReport(txPackets: 5, retransmitted: 0), .controllerCommand("BD_VSC_EXAMPLE")], at: noon + 30)
        await store.tick(now: noon + 30)
        // It was judged against a settled posture — and recorded, just not as Bluetooth off.
        #expect(store.day.findings.contains { $0.kind == .transmittedWhileLockedDown })
        #expect(!store.day.findings.contains { $0.kind == .transmittedWhileBluetoothOff })
        #expect(!store.day.findings.contains { $0.kind == .commandsWhileBluetoothOff })
        #expect(store.day.contradictions.isEmpty)
    }

    @Test func aTransmissionWithBluetoothReportedOffIsAContradictionOnceSettled() async {
        let (store, _, source, _) = makeStore(everythingOff)
        store.setObserving(true, at: noon)
        source.status(.running, at: noon)
        await store.tick(now: noon)
        // Six seconds after the posture was read: it may still be switching, so nothing is judged.
        source.events([.audioReport(txPackets: 5, retransmitted: 0)], at: noon + 6)
        await store.tick(now: noon + 6)
        #expect(store.day.contradictions.isEmpty)
        // Settled.
        source.events([.audioReport(txPackets: 5, retransmitted: 0)], at: noon + 12)
        await store.tick(now: noon + 12)
        let contradiction = store.day.contradictions
        #expect(contradiction.map(\.kind) == [.transmittedWhileBluetoothOff])
        #expect(store.standing == .contradiction(1))
        #expect(store.summaryLine == "Radios: 1 contradiction")
    }

    @Test func packetsCountedWithWiFiReportedOffAreAContradiction() async {
        let (store, system, source, _) = makeStore(lockedDownUnknown)
        store.setObserving(true, at: noon)
        source.status(.running, at: noon)
        await store.tick(now: noon)       // posture and counters read; not settled yet
        await store.tick(now: noon + 5)
        system.send(3)                    // sent while the posture was still settling: not judged
        await store.tick(now: noon + 10)
        #expect(store.day.contradictions.isEmpty)
        system.send(5)
        await store.tick(now: noon + 15)
        let finding = store.day.contradictions.first
        #expect(finding?.kind == .packetsWhileWiFiOff)
        #expect(finding?.subject == "en0")
        #expect(finding?.count == 5)
    }

    @Test func twoReportsDisagreeingAboutWiFiIsNotedNotConcluded() async {
        let (store, _, source, _) = makeStore(lockedDownUnknown)
        store.setObserving(true, at: noon)
        source.status(.running, at: noon)
        await run(store, from: noon, through: noon + 15)
        source.events([.wlanStatus(.on)], at: noon + 20)
        await store.tick(now: noon + 20)
        #expect(store.bluetoothdWLAN == .on)
        let finding = store.day.findings.first { $0.kind == .reportsDisagree }
        #expect(finding != nil)
        #expect(finding?.kind.isContradiction == false)
    }

    @Test func anUnreadableLogIsBlindNeverCalm() async {
        let (store, _, source, _) = makeStore(normal)
        store.setObserving(true, at: noon)
        source.status(.running, at: noon)
        await store.tick(now: noon)
        source.status(.unavailable("log exited with status 64: must be admin"), at: noon + 3)
        await store.tick(now: noon + 3)
        #expect(store.standing == .blind("log exited with status 64: must be admin"))
        #expect(store.day.coverage == [TimeSpan(start: noon, end: noon + 3)])
        #expect(store.day.source == "unavailable — log exited with status 64: must be admin")
    }

    @Test func midnightSplitsTheRecordAndCarriesThePosture() async throws {
        let late = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 23, minute: 59, second: 50))!
        let midnight = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 5))!
        let (store, _, source, days) = makeStore(lockedDownBluetoothOn, at: late)
        store.setObserving(true, at: late)
        source.status(.running, at: late)
        for step in stride(from: 0.0, through: 20, by: 5) { await store.tick(now: late + step) }

        #expect(store.day.day == "2026-10-05")
        #expect(store.day.coverage.first?.start == midnight)
        #expect(store.day.postures.first?.span.start == midnight)
        #expect(store.day.postures.first?.posture == lockedDownBluetoothOn)
        let yesterday = try #require(days.loadNow(day: "2026-10-04"))
        #expect(yesterday.coverage.last?.end == midnight)
        #expect(yesterday.postures.last?.span.end == midnight)
    }

    @Test func nothingRawReachesTheSavedRecord() async throws {
        let source = BluetoothLogSource(command: .init("/bin/sh", ["-c", "exec sleep 30"]), restart: nil,
                                        processName: { _ in nil })
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let days = DayFileStore<RadioDay>(folder: "radio", root: root)
        let store = RadioStore(system: ScriptedSystem(normal), source: source, store: days, now: noon)
        store.setObserving(true, at: noon)
        await source.inject(lines: [Fixture.personal, Fixture.accessoryMessage, Fixture.accessoryEcho,
                                    Fixture.indication, Fixture.frameworkRequest, Fixture.deviceFound],
                            at: noon + 1)
        await store.tick(now: noon + 1)
        source.stopNow()
        #expect(store.day.accessoryMessages == 1)
        #expect(store.day.linesInterpreted == 5)
        store.flushNow()

        let saved = try String(contentsOf: days.url(day: store.day.day), encoding: .utf8)
        let inMemory = String(describing: store.day)
        let raw = Fixture.personalDetails + ["AA:BB:CC:DD:EE:01", "00000000-0000-0000-0000-00000000000"]
        for detail in raw {
            #expect(!saved.contains(detail), "the saved record contains \(detail)")
            #expect(!inMemory.contains(detail), "the in-memory record contains \(detail)")
        }
        // What it does keep: who asked, and the format of what it could not read.
        #expect(saved.contains("sharingd"))
        #expect(saved.contains("BTSmartRoutingDaemon"))
    }

    @Test func aDayFromAnOlderBuildStillLoads() throws {
        let data = Data(#"{"day":"2026-10-04"}"#.utf8)
        let day = try DayFileStore<RadioDay>.decoder.decode(RadioDay.self, from: data)
        #expect(day.day == "2026-10-04")
        #expect(day.minutes.isEmpty && day.findings.isEmpty && day.accessoryMessages == 0)

        var full = RadioDay(day: "2026-10-04", pelicanBuild: "test")
        full.minutes = [RadioMinute(minute: 42)]
        full.uninterpreted = ["bluetoothd Server.Core: Sending: %{public}s": 3]
        let encoded = try DayFileStore<RadioDay>.encoder.encode(full)
        #expect(try DayFileStore<RadioDay>.decoder.decode(RadioDay.self, from: encoded) == full)
    }

    @Test func interfaceCountersWrap() {
        let old = InterfaceCounter(name: "en0", packetsOut: UInt64(UInt32.max) - 1, packetsIn: 0, isUp: true)
        let new = InterfaceCounter(name: "en0", packetsOut: 3, packetsIn: 0, isUp: true)
        #expect(InterfaceCounter.sent(from: old, to: new) == 5)
    }
}
