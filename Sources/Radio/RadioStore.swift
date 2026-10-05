import Combine
import Foundation
import PelicanKit

/// Watches what the Mac's radios do: what the radio chips' own transports carry, as their
/// drivers count it, and what bluetoothd reports about who asked for what.
///
/// Owns its sources, unlike the other feature stores, which the app feeds from the network
/// monitor: pausing stops the log child, and the time it was stopped is left uncovered.
@MainActor
package final class RadioStore: ObservableObject {

    @Published package private(set) var day: RadioDay
    @Published package private(set) var observing = false
    @Published package private(set) var posture: RadioPosture = .unknown
    /// bluetoothd's own view of Wi-Fi, from its last coexistence report.
    @Published package private(set) var bluetoothdWLAN: Reported = .unknown
    @Published package private(set) var sourceStatus: FlowSourceStatus = .stopped
    @Published package private(set) var transportStatus: FlowSourceStatus = .stopped
    @Published package private(set) var standing: RadioStanding = .paused
    /// What moved on each transport in the last second.
    @Published package private(set) var latestMovement = TransportMovement()
    /// When each transport last moved, by `TransportLink` raw value.
    @Published package private(set) var lastMoved: [String: Date] = [:]
    /// The Mac's network services, as macOS has them configured.
    @Published package private(set) var services: [NetworkService] = []
    /// What the person asked to be switched off, if anything.
    @Published package private(set) var quiet: QuietRequest?
    /// Whether what was switched off has stayed off.
    @Published package private(set) var quietStanding: QuietStanding = .notAsked
    /// A switch is being carried out — an authorization prompt may be up.
    @Published package private(set) var switching = false
    /// What came of the last switch, for the screen to show.
    @Published package private(set) var lastSwitch: String?

    package static let tickInterval: TimeInterval = 1
    /// How often the Mac's list of network services is re-read. The posture is read every tick;
    /// this is a file read and a plist parse, so it is slower and nothing live depends on it.
    package static let serviceInterval: TimeInterval = 5
    /// A gap this long between ticks means the Mac slept or Pelican was suspended; the gap is not
    /// counted as watched.
    package static let sleepGap: TimeInterval = 15
    /// How long a posture must have held before anything is judged against it, so a radio being
    /// switched off is not caught mid-switch.
    package static let settle: TimeInterval = 10
    package static let reasonCap = 40

    private let system: any RadioSystem
    private let source: any RadioLogSource
    private let store: DayFileStore<RadioDay>
    private let switcher: any NetworkSwitching

    /// The day being written. Published to `day` once per tick, so a burst of log lines is one
    /// update for the screen rather than dozens.
    private var today: RadioDay
    private var minuteIndex: [Int: Int] = [:]
    private var transportIndex: [Int: Int] = [:]
    private var openCoverage: Int?
    private var openPosture: Int?
    private var counters: [String: InterfaceCounter] = [:]
    private var countersAt: Date?
    private var meter = TransportMeter()
    private var lastTransportRead: Date?
    /// The next movement read spans time Pelican was not watching.
    private var awayPending = false
    private var started = false
    private var timer: Timer?
    private var tickRunning = false
    private var lastTick: Date?
    private var lastServiceRead: Date?
    private var saveScheduled = false

    package init(system: any RadioSystem = LiveRadioSystem(),
                 source: any RadioLogSource = BluetoothLogSource(),
                 store: DayFileStore<RadioDay> = DayFileStore(folder: "radio"),
                 switcher: any NetworkSwitching = LiveNetworkSwitch(),
                 now: Date = Date()) {
        self.system = system
        self.source = source
        self.store = store
        self.switcher = switcher
        let fresh = RadioDay(day: DayFileStore<RadioDay>.dayKey(for: now), pelicanBuild: BuildInfo.current.line)
        self.today = fresh
        self.day = fresh
    }

    // MARK: - Lifecycle

    package func start() {
        guard !started else { return }
        started = true
        if let saved = store.loadNow(day: today.day) { adopt(saved) }
        quiet = today.quiet
        publish()
        Task {
            await store.prune()
            await refreshServices()
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick(now: Date()) }
        }
    }

    package func setObserving(_ on: Bool, at now: Date = Date()) {
        guard on != observing else { return }
        observing = on
        let source = self.source
        if on {
            lastServiceRead = nil
            Task { await source.start() }
        } else {
            closeOpenSpans(at: now)
            // The drivers keep counting while Pelican is paused; what they count is filed as
            // unwatched when watching resumes.
            awayPending = true
            Task { await source.stop() }
        }
        publish()
    }

    /// Write the day synchronously.
    package func flushNow() {
        today.lastSeen = Date()
        store.saveNow(today)
    }

    /// For quitting: end the log child and close what is open. Call `flushNow()` after.
    package func shutdown() {
        source.stopNow()
        closeOpenSpans(at: Date())
    }

    // MARK: - Tick

    /// Once a second: count what moved on the transports, read the posture beside them, take
    /// what the log said, and keep the record's spans honest about sleep and midnight.
    /// Internal so tests can drive time.
    func tick(now: Date) async {
        guard !tickRunning else { return }
        tickRunning = true
        defer { tickRunning = false }

        if let last = lastTick, now.timeIntervalSince(last) > Self.sleepGap {
            closeOpenSpans(at: last)
            lastServiceRead = nil
            awayPending = true
        }
        lastTick = now
        rolloverIfNeeded(now)
        if observing, sourceStatus == .running, openCoverage == nil { openCoverage(at: now) }

        apply(await source.drain(), now: now)

        guard observing else {
            publish()
            return
        }
        // The posture is read on every tick, with the counters and in the same breath. It costs
        // well under a millisecond, and reading it any less often would mean judging live
        // counters against a stale idea of which radios are on — which reports a switch being
        // flipped as a radio misbehaving.
        let system = self.system
        let names = watchedInterfaces
        let reading = await Task.detached(priority: .utility) {
            (system.transports(), system.posture(), system.counters(named: names))
        }.value
        apply(posture: reading.1, counters: reading.2, at: now)
        apply(transports: reading.0, at: now)
        if quiet != nil { await checkQuiet(at: now) }
        if transportStatus == .running, openCoverage == nil { openCoverage(at: now) }
        extendOpenSpans(to: now)
        publish()
    }

    private func publish() {
        if day != today { day = today }
        if quiet != nil { updateQuietStanding() }
        let next = RadioAssessor.standing(day: today, observing: observing, source: sourceStatus,
                                          transports: transportStatus)
        if next != standing { standing = next }
    }

    // MARK: - Transports

    private func apply(transports snapshot: TransportSnapshot, at now: Date) {
        if snapshot.status != transportStatus {
            transportStatus = snapshot.status
            today.transportSource = snapshot.status.description
            if snapshot.status != .running, sourceStatus != .running { closeCoverage(at: now) }
        }
        let links = snapshot.links.map(\.rawValue).sorted()
        if links != today.transportLinks { today.transportLinks = links }

        let moved = meter.read(snapshot)
        let since = lastTransportRead
        lastTransportRead = now
        if latestMovement != moved { latestMovement = moved }
        if awayPending {
            // This movement spans time Pelican was not watching: known in amount, not in time.
            awayPending = false
            for (key, count) in moved.counts where count > 0 { today.transportAway[key, default: 0] += count }
            if !moved.isEmpty { scheduleSave() }
            return
        }
        guard !moved.isEmpty || !moved.reasons.isEmpty else { return }

        for (key, count) in moved.counts where count > 0 { today.transportTotals[key, default: 0] += count }
        for (reason, count) in moved.reasons where count > 0 {
            if today.antennaReasons[reason] != nil || today.antennaReasons.count < Self.reasonCap {
                today.antennaReasons[reason, default: 0] += count
            }
        }
        for link in TransportLink.allCases where moved.count(link, .out) + moved.count(link, .in) > 0 {
            lastMoved[link.rawValue] = now
        }
        recordMinute(moved, at: now)

        if posture.isLockedDown {
            for link in [TransportLink.hci, .acl, .sco, .iso] {
                let count = moved.count(link, .out)
                guard count > 0 else { continue }
                find(.dataIntoBluetoothWhileLockedDown, subject: link.label,
                     evidence: .counted(source: "the Bluetooth chip's driver"),
                     detail: "Packets went into the Bluetooth chip's \(link.label) channel — \(link.meaning) — while Wi-Fi was off and Lockdown Mode on.",
                     count: count, at: now)
            }
        }
        // You said you had switched Bluetooth off; the chip's own driver says otherwise.
        if quiet?.bluetooth == true, let since, since >= (quiet?.since ?? .distantFuture), moved.dataToBluetooth > 0 {
            find(.movedWhileSwitchedOff, subject: "Bluetooth chip",
                 evidence: .counted(source: "the Bluetooth chip's driver"),
                 detail: "Data went into the Bluetooth chip's transport after you said you had switched Bluetooth off.",
                 count: moved.dataToBluetooth, at: now)
        }
        // Judge the whole interval only if the posture had settled before it began.
        let settledThroughout = since.map(settled) ?? false
        if posture.bluetooth == .off, settledThroughout, moved.dataToBluetooth > 0 {
            find(.transmittedWhileBluetoothOff, subject: "Bluetooth chip",
                 evidence: .counted(source: "the Bluetooth chip's driver"),
                 detail: "Data went into the Bluetooth chip's transport while macOS reported Bluetooth off.",
                 count: moved.dataToBluetooth, at: now)
        }
        if posture.wifi == .off, settledThroughout {
            let airtime = moved.count(.wifiAirtime, .out)
            if airtime > 0 {
                find(.wifiTransmittedWhileOff, subject: "Wi-Fi radio",
                     evidence: .counted(source: "the Wi-Fi driver's airtime counter"),
                     detail: "The Wi-Fi radio counted time spent transmitting while macOS reported Wi-Fi off.",
                     count: airtime, at: now)
            }
            let bus = moved.count(.wifiBus, .out) + moved.count(.wifiBus, .in)
            if bus > 0 {
                find(.wifiChipBusyWhileOff, subject: "Wi-Fi chip",
                     evidence: .counted(source: "the Wi-Fi chip's bus driver"),
                     detail: "The Mac and the Wi-Fi chip kept exchanging doorbells and interrupts while macOS reported Wi-Fi off. Not necessarily a transmission: the chip may be doing housekeeping.",
                     count: bus, at: now)
            }
        }
        scheduleSave()
    }

    private func recordMinute(_ moved: TransportMovement, at time: Date) {
        let key = EpochMinute.of(time)
        let position: Int
        if let existing = transportIndex[key] {
            position = existing
        } else {
            guard today.transportMinutes.count < RadioDay.minuteCap else {
                today.overflow += 1
                return
            }
            today.transportMinutes.append(TransportMinute(minute: key))
            position = today.transportMinutes.count - 1
            transportIndex[key] = position
        }
        for (name, count) in moved.counts where count > 0 {
            today.transportMinutes[position].counts[name, default: 0] += count
        }
        if posture.isLockedDown { today.transportMinutes[position].lockedDown = true }
    }

    // MARK: - The log

    private func apply(_ batch: RadioBatch, now: Date) {
        for change in batch.status { applyStatus(change.status, at: change.at) }
        guard observing, batch.linesRead > 0 || !batch.events.isEmpty else { return }
        today.linesRead += batch.linesRead - batch.notJSON
        today.linesInterpreted += batch.events.count
        for (key, count) in batch.uninterpreted {
            if today.uninterpreted[key] != nil || today.uninterpreted.count < RadioDay.uninterpretedCap {
                today.uninterpreted[key, default: 0] += count
            }
        }
        for timed in batch.events { record(timed) }
        scheduleSave()
    }

    private func applyStatus(_ status: FlowSourceStatus, at time: Date) {
        sourceStatus = status
        today.source = status.description
        if status == .running {
            if observing, openCoverage == nil { openCoverage(at: time) }
        } else if transportStatus != .running {
            closeCoverage(at: time)
        }
    }

    private func record(_ timed: TimedEvent) {
        let at = timed.at
        switch timed.event {
        case .scanRequested(let client, let active):
            touch(client, at: at) { rollup in
                rollup.scans += 1
                if active == true { rollup.activeScans += 1 }
            }
        case .scanStopRequested(let client):
            touch(client, at: at) { $0.requests += 1 }
        case .scanStarted(let active):
            if !active { bump(at) { $0.listening += 1 } }
        case .request(let client, let message):
            touch(client, at: at) { rollup in
                rollup.requests += 1
                if rollup.messages[message] != nil || rollup.messages.count < RadioDay.messageCap {
                    rollup.messages[message, default: 0] += 1
                }
            }
            bump(at) { $0.requests += 1 }
        case .scanAgents(let clients):
            for client in clients { touch(client, at: at) { _ in } }
        case .indication(let client):
            touch(client, at: at) { $0.indications += 1 }
        case .linkReport(let kind, let handle, let txSuccess, let txFailed, _, _):
            link("\(kind.label) \(handle)", kind: kind, at: at) { rollup in
                rollup.reports += 1
                if txSuccess + txFailed > 0 {
                    rollup.transmitting += 1
                    rollup.packets += txSuccess + txFailed
                }
            }
        case .audioReport(let txPackets, _):
            link(LinkKind.audio.label, kind: .audio, at: at) { rollup in
                rollup.reports += 1
                if txPackets > 0 {
                    rollup.transmitting += 1
                    rollup.packets += txPackets
                }
            }
        case .connectionAdded:
            break
        case .controllerCommand(let name):
            if today.commands[name] != nil || today.commands.count < RadioDay.commandCap {
                today.commands[name, default: 0] += 1
            }
            bump(at) { $0.commands += 1 }
            if posture.bluetooth == .off, settled(at) {
                find(.commandsWhileBluetoothOff, subject: "Bluetooth controller",
                     evidence: .reported(source: "bluetoothd's log"),
                     detail: "The Mac kept sending commands to its Bluetooth controller while reporting Bluetooth off. Commands stay inside the Mac; they are not transmissions, but they show the controller was not idle.",
                     at: at)
            }
        case .wlanStatus(let status):
            bluetoothdWLAN = status
            if status == .on, posture.wifi == .off, settled(at) {
                find(.reportsDisagree, subject: "Wi-Fi",
                     evidence: .reported(source: "CoreWLAN and bluetoothd's log"),
                     detail: "CoreWLAN reported Wi-Fi off while bluetoothd reported WLAN on. Apple does not document what bluetoothd's line means, so which is right is not known.",
                     at: at)
            }
        case .devicesHeard(let count):
            today.devicesHeard += count
        case .accessoryMessage:
            today.accessoryMessages += 1
        case .echo:
            break
        }

        guard let transmission = timed.event.transmission else { return }
        bump(at) { minute in
            minute.transmissions += 1
            minute.packets += transmission.packets
        }
        if posture.isLockedDown {
            find(.transmittedWhileLockedDown, subject: transmission.subject,
                 evidence: .reported(source: "bluetoothd's log"),
                 detail: "\(transmission.subject) \(transmission.why) while Wi-Fi was off and Lockdown Mode on.",
                 at: at)
        }
        if posture.bluetooth == .off, settled(at) {
            find(.transmittedWhileBluetoothOff, subject: transmission.subject,
                 evidence: .reported(source: "bluetoothd's log"),
                 detail: "\(transmission.subject) \(transmission.why), yet macOS reported Bluetooth off.",
                 at: at)
        }
    }

    private func touch(_ client: RadioClient, at time: Date, _ change: (inout ClientRollup) -> Void) {
        if let position = today.clients.firstIndex(where: { $0.id == client.key }) {
            change(&today.clients[position])
            today.clients[position].lastSeen = max(today.clients[position].lastSeen, time)
            // A confirmed pid is better than a name alone.
            if case .process(_, let pid) = client, pid != nil { today.clients[position].label = client.label }
        } else if today.clients.count < RadioDay.clientCap {
            var rollup = ClientRollup(client: client, at: time)
            change(&rollup)
            today.clients.append(rollup)
        } else {
            today.overflow += 1
        }
    }

    private func link(_ id: String, kind: LinkKind, at time: Date, _ change: (inout LinkRollup) -> Void) {
        if let position = today.links.firstIndex(where: { $0.id == id }) {
            change(&today.links[position])
            today.links[position].lastSeen = max(today.links[position].lastSeen, time)
        } else if today.links.count < RadioDay.clientCap {
            var rollup = LinkRollup(id: id, kind: kind, at: time)
            change(&rollup)
            today.links.append(rollup)
        } else {
            today.overflow += 1
        }
    }

    private func bump(_ time: Date, _ change: (inout RadioMinute) -> Void) {
        let key = EpochMinute.of(time)
        let position: Int
        if let existing = minuteIndex[key] {
            position = existing
        } else {
            guard today.minutes.count < RadioDay.minuteCap else {
                today.overflow += 1
                return
            }
            today.minutes.append(RadioMinute(minute: key))
            position = today.minutes.count - 1
            minuteIndex[key] = position
        }
        change(&today.minutes[position])
        if posture.isLockedDown { today.minutes[position].lockedDown = true }
    }

    /// One finding per kind, subject and posture span; repeats add to its count.
    private func find(_ kind: RadioFinding.Kind, subject: String, evidence: RadioEvidence, detail: String,
                      count: Int = 1, at time: Date) {
        let span = openPosture.map { Int(today.postures[$0].span.start.timeIntervalSince1970) } ?? 0
        let id = "\(kind.rawValue)|\(subject)|\(span)"
        if let position = today.findings.firstIndex(where: { $0.id == id }) {
            // A state is one fact that goes on being true; only its end moves.
            if !kind.isState { today.findings[position].count += count }
            today.findings[position].lastSeen = max(today.findings[position].lastSeen, time)
            today.findings[position].detail = detail
        } else if today.findings.count < RadioDay.findingCap {
            today.findings.append(RadioFinding(id: id, kind: kind, subject: subject, evidence: evidence,
                                               detail: detail, count: count, firstSeen: time, lastSeen: time))
        } else {
            today.overflow += 1
        }
    }

    // MARK: - Posture

    private func apply(posture reading: RadioPosture, counters latest: [String: InterfaceCounter], at now: Date) {
        posture = reading
        if let open = openPosture, today.postures[open].posture == reading {
            today.postures[open].span.end = now
        } else {
            closePosture(at: now)
            if today.postures.count < RadioDay.spanCap {
                today.postures.append(PostureSpan(span: TimeSpan(start: now, end: now), posture: reading))
                openPosture = today.postures.count - 1
            } else {
                today.overflow += 1
            }
        }
        // Packets counted on an interface that should be quiet, between two readings both taken
        // after the posture settled.
        if let previous = countersAt, settled(previous), settled(now) {
            let wifiFamily = LiveRadioSystem.wifiFamily()
            let switchedOff = switchedOffInterfaces
            for (name, counter) in latest {
                guard let old = counters[name] else { continue }
                let sent = InterfaceCounter.sent(from: old, to: counter)
                guard sent > 0 else { continue }
                let packets = Int(min(sent, UInt64(Int.max)))
                if let service = switchedOff[name] {
                    find(.movedWhileSwitchedOff, subject: name,
                         evidence: .counted(source: "the kernel's interface counters"),
                         detail: "\(name) counted packets sent after you switched “\(service)” off.",
                         count: packets, at: now)
                } else if reading.wifi == .off, wifiFamily.contains(name) {
                    find(.packetsWhileWiFiOff, subject: name,
                         evidence: .counted(source: "the kernel's interface counters, against CoreWLAN"),
                         detail: "\(name) counted packets sent while macOS reported Wi-Fi off.",
                         count: packets, at: now)
                }
            }
        }
        counters = latest
        countersAt = now
        scheduleSave()
    }

    /// Interfaces belonging to a service the person switched off, by interface name.
    private var switchedOffInterfaces: [String: String] {
        guard let quiet else { return [:] }
        var out: [String: String] = [:]
        for service in services where quiet.services.contains(service.name) {
            if let interface = service.interface { out[interface] = service.name }
        }
        return out
    }

    private var watchedInterfaces: Set<String> {
        LiveRadioSystem.wifiFamily().union(switchedOffInterfaces.keys)
    }

    /// Whether the posture in force at `time` has held long enough to judge against.
    private func settled(_ time: Date) -> Bool {
        guard let open = openPosture else { return false }
        return time.timeIntervalSince(today.postures[open].span.start) >= Self.settle
    }

    // MARK: - Spans

    private func openCoverage(at time: Date) {
        guard openCoverage == nil else { return }
        guard today.coverage.count < RadioDay.spanCap else {
            today.overflow += 1
            return
        }
        today.coverage.append(TimeSpan(start: time, end: time))
        openCoverage = today.coverage.count - 1
    }

    private func closeCoverage(at time: Date) {
        guard let open = openCoverage else { return }
        today.coverage[open].end = max(today.coverage[open].start, time)
        openCoverage = nil
    }

    private func closePosture(at time: Date) {
        guard let open = openPosture else { return }
        today.postures[open].span.end = max(today.postures[open].span.start, time)
        openPosture = nil
        countersAt = nil
    }

    private func closeOpenSpans(at time: Date) {
        closeCoverage(at: time)
        closePosture(at: time)
    }

    private func extendOpenSpans(to time: Date) {
        if let open = openCoverage { today.coverage[open].end = max(today.coverage[open].end, time) }
        if let open = openPosture { today.postures[open].span.end = max(today.postures[open].span.end, time) }
    }

    // MARK: - Day

    private func adopt(_ saved: RadioDay) {
        today = saved
        minuteIndex = Dictionary(saved.minutes.enumerated().map { ($1.minute, $0) }, uniquingKeysWith: { first, _ in first })
        transportIndex = Dictionary(saved.transportMinutes.enumerated().map { ($1.minute, $0) },
                                    uniquingKeysWith: { first, _ in first })
        openCoverage = nil
        openPosture = nil
    }

    /// At midnight the open spans are split: the old day closes them, the new day opens them
    /// again, carrying the posture across.
    private func rolloverIfNeeded(_ now: Date) {
        let key = DayFileStore<RadioDay>.dayKey(for: now)
        guard key != today.day else { return }
        let midnight = Calendar.current.startOfDay(for: now)
        let coverageWasOpen = openCoverage != nil
        let carried = openPosture.map { today.postures[$0].posture }
        closeOpenSpans(at: midnight)
        today.lastSeen = midnight
        store.saveNow(today)

        adopt(RadioDay(day: key, pelicanBuild: BuildInfo.current.line))
        // What you switched off stays switched off across midnight, and so does the check.
        today.quiet = quiet
        if coverageWasOpen { openCoverage(at: midnight) }
        if let carried {
            today.postures.append(PostureSpan(span: TimeSpan(start: midnight, end: midnight), posture: carried))
            openPosture = today.postures.count - 1
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(5))
            saveScheduled = false
            today.lastSeen = Date()
            await store.save(today)
        }
    }

    // MARK: - Switching off, and checking it stayed off

    /// Re-read the Mac's network services. Read-only; needs no authorization.
    package func refreshServices() async {
        let switcher = self.switcher
        services = await Task.detached(priority: .utility) { switcher.services() }.value
    }

    /// Ask macOS to switch these off, and start checking that they stay off.
    ///
    /// Wi-Fi is switched through CoreWLAN, the same switch as the menu bar's. Wired services are
    /// disabled through `networksetup` under one authorization prompt. Bluetooth is yours to
    /// switch in Control Center: doing it here would need Bluetooth permission and would drop
    /// your keyboard and mouse.
    ///
    /// Each of these is a request to the same macOS Pelican is watching. What makes it worth
    /// anything is what happens next: the counters keep running, and anything that moves
    /// afterwards becomes a finding.
    package func turnOff(wifi: Bool, services serviceNames: [String], bluetooth: Bool,
                         at now: Date = Date()) async {
        guard !switching else { return }
        switching = true
        defer { switching = false }
        let switcher = self.switcher
        var notes: [String] = []
        var switchedWiFi = false
        var switchedServices: [String] = []

        if wifi {
            switch await Task.detached(priority: .userInitiated, operation: { switcher.setWiFi(on: false) }).value {
            case .done: switchedWiFi = true
            case .cancelled: notes.append("Wi-Fi: cancelled")
            case .failed(let why): notes.append("Wi-Fi: \(why)")
            }
        }
        if !serviceNames.isEmpty {
            switch await Task.detached(priority: .userInitiated,
                                       operation: { switcher.setServices(serviceNames, on: false) }).value {
            case .done: switchedServices = serviceNames
            case .cancelled: notes.append("wired services: you dismissed the authorization prompt")
            case .failed(let why): notes.append("wired services: \(why)")
            }
        }

        let previous = quiet
        let request = QuietRequest(
            since: previous?.since ?? now,
            wifi: switchedWiFi || previous?.wifi == true,
            services: Array(Set((previous?.services ?? []) + switchedServices)).sorted(),
            bluetooth: bluetooth || previous?.bluetooth == true)
        set(quiet: request.isEmpty ? nil : request)
        lastSwitch = notes.isEmpty
            ? "Switched off \(request.summary). Pelican is checking it stays off."
            : notes.joined(separator: " · ")
        await refreshServices()
        lastServiceRead = now
        // Deliberately no break check here. Switching something off is itself a change of
        // posture, and the readings take a moment to follow it; checking now would report the
        // switch Pelican just threw. The next tick checks, once the posture has settled.
        scheduleSave()
        publish()
    }

    /// Put back what Pelican switched off, and stop checking. Only services Pelican disabled are
    /// enabled again, so one that was already off stays off.
    package func restore() async {
        guard !switching, let quiet else { return }
        switching = true
        defer { switching = false }
        let switcher = self.switcher
        var notes: [String] = []

        if quiet.wifi {
            switch await Task.detached(priority: .userInitiated, operation: { switcher.setWiFi(on: true) }).value {
            case .done: break
            case .cancelled: notes.append("Wi-Fi: cancelled")
            case .failed(let why): notes.append("Wi-Fi: \(why)")
            }
        }
        if !quiet.services.isEmpty {
            let names = quiet.services
            switch await Task.detached(priority: .userInitiated,
                                       operation: { switcher.setServices(names, on: true) }).value {
            case .done: break
            case .cancelled:
                notes.append("wired services: you dismissed the authorization prompt")
            case .failed(let why): notes.append("wired services: \(why)")
            }
        }
        if notes.isEmpty {
            set(quiet: nil)
            lastSwitch = "Put back \(quiet.summary)."
        } else {
            lastSwitch = notes.joined(separator: " · ")
        }
        await refreshServices()
        scheduleSave()
        publish()
    }

    /// Whether what was switched off is still switched off. Anything that came back on is a
    /// finding: Pelican did not do it.
    ///
    /// Nothing is judged until the posture has held for `settle`, so flipping a switch — which
    /// is a posture change like any other — is never itself reported as a break.
    private func checkQuiet(at now: Date) async {
        guard let quiet, settled(now) else { return }
        if lastServiceRead.map({ now.timeIntervalSince($0) >= Self.serviceInterval }) ?? true {
            lastServiceRead = now
            await refreshServices()
        }
        if quiet.wifi, posture.wifi == .on {
            find(.turnedBackOn, subject: "Wi-Fi",
                 evidence: .counted(source: "CoreWLAN, against what you switched off"),
                 detail: "You switched Wi-Fi off at \(quiet.since.formatted(date: .omitted, time: .shortened)), and its radio is on again. Pelican did not do that.",
                 at: now)
        }
        for name in quiet.services {
            guard let service = services.first(where: { $0.name == name }), service.enabled else { continue }
            find(.turnedBackOn, subject: name,
                 evidence: .counted(source: "the system's network configuration, against what you switched off"),
                 detail: "You switched “\(name)” off, and it is enabled again. Pelican did not do that.",
                 at: now)
        }
        updateQuietStanding()
    }

    private func set(quiet request: QuietRequest?) {
        quiet = request
        today.quiet = request
        updateQuietStanding()
    }

    private func updateQuietStanding() {
        guard let quiet else {
            quietStanding = .notAsked
            return
        }
        let broken = today.findings.filter { finding in
            [.turnedBackOn, .movedWhileSwitchedOff, .wifiTransmittedWhileOff, .packetsWhileWiFiOff]
                .contains(finding.kind) && finding.lastSeen >= quiet.since
        }
        quietStanding = broken.isEmpty ? .holding(since: quiet.since) : .broken(broken.count)
    }

    // MARK: - Reading the record

    /// Every finding for the day, contradictions first.
    package var findings: [RadioFinding] {
        day.findings.sorted { a, b in
            if a.kind.isContradiction != b.kind.isContradiction { return a.kind.isContradiction }
            return a.lastSeen > b.lastSeen
        }
    }

    /// The menubar line.
    package var summaryLine: String {
        switch standing {
        case .paused: return "Radios: paused"
        case .contradiction(let count): return "Radios: \(count) contradiction\(count == 1 ? "" : "s")"
        case .blind: return "Radios: can't see the Bluetooth radio"
        case .lockedDown(let minutes): return "Radios: Bluetooth sent in \(minutes) min while locked down"
        case .transmitting(let minutes): return "Radios: Bluetooth sent in \(minutes) min today"
        case .nothingReported: return "Radios: nothing seen today"
        }
    }
}
