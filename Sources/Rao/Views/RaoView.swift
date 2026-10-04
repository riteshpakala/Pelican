import AppKit
import PelicanKit
import PelicanUI
import SwiftUI
import UniformTypeIdentifiers

package struct RaoView: View {
    let monitor: TrustMonitor
    let host: MonitorHost

    package init(monitor: TrustMonitor, host: MonitorHost) {
        self.monitor = monitor
        self.host = host
    }

    package var body: some View {
        // The monitor is an ObservableObject; observe it in a child view.
        RaoContent(monitor: monitor, host: host)
    }
}

private struct RaoContent: View {
    @ObservedObject var monitor: TrustMonitor
    let host: MonitorHost
    @State private var selectedAppId = RaoApp.ambient.id

    private var selectedApp: RaoApp { RaoApp.all.first { $0.id == selectedAppId } ?? .ambient }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                AppSelector(selection: $selectedAppId)
                if selectedApp.availability == .comingSoon || selectedApp.id != monitor.app.id {
                    ComingSoonCard(app: selectedApp)
                } else {
                    if let viewed = monitor.viewedDay {
                        PastDayBanner(day: viewed.day) { monitor.showDay(nil) }
                    }
                    TrustHero(monitor: monitor, host: host)
                    DayTimeline(ledger: monitor.displayed, appName: monitor.app.name)
                    HStack(alignment: .top, spacing: 16) {
                        ConsentCard(monitor: monitor)
                        IdentityCard(monitor: monitor)
                    }
                    ActivityCard(monitor: monitor)
                    HStack(alignment: .top, spacing: 16) {
                        EventLogCard(events: monitor.displayed.events)
                        HistoryCard(monitor: monitor)
                    }
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Rao")
                .font(.pelicanSerif(26, weight: .light, italic: true))
                .foregroundStyle(Color.pelicanInk)
            Text("live trust for the Rao apps that listen all day — every connection, checked against what you agreed to")
                .font(.pelicanSans(12))
                .foregroundStyle(Color.pelicanInk.opacity(0.45))
        }
    }
}

// MARK: - App selector

