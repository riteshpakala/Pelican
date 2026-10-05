import Combine
import Foundation
import PelicanKit

/// A day of exposure findings. Values are never in here — only what was found, how Pelican
/// knows, and a masked sample.
package struct GuardDay: DayDocument, Sendable, Hashable {
    package static let formatVersion = 1

    package var formatVersion: Int
    package var day: String
    package var findings: [ExposureFinding]
    package var profiles: [EndpointProfile]

    package init(day: String) {
        self.formatVersion = Self.formatVersion
        self.day = day
        self.findings = []
        self.profiles = []
    }

    package var seen: [ExposureFinding] { findings.filter(\.evidence.isSeen) }
    package var likely: [ExposureFinding] { findings.filter { !$0.evidence.isSeen } }
}

/// Watches what personal information leaves this Mac.
///
/// Two kinds of finding, never mixed: what Pelican *read*, and what it *expects* based on
/// something it can name. Until inspection is turned on, the only readable text is hostnames
/// and the command lines of what agents run, so most findings are predictions — and each says
/// what it rests on.
@MainActor
package final class LeakGuard: ObservableObject {

    @Published package private(set) var day: GuardDay
    @Published package private(set) var observing = false

    private let detectors: [any ExposureDetector]
    private let predictor = ExposurePredictor()
    private let store: DayFileStore<GuardDay>
    private var saveScheduled = false
    private var started = false
    /// Endpoints already predicted for, so one connection does not re-add its findings.
    private var predicted: Set<String> = []

    package init(detectors: [any ExposureDetector]? = nil,
                 store: DayFileStore<GuardDay> = DayFileStore(folder: "guard")) {
        self.detectors = detectors ?? [
            MachineIdentityDetector.current(),
            PatternDetector(),
            FieldNameDetector(),
        ]
        self.store = store
        self.day = GuardDay(day: DayFileStore<GuardDay>.dayKey(for: Date()))
    }

    package func start() {
        guard !started else { return }
        started = true
        if let saved = store.loadNow(day: day.day) { day = saved }
        Task { await store.prune() }
    }

    package func setObserving(_ on: Bool) { observing = on }

    package func flushNow() { store.saveNow(day) }

    // MARK: - What Pelican can read

    /// Scan text Pelican could actually read, and record what it finds as *seen*. One call is
    /// one sample of what this endpoint carries.
    @discardableResult
    package func scan(_ text: String, where location: String, originName: String,
                      toolID: String? = nil, endpoint: String, at time: Date = Date()) -> [ExposureFinding] {
        let added = detect(text, where: location, originName: originName, toolID: toolID,
                           endpoint: endpoint, at: time)
        if !added.isEmpty {
            learn(endpoint: endpoint, originName: originName, categories: added.map(\.category), at: time)
        }
        return added
    }

    /// Scan a readable exchange end to end. One exchange is one sample, however many of its
    /// parts carried something. Used from M4 on; exercised by tests now.
    @discardableResult
    package func scan(_ exchange: InspectedExchange) -> [ExposureFinding] {
        var added: [ExposureFinding] = []
        for part in exchange.scannable {
            added += detect(part.text, where: part.where, originName: exchange.originName,
                            toolID: exchange.toolID, endpoint: exchange.authority, at: exchange.startedAt)
        }
        if !added.isEmpty {
            learn(endpoint: exchange.authority, originName: exchange.originName,
                  categories: added.map(\.category), at: exchange.startedAt)
        }
        return added
    }

    private func detect(_ text: String, where location: String, originName: String,
                        toolID: String?, endpoint: String, at time: Date) -> [ExposureFinding] {
        guard observing, !text.isEmpty else { return [] }
        var added: [ExposureFinding] = []
        for detector in detectors {
            for detection in detector.scan(text) {
                let finding = ExposureFinding(
                    id: "\(originName)|\(endpoint)|\(detection.category.rawValue)|\(detection.subject)|seen",
                    subject: detection.describedSubject,
                    category: detection.category,
                    evidence: .seen(where: location),
                    detail: "Found in the \(location) of a request from \(originName) to \(endpoint).",
                    maskedSample: ExposureMask.sample(detection.value, category: detection.category),
                    originName: originName, toolID: toolID, endpoint: endpoint,
                    firstSeen: time, lastSeen: time)
                record(finding)
                added.append(finding)
            }
        }
        return added
    }

    // MARK: - What Pelican cannot read

    /// Record what an encrypted connection probably carried, labelled as a prediction.
    package func predict(originName: String, toolID: String?, endpoint: String,
                         candidates: [String], claims: [String] = [],
                         bytesOut: UInt64, bytesIn: UInt64, at time: Date = Date()) {
        guard observing else { return }
        let key = "\(originName)|\(endpoint)|\(bytesOut > 1_048_576)"
        guard !predicted.contains(key) else { return }
        let profile = day.profiles.first { $0.originName == originName && $0.endpoint == endpoint }
        let findings = predictor.predict(
            originName: originName, toolID: toolID, endpoint: endpoint, candidates: candidates,
            claims: claims, profile: profile, bytesOut: bytesOut, bytesIn: bytesIn, at: time)
        // A connection seen before its address has a name yields nothing; don't let that first
        // uninformed look stop a later one that knows where it went.
        guard !findings.isEmpty else { return }
        predicted.insert(key)
        for finding in findings { record(finding) }
    }

    // MARK: - Watching the AI tools

    /// One connection an AI tool made. Pelican cannot read it, so this produces predictions —
    /// except for the command line of something the tool ran, which it can read.
    ///
    /// `rawCommand` is scanned and dropped: only a masked finding survives.
    package func observe(flow: ToolFlowFacts, claims: [String], rawCommand: [String]?) {
        guard observing else { return }
        if let rawCommand, !rawCommand.isEmpty {
            scan(rawCommand.joined(separator: " "), where: "command \(flow.originName) was run with",
                 originName: flow.originName, toolID: flow.toolID, endpoint: flow.endpoint,
                 at: flow.at)
        }
        predict(originName: flow.originName, toolID: flow.toolID, endpoint: flow.endpoint,
                candidates: flow.candidates, claims: claims,
                bytesOut: flow.bytesOut, bytesIn: flow.bytesIn, at: flow.at)
    }

    // MARK: - Test seam (internal; used by the tests through @testable import)

    func inject(_ finding: ExposureFinding) { record(finding) }

    // MARK: - Record

    private func record(_ finding: ExposureFinding) {
        if let position = day.findings.firstIndex(where: { $0.id == finding.id }) {
            day.findings[position].count += 1
            day.findings[position].lastSeen = max(day.findings[position].lastSeen, finding.lastSeen)
            // A reading always replaces a guess about the same thing.
            if finding.evidence.isSeen, !day.findings[position].evidence.isSeen {
                day.findings[position].evidence = finding.evidence
                day.findings[position].detail = finding.detail
                day.findings[position].maskedSample = finding.maskedSample
            }
        } else {
            day.findings.append(finding)
        }
        scheduleSave()
    }

    /// Remember what an endpoint carried, as categories and counts only.
    private func learn(endpoint: String, originName: String, categories: [DataCategory], at time: Date) {
        let id = "\(originName)|\(endpoint)"
        if let position = day.profiles.firstIndex(where: { $0.id == id }) {
            day.profiles[position].samples += 1
            day.profiles[position].lastSeen = time
            day.profiles[position].categories = Array(Set(day.profiles[position].categories)
                .union(categories)).sorted { $0.rawValue < $1.rawValue }
        } else {
            day.profiles.append(EndpointProfile(
                id: id, originName: originName, endpoint: endpoint,
                categories: Array(Set(categories)).sorted { $0.rawValue < $1.rawValue },
                samples: 1, since: time, lastSeen: time))
        }
    }

    // MARK: - Reading the record

    package func findings(forTool toolID: String?) -> [ExposureFinding] {
        let chosen = toolID.map { id in day.findings.filter { $0.toolID == id } } ?? day.findings
        return chosen.sorted { a, b in
            if a.evidence.isSeen != b.evidence.isSeen { return a.evidence.isSeen }
            if a.category.isSensitive != b.category.isSensitive { return a.category.isSensitive }
            return a.lastSeen > b.lastSeen
        }
    }

    /// Findings tied to one process name, for the Connections and Processes screens.
    package func findings(forOrigin originName: String) -> [ExposureFinding] {
        day.findings.filter { $0.originName == originName }
    }

    /// Where the day stands at a glance. Deliberately not a claim that anything is "safe":
    /// Pelican cannot read most traffic, so the calm state means *nothing was noticed*, which
    /// is a weaker and more honest thing to say.
    package enum Standing: Equatable {
        /// Something personal was actually read leaving this Mac.
        case seen(Int)
        /// Only inferences: the traffic was encrypted and something about it suggests this.
        case likely(Int)
        /// Nothing noticed today — within the narrow part Pelican can examine.
        case quiet
        /// Not watching.
        case paused
    }

    package var standing: Standing {
        guard observing else { return .paused }
        let seen = day.seen.count
        if seen > 0 { return .seen(seen) }
        let likely = day.likely.count
        return likely > 0 ? .likely(likely) : .quiet
    }

    /// "2 seen, 14 likely" — the menubar line. Counts never blur the two.
    package var summaryLine: String {
        let seen = day.seen.count, likely = day.likely.count
        if seen == 0 && likely == 0 { return "Leak Guard: nothing noted today" }
        return "Leak Guard: \(seen) seen, \(likely) likely"
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(5))
            saveScheduled = false
            await store.save(day)
        }
    }
}
