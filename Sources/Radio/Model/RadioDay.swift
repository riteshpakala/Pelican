import Foundation
import PelicanKit

/// A stretch of time, with whole-second ends (the day files store dates as ISO 8601).
package struct TimeSpan: Sendable, Codable, Hashable {
    package var start: Date
    package var end: Date

    package init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    package var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    package func contains(_ date: Date) -> Bool { date >= start && date <= end }

    /// Whether any part of `minute` falls inside the span.
    package func overlaps(minute: Int) -> Bool {
        let from = EpochMinute.start(minute)
        return from <= end && from.addingTimeInterval(60) > start
    }
}

/// What macOS reported for one stretch of time.
package struct PostureSpan: Sendable, Codable, Hashable {
    package var span: TimeSpan
    package var posture: RadioPosture

    package init(span: TimeSpan, posture: RadioPosture) {
        self.span = span
        self.posture = posture
    }
}

/// One minute of what macOS reported about Bluetooth. Only minutes with something in them are
/// kept.
package struct RadioMinute: Sendable, Codable, Hashable {
    package var minute: Int
    /// Reports that mean the radio sent something.
    package var transmissions: Int = 0
    /// Packets counted by link and audio reports.
    package var packets: Int = 0
    /// Passive scans started: the radio listening.
    package var listening: Int = 0
    /// Requests from processes to bluetoothd.
    package var requests: Int = 0
    /// Commands to the controller inside the Mac.
    package var commands: Int = 0
    /// Whether the posture was locked down at any point in this minute.
    package var lockedDown = false

    package init(minute: Int) { self.minute = minute }
}

/// One minute of movement on the radio chips' transports. Only minutes in which something moved
/// are kept.
package struct TransportMinute: Sendable, Codable, Hashable {
    package var minute: Int
    /// By `transportKey(link, direction)`.
    package var counts: [String: Int] = [:]
    /// Whether the posture was locked down at any point in this minute.
    package var lockedDown = false

    package init(minute: Int) { self.minute = minute }

    package func count(_ link: TransportLink, _ direction: TransportDirection) -> Int {
        counts[transportKey(link, direction)] ?? 0
    }

    /// Packets handed to the Bluetooth chip on the channels that carry payload.
    package var dataToBluetooth: Int { TransportLink.allCases.filter(\.carriesData).reduce(0) { $0 + count($1, .out) } }
}

/// Everything one client asked bluetoothd for today.
package struct ClientRollup: Sendable, Codable, Hashable, Identifiable {
    package var id: String
    package var label: String
    package var requests = 0
    package var scans = 0
    package var activeScans = 0
    package var indications = 0
    /// Requests by message name, capped at `RadioDay.messageCap` names.
    package var messages: [String: Int] = [:]
    package var firstSeen: Date
    package var lastSeen: Date

    package init(client: RadioClient, at time: Date) {
        id = client.key
        label = client.label
        firstSeen = time
        lastSeen = time
    }
}

/// A link's reports today.
package struct LinkRollup: Sendable, Codable, Hashable, Identifiable {
    package var id: String
    package var kind: LinkKind
    package var reports = 0
    /// Reports that counted a transmission.
    package var transmitting = 0
    package var packets = 0
    package var firstSeen: Date
    package var lastSeen: Date

    package init(id: String, kind: LinkKind, at time: Date) {
        self.id = id
        self.kind = kind
        firstSeen = time
        lastSeen = time
    }
}