private struct AppSelector: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(RaoApp.all) { app in
                Button {
                    selection = app.id
                } label: {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.pelicanSans(12, weight: selection == app.id ? .semibold : .regular))
                        if app.availability == .comingSoon {
                            Text("soon")
                                .font(.pelicanSans(9, weight: .medium))
                                .foregroundStyle(Color.pelicanInk.opacity(0.45))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.pelicanFill))
                        }
                    }
                    .foregroundStyle(Color.pelicanInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(selection == app.id ? Color.pelicanGold.opacity(0.14) : Color.pelicanCard)
                            .overlay(Capsule().strokeBorder(selection == app.id ? Color.pelicanGold.opacity(0.5) : Color.pelicanBorder, lineWidth: 1))
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct ComingSoonCard: View {
    let app: RaoApp

    var body: some View {
        PelicanCard {
            VStack(spacing: 12) {
                PelicanEmblem(iconSize: 48)
                Text("\(app.name) is coming soon")
                    .font(.pelicanSerif(20, weight: .light, italic: true))
                    .foregroundStyle(Color.pelicanInk)
                Text(app.tagline)
                    .font(.pelicanSans(12))
                    .foregroundStyle(Color.pelicanInk.opacity(0.5))
                Text("When \(app.name) ships, Pelican will watch it the way it watches Ambient: every connection its processes make, checked against the consent you give it.")
                    .font(.pelicanSans(11.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Link(app.siteURL.host ?? app.siteURL.absoluteString, destination: app.siteURL)
                    .font(.pelicanSans(11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }
}

private struct PastDayBanner: View {
    let day: String
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(Color.pelicanGold)
            Text("Viewing \(day) — a saved day, read-only")
                .font(.pelicanSans(12, weight: .medium))
                .foregroundStyle(Color.pelicanInk)
            Spacer()
            Button("Back to today", action: back)
                .buttonStyle(.pelicanQuiet)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.pelicanGold.opacity(0.08)))
    }
}

// MARK: - Trust hero

private struct TrustHero: View {
    @ObservedObject var monitor: TrustMonitor
    let host: MonitorHost
    @State private var copied = false

    var body: some View {
        let assessment = monitor.displayedAssessment
        let today = monitor.viewedDay == nil
        PelicanCard {
            HStack(alignment: .top, spacing: 18) {
                Image(systemName: assessment.level.symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(assessment.level.color)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text(assessment.level.displayName)
                        .font(.pelicanSerif(24, weight: .light, italic: true))
                        .foregroundStyle(Color.pelicanInk)
                    Text(assessment.summary)
                        .font(.pelicanSans(13))
                        .foregroundStyle(Color.pelicanInk.opacity(0.75))
                    Text(watchLine(monitor.displayed, today: today))
                        .font(.pelicanSans(11))
                        .foregroundStyle(Color.pelicanInk.opacity(0.45))
                    if !assessment.reasons.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(assessment.reasons, id: \.self) { reason in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Circle().fill(assessment.level.color).frame(width: 5, height: 5)
                                    Text(reason)
                                        .font(.pelicanSans(11.5))
                                        .foregroundStyle(Color.pelicanInk.opacity(0.7))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                    HStack(spacing: 10) {
                        if today {
                            Button(host.monitorRunning ? "Pause watching" : "Resume watching") {
                                host.setMonitoring(!host.monitorRunning)
                            }
                            .buttonStyle(host.monitorRunning ? .pelicanQuiet : .pelican)
                        }
                        Button("Export report…") { ReportExport.save(monitor.report()) }
                            .buttonStyle(.pelicanQuiet)
                        Button(copied ? "Copied" : "Copy report") {
                            ReportExport.copy(monitor.report())
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        }
                        .buttonStyle(.pelicanQuiet)
                        Button("Analyze with model") {
                            host.analyze(RaoPrompt.instruction(monitor: monitor),
                                         "Rao · \(monitor.app.name)",
                                         monitor.externalFlowsForAnalysis)
                        }
                        .buttonStyle(.pelicanQuiet)
                        .disabled(!host.modelReady || monitor.externalFlowsForAnalysis.isEmpty)
                        .help(host.modelReady
                              ? (monitor.externalFlowsForAnalysis.isEmpty ? "No external connections to analyse" : "Ask the on-device model to review the day's external connections")
                              : "Load the model first — Model tab")
                    }
                    .padding(.top, 6)
                    Text(captureLine)
                        .font(.pelicanMono(9.5))
                        .foregroundStyle(Color.pelicanInk.opacity(0.35))
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var captureLine: String {
        if case .running = monitor.captureStatus[.nstat] {
            return "live socket events for kernel sockets + nettop every \(Int(host.pollInterval))s for URLSession connections"
        }
        if case .unavailable(let reason) = monitor.captureStatus[.nstat] {
            return "socket events unavailable (\(reason)) — nettop every \(Int(host.pollInterval))s; very short connections can be missed"
        }
        return host.monitorRunning ? "starting capture…" : "capture paused"
    }

    private func watchLine(_ ledger: DayLedger, today: Bool) -> String {
        guard let first = ledger.observed.first else { return today ? "Not watching yet." : "Not watched that day." }
        let watched = ledger.observed.reduce(0) { $0 + max(0, $1.end.timeIntervalSince($1.start)) }
        let gaps = max(0, ledger.observed.count - 1)
        var line = "Watched since \(TrustAssessor.time(first.start)) · \(TrustAssessor.duration(watched)) observed"
        if gaps > 0 { line += " · \(gaps) gap\(gaps == 1 ? "" : "s")" }
        return line
    }
}

// MARK: - Timeline

private struct DayTimeline: View {
    let ledger: DayLedger
    let appName: String

    var body: some View {
        let buckets = ledger.hourly()
        let peak = max(1, buckets.map { $0.local + $0.expected + $0.unexpected }.max() ?? 1)
        let day = ledger.interval()
        PelicanCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionLabel("Today, hour by hour")
                    Spacer()
                    legend(.local)
                    legend(.expected)
                    legend(.unexpected)
                }
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<24, id: \.self) { hour in
                        bar(buckets[hour], peak: peak)
                            .help(help(hour, buckets[hour]))
                    }
                }
                .frame(height: 56)
                strip(title: "\(appName) running", color: .pelicanGreen,
                      intervals: ledger.runs.map { DateInterval(start: max($0.launchedAt, day.start), end: max(max($0.launchedAt, day.start), min($0.quitAt ?? Date(), day.end))) },
                      day: day)
                strip(title: "Pelican watching", color: Color.pelicanInk.opacity(0.45),
                      intervals: ledger.observed.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) },
                      day: day)
                HStack {
                    ForEach([0, 6, 12, 18], id: \.self) { hour in
                        Text(String(format: "%02d:00", hour))
                            .font(.pelicanMono(9))
                            .foregroundStyle(Color.pelicanInk.opacity(0.35))
                        if hour != 18 { Spacer() }
                    }
                    Spacer()
                    Text("24:00").font(.pelicanMono(9)).foregroundStyle(Color.pelicanInk.opacity(0.35))
                }
            }
        }
    }

    private func legend(_ kind: FlowClassKind) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(kind.color).frame(width: 8, height: 8)
            Text(kind.label).font(.pelicanSans(10)).foregroundStyle(Color.pelicanInk.opacity(0.5))
        }
    }

    private func bar(_ bucket: DayLedger.HourBucket, peak: Int) -> some View {
        // Square-root scale so one unexpected connection is visible next to hundreds of local ones.
        func height(_ count: Int) -> CGFloat {
            count == 0 ? 0 : max(3, 56 * CGFloat((Double(count) / Double(peak)).squareRoot()))
        }
        return VStack(spacing: 1) {
            Spacer(minLength: 0)
            if bucket.unexpected > 0 { RoundedRectangle(cornerRadius: 2).fill(FlowClassKind.unexpected.color).frame(height: height(bucket.unexpected)) }
            if bucket.expected > 0 { RoundedRectangle(cornerRadius: 2).fill(FlowClassKind.expected.color).frame(height: height(bucket.expected)) }
            if bucket.local > 0 { RoundedRectangle(cornerRadius: 2).fill(FlowClassKind.local.color.opacity(0.6)).frame(height: height(bucket.local)) }
            if bucket.local + bucket.expected + bucket.unexpected == 0 {
                RoundedRectangle(cornerRadius: 1).fill(Color.pelicanFill).frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func help(_ hour: Int, _ bucket: DayLedger.HourBucket) -> String {
        String(format: "%02d:00–%02d:00 — ", hour, hour + 1)
            + "\(bucket.local) local, \(bucket.expected) expected, \(bucket.unexpected) outside consent"
            + (bucket.bytesOutExternal > 0 ? ", \(formatBytes(bucket.bytesOutExternal)) out" : "")
    }

    private func strip(title: String, color: Color, intervals: [DateInterval], day: DateInterval) -> some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.pelicanFill)
                    ForEach(Array(intervals.enumerated()), id: \.offset) { _, interval in
                        let start = max(0, interval.start.timeIntervalSince(day.start) / day.duration)
                        let end = min(1, interval.end.timeIntervalSince(day.start) / day.duration)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color)
                            .frame(width: max(2, geometry.size.width * CGFloat(end - start)))
                            .offset(x: geometry.size.width * CGFloat(start))
                    }
                }
            }
            .frame(height: 5)
            Text(title)
                .font(.pelicanSans(9.5))
                .foregroundStyle(Color.pelicanInk.opacity(0.45))
                .frame(width: 104, alignment: .leading)
        }
    }
}

