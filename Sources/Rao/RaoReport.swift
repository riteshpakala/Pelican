import Foundation
import PelicanKit

/// A day's trust report: everything Pelican observed about one app, with the values macOS
/// reported, so anyone can check it. No constants from Pelican's side beyond the app profile.
struct RaoReport: Sendable, Codable {
    var generatedAt: Date
    var pelican: String
    var macOS: String
    var app: String
    var appSite: String
    var day: String
    var assessment: TrustAssessment
    var capture: [String: String]
    var consentNow: ConsentSnapshot?
    var declaredUsage: [String: String]
    var reference: InstalledReference?
    var processes: [RaoProcess]
    var ledger: DayLedger
}

extension TrustMonitor {
    /// The report for the day on screen (today, or a past day from history).
    func report(now: Date = Date()) -> RaoReport {
        let ledger = displayed
        let today = viewedDay == nil
        var capture: [String: String] = [:]
        for kind in FlowSourceKind.allCases {
            capture[kind.displayName] = today ? (captureStatus[kind]?.description ?? "not started") : (ledger.capture[kind.rawValue] ?? "not recorded")
        }
        return RaoReport(
            generatedAt: now,
            pelican: BuildInfo.current.line,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            app: app.name,
            appSite: app.siteURL.absoluteString,
            day: ledger.day,
            assessment: displayedAssessment,
            capture: capture,
            consentNow: today ? consent : nil,
            declaredUsage: declaredUsage,
            reference: today ? reference : nil,
            processes: today ? processes : [],
            ledger: ledger)
    }
}

enum RaoReportRenderer {

    static func json(_ report: RaoReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    static func markdown(_ r: RaoReport, calendar: Calendar = .current) -> String {
        let ledger = r.ledger
        var out: [String] = []
        let dayDate = ledger.interval(calendar: calendar).start
        out.append("# \(r.app) trust report — \(dayDate.formatted(date: .complete, time: .omitted))")
        out.append("")
        out.append("**\(r.assessment.level.displayName)** · \(r.assessment.summary)")
        out.append("")
        if r.assessment.reasons.isEmpty {
            out.append("Every connection \(r.app) made stayed within the consent you gave it, and its identity checked out.")
        } else {
            for reason in r.assessment.reasons { out.append("- \(escape(reason))") }
        }
        out.append("")

        out.append("## How this was observed")
        out.append("")
        out.append("| | |")
        out.append("|---|---|")
        out.append("| Pelican | \(escape(r.pelican)) |")
        out.append("| macOS | \(escape(r.macOS)) |")
        for (source, status) in r.capture.sorted(by: { $0.key < $1.key }) {
            out.append("| \(escape(source)) | \(escape(status)) |")
        }
        let observed = ledger.observed.map { "\(time($0.start))–\(time($0.end))" }.joined(separator: ", ")
        let watched = ledger.observed.reduce(0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) }
        out.append("| Watched | \(observed.isEmpty ? "not at all" : observed) (\(TrustAssessor.duration(watched))) |")
        out.append("| Report generated | \(r.generatedAt.formatted(date: .abbreviated, time: .standard)) |")
        out.append("")
        out.append("Pelican sees kernel sockets through macOS's NetworkStatistics events the moment they open and close, and polls `nettop` — which also sees connections made through the user-space network stack (URLSession) — every second while \(r.app) runs. URLSession keeps a connection open for about 30 seconds after a request, so those are seen too; a user-space connection opened and closed within one poll could be missed. Pelican only observes these connections; it does not block or alter them. Traffic outside the watched hours is not covered.")
        out.append("")

        out.append("## Consent")
        out.append("")
        if ledger.consent.isEmpty {
            out.append("No consent mode was recorded.")
        } else {
            out.append("| Time | Mode | Source | Change |")
            out.append("|---|---|---|---|")
            for event in ledger.consent {
                out.append("| \(time(event.at)) | \(event.mode.displayName) | \(event.source.rawValue) | \(escape(event.changes.joined(separator: "; "))) |")
            }
        }
        out.append("")
        if let consent = r.consentNow {
            out.append("\(r.app)'s saved settings (read from `\(consent.sourcePath)`):")
            out.append("")
            for setting in consent.settings { out.append("- \(setting.label): \(escape(setting.value))") }
            out.append("")
        }
        if !r.declaredUsage.isEmpty {
            out.append("Permissions \(r.app) declares it may ask for:")
            out.append("")
            for (key, text) in r.declaredUsage.sorted(by: { $0.key < $1.key }) {
                out.append("- \(UsageNames.name(for: key)): \u{201C}\(escape(text))\u{201D}")
            }
            out.append("")
        }

        out.append("## Identity")
        out.append("")
        if let reference = r.reference {
            let signature = reference.signature
            out.append("Installed copy: `\(reference.path)` \(reference.version ?? "") \(reference.build.map { "(\($0))" } ?? "") — signed as \(signature?.identifier ?? "?") by \(signature?.leafSubject ?? "no certificate"), team \(signature?.teamIdentifier ?? "none"), notarized: \(signature?.notarized.map { $0 ? "yes" : "no" } ?? "unknown").")
            out.append("")
        }
        if !r.processes.isEmpty {
            out.append("| Process | pid | Path | Signed as | Team | Certificate | Runtime | Notarized | Valid | cdhash |")
            out.append("|---|---|---|---|---|---|---|---|---|---|")
            for process in r.processes {
                let identity = process.identity
                let signature = identity?.signature
                out.append("| \(process.name) | \(process.pid) | \(escape(identity?.executablePath ?? "?")) | \(signature?.identifier ?? "?") | \(signature?.teamIdentifier ?? "—") | \(escape(signature?.leafSubject ?? (signature?.isAdHoc == true ? "ad-hoc" : "—"))) | \(yesNo(signature?.hardenedRuntime)) | \(yesNo(signature?.notarized)) | \(yesNo(signature?.isValid)) | \(signature?.cdHash.map { String($0.prefix(16)) } ?? "—") |")
            }
            out.append("")
        }
        let findings = ledger.findings.sorted { ($0.finding.severity, $0.firstSeen) > ($1.finding.severity, $1.firstSeen) }
        for finding in findings {
            out.append("- **\(finding.finding.severity.rawValue)** — \(escape(finding.finding.title)): \(escape(finding.finding.detail)) (\(time(finding.firstSeen))–\(time(finding.lastSeen)))")
        }
        if !findings.isEmpty { out.append("") }

        if !ledger.runs.isEmpty {
            out.append("## Runs")
            out.append("")
            out.append("| Started | Quit | pid | Version | Path |")
            out.append("|---|---|---|---|---|")
            for run in ledger.runs {
                out.append("| \(stamp(run.launchedAt)) | \(run.quitAt.map(time) ?? "still running") | \(run.pid) | \(run.version ?? "—") | \(escape(run.path ?? "—")) |")
            }
            out.append("")
        }

        let unexpected = ledger.flows.filter { $0.classification.kind == .unexpected }
        let expected = ledger.flows.filter { $0.classification.kind == .expected }
        out.append("## Connections outside your consent")
        out.append("")
        if unexpected.isEmpty { out.append("None.") } else { out.append(contentsOf: flowTable(unexpected)) }
        out.append("")
        out.append("## Expected connections that left this Mac")
        out.append("")
        if expected.isEmpty { out.append("None.") } else { out.append(contentsOf: flowTable(expected)) }
        out.append("")

        out.append("## Local connections (stayed on this Mac)")
        out.append("")
        let local = ledger.flows.filter { $0.classification.kind == .local }
        let grouped = Dictionary(grouping: local) { $0.classification.note }
        if grouped.isEmpty && ledger.localOverflow.connections == 0 {
            out.append("None.")
        } else {
            for (note, flows) in grouped.sorted(by: { $0.value.count > $1.value.count }) {
                out.append("- \(escape(note)): \(flows.count)")
            }
            if ledger.localOverflow.connections > 0 {
                out.append("- Further loopback connections, counted but not listed: \(ledger.localOverflow.connections) (\(formatBytes(ledger.localOverflow.bytes)))")
            }
        }
        out.append("")

        out.append("## Timeline")
        out.append("")
        for event in ledger.events.suffix(300) {
            out.append("- \(time(event.at)) — \(escape(event.text))")
        }
        out.append("")
        out.append("_Generated by \(escape(r.pelican)), an open-source monitor that does not block or alter traffic. \(r.app): \(r.appSite)_")
        return out.joined(separator: "\n") + "\n"
    }