/// One local day of what the radios did: what bluetoothd reported, and what the drivers counted
/// on the chips' transports. Nothing in here is a log line: the lines carry device names and
/// addresses, so only parsed counts and process names are kept.
package struct RadioDay: DayDocument, Sendable, Hashable {
    package static let formatVersion = 1
    package static let minuteCap = 1_500
    package static let spanCap = 500
    package static let findingCap = 500
    package static let clientCap = 200
    package static let uninterpretedCap = 200
    package static let commandCap = 200
    package static let messageCap = 40

    package var formatVersion = RadioDay.formatVersion
    package var day: String
    package var pelicanBuild: String
    package var lastSeen: Date?
    /// When bluetoothd's log was being read. Outside these, Pelican has no record at all.
    package var coverage: [TimeSpan] = []
    package var postures: [PostureSpan] = []
    package var minutes: [RadioMinute] = []
    package var clients: [ClientRollup] = []
    package var links: [LinkRollup] = []
    package var findings: [RadioFinding] = []
    package var commands: [String: Int] = [:]
    /// Lines Pelican could not interpret, by their format string (static text, never the
    /// message itself).
    package var uninterpreted: [String: Int] = [:]
    package var linesRead = 0
    package var linesInterpreted = 0
    package var devicesHeard = 0
    /// Messages connected accessories sent the Mac.
    package var accessoryMessages = 0
    /// Movement on the radio chips' transports, minute by minute.
    package var transportMinutes: [TransportMinute] = []
    /// The day's movement on each transport, by `transportKey(link, direction)`.
    package var transportTotals: [String: Int] = [:]
    /// Movement while Pelican was not watching — the Mac asleep, or watching paused. The drivers
    /// kept counting, so it is known how much moved, though not when.
    package var transportAway: [String: Int] = [:]
    /// Antenna requests by what Bluetooth wanted the air for.
    package var antennaReasons: [String: Int] = [:]
    /// The transports found on this Mac, by `TransportLink` raw value.
    package var transportLinks: [String] = []
    /// What the person asked to be switched off, if anything.
    package var quiet: QuietRequest?
    /// Records dropped at a cap.
    package var overflow = 0
    /// The log source's status, as last reported.
    package var source: String?
    /// The transport counters' status, as last reported.
    package var transportSource: String?

    package init(day: String, pelicanBuild: String) {
        self.day = day
        self.pelicanBuild = pelicanBuild
    }

    // Every field but the day is optional on disk, so a day written by an older build — or one
    // missing a field added later — still loads instead of being silently replaced.
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.formatVersion
        pelicanBuild = try c.decodeIfPresent(String.self, forKey: .pelicanBuild) ?? ""
        lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen)
        coverage = try c.decodeIfPresent([TimeSpan].self, forKey: .coverage) ?? []
        postures = try c.decodeIfPresent([PostureSpan].self, forKey: .postures) ?? []
        minutes = try c.decodeIfPresent([RadioMinute].self, forKey: .minutes) ?? []
        clients = try c.decodeIfPresent([ClientRollup].self, forKey: .clients) ?? []
        links = try c.decodeIfPresent([LinkRollup].self, forKey: .links) ?? []
        findings = try c.decodeIfPresent([RadioFinding].self, forKey: .findings) ?? []
        commands = try c.decodeIfPresent([String: Int].self, forKey: .commands) ?? [:]
        uninterpreted = try c.decodeIfPresent([String: Int].self, forKey: .uninterpreted) ?? [:]
        linesRead = try c.decodeIfPresent(Int.self, forKey: .linesRead) ?? 0
        linesInterpreted = try c.decodeIfPresent(Int.self, forKey: .linesInterpreted) ?? 0
        devicesHeard = try c.decodeIfPresent(Int.self, forKey: .devicesHeard) ?? 0
        accessoryMessages = try c.decodeIfPresent(Int.self, forKey: .accessoryMessages) ?? 0
        transportMinutes = try c.decodeIfPresent([TransportMinute].self, forKey: .transportMinutes) ?? []
        transportTotals = try c.decodeIfPresent([String: Int].self, forKey: .transportTotals) ?? [:]
        transportAway = try c.decodeIfPresent([String: Int].self, forKey: .transportAway) ?? [:]
        antennaReasons = try c.decodeIfPresent([String: Int].self, forKey: .antennaReasons) ?? [:]
        transportLinks = try c.decodeIfPresent([String].self, forKey: .transportLinks) ?? []
        quiet = try c.decodeIfPresent(QuietRequest.self, forKey: .quiet)
        overflow = try c.decodeIfPresent(Int.self, forKey: .overflow) ?? 0
        source = try c.decodeIfPresent(String.self, forKey: .source)
        transportSource = try c.decodeIfPresent(String.self, forKey: .transportSource)
    }

    // MARK: - Reading

    package var watched: TimeInterval { coverage.reduce(0) { $0 + $1.duration } }

    /// Minutes in which the Bluetooth radio sent something: bluetoothd reported a transmission,
    /// or payload went into the chip's transport.
    package var sendingMinutes: Set<Int> {
        Set(minutes.filter { $0.transmissions > 0 }.map(\.minute))
            .union(transportMinutes.filter { $0.dataToBluetooth > 0 }.map(\.minute))
    }

    package var transmittingMinutes: Int { sendingMinutes.count }

    package var lockedDownTransmittingMinutes: Int {
        Set(minutes.filter { $0.transmissions > 0 && $0.lockedDown }.map(\.minute))
            .union(transportMinutes.filter { $0.dataToBluetooth > 0 && $0.lockedDown }.map(\.minute)).count
    }

    package func total(_ link: TransportLink, _ direction: TransportDirection) -> Int {
        transportTotals[transportKey(link, direction)] ?? 0
    }

    package func away(_ link: TransportLink, _ direction: TransportDirection) -> Int {
        transportAway[transportKey(link, direction)] ?? 0
    }

    package func transportMinute(_ minute: Int) -> TransportMinute? { transportMinutes.first { $0.minute == minute } }

    package var contradictions: [RadioFinding] { findings.filter(\.kind.isContradiction) }

    package func covered(minute: Int) -> Bool { coverage.contains { $0.overlaps(minute: minute) } }

    /// The posture in force for most of a minute, or nil when none was recorded.
    package func posture(atMinute minute: Int) -> RadioPosture? {
        let middle = EpochMinute.start(minute).addingTimeInterval(30)
        return postures.last { $0.span.contains(middle) }?.posture
            ?? postures.last { $0.span.overlaps(minute: minute) }?.posture
    }

    package func minute(_ minute: Int) -> RadioMinute? { minutes.first { $0.minute == minute } }

    /// Share of log lines Pelican could read. Most of what bluetoothd logs is not about sending,
    /// so the share is naturally low; it is shown, not judged.
    package var interpretedShare: Double {
        linesRead == 0 ? 1 : Double(linesInterpreted) / Double(linesRead)
    }

    /// Many lines read and none understood: the sign that macOS changed what it logs.
    package var looksUnreadable: Bool { linesRead >= 500 && linesInterpreted == 0 }
}