// MARK: - Consent

private struct ConsentCard: View {
    @ObservedObject var monitor: TrustMonitor

    private enum Choice: String, CaseIterable, Identifiable {
        case follow = "Follow Ambient", onDevice = "On-device", signedIn = "Signed in"
        var id: String { rawValue }
    }

    var body: some View {
        let mode = monitor.effectiveMode
        PelicanCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Consent")
                Picker("", selection: Binding(
                    get: {
                        switch monitor.modeOverride {
                        case .none: return Choice.follow
                        case .onDevice?: return Choice.onDevice
                        default: return Choice.signedIn
                        }
                    },
                    set: { choice in
                        switch choice {
                        case .follow: monitor.setModeOverride(nil)
                        case .onDevice: monitor.setModeOverride(.onDevice)
                        case .signedIn: monitor.setModeOverride(.signedIn)
                        }
                    })) {
                    ForEach(Choice.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(monitor.viewedDay != nil)

                Text(detectionLine)
                    .font(.pelicanSans(11))
                    .foregroundStyle(Color.pelicanInk.opacity(0.5))
                Text(monitor.app.boundary[mode] ?? "")
                    .font(.pelicanSerif(13.5, italic: true))
                    .foregroundStyle(Color.pelicanInk)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel("May leave this Mac — \(mode == .unknown ? "on-device" : mode.displayName.lowercased())")
                    let allowed = monitor.app.expectedHosts.filter { $0.modes.contains(mode == .unknown ? .onDevice : mode) }
                    if allowed.isEmpty {
                        Text("Nothing.").font(.pelicanSans(11)).foregroundStyle(Color.pelicanInk.opacity(0.5))
                    }
                    ForEach(allowed) { hostRow($0, allowed: true) }
                    let other = monitor.app.expectedHosts.filter { !$0.modes.contains(mode == .unknown ? .onDevice : mode) }
                    if !other.isEmpty {
                        SectionLabel("Not in this mode").padding(.top, 4)
                        ForEach(other) { hostRow($0, allowed: false) }
                    }
                }

                if let consent = monitor.consent {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("\(monitor.app.name)'s own settings")
                        ForEach(consent.settings) { setting in
                            HStack {
                                Text(setting.label).font(.pelicanSans(11)).foregroundStyle(Color.pelicanInk.opacity(0.6))
                                Spacer()
                                Text(setting.value).font(.pelicanMono(10.5)).foregroundStyle(Color.pelicanInk)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }

                if !monitor.declaredUsage.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel("Permissions it declares")
                        ForEach(monitor.declaredUsage.sorted { $0.key < $1.key }, id: \.key) { key, text in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(UsageNames.name(for: key)).font(.pelicanSans(11, weight: .semibold)).foregroundStyle(Color.pelicanInk)
                                Text(text).font(.pelicanSans(10.5)).foregroundStyle(Color.pelicanInk.opacity(0.55))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var detectionLine: String {
        if let override = monitor.modeOverride {
            let detected = monitor.consent.map { " (\(monitor.app.name) itself says \($0.mode.displayName.lowercased()))" } ?? ""
            return "You set this to \(override.displayName.lowercased()) in Pelican\(detected)."
        }
        if let consent = monitor.consent {
            return "Read from \(monitor.app.name)'s settings at \(TrustAssessor.time(consent.readAt)): \(consent.mode.displayName.lowercased())."
        }
        return "Pelican couldn't read \(monitor.app.name)'s settings — pick its mode above. Until then it's held to on-device rules."
    }

    private func hostRow(_ host: ExpectedHost, allowed: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: allowed ? "arrow.up.right.circle" : "nosign")
                .font(.system(size: 10))
                .foregroundStyle(allowed ? Color.pelicanGold : Color.pelicanInk.opacity(0.3))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(host.displayPattern).font(.pelicanMono(10.5)).foregroundStyle(Color.pelicanInk)
                    if let processes = host.processes {
                        Text("from " + processes.sorted().joined(separator: ", "))
                            .font(.pelicanSans(9.5)).foregroundStyle(Color.pelicanInk.opacity(0.4))
                    }
                }
                Text(host.purpose).font(.pelicanSans(10.5)).foregroundStyle(Color.pelicanInk.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(allowed ? 1 : 0.55)
    }
}

// MARK: - Identity

private struct IdentityCard: View {
    @ObservedObject var monitor: TrustMonitor

    var body: some View {
        PelicanCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Identity")
                HStack(spacing: 12) {
                    if let icon = appIcon {
                        Image(nsImage: icon).resizable().frame(width: 40, height: 40)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitor.app.name).font(.pelicanSerif(17, italic: true)).foregroundStyle(Color.pelicanInk)
                        Text(versionLine).font(.pelicanSans(11)).foregroundStyle(Color.pelicanInk.opacity(0.5))
                    }
                    Spacer()
                    Link("Compare with \(monitor.app.siteURL.host ?? "its site")", destination: monitor.app.siteURL)
                        .font(.pelicanSans(10.5))
                }

                if monitor.processes.isEmpty {
                    Text("\(monitor.app.name) isn't running right now.")
                        .font(.pelicanSans(11.5)).foregroundStyle(Color.pelicanInk.opacity(0.5))
                }
                ForEach(monitor.processes) { process in
                    ProcessIdentityRow(process: process)
                }

                if !monitor.findings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(monitor.findings.sorted { $0.severity > $1.severity }) { finding in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: finding.severity.symbol)
                                    .font(.system(size: 11))
                                    .foregroundStyle(finding.severity.color)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(finding.title).font(.pelicanSans(11.5, weight: .semibold)).foregroundStyle(Color.pelicanInk)
                                    Text(finding.detail).font(.pelicanSans(10.5)).foregroundStyle(Color.pelicanInk.opacity(0.55))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                Text("Pelican compares what macOS reports about these processes with each other, with \(monitor.app.name)'s published identifiers, and with the installed copy. It carries no signing secrets of its own — check the certificate and team above against \(monitor.app.siteURL.host ?? "the site").")
                    .font(.pelicanSans(10))
                    .foregroundStyle(Color.pelicanInk.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private var appPath: String? {
        monitor.processes.first { $0.attribution.role == .app }?.identity?.bundlePath ?? monitor.reference?.path
    }

    private var appIcon: NSImage? {
        appPath.map { NSWorkspace.shared.icon(forFile: $0) }
    }

    private var versionLine: String {
        if let identity = monitor.processes.first(where: { $0.attribution.role == .app })?.identity {
            let version = identity.bundleVersion.map { "\($0)\(identity.bundleBuild.map { " (\($0))" } ?? "")" } ?? "from source"
            return "\(version) · running"
        }
        if let reference = monitor.reference {
            return "\(reference.version ?? "?") installed · not running"
        }
        return "not installed in /Applications"
    }
}

private struct ProcessIdentityRow: View {
    let process: RaoProcess

    var body: some View {
        let signature = process.identity?.signature
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(process.name).font(.pelicanSans(12, weight: .semibold)).foregroundStyle(Color.pelicanInk)
                Text("pid \(process.pid)").font(.pelicanMono(10)).foregroundStyle(Color.pelicanInk.opacity(0.4))
                Spacer()
                flag("notarized", signature?.notarized == true)
                flag("hardened", signature?.hardenedRuntime == true)
                flag("valid", signature?.isValid == true)
            }
            detail("signed as", signature?.identifier ?? "—")
            detail("certificate", signature?.leafSubject ?? (signature?.isAdHoc == true ? "none (ad-hoc)" : "—"))
            detail("team", signature?.teamIdentifier ?? "—")
            detail("path", process.identity?.executablePath ?? "—")
            detail("why Ambient's", process.attribution.evidence)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.pelicanFill))
    }

    private func flag(_ label: String, _ on: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: on ? "checkmark" : "xmark").font(.system(size: 8, weight: .bold))
            Text(label).font(.pelicanSans(9.5))
        }
        .foregroundStyle(on ? Color.pelicanGreen : Color.pelicanInk.opacity(0.4))
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.pelicanSans(10)).foregroundStyle(Color.pelicanInk.opacity(0.45)).frame(width: 84, alignment: .leading)
            Text(value).font(.pelicanMono(10)).foregroundStyle(Color.pelicanInk.opacity(0.8))
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

// MARK: - Activity

private struct ActivityCard: View {
    @ObservedObject var monitor: TrustMonitor
    @State private var filter: Filter = .external
    @State private var selection: LedgerFlow.ID?

