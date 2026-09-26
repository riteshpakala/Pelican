import Foundation

/// One connection made by a Rao app's processes, kept for the day.
struct LedgerFlow: Sendable, Equatable, Codable, Identifiable {
    var id: String
    var pid: Int32
    /// The Rao process it belongs to ("Ambient", "sewn-server", …).
    var process: String
    /// The process that held the socket, when it differs (a daemon acting for the app).
    var socketOwner: String?
    var attribution: String
    var proto: FlowProto
    var direction: FlowDirection
    var scope: FlowScope
    var localAddress: String
    var localPort: UInt16?
    var remoteAddress: String
    var remotePort: UInt16?
    var remoteHost: String?
    var openedAt: Date
    var closedAt: Date?
    var bytesIn: UInt64
    var bytesOut: UInt64
    var mode: ConsentMode
    var classification: FlowClassification
    var seenBy: [FlowSourceKind]

    var facts: FlowFacts {
        FlowFacts(process: process, proto: proto, direction: direction, scope: scope,
                  localAddress: localAddress, localPort: localPort, remoteAddress: remoteAddress,
                  remotePort: remotePort, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    var remoteDisplay: String {
        if direction == .listening { return "listening" + (localPort.map { " :\($0)" } ?? "") }
        let host = remoteHost ?? classification.matchedHost ?? remoteAddress
        return host + (remotePort.map { ":\($0)" } ?? "")
    }
}

struct ObservedInterval: Sendable, Equatable, Codable {
    var start: Date
    var end: Date
}

/// One run of the app's main process.
struct AppRun: Sendable, Equatable, Codable, Identifiable {
    var pid: Int32
    var startTime: UInt64
    var launchedAt: Date
    var quitAt: Date?
    var version: String?
    var path: String?
    var id: String { "\(pid)-\(startTime)" }
}

struct ConsentEvent: Sendable, Equatable, Codable, Identifiable {
    enum Source: String, Sendable, Codable {
        case detected   // read from the app's settings
        case manual     // chosen in Pelican
        case carried    // in effect when the day began
    }
    var at: Date
    var mode: ConsentMode
    var source: Source
    var changes: [String]
    var id: String { "\(at.timeIntervalSince1970)-\(mode.rawValue)-\(source.rawValue)" }
}

struct LedgerFinding: Sendable, Equatable, Codable, Identifiable {
    var finding: RaoFinding
    var firstSeen: Date
    var lastSeen: Date
    var id: String { finding.id }
}

struct LedgerEvent: Sendable, Equatable, Codable, Identifiable {
    enum Kind: String, Sendable, Codable {
        case observing, stoppedObserving, launched, quit, consent, finding, unexpected, expected, capture
    }
    var at: Date
    var kind: Kind
    var text: String
    var id: String = UUID().uuidString
}

/// Loopback connections beyond the per-day cap are counted, not listed.
struct LocalAggregate: Sendable, Equatable, Codable {
    var connections = 0
    var bytes: UInt64 = 0
}

/// Everything Pelican observed about one app on one local calendar day.
struct DayLedger: Sendable, Equatable, Codable {
    static let formatVersion = 1
    static let loopbackCap = 2_000

    var formatVersion = DayLedger.formatVersion
    var day: String
    var appId: String
    var observed: [ObservedInterval] = []
    var runs: [AppRun] = []
    var consent: [ConsentEvent] = []
    var flows: [LedgerFlow] = []
    var localOverflow = LocalAggregate()
    var findings: [LedgerFinding] = []
    var events: [LedgerEvent] = []
    var capture: [String: String] = [:]   // source → status, as last seen
    var pelicanBuild: String
    var assessment: TrustAssessment?

    init(day: String, appId: String, pelicanBuild: String) {
        self.day = day
        self.appId = appId
        self.pelicanBuild = pelicanBuild
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func interval(calendar: Calendar = .current) -> DateInterval {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        var components = DateComponents()
        if parts.count == 3 { components.year = parts[0]; components.month = parts[1]; components.day = parts[2] }
        let start = calendar.date(from: components) ?? Date()
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    /// The consent mode in effect at a moment, from the day's consent log.
    func mode(at date: Date) -> ConsentMode? {
        consent.last { $0.at <= date }?.mode ?? consent.first?.mode
    }

    var loopbackFlowCount: Int { flows.filter { $0.scope == .loopback }.count }

    // MARK: Observation

    mutating func beginObserving(at date: Date) {
        observed.append(ObservedInterval(start: date, end: date))
    }

    mutating func heartbeat(at date: Date) {
        guard !observed.isEmpty else { return }
        observed[observed.count - 1].end = max(observed[observed.count - 1].end, date)
    }

    mutating func record(finding: RaoFinding, at date: Date) -> Bool {
        if let index = findings.firstIndex(where: { $0.id == finding.id }) {
            findings[index].lastSeen = date
            findings[index].finding = finding
            return false
        }
        findings.append(LedgerFinding(finding: finding, firstSeen: date, lastSeen: date))
        return true
    }

    // MARK: Derived

    /// Seconds of `interval` not covered by any observed interval.
    func unobserved(_ interval: DateInterval) -> [DateInterval] {
        let covered = observed
            .map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
            .sorted { $0.start < $1.start }
        var gaps: [DateInterval] = []
        var cursor = interval.start
        for window in covered where window.end > cursor && window.start < interval.end {
            if window.start > cursor { gaps.append(DateInterval(start: cursor, end: min(window.start, interval.end))) }
            cursor = max(cursor, window.end)
            if cursor >= interval.end { break }
        }
        if cursor < interval.end { gaps.append(DateInterval(start: cursor, end: interval.end)) }
        return gaps
    }

    struct HourBucket: Sendable, Equatable {
        var local = 0
        var expected = 0
        var unexpected = 0
        var bytesOutExternal: UInt64 = 0
    }

    func hourly(calendar: Calendar = .current) -> [HourBucket] {
        var buckets = Array(repeating: HourBucket(), count: 24)
        let dayStart = interval(calendar: calendar).start
        for flow in flows {
            let hour = max(0, min(23, Int(flow.openedAt.timeIntervalSince(dayStart) / 3600)))
            switch flow.classification.kind {
            case .local: buckets[hour].local += 1
            case .expected: buckets[hour].expected += 1
            case .unexpected: buckets[hour].unexpected += 1
            }
            if flow.scope == .external { buckets[hour].bytesOutExternal += flow.bytesOut }
        }
        return buckets
    }
}

enum TrustLevel: String, Sendable, Codable, Comparable {
    case trusted, review, breach

    private var rank: Int {
        switch self {
        case .trusted: return 0
        case .review: return 1
        case .breach: return 2
        }
    }
    static func < (a: TrustLevel, b: TrustLevel) -> Bool { a.rank < b.rank }

    var displayName: String {
        switch self {
        case .trusted: return "Within your consent"
        case .review: return "Worth a look"
        case .breach: return "Outside your consent"
        }
    }
}

struct TrustAssessment: Sendable, Equatable, Codable {
    var level: TrustLevel
    var reasons: [String]
    var summary: String
    var ranFor: TimeInterval
    var localConnections: Int
    var expectedConnections: Int
    var unexpectedConnections: Int
    var bytesLeftMac: UInt64
}

enum TrustAssessor {

    /// Pure: a day's ledger → its trust level, reasons and one-line summary.
    static func assess(_ ledger: DayLedger, app: RaoApp, now: Date, captureDegraded: Bool,
                       calendar: Calendar = .current) -> TrustAssessment {
        let day = ledger.interval(calendar: calendar)
        let dayEnd = min(day.end, now)
        var breach: [String] = []
        var review: [String] = []

        let unexpected = ledger.flows.filter { $0.classification.kind == .unexpected }
        if let first = unexpected.min(by: { $0.openedAt < $1.openedAt }) {
            let hosts = Set(unexpected.map { $0.remoteHost ?? $0.classification.matchedHost ?? $0.remoteAddress })
            breach.append("\(unexpected.count) connection\(unexpected.count == 1 ? "" : "s") outside your consent — to \(hosts.sorted().prefix(3).joined(separator: ", "))\(hosts.count > 3 ? "…" : ""), first at \(time(first.openedAt))")
        }
        for finding in ledger.findings where finding.finding.severity == .alarm {
            breach.append(finding.finding.title)
        }
        for finding in ledger.findings where finding.finding.severity == .warning {
            review.append(finding.finding.title)
        }

        var ranFor: TimeInterval = 0
        var unobservedTotal: TimeInterval = 0
        var firstGap: DateInterval?
        for run in ledger.runs {
            let start = max(run.launchedAt, day.start)
            let end = min(run.quitAt ?? now, dayEnd)
            guard end > start else { continue }
            let window = DateInterval(start: start, end: end)
            ranFor += window.duration
            for gap in ledger.unobserved(window) where gap.duration >= 10 {
                unobservedTotal += gap.duration
                if firstGap == nil || gap.start < firstGap!.start { firstGap = gap }
            }
        }
        if let firstGap, unobservedTotal >= 10 {
            review.append("\(app.name) ran for \(duration(unobservedTotal)) while Pelican wasn't watching (from \(time(firstGap.start)))")
        }

        let downloads = ledger.flows.filter { $0.classification.kind == .expected && $0.classification.firstRun }
        if !downloads.isEmpty {
            let bytes = downloads.reduce(UInt64(0)) { $0 + $1.bytesIn }
            review.append("\(app.name) downloaded its model today (\(formatBytes(bytes))) — expected once")
        }
        let odd = Set(ledger.flows.filter(\.classification.unknownLoopbackPort).compactMap { $0.remotePort ?? $0.localPort })
        if !odd.isEmpty {
            review.append("Local traffic on port\(odd.count == 1 ? "" : "s") \(odd.sorted().map(String.init).joined(separator: ", ")) that \(app.name) doesn't list")
        }
        if ledger.flows.contains(where: \.classification.modeWasUnknown) {
            review.append("\(app.name)'s mode couldn't be read, so it was held to on-device rules")
        }
        if captureDegraded && !ledger.runs.isEmpty {
            review.append("Live socket events were unavailable; connections shorter than a poll could be missed")
        }

        let local = ledger.flows.filter { $0.scope == .loopback && $0.direction == .outbound }.count
            + ledger.localOverflow.connections
        let expected = ledger.flows.filter { $0.classification.kind == .expected }.count
        let bytesLeft = ledger.flows.filter { $0.scope == .external }.reduce(UInt64(0)) { $0 + $1.bytesOut }

        let level: TrustLevel = !breach.isEmpty ? .breach : (!review.isEmpty ? .review : .trusted)
        var summary: String
        if ledger.runs.isEmpty && ledger.flows.isEmpty {
            summary = "\(app.name) hasn't run today."
        } else {
            var parts = [ledger.runs.isEmpty ? "\(app.name) hasn't run today" : "\(app.name) ran for \(duration(ranFor)) today"]
            parts.append("\(local.formatted()) local exchange\(local == 1 ? "" : "s")")
            if !unexpected.isEmpty {
                parts.append("\(unexpected.count) connection\(unexpected.count == 1 ? "" : "s") outside your consent")
            } else if expected > 0 {
                parts.append("\(expected) expected connection\(expected == 1 ? "" : "s")")
            }
            parts.append(bytesLeft == 0 ? "nothing left this Mac" : "\(formatBytes(bytesLeft)) left this Mac")
            summary = parts.joined(separator: " · ")
        }
        return TrustAssessment(level: level, reasons: breach + review, summary: summary, ranFor: ranFor,
                               localConnections: local, expectedConnections: expected,
                               unexpectedConnections: unexpected.count, bytesLeftMac: bytesLeft)
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let hours = total / 3600, minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}

/// Day ledgers on disk: ~/Library/Application Support/Pelican/ledger/<app>/<yyyy-mm-dd>.json
actor LedgerStore {
    nonisolated let root: URL
    static let keepDays = 30

    init(root: URL = LedgerStore.defaultRoot) {
        self.root = root
    }

    nonisolated static var defaultRoot: URL {
        if let override = ProcessInfo.processInfo.environment["PELICAN_LEDGER_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Pelican/ledger", isDirectory: true)
    }

    nonisolated func url(appId: String, day: String) -> URL {
        root.appendingPathComponent(appId, isDirectory: true).appendingPathComponent(day + ".json")
    }

    /// Synchronous, for launch: the saved day must be in place before anything is recorded.
    nonisolated func loadNow(appId: String, day: String) -> DayLedger? {
        guard let data = try? Data(contentsOf: url(appId: appId, day: day)) else { return nil }
        return try? Self.decoder.decode(DayLedger.self, from: data)
    }

    func load(appId: String, day: String) -> DayLedger? {
        guard let data = try? Data(contentsOf: url(appId: appId, day: day)) else { return nil }
        return try? Self.decoder.decode(DayLedger.self, from: data)
    }

    func save(_ ledger: DayLedger) throws {
        try Self.write(ledger, to: url(appId: ledger.appId, day: ledger.day))
    }

    /// Synchronous, for app termination.
    nonisolated func saveNow(_ ledger: DayLedger) {
        try? Self.write(ledger, to: url(appId: ledger.appId, day: ledger.day))
    }

    func days(appId: String) -> [String] {
        let dir = root.appendingPathComponent(appId, isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted(by: >)
    }

    func prune(appId: String, keep: Int = LedgerStore.keepDays) {
        for day in days(appId: appId).dropFirst(keep) {
            try? FileManager.default.removeItem(at: url(appId: appId, day: day))
        }
    }

    private static func write(_ ledger: DayLedger, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(ledger)
        try data.write(to: url, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
