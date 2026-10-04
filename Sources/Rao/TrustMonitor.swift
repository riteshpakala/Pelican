import AppKit
import Combine
import Foundation
import PelicanKit

struct HistoryDay: Sendable, Equatable, Identifiable {
    var day: String
    var level: TrustLevel?
    var summary: String
    var id: String { day }
}

/// Watches one Rao app all day: attributes connections to its processes, judges each against
/// the consent the user has given, checks who the processes are, and keeps the day's ledger.
@MainActor
package final class TrustMonitor: ObservableObject {

    let app: RaoApp

    @Published private(set) var ledger: DayLedger
    @Published private(set) var assessment: TrustAssessment
    @Published private(set) var processes: [RaoProcess] = []
    @Published private(set) var findings: [RaoFinding] = []
    @Published private(set) var consent: ConsentSnapshot?
    @Published private(set) var reference: InstalledReference?
    @Published private(set) var declaredUsage: [String: String] = [:]
    @Published private(set) var observing = false
    @Published private(set) var captureStatus: [FlowSourceKind: FlowSourceStatus] = [:]
    @Published private(set) var history: [HistoryDay] = []
    /// A past day being viewed (read-only); nil = today.
    @Published private(set) var viewedDay: DayLedger?
    /// nil = follow the app's own setting.
    @Published private(set) var modeOverride: ConsentMode?

    /// Called when the trust level changes: (new assessment, previous level).
    var onLevelChange: ((TrustAssessment, TrustLevel) -> Void)?

    var effectiveMode: ConsentMode { modeOverride ?? consent?.mode ?? .unknown }
    var displayed: DayLedger { viewedDay ?? ledger }
    var displayedAssessment: TrustAssessment {
        viewedDay.map { $0.assessment ?? TrustAssessor.assess($0, app: app, now: $0.interval().end, captureDegraded: false) }
            ?? assessment
    }

    /// Ambient reaches the internet through URLSession, which only nettop sees: poll every
    /// second while its app process runs.
    package var captureDemand: AnyPublisher<CaptureDemand, Never> {
        $processes
            .map { $0.contains { $0.attribution.role == .app } ? CaptureDemand.userSpace : .idle }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    private let identities = ProcessIdentityCache()
    private let hosts: HostTable
    private let store: LedgerStore
    private let classifier: RaoClassifier

    private struct Resolved {
        var startTime: UInt64?
        var attribution: RaoAttribution?
        var identity: ProcessIdentity?
    }

    private var hostMap: [String: Set<String>] = [:]
    private var reverseNames: [String: String] = [:]
    private var resolved: [Int32: Resolved] = [:]
    private var resolving: Set<Int32> = []
    /// Live flow → ledger flow id; "" when counted in the loopback overflow.
    private var active: [FlowKey: String] = [:]
    private var index: [String: Int] = [:]
    private var pending: [FlowEvent] = []
    private var latestFlows: [Flow] = []
    private var loopbackStored = 0
    private var knownExternalHosts: Set<String> = []

    private var tickTimer: Timer?
    private var tickRunning = false
    private var saveScheduled = false
    private var started = false
    private var startedAt = Date()
    private var reconciled = false
    private var lastConsentFileDate: Date?
    private var lastReferenceRead: Date?
    private var lastHostRefresh: Date?
    private var hostRefreshInFlight = false

    private var overrideKey: String { "pelican.rao.\(app.id).modeOverride" }

    /// Ambient's monitor, as the app runs it.
    package convenience init() { self.init(app: .ambient) }

    init(app: RaoApp = .ambient, store: LedgerStore = LedgerStore()) {
        self.app = app
        self.store = store
        self.hosts = HostTable(hostnames: app.hostnamesToResolve)
        self.classifier = RaoClassifier(app: app)
        let ledger = DayLedger(day: DayLedger.dayKey(for: Date()), appId: app.id, pelicanBuild: BuildInfo.current.line)
        self.ledger = ledger
        self.assessment = TrustAssessor.assess(ledger, app: app, now: Date(), captureDegraded: false)
        if let raw = UserDefaults.standard.string(forKey: overrideKey) {
            modeOverride = ConsentMode(rawValue: raw)
        }
    }

    // MARK: - Lifecycle

    package func start() {
        guard !started else { return }
        started = true
        startedAt = Date()
        if let saved = store.loadNow(appId: app.id, day: ledger.day) {
            adopt(saved)
        }
        setObserving(true)
        Task {
            readConsent(Date())
            readReference()
            hostMap = await hosts.refresh()
            lastHostRefresh = Date()
            reclassifyExternal()
            await store.prune(appId: app.id)
            await refreshHistory()
            await tick()
        }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    /// Monitoring on or off (Pause/Resume). Time not observed is recorded as a gap.
    package func setObserving(_ on: Bool) {
        let now = Date()
        guard on != observing else { return }
        if on {
            ledger.beginObserving(at: now)
            event(.observing, "Pelican started watching \(app.name)", at: now)
        } else {
            ledger.heartbeat(at: now)
            event(.stoppedObserving, "Pelican stopped watching", at: now)
        }
        observing = on
        reassess()
        scheduleSave()
    }

    /// Before quitting: close the observed interval and write the ledger synchronously.
    package func flushNow() {
        ledger.heartbeat(at: Date())
        ledger.assessment = assessment
        store.saveNow(ledger)
    }

    func setModeOverride(_ mode: ConsentMode?) {
        guard mode != modeOverride else { return }
        modeOverride = mode
        if let mode { UserDefaults.standard.set(mode.rawValue, forKey: overrideKey) }
        else { UserDefaults.standard.removeObject(forKey: overrideKey) }
        let now = Date()
        let text = mode.map { "Set to \($0.displayName.lowercased()) in Pelican" } ?? "Following \(app.name)'s own setting"
        ledger.consent.append(ConsentEvent(at: now, mode: effectiveMode, source: .manual, changes: [text]))
        event(.consent, "Consent mode: \(effectiveMode.displayName). \(text).", at: now)
        reassess()
        scheduleSave()
    }

    func showDay(_ day: String?) {
        guard let day, day != ledger.day else { viewedDay = nil; return }
        Task { viewedDay = await store.load(appId: app.id, day: day) }
    }

    // MARK: - Snapshots

    package func ingest(_ snapshot: NetworkMonitor.Snapshot) {
        if captureStatus != snapshot.sourceStatus {
            for (kind, status) in snapshot.sourceStatus where captureStatus[kind] != status {
                ledger.capture[kind.rawValue] = status.description
                // Starting is implied by "started watching"; log trouble and recovery from it.
                let recovered = status == .running && captureStatus[kind] != nil && captureStatus[kind] != .stopped
                if observing, status != .running || recovered {
                    event(.capture, "\(kind.displayName): \(status.description)", at: Date())
                }
            }
            captureStatus = snapshot.sourceStatus
        }
        guard observing else { return }
        let now = Date()
        rolloverIfNeeded(now)
        ledger.heartbeat(at: now)
        latestFlows = snapshot.flows
        for flow in snapshot.flows where flow.resolvedHost != nil { reverseNames[flow.remoteAddress] = flow.resolvedHost }
        for flow in snapshot.recentClosed.prefix(200) where flow.resolvedHost != nil {
            reverseNames[flow.remoteAddress] = flow.resolvedHost
        }
        for event in snapshot.newEvents {
            switch event {
            case .opened(let flow, _), .closed(let flow, _):
                if isCandidate(flow) { pending.append(event) }
            case .verdictAssigned:
                break
            }
        }
        var changed = false
        for flow in snapshot.flows {
            if let id = active[flow.id], !id.isEmpty, let position = index[id] {
                changed = update(at: position, with: flow) || changed
            }
        }
        drain()
        if changed || !snapshot.newEvents.isEmpty {
            reassess()
            scheduleSave()
        }
    }

    private func isCandidate(_ flow: Flow) -> Bool {
        if active[flow.id] != nil { return true }
        if app.processNames.contains(flow.processName) { return true }
        if resolved[flow.pid]?.attribution != nil { return true }
        if let effective = flow.effectivePid, resolved[effective]?.attribution != nil { return true }
        return false
    }

    private static func flow(of event: FlowEvent) -> Flow? {
        switch event {
        case .opened(let flow, _), .closed(let flow, _): return flow
        case .verdictAssigned: return nil
        }
    }

    /// Apply queued events in order, pausing at the first whose process isn't identified yet.
    private func drain() {
        while let event = pending.first {
            guard let flow = Self.flow(of: event) else { pending.removeFirst(); continue }
            // A close for a flow already in the ledger needs no identification.
            let knownClose: Bool
            if case .closed = event, active[flow.id] != nil { knownClose = true } else { knownClose = false }
            if !knownClose, resolved[flow.pid] == nil {
                resolve([flow.pid])
                return
            }
            pending.removeFirst()
            apply(event)
        }
    }

    private func resolve(_ pids: Set<Int32>) {
        let todo = pids.subtracting(resolving)
        guard !todo.isEmpty else { return }
        resolving.formUnion(todo)
        Task {
            // The app first, so a helper can be recognised as its child.
            let ordered = todo.sorted { a, b in
                let an = nameFromFlows(a) == app.executableName, bn = nameFromFlows(b) == app.executableName
                return an && !bn
            }
            for pid in ordered {
                let identity = await identities.identity(for: pid)
                record(pid: pid, identity: identity)
            }
            resolving.subtract(todo)
            drain()
            reassess()
            scheduleSave()
        }
    }

    private func nameFromFlows(_ pid: Int32) -> String? {
        if let flow = latestFlows.first(where: { $0.pid == pid }) { return flow.processName }
        for event in pending { if let flow = Self.flow(of: event), flow.pid == pid { return flow.processName } }
        return nil
    }

    private func touchesKnownPort(_ flow: Flow) -> Bool {
        flow.scope == .loopback && (app.loopbackLabel(flow.localPort) != nil || app.loopbackLabel(flow.remotePort) != nil)
    }

    @discardableResult
    private func record(pid: Int32, identity: ProcessIdentity?) -> RaoAttribution? {
        let name = identity?.name ?? nameFromFlows(pid) ?? "pid \(pid)"
        let touches = latestFlows.contains { $0.pid == pid && touchesKnownPort($0) }
            || pending.contains { Self.flow(of: $0).map { $0.pid == pid && touchesKnownPort($0) } ?? false }
        let appPids = Set(resolved.filter { $0.value.attribution?.role == .app }.map(\.key))
        var attribution = RaoAttributor.attribute(
            name: name, identity: identity, parentPid: identity?.parentPid, appPids: appPids,
            touchesKnownPorts: touches, app: app)
        if identity == nil, attribution != nil {
            attribution?.evidence += " (it exited before Pelican could check it)"
        }
        resolved[pid] = Resolved(startTime: identity?.startTime, attribution: attribution, identity: identity)
        if attribution?.role == .app, let identity { recordLaunch(identity) }
        return attribution
    }

    private func attribution(for flow: Flow) -> (RaoAttribution, owner: String?)? {
        if let attribution = resolved[flow.pid]?.attribution { return (attribution, nil) }
        if let effective = flow.effectivePid, let base = resolved[effective]?.attribution {
            var delegated = base
            delegated.confidence = .delegated
            delegated.evidence = "\(flow.processName) acting for \(base.roleName(in: app)) (pid \(effective))"
            return (delegated, flow.processName)
        }
        return nil
    }

    private func apply(_ event: FlowEvent) {
        switch event {
        case .opened(let flow, let at):
            guard active[flow.id] == nil, let (attribution, owner) = attribution(for: flow) else { return }
            if let id = openEntry(matching: flow) {   // Pelican relaunched mid-connection
                active[flow.id] = id
                if let position = index[id] { update(at: position, with: flow) }
                return
            }
            let mode = ledger.mode(at: flow.firstSeen) ?? effectiveMode
            var entry = LedgerFlow(
                id: "\(flow.pid)|\(flow.proto.rawValue)|\(flow.id.local)|\(flow.id.remote)|\(Int(at.timeIntervalSince1970 * 1000))",
                pid: flow.pid,
                process: attribution.roleName(in: app),
                socketOwner: owner,
                attribution: attribution.evidence,
                proto: flow.proto,
                direction: flow.direction,
                scope: flow.scope,
                localAddress: flow.localAddress,
                localPort: flow.localPort,
                remoteAddress: flow.remoteAddress,
                remotePort: flow.remotePort,
                remoteHost: flow.resolvedHost ?? reverseNames[flow.remoteAddress],
                openedAt: flow.firstSeen,
                closedAt: nil,
                bytesIn: flow.bytesIn,
                bytesOut: flow.bytesOut,
                mode: mode,
                classification: FlowClassification(kind: .local, note: ""),
                seenBy: flow.seenBy.sorted { $0.rawValue < $1.rawValue })
            entry.classification = classify(entry)
            if entry.scope == .loopback && loopbackStored >= DayLedger.loopbackCap {
                if entry.direction == .outbound { ledger.localOverflow.connections += 1 }
                active[flow.id] = ""
                return
            }
            if entry.scope == .loopback { loopbackStored += 1 }
            ledger.flows.append(entry)
            index[entry.id] = ledger.flows.count - 1
            active[flow.id] = entry.id
            note(entry, previous: nil)

        case .closed(let flow, let at):
            guard let id = active.removeValue(forKey: flow.id) else { return }
            if id.isEmpty {
                ledger.localOverflow.bytes += flow.bytesIn + flow.bytesOut
                return
            }
            guard let position = index[id] else { return }
            update(at: position, with: flow)
            ledger.flows[position].closedAt = at

        case .verdictAssigned:
            break
        }
    }

    private func openEntry(matching flow: Flow) -> String? {
        let taken = Set(active.values)
        return ledger.flows.last {
            $0.closedAt == nil && $0.pid == flow.pid && $0.proto == flow.proto
                && $0.localAddress == flow.localAddress && $0.localPort == flow.localPort
                && $0.remoteAddress == flow.remoteAddress && $0.remotePort == flow.remotePort
                && !taken.contains($0.id)
        }?.id
    }

    /// Returns whether anything changed.
    @discardableResult
    private func update(at position: Int, with flow: Flow) -> Bool {
        var entry = ledger.flows[position]
        let before = entry
        entry.bytesIn = max(entry.bytesIn, flow.bytesIn)
        entry.bytesOut = max(entry.bytesOut, flow.bytesOut)
        entry.direction = flow.direction
        if entry.remoteHost == nil { entry.remoteHost = flow.resolvedHost ?? reverseNames[flow.remoteAddress] }
        let seen = Set(entry.seenBy).union(flow.seenBy)
        if seen.count != entry.seenBy.count { entry.seenBy = seen.sorted { $0.rawValue < $1.rawValue } }
        let classification = classify(entry)
        if classification != entry.classification {
            let previous = entry.classification
            entry.classification = classification
            ledger.flows[position] = entry
            note(entry, previous: previous)
            return true
        }
        guard entry != before else { return false }
        ledger.flows[position] = entry
        return true
    }

    private func hostnames(for address: String) -> [String] {
        var names = (hostMap[address] ?? []).sorted()
        if let reverse = reverseNames[address], !names.contains(reverse) { names.append(reverse) }
        return names
    }

    private func classify(_ entry: LedgerFlow) -> FlowClassification {
        classifier.classify(entry.facts, mode: entry.mode, hostnames: hostnames(for: entry.remoteAddress),
                            settings: consent?.booleans ?? [:])
    }

    private func note(_ entry: LedgerFlow, previous: FlowClassification?) {
        let now = Date()
        switch entry.classification.kind {
        case .unexpected where previous?.kind != .unexpected:
            event(.unexpected, "\(entry.process) → \(entry.remoteDisplay): \(entry.classification.note)", at: now)
            refreshHostsSoon()
        case .expected where entry.scope == .external:
            let host = entry.classification.matchedHost ?? entry.remoteHost ?? entry.remoteAddress
            if previous?.kind == .unexpected {
                event(.expected, "Recognised \(entry.process) → \(host): \(entry.classification.note)", at: now)
            } else if !knownExternalHosts.contains(host) {
                event(.expected, "\(entry.process) → \(host): \(entry.classification.note)", at: now)
            }
            knownExternalHosts.insert(host)
        default:
            break
        }
    }

    private func refreshHostsSoon() {
        guard !hostRefreshInFlight else { return }
        hostRefreshInFlight = true
        Task {
            if let map = await hosts.refreshIfStale(maxAge: 30) {
                hostMap = map
                lastHostRefresh = Date()
                reclassifyExternal()
            }
            hostRefreshInFlight = false
        }
    }

    private func reclassifyExternal() {
        var changed = false
        for position in ledger.flows.indices where ledger.flows[position].scope == .external {
            let classification = classify(ledger.flows[position])
            if classification != ledger.flows[position].classification {
                let previous = ledger.flows[position].classification
                ledger.flows[position].classification = classification
                note(ledger.flows[position], previous: previous)
                changed = true
            }
        }
        if changed { reassess(); scheduleSave() }
    }

    // MARK: - Periodic

    private func tick() async {
        guard !tickRunning else { return }
        tickRunning = true
        defer { tickRunning = false }
        let now = Date()
        rolloverIfNeeded(now)
        if observing { ledger.heartbeat(at: now) }
        readConsent(now)
        if lastReferenceRead.map({ now.timeIntervalSince($0) > 60 }) ?? true { readReference() }
        if let last = lastHostRefresh, now.timeIntervalSince(last) > 300, !hostRefreshInFlight {
            hostRefreshInFlight = true
            hostMap = await hosts.refresh()
            lastHostRefresh = Date()
            hostRefreshInFlight = false
            reclassifyExternal()
        }

        // Who is running now.
        let found = await identities.scan(names: app.processNames)
        var present: [RaoProcess] = []
        for identity in found {
            // Recomputed every tick: port affinity and parentage can appear after first sight.
            guard let attribution = record(pid: identity.pid, identity: identity) else { continue }
            let parentName = identity.parentPid.flatMap { ProcessIdentity.bsdInfo(pid: $0)?.name }
            present.append(RaoProcess(pid: identity.pid, name: identity.name, attribution: attribution,
                                      identity: identity, parentName: parentName))
        }
        present.sort { ($0.attribution.role == .app ? 0 : 1, $0.name) < ($1.attribution.role == .app ? 0 : 1, $1.name) }
        if present != processes { processes = present }

        for process in present where process.attribution.role == .app {
            if let identity = process.identity { recordLaunch(identity) }
        }
        for position in ledger.runs.indices where ledger.runs[position].quitAt == nil {
            let run = ledger.runs[position]
            if !present.contains(where: { $0.pid == run.pid && $0.identity?.startTime == run.startTime }) {
                ledger.runs[position].quitAt = now
                event(.quit, "\(app.name) quit (pid \(run.pid))", at: now)
            }
        }
        // Forget pids that are gone.
        for (pid, entry) in resolved where !resolving.contains(pid) {
            let current = ProcessIdentity.bsdInfo(pid: pid)?.startTime
            if current == nil || (entry.startTime != nil && current != entry.startTime) {
                resolved.removeValue(forKey: pid)
            }
        }

        if let bundle = present.first(where: { $0.attribution.role == .app })?.identity?.bundlePath
            ?? reference?.path {
            let usage = ProcessIdentity.declaredUsage(bundlePath: bundle)
            if usage != declaredUsage { declaredUsage = usage }
        }

        let current = RaoIdentityAuditor.audit(app: app, processes: present, reference: reference)
        if current != findings { findings = current }
        if observing {
            for finding in current where ledger.record(finding: finding, at: now) {
                if finding.severity >= .warning {
                    event(.finding, finding.title, at: now)
                }
            }
        }

        if !reconciled, now.timeIntervalSince(startedAt) > 8 { reconcileCarriedFlows() }
        reassess()
        scheduleSave()
    }

    private func recordLaunch(_ identity: ProcessIdentity) {
        guard !ledger.runs.contains(where: { $0.pid == identity.pid && $0.startTime == identity.startTime }) else { return }
        let launchedAt = identity.launchedAt ?? Date()
        let previousVersion = ledger.runs.last?.version
        ledger.runs.append(AppRun(pid: identity.pid, startTime: identity.startTime, launchedAt: launchedAt,
                                  quitAt: nil, version: identity.bundleVersion, path: identity.executablePath))
        let version = identity.bundleVersion.map { " \($0)" } ?? ""
        let firstObserved = ledger.observed.first?.start ?? Date()
        if launchedAt < firstObserved.addingTimeInterval(-5) {
            event(.launched, "\(app.name)\(version) was already running (since \(TrustAssessor.time(launchedAt)))", at: Date())
        } else {
            event(.launched, "\(app.name)\(version) started", at: launchedAt)
        }
        if let previousVersion, let current = identity.bundleVersion, previousVersion != current {
            event(.finding, "\(app.name) was updated from \(previousVersion) to \(current)", at: Date())
        }
    }

    /// Flows left open in a ledger written by an earlier session that this session never saw
    /// again closed while Pelican wasn't running.
    private func reconcileCarriedFlows() {
        reconciled = true
        let live = Set(active.values)
        let previousEnd = ledger.observed.dropLast().last?.end
        for position in ledger.flows.indices where ledger.flows[position].closedAt == nil && !live.contains(ledger.flows[position].id) {
            ledger.flows[position].closedAt = previousEnd ?? ledger.flows[position].openedAt
        }
    }

    private func readConsent(_ now: Date) {
        guard let store = app.consentStore else { return }
        guard let url = ConsentDetector.newestFile(store) else {
            if ledger.consent.isEmpty {
                ledger.consent.append(ConsentEvent(at: now, mode: effectiveMode, source: .detected,
                                                   changes: ["\(app.name)'s settings file wasn't found"]))
            }
            return
        }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if consent != nil, modified == lastConsentFileDate { return }
        lastConsentFileDate = modified
        guard let snapshot = ConsentDetector.read(url: url, store: store) else { return }
        let previous = consent
        let previousMode = effectiveMode
        consent = snapshot
        let changes = snapshot.changes(since: previous)
        if previous == nil {
            if ledger.consent.last?.mode != effectiveMode || ledger.consent.isEmpty {
                ledger.consent.append(ConsentEvent(at: now, mode: effectiveMode, source: .detected, changes: []))
                event(.consent, "\(app.name) is set to \(snapshot.mode.displayName.lowercased())", at: now)
            }
        } else if !changes.isEmpty || previousMode != effectiveMode {
            ledger.consent.append(ConsentEvent(at: now, mode: effectiveMode, source: .detected, changes: changes))
            event(.consent, "\(app.name)'s settings changed: \(changes.joined(separator: "; "))", at: now)
        }
    }

    private func readReference() {
        lastReferenceRead = Date()
        let app = self.app
        Task {
            let reference = await Task.detached(priority: .utility) { InstalledReference.read(app: app) }.value
            if reference != self.reference { self.reference = reference }
        }
    }

    // MARK: - Day boundaries and persistence

    private func adopt(_ saved: DayLedger) {
        var saved = saved
        saved.pelicanBuild = BuildInfo.current.line
        ledger = saved
        index = Dictionary(uniqueKeysWithValues: ledger.flows.enumerated().map { ($1.id, $0) })
        loopbackStored = ledger.loopbackFlowCount
        knownExternalHosts = Set(ledger.flows.filter { $0.scope == .external && $0.classification.kind == .expected }
            .map { $0.classification.matchedHost ?? $0.remoteHost ?? $0.remoteAddress })
    }

    private func rolloverIfNeeded(_ now: Date) {
        let today = DayLedger.dayKey(for: now)
        guard today != ledger.day else { return }
        let end = ledger.interval().end
        if observing { ledger.heartbeat(at: end) }
        ledger.assessment = TrustAssessor.assess(ledger, app: app, now: end, captureDegraded: captureDegraded)
        store.saveNow(ledger)

        var next = DayLedger(day: today, appId: app.id, pelicanBuild: BuildInfo.current.line)
        let start = next.interval().start
        next.consent = [ConsentEvent(at: start, mode: effectiveMode, source: .carried, changes: [])]
        if observing { next.beginObserving(at: start) }
        next.runs = ledger.runs.filter { $0.quitAt == nil }
        var carried: [LedgerFlow] = []
        for id in active.values where !id.isEmpty {
            if let position = index[id] { carried.append(ledger.flows[position]) }
        }
        next.flows = carried
        ledger = next
        index = Dictionary(uniqueKeysWithValues: ledger.flows.enumerated().map { ($1.id, $0) })
        active = active.filter { !$0.value.isEmpty && index[$0.value] != nil }
        loopbackStored = ledger.loopbackFlowCount
        knownExternalHosts = []
        viewedDay = nil
        Task { await refreshHistory() }
    }

    private var captureDegraded: Bool {
        if case .unavailable = captureStatus[.nstat] { return true }
        return false
    }

    private func reassess() {
        let next = TrustAssessor.assess(ledger, app: app, now: Date(), captureDegraded: captureDegraded)
        guard next != assessment else { return }
        let previous = assessment.level
        assessment = next
        ledger.assessment = next
        if next.level != previous, Date().timeIntervalSince(startedAt) > 10 {
            onLevelChange?(next, previous)
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            saveScheduled = false
            try? await store.save(ledger)
        }
    }

    func refreshHistory() async {
        var rows: [HistoryDay] = []
        for day in await store.days(appId: app.id).prefix(LedgerStore.keepDays) where day != ledger.day {
            let saved = await store.load(appId: app.id, day: day)
            rows.append(HistoryDay(day: day, level: saved?.assessment?.level, summary: saved?.assessment?.summary ?? ""))
        }
        history = rows
    }

    private func event(_ kind: LedgerEvent.Kind, _ text: String, at date: Date) {
        ledger.events.append(LedgerEvent(at: date, kind: kind, text: text))
        if ledger.events.count > 2_000 { ledger.events.removeFirst(ledger.events.count - 2_000) }
    }

    // MARK: - For the model and the report

    /// The day's external connections as flows, for the on-device analyst.
    var externalFlowsForAnalysis: [Flow] {
        displayed.flows.filter { $0.scope == .external }.map { $0.asFlow() }
    }
}

extension LedgerFlow {
    func asFlow() -> Flow {
        let key = FlowKey(
            pid: pid, proto: proto,
            local: EndpointFormat.string(address: localAddress.isEmpty ? nil : localAddress, port: localPort, ipv6: proto.isIPv6),
            remote: EndpointFormat.string(address: remoteAddress.isEmpty ? nil : remoteAddress, port: remotePort, ipv6: proto.isIPv6))
        return Flow(
            id: key, processName: process, pid: pid, proto: proto,
            localAddress: localAddress, localPort: localPort, remoteAddress: remoteAddress, remotePort: remotePort,
            interface: "", state: closedAt == nil ? .established : .closed, direction: direction,
            bytesIn: bytesIn, bytesOut: bytesOut, deltaIn: 0, deltaOut: 0,
            firstSeen: openedAt, lastSeen: closedAt ?? Date(), resolvedHost: remoteHost ?? classification.matchedHost,
            verdict: nil, effectivePid: nil, scope: scope, seenBy: Set(seenBy))
    }
}