    private enum Filter: String, CaseIterable, Identifiable {
        case unexpected = "Outside consent", external = "Left this Mac", all = "Everything"
        var id: String { rawValue }
    }

    var body: some View {
        let flows = monitor.displayed.flows
        let rows = filtered(flows)
        PelicanCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel("Connections")
                    Spacer()
                    ForEach(Filter.allCases) { option in
                        chip(option, count: filtered(flows, option).count)
                    }
                }
                if rows.isEmpty {
                    Text(emptyText)
                        .font(.pelicanSans(11.5))
                        .foregroundStyle(Color.pelicanInk.opacity(0.5))
                        .padding(.vertical, 8)
                } else {
                    table(rows)
                        .frame(height: min(360, CGFloat(rows.count) * 26 + 32))
                    if let flow = rows.first(where: { $0.id == selection }) {
                        detail(flow)
                    }
                }
                let local = monitor.displayed.flows.filter { $0.scope == .loopback && $0.direction == .outbound }.count
                    + monitor.displayed.localOverflow.connections
                Text("\(local.formatted()) local exchange\(local == 1 ? "" : "s") between \(monitor.app.name) and its own servers stayed on this Mac.")
                    .font(.pelicanSans(10.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.45))
            }
        }
    }

    private var emptyText: String {
        switch filter {
        case .unexpected: return "Nothing outside your consent."
        case .external: return "Nothing has left this Mac."
        case .all: return "No connections yet."
        }
    }

    private func filtered(_ flows: [LedgerFlow], _ option: Filter? = nil) -> [LedgerFlow] {
        let chosen: [LedgerFlow]
        switch option ?? filter {
        case .unexpected: chosen = flows.filter { $0.classification.kind == .unexpected }
        case .external: chosen = flows.filter { $0.scope == .external || $0.classification.kind == .unexpected }
        case .all: chosen = flows
        }
        return chosen.sorted { $0.openedAt > $1.openedAt }
    }

    private func chip(_ option: Filter, count: Int) -> some View {
        Button {
            filter = option
        } label: {
            Text("\(option.rawValue) \(count)")
                .font(.pelicanSans(10.5, weight: filter == option ? .semibold : .regular))
                .foregroundStyle(option == .unexpected && count > 0 ? Color.pelicanError : Color.pelicanInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(filter == option ? Color.pelicanGold.opacity(0.14) : Color.pelicanFill))
        }
        .buttonStyle(.plain)
    }

    private func table(_ rows: [LedgerFlow]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Opened") { flow in
                Text(flow.openedAt.formatted(date: .omitted, time: .standard)).font(.pelicanMono(10.5))
            }
            .width(72)
            TableColumn("Process") { flow in
                Text(flow.process + (flow.socketOwner.map { " via \($0)" } ?? ""))
                    .font(.pelicanSans(11.5, weight: .medium))
            }
            .width(min: 90, ideal: 110)
            TableColumn("Remote") { flow in
                Text(flow.remoteDisplay).font(.pelicanMono(10.5)).lineLimit(1).truncationMode(.middle)
            }
            .width(min: 180, ideal: 260)
            TableColumn("Proto") { flow in
                Text(flow.proto.rawValue).font(.pelicanMono(10.5)).foregroundStyle(Color.pelicanInk.opacity(0.6))
            }
            .width(46)
            TableColumn("Out") { flow in Text(formatBytes(flow.bytesOut)).font(.pelicanMono(10.5)) }
                .width(64)
            TableColumn("In") { flow in Text(formatBytes(flow.bytesIn)).font(.pelicanMono(10.5)) }
                .width(64)
            TableColumn("Consent") { flow in ClassBadge(classification: flow.classification) }
                .width(min: 110, ideal: 130)
            TableColumn("Why") { flow in
                Text(flow.classification.note).font(.pelicanSans(10.5)).foregroundStyle(Color.pelicanInk.opacity(0.6))
                    .lineLimit(1).truncationMode(.tail)
            }
        }
        .scrollContentBackground(.hidden)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.pelicanBorder, lineWidth: 1))
        )
    }

    private func detail(_ flow: LedgerFlow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(flow.process) → \(flow.remoteDisplay)").font(.pelicanSerif(14, italic: true)).foregroundStyle(Color.pelicanInk)
                ClassBadge(classification: flow.classification)
                Spacer()
            }
            Text(flow.classification.note).font(.pelicanSans(11.5))
                .foregroundStyle(flow.classification.kind == .unexpected ? Color.pelicanError : Color.pelicanInk.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 18) {
                labeled("address", "\(flow.remoteAddress)\(flow.remotePort.map { ":\($0)" } ?? "")")
                labeled("opened", flow.openedAt.formatted(date: .omitted, time: .standard))
                labeled("closed", flow.closedAt?.formatted(date: .omitted, time: .standard) ?? "still open")
                labeled("mode then", flow.mode.displayName)
                labeled("seen by", flow.seenBy.map(\.rawValue).joined(separator: " + "))
            }
            labeled("attributed because", flow.attribution)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.pelicanFill))
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(label)
            Text(value).font(.pelicanMono(10.5)).foregroundStyle(Color.pelicanInk).textSelection(.enabled)
        }
    }
}