    private static func flowTable(_ flows: [LedgerFlow]) -> [String] {
        var rows = ["| Opened | Closed | Process | Remote | Proto | Out | In | Mode | Why |", "|---|---|---|---|---|---|---|---|---|"]
        for flow in flows.sorted(by: { $0.openedAt < $1.openedAt }) {
            let remote = [flow.remoteHost ?? flow.classification.matchedHost, flow.remoteAddress]
                .compactMap { $0 }.filter { !$0.isEmpty }
            let unique = Array(NSOrderedSet(array: remote)) as? [String] ?? remote
            rows.append("| \(time(flow.openedAt)) | \(flow.closedAt.map(time) ?? "open") | \(flow.process)\(flow.socketOwner.map { " (via \($0))" } ?? "") | \(escape(unique.joined(separator: " / ")))\(flow.remotePort.map { ":\($0)" } ?? "") | \(flow.proto.rawValue) | \(formatBytes(flow.bytesOut)) | \(formatBytes(flow.bytesIn)) | \(flow.mode.displayName) | \(escape(flow.classification.note)) |")
        }
        return rows
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
    }

    private static func yesNo(_ value: Bool?) -> String {
        value.map { $0 ? "yes" : "no" } ?? "—"
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

/// Friendly names for Info.plist usage-description keys.
enum UsageNames {
    static func name(for key: String) -> String {
        let known: [String: String] = [
            "NSMicrophoneUsageDescription": "Microphone",
            "NSSpeechRecognitionUsageDescription": "Speech recognition",
            "NSCameraUsageDescription": "Camera",
            "NSAppleEventsUsageDescription": "Controlling other apps",
            "NSScreenCaptureUsageDescription": "Screen recording",
            "NSContactsUsageDescription": "Contacts",
            "NSCalendarsUsageDescription": "Calendars",
            "NSRemindersUsageDescription": "Reminders",
            "NSLocationUsageDescription": "Location",
            "NSLocationWhenInUseUsageDescription": "Location",
            "NSPhotoLibraryUsageDescription": "Photos",
            "NSDesktopFolderUsageDescription": "Desktop folder",
            "NSDocumentsFolderUsageDescription": "Documents folder",
            "NSDownloadsFolderUsageDescription": "Downloads folder",
            "NSLocalNetworkUsageDescription": "Local network",
            "NSBluetoothAlwaysUsageDescription": "Bluetooth",
        ]
        if let name = known[key] { return name }
        return key.replacingOccurrences(of: "NS", with: "").replacingOccurrences(of: "UsageDescription", with: "")
    }
}