// MARK: - Event log and history

private struct EventLogCard: View {
    let events: [LedgerEvent]

    var body: some View {
        PelicanCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("What happened")
                if events.isEmpty {
                    Text("Nothing yet.").font(.pelicanSans(11.5)).foregroundStyle(Color.pelicanInk.opacity(0.5))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(events.reversed().prefix(200)) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(event.at.formatted(date: .omitted, time: .shortened))
                                    .font(.pelicanMono(10)).foregroundStyle(Color.pelicanInk.opacity(0.4))
                                    .frame(width: 58, alignment: .leading)
                                Image(systemName: symbol(event.kind)).font(.system(size: 9)).foregroundStyle(color(event.kind))
                                Text(event.text).font(.pelicanSans(11)).foregroundStyle(Color.pelicanInk.opacity(0.75))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
    }

    private func symbol(_ kind: LedgerEvent.Kind) -> String {
        switch kind {
        case .observing: return "eye"
        case .stoppedObserving: return "eye.slash"
        case .launched: return "play.circle"
        case .quit: return "stop.circle"
        case .consent: return "hand.raised"
        case .finding: return "checkmark.seal"
        case .unexpected: return "exclamationmark.circle.fill"
        case .expected: return "arrow.up.right.circle"
        case .capture: return "dot.radiowaves.left.and.right"
        }
    }

    private func color(_ kind: LedgerEvent.Kind) -> Color {
        switch kind {
        case .unexpected: return .pelicanError
        case .expected: return .pelicanGold
        case .launched, .observing: return .pelicanGreen
        default: return Color.pelicanInk.opacity(0.45)
        }
    }
}

private struct HistoryCard: View {
    @ObservedObject var monitor: TrustMonitor

    var body: some View {
        PelicanCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Earlier days")
                row(day: monitor.ledger.day, level: monitor.assessment.level, summary: "Today", selected: monitor.viewedDay == nil) {
                    monitor.showDay(nil)
                }
                if monitor.history.isEmpty {
                    Text("Days are kept for \(LedgerStore.keepDays) days, on this Mac only.")
                        .font(.pelicanSans(10.5)).foregroundStyle(Color.pelicanInk.opacity(0.45))
                }
                ForEach(monitor.history) { day in
                    row(day: day.day, level: day.level, summary: day.summary, selected: monitor.viewedDay?.day == day.day) {
                        monitor.showDay(day.day)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 300)
    }

    private func row(day: String, level: TrustLevel?, summary: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(color: level?.color ?? Color.pelicanInk.opacity(0.25))
                VStack(alignment: .leading, spacing: 1) {
                    Text(day).font(.pelicanMono(11)).foregroundStyle(Color.pelicanInk)
                    if !summary.isEmpty {
                        Text(summary).font(.pelicanSans(10)).foregroundStyle(Color.pelicanInk.opacity(0.5)).lineLimit(2)
                    }
                }
                Spacer()
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.pelicanGold.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Export and prompt

@MainActor
enum ReportExport {
    static func save(_ report: RaoReport) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(report.app)-trust-\(report.day).md"
        panel.message = "Pelican writes the report as Markdown, with the same data as JSON beside it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? RaoReportRenderer.markdown(report).write(to: url, atomically: true, encoding: .utf8)
        if let json = try? RaoReportRenderer.json(report) {
            try? json.write(to: url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
        }
    }

    static func copy(_ report: RaoReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(RaoReportRenderer.markdown(report), forType: .string)
    }
}

enum RaoPrompt {
    @MainActor
    static func instruction(monitor: TrustMonitor) -> String {
        let mode = monitor.effectiveMode == .unknown ? ConsentMode.onDevice : monitor.effectiveMode
        let allowed = monitor.app.expectedHosts.filter { $0.modes.contains(mode) }
            .map { "\($0.displayPattern) (\($0.purpose))" }
        return """
        These are the connections that \(monitor.app.name)'s processes (\(monitor.app.processNames.sorted().joined(separator: ", "))) \
        made to hosts outside this Mac today. \(monitor.app.name) is in \(mode.displayName.lowercased()) mode, where it may only \
        contact: \(allowed.isEmpty ? "nothing" : allowed.joined(separator: "; ")). Flag every flow that doesn't fit — an unknown \
        host, data sent to a download host, an odd port — as suspicious, with a short reason. Mark flows that fit as ok.
        """
    }
}
