import PelicanKit
import PelicanUI
import SwiftUI

package struct RadioView: View {
    let store: RadioStore
    let host: MonitorHost

    package init(store: RadioStore, host: MonitorHost) {
        self.store = store
        self.host = host
    }

    package var body: some View {
        // The store is an ObservableObject; observe it in a child view.
        RadioContent(store: store, host: host)
    }
}

private struct RadioContent: View {
    @ObservedObject var store: RadioStore
    let host: MonitorHost

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenHeader("Radios",
                             "what reached this Mac's radio chips today, counted on their own transports")
                PostureCard(store: store, host: host)
                SwitchOffCard(store: store)
                let findings = store.findings
                if !findings.isEmpty { FindingsCard(findings: findings) }
                ModuleCard(store: store)
                WiFiChipCard(store: store)
                ActivityCard(store: store)
                ClientsCard(store: store)
                ObservedCard(store: store)
            }
            .padding(24)
        }
    }
}

// MARK: - Posture

private struct PostureCard: View {
    @ObservedObject var store: RadioStore
    let host: MonitorHost

    var body: some View {
        PelicanCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(store.posture.isLockedDown ? "Locked down" : "Today")
                        .font(.pelicanSerif(22, weight: .light, italic: true))
                        .foregroundStyle(Color.pelicanInk)
                    Spacer()
                    Button(host.monitorRunning ? "Pause watching" : "Resume watching") {
                        host.setMonitoring(!host.monitorRunning)
                    }
                    .buttonStyle(host.monitorRunning ? .pelicanQuiet : .pelican)
                }
                Text(headline)
                    .font(.pelicanSans(13))
                    .foregroundStyle(Color.pelicanInk.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    PostureChip(label: "Wi-Fi", value: store.posture.wifi, basis: LiveRadioSystem.wifiBasis)
                    PostureChip(label: "Lockdown Mode", value: store.posture.lockdown,
                                basis: "\(LiveRadioSystem.lockdownBasis) — any app running as you could change it")
                    PostureChip(label: "bluetoothd says WLAN", value: store.bluetoothdWLAN,
                                basis: "bluetoothd's own coexistence report; Apple does not document what it means")
                }
                Text("Locked down means Wi-Fi off and Lockdown Mode on. Pelican does not read Bluetooth's switch — that would mean asking for Bluetooth permission — it counts what reaches the chip instead.")
                    .font(.pelicanMono(9.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headline: String {
        switch store.standing {
        case .paused:
            return "Pelican is not watching the radios right now."
        case .contradiction(let count):
            return "\(count) reading\(count == 1 ? "" : "s") that cannot all be true. Each says what it rests on, below."
        case .blind(let reason):
            return "Pelican can read neither the Bluetooth chip's transport nor bluetoothd's log (\(reason)), so it knows nothing about Bluetooth right now — which is not the same as nothing happening."
        case .lockedDown(let minutes):
            return "With Wi-Fi off and Lockdown Mode on, data still reached the Bluetooth radio in \(minutes) minute\(minutes == 1 ? "" : "s"). Each channel is itemised below."
        case .transmitting(let minutes):
            return "Data reached the Bluetooth radio in \(minutes) minute\(minutes == 1 ? "" : "s") today."
        case .nothingReported:
            return "No data reached the Bluetooth radio today, as far as its transport counts. That covers what the Mac hands the chip, not what the chip's firmware might do alone."
        }
    }
}

private struct PostureChip: View {
    let label: String
    let value: Reported
    let basis: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(label).font(.pelicanSans(11))
            Text(value.rawValue).font(.pelicanSans(11, weight: .semibold))
        }
        .foregroundStyle(Color.pelicanInk)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.pelicanFill))
        .help("\(label): \(value.rawValue) — \(basis)")
    }

    private var tint: Color {
        switch value {
        case .on: return .pelicanGold
        case .off: return Color.pelicanInk.opacity(0.3)
        case .unknown: return Color.pelicanInk.opacity(0.12)
        }
    }
}

// MARK: - Switching off

/// The one place Pelican changes something rather than watching it. The switching is ordinary —
/// the same calls the menu bar and Network settings make. What the card is really for is the
/// line underneath: whether it stayed off, checked against the drivers' own counters.
private struct SwitchOffCard: View {
    @ObservedObject var store: RadioStore
    @State private var wifi = true
    @State private var wired: Set<String> = []
    @State private var bluetooth = false

    private var switchable: [NetworkService] {
        store.services.filter { !$0.isWiFi && $0.enabled }
    }

    var body: some View {
        PelicanCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Switch off, and watch")
                    Spacer()
                    StandingLine(standing: store.quietStanding)
                }
                if let quiet = store.quiet {
                    switchedOff(quiet)
                } else {
                    chooser
                }
                if let message = store.lastSwitch {
                    Text(message)
                        .font(.pelicanSans(11))
                        .foregroundStyle(Color.pelicanInk.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 3) {
                    limit("Each of these is a request to the same macOS Pelican is watching, and none of them powers a chip down. The check is what follows: the drivers keep counting, and anything that moves afterwards becomes a finding above.")
                    limit("Wi-Fi uses the same switch as the menu bar. Wired services are disabled through networksetup, which asks you to authorize once; Pelican installs no privileged helper and keeps nothing.")
                    limit("Bluetooth stays yours to switch in Control Center — switching it here would need Bluetooth permission and would drop your keyboard and mouse. Tell Pelican you have, and it will hold the chip's own counters to it.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await store.refreshServices() }
    }

    // MARK: Choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $wifi) {
                Text("Wi-Fi — its radio, and AirDrop and Sidecar with it")
                    .font(.pelicanSans(12))
            }
            .toggleStyle(.checkbox)
            ForEach(switchable) { service in
                Toggle(isOn: Binding(
                    get: { wired.contains(service.name) },
                    set: { on in
                        if on { wired.insert(service.name) } else { wired.remove(service.name) }
                    })) {
                        Text("\(service.name)\(service.interface.map { " (\($0))" } ?? "")")
                            .font(.pelicanSans(12))
                    }
                    .toggleStyle(.checkbox)
            }
            if switchable.isEmpty {
                Text("No wired service is enabled on this Mac.")
                    .font(.pelicanSans(11))
                    .foregroundStyle(Color.pelicanInk.opacity(0.5))
            }
            Toggle(isOn: $bluetooth) {
                Text("I have switched Bluetooth off myself")
                    .font(.pelicanSans(12))
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 10) {
                Button(store.switching ? "Switching…" : "Switch off") {
                    Task { await store.turnOff(wifi: wifi, services: Array(wired).sorted(), bluetooth: bluetooth) }
                }
                .buttonStyle(.pelican)
                .disabled(store.switching || (!wifi && wired.isEmpty && !bluetooth))
                if wifi {
                    Text("This Mac will lose its network connection.")
                        .font(.pelicanSans(10.5))
                        .foregroundStyle(Color.pelicanInk.opacity(0.5))
                }
            }
        }
    }

    // MARK: Switched off

    @ViewBuilder
    private func switchedOff(_ quiet: QuietRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Off since \(quiet.since.formatted(date: .omitted, time: .shortened)): \(quiet.summary).")
                .font(.pelicanSans(12.5))
                .foregroundStyle(Color.pelicanInk)
            Text(explanation(quiet))
                .font(.pelicanSans(11.5))
                .foregroundStyle(Color.pelicanInk.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
            Button(store.switching ? "Putting back…" : "Put back") {
                Task { await store.restore() }
            }
            .buttonStyle(.pelicanQuiet)
            .disabled(store.switching)
        }
    }

    private func explanation(_ quiet: QuietRequest) -> String {
        switch store.quietStanding {
        case .broken(let count):
            return "\(count) thing\(count == 1 ? " has" : "s have") happened since that should not have — listed above. Pelican did not switch anything back on."
        case .holding:
            let watched = Date().timeIntervalSince(quiet.since)
            let minutes = Int(watched / 60)
            let span = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : (minutes > 0 ? "\(minutes) min" : "\(Int(watched)) s")
            return "Nothing has moved on them in \(span) of checking, and nothing has been switched back on. Only Pelican would put them back."
        case .notAsked:
            return ""
        }
    }

    private func limit(_ text: String) -> some View {
        Text(text)
            .font(.pelicanMono(9.5))
            .foregroundStyle(Color.pelicanInk.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StandingLine: View {
    let standing: QuietStanding

    var body: some View {
        switch standing {
        case .notAsked:
            Text("everything on")
                .font(.pelicanMono(10))
                .foregroundStyle(Color.pelicanInk.opacity(0.5))
        case .holding:
            HStack(spacing: 5) {
                Circle().fill(Color.pelicanGreen).frame(width: 7, height: 7)
                Text("stayed off").font(.pelicanMono(10))
            }
            .foregroundStyle(Color.pelicanGreen)
        case .broken(let count):
            HStack(spacing: 5) {
                Circle().fill(Color.pelicanError).frame(width: 7, height: 7)
                Text("\(count) break\(count == 1 ? "" : "s")").font(.pelicanMono(10))
            }
            .foregroundStyle(Color.pelicanError)
        }
    }
}

// MARK: - Findings

private struct FindingsCard: View {
    let findings: [RadioFinding]

    var body: some View {
        PelicanCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Findings")
                ForEach(findings) { finding in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(finding.kind.title)
                                .font(.pelicanSans(12, weight: .semibold))
                                .foregroundStyle(finding.kind.isContradiction ? Color.pelicanError : Color.pelicanGold)
                            Text(finding.subject)
                                .font(.pelicanMono(10.5))
                                .foregroundStyle(Color.pelicanInk)
                            Spacer()
                            Text(times(finding))
                                .font(.pelicanMono(10))
                                .foregroundStyle(Color.pelicanInk.opacity(0.5))
                        }
                        Text(finding.detail)
                            .font(.pelicanSans(11))
                            .foregroundStyle(Color.pelicanInk.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(finding.evidence.label)
                            .font(.pelicanMono(9.5))
                            .foregroundStyle(Color.pelicanInk.opacity(0.4))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.pelicanFill))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func times(_ finding: RadioFinding) -> String {
        let first = finding.firstSeen.formatted(date: .omitted, time: .shortened)
        let last = finding.lastSeen.formatted(date: .omitted, time: .shortened)
        let span = first == last ? first : "\(first)–\(last)"
        // A state held rather than happened, so a count of it would be a count of how often
        // Pelican looked.
        guard !finding.kind.isState else {
            let seconds = Int(finding.lastSeen.timeIntervalSince(finding.firstSeen))
            return seconds >= 60 ? "since \(first), \(seconds / 60) min" : "since \(first)"
        }
        let unit = finding.kind.unit
        let plural = finding.count == 1 || unit.hasPrefix("µs") ? unit : unit + "s"
        return "\(finding.count) \(plural) · \(span)"
    }
}

// MARK: - Inside the Bluetooth module

private struct ModuleCard: View {
    @ObservedObject var store: RadioStore

    var body: some View {
        let day = store.day
        PelicanCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionLabel("Inside the Bluetooth module")
                    Spacer()
                    Text(status)
                        .font(.pelicanMono(10))
                        .foregroundStyle(Color.pelicanInk.opacity(0.5))
                }
                Text("The Bluetooth chip talks to macOS over PCIe, through one channel per kind of traffic. Its driver counts every packet the Mac hands the chip and every packet the chip hands back — below bluetoothd and anything it chooses to log.")
                    .font(.pelicanSans(12))
                    .foregroundStyle(Color.pelicanInk.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 0) {
                    TransportHeader()
                    ForEach(TransportLink.bluetooth, id: \.self) { link in
                        TransportRow(link: link, day: day, found: day.transportLinks.contains(link.rawValue),
                                     latest: store.latestMovement, lastMoved: store.lastMoved[link.rawValue])
                    }
                }
                if !day.antennaReasons.isEmpty {
                    Text("Antenna wanted for: " + day.antennaReasons.sorted { $0.value > $1.value }.prefix(8)
                        .map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                        .font(.pelicanMono(10))
                        .foregroundStyle(Color.pelicanInk.opacity(0.6))
                }
                let away = TransportLink.bluetooth.reduce(0) { $0 + day.away($1, .out) + day.away($1, .in) }
                if away > 0 {
                    Text("While Pelican was not watching — the Mac asleep, or watching paused — the driver kept counting: \(TransportLink.pipes.reduce(0) { $0 + day.away($1, .out) }) packets to the chip and \(TransportLink.pipes.reduce(0) { $0 + day.away($1, .in) }) from it. How much is known; when is not.")
                        .font(.pelicanSans(11))
                        .foregroundStyle(Color.pelicanInk.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("To the chip is toward the air. Counts are packets: the driver publishes no byte counts. A channel created when Bluetooth is switched on is counted from when Pelican finds it, within 15 seconds.")
                    .font(.pelicanMono(9.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var status: String {
        switch store.transportStatus {
        case .running: return "counting"
        case .stopped: return store.observing ? "starting…" : "paused"
        case .unavailable(let reason): return reason
        }
    }
}

private struct TransportHeader: View {
    var body: some View {
        HStack(spacing: 10) {
            Text("").frame(width: 12)
            Text("channel").frame(width: 130, alignment: .leading)
            Text("toward the radio today").frame(width: 170, alignment: .leading)
            Text("from the radio today").frame(width: 170, alignment: .leading)
            Text("last moved").frame(width: 80, alignment: .leading)
            Spacer()
        }
        .font(.pelicanSans(9.5, weight: .semibold))
        .foregroundStyle(Color.pelicanInk.opacity(0.4))
        .padding(.vertical, 4)
    }
}

private struct TransportRow: View {
    let link: TransportLink
    let day: RadioDay
    let found: Bool
    let latest: TransportMovement
    let lastMoved: Date?

    var body: some View {
        let movingNow = latest.count(link, .out) + latest.count(link, .in) > 0
        HStack(spacing: 10) {
            Circle()
                .fill(movingNow ? Color.pelicanGold : (found ? Color.pelicanInk.opacity(0.15) : .clear))
                .overlay(Circle().strokeBorder(found ? .clear : Color.pelicanInk.opacity(0.2), lineWidth: 1))
                .frame(width: 8, height: 8)
                .frame(width: 12)
                .help(movingNow ? "moved in the last second" : (found ? "quiet in the last second" : "not found on this Mac"))
            Text(link.label)
                .font(.pelicanSans(11.5, weight: .medium))
                .foregroundStyle(Color.pelicanInk.opacity(found ? 1 : 0.4))
                .frame(width: 130, alignment: .leading)
                .help(link.meaning)
            cell(link.outLabel, day.total(link, .out))
            cell(link.inLabel, day.total(link, .in))
            Text(lastMoved?.formatted(date: .omitted, time: .standard) ?? "—")
                .font(.pelicanMono(10))
                .foregroundStyle(Color.pelicanInk.opacity(0.5))
                .frame(width: 80, alignment: .leading)
            Spacer()
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) { Divider().opacity(0.4) }
    }

    @ViewBuilder
    private func cell(_ label: String?, _ value: Int) -> some View {
        Group {
            if let label {
                Text("\(value.formatted()) \(label)")
            } else {
                Text("—")
            }
        }
        .font(.pelicanMono(10.5))
        .foregroundStyle(Color.pelicanInk.opacity(found ? 0.8 : 0.3))
        .frame(width: 170, alignment: .leading)
    }
}

// MARK: - Wi-Fi chip

private struct WiFiChipCard: View {
    @ObservedObject var store: RadioStore

    var body: some View {
        let day = store.day
        PelicanCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Inside the Wi-Fi chip")
                HStack(alignment: .top, spacing: 18) {
                    LabeledValue("doorbells to chip", day.total(.wifiBus, .out).formatted())
                    LabeledValue("interrupts from chip", day.total(.wifiBus, .in).formatted())
                    LabeledValue("time transmitting", airtime(day.total(.wifiAirtime, .out)))
                    LabeledValue("time receiving", airtime(day.total(.wifiAirtime, .in)))
                }
                Text(found
                     ? "Counted by the Wi-Fi drivers. With Wi-Fi off, the radio should spend no time transmitting; if it does, that is a finding above."
                     : "The Wi-Fi drivers publish no counters right now — usually because Wi-Fi is off and its driver is not running.")
                    .font(.pelicanMono(9.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var found: Bool { TransportLink.wifi.contains { store.day.transportLinks.contains($0.rawValue) } }

    private func airtime(_ microseconds: Int) -> String {
        let seconds = Double(microseconds) / 1_000_000
        if seconds >= 60 { return String(format: "%.1f min", seconds / 60) }
        if seconds >= 1 { return String(format: "%.1f s", seconds) }
        return String(format: "%.0f ms", seconds * 1_000)
    }
}

// MARK: - Activity

private struct ActivityCard: View {
    @ObservedObject var store: RadioStore

    var body: some View {
        let day = store.day
        PelicanCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Bluetooth, minute by minute")
                DayStrip(day: day)
                    .frame(height: 34)
                HStack(spacing: 14) {
                    Legend(color: Color.pelicanFill, text: "watched")
                    Legend(color: Color.pelicanInk.opacity(0.55), text: "data to the radio")
                    Legend(color: .pelicanGold, text: "data to the radio while locked down")
                    Legend(color: Color.pelicanInk.opacity(0.18), text: "listening only")
                }
                HStack(alignment: .top, spacing: 18) {
                    LabeledValue("watched", duration(day.watched))
                    LabeledValue("minutes sending", "\(day.transmittingMinutes)")
                    LabeledValue("devices heard", "\(day.devicesHeard)")
                    LabeledValue("accessory messages in", "\(day.accessoryMessages)")
                    LabeledValue("controller commands", "\(day.commands.values.reduce(0, +))")
                }
                if !day.links.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(day.links.sorted { $0.packets > $1.packets }) { link in
                            Text("\(link.id) — \(link.reports) report\(link.reports == 1 ? "" : "s") in bluetoothd's log, \(link.transmitting) counting transmissions, \(link.packets) packets")
                                .font(.pelicanMono(10))
                                .foregroundStyle(Color.pelicanInk.opacity(0.6))
                        }
                    }
                }
                Text("A minute is marked when payload went into the chip's ACL, SCO or ISO channel, or bluetoothd logged a transmission: an active scan, or a link or audio report that counted one.")
                    .font(.pelicanMono(9.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.35))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes == 0 { return "\(Int(seconds)) s" }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}

private struct Legend: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).font(.pelicanSans(10)).foregroundStyle(Color.pelicanInk.opacity(0.6))
        }
    }
}

/// The day from midnight to midnight: watched time as a pale band, each minute in which data
/// reached the Bluetooth radio as a tick.
private struct DayStrip: View {
    let day: RadioDay

    var body: some View {
        Canvas { context, size in
            guard let midnight = midnight else { return }
            let width = size.width
            func x(_ date: Date) -> CGFloat {
                CGFloat(max(0, min(1, date.timeIntervalSince(midnight) / 86_400))) * width
            }
            for span in day.coverage {
                let rect = CGRect(x: x(span.start), y: 0, width: max(1, x(span.end) - x(span.start)), height: size.height)
                context.fill(Path(rect), with: .color(Color.pelicanFill))
            }
            let tick = max(1, width / 1_440)
            let lockedDown = Set(day.minutes.filter(\.lockedDown).map(\.minute))
                .union(day.transportMinutes.filter(\.lockedDown).map(\.minute))
            let sending = day.sendingMinutes
            for minute in day.minutes where minute.listening > 0 && !sending.contains(minute.minute) {
                context.fill(Path(CGRect(x: x(EpochMinute.start(minute.minute)), y: size.height / 2 - 3, width: tick, height: 6)),
                             with: .color(Color.pelicanInk.opacity(0.18)))
            }
            for minute in sending {
                let color = lockedDown.contains(minute) ? Color.pelicanGold : Color.pelicanInk.opacity(0.55)
                context.fill(Path(CGRect(x: x(EpochMinute.start(minute)), y: 4, width: tick, height: size.height - 8)),
                             with: .color(color))
            }
            for hour in stride(from: 0, through: 24, by: 6) {
                let position = CGFloat(hour) / 24 * width
                context.fill(Path(CGRect(x: min(position, width - 1), y: size.height - 3, width: 1, height: 3)),
                             with: .color(Color.pelicanInk.opacity(0.3)))
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.pelicanBorder, lineWidth: 1))
    }

    private var midnight: Date? {
        let parts = day.day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

// MARK: - Clients

private struct ClientsCard: View {
    @ObservedObject var store: RadioStore

    var body: some View {
        let clients = store.day.clients.sorted { $0.requests + $0.scans > $1.requests + $1.scans }
        PelicanCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Who used Bluetooth today")
                if clients.isEmpty {
                    Text("No process has asked bluetoothd for anything since Pelican started watching.")
                        .font(.pelicanSans(12))
                        .foregroundStyle(Color.pelicanInk.opacity(0.5))
                }
                ForEach(clients.prefix(40)) { client in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(client.label)
                            .font(.pelicanMono(11))
                            .foregroundStyle(Color.pelicanInk)
                            .frame(width: 230, alignment: .leading)
                        Text(activity(client))
                            .font(.pelicanSans(11))
                            .foregroundStyle(Color.pelicanInk.opacity(0.7))
                        Spacer()
                        Text(client.lastSeen.formatted(date: .omitted, time: .shortened))
                            .font(.pelicanMono(10))
                            .foregroundStyle(Color.pelicanInk.opacity(0.45))
                    }
                    .help(messages(client))
                }
                Text("Named from bluetoothd's own log. A pid is shown only when it still belonged to a process of that name when the line arrived.")
                    .font(.pelicanMono(9.5))
                    .foregroundStyle(Color.pelicanInk.opacity(0.35))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func activity(_ client: ClientRollup) -> String {
        var parts: [String] = []
        if client.requests > 0 { parts.append("\(client.requests) request\(client.requests == 1 ? "" : "s")") }
        if client.scans > 0 {
            let active = client.activeScans > 0 ? ", \(client.activeScans) active" : ""
            parts.append("\(client.scans) scan\(client.scans == 1 ? "" : "s")\(active)")
        }
        if client.indications > 0 { parts.append("\(client.indications) received from a device") }
        return parts.isEmpty ? "scanning" : parts.joined(separator: " · ")
    }

    private func messages(_ client: ClientRollup) -> String {
        client.messages.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) ×\($0.value)" }.joined(separator: "\n")
    }
}

// MARK: - How this was observed

private struct ObservedCard: View {
    @ObservedObject var store: RadioStore

    var body: some View {
        let day = store.day
        PelicanCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("How this was observed")
                HStack(alignment: .top, spacing: 18) {
                    LabeledValue("transport counters", store.transportStatus.description)
                    LabeledValue("bluetoothd's log", store.sourceStatus.description)
                    LabeledValue("log entries read", "\(day.linesRead)")
                    LabeledValue("interpreted", "\(Int((day.interpretedShare * 100).rounded()))%")
                    LabeledValue("watched spans", "\(day.coverage.count)")
                }
                if day.looksUnreadable {
                    Text("None of bluetoothd's lines were interpreted today. macOS may have changed what it logs; run Pelican --radio-probe to see which lines are new.")
                        .font(.pelicanSans(11))
                        .foregroundStyle(Color.pelicanGold)
                }
                let unread = day.uninterpreted.sorted { $0.value > $1.value }.prefix(6)
                if !unread.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Most frequent log lines not interpreted, by format")
                            .font(.pelicanSans(10.5, weight: .medium))
                            .foregroundStyle(Color.pelicanInk.opacity(0.5))
                        ForEach(Array(unread), id: \.key) { entry in
                            Text("\(entry.value)  \(entry.key)")
                                .font(.pelicanMono(9.5))
                                .foregroundStyle(Color.pelicanInk.opacity(0.45))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    limit("The transport counts are the drivers' own, read through IOReport with no root and no permission. They sit below bluetoothd, but they are still the Mac's software counting itself.")
                    limit("Anything the radio chip's firmware does on its own, without the Mac handing it a packet, does not pass through these channels and is not counted. BLE advertising is the main case: one HCI command starts it, which is counted, and the chip then advertises by itself until told to stop. While Wi-Fi is on, its antenna requests may still show it.")
                    limit("macOS does not keep bluetoothd's log, so who asked for what is known only while Pelican was watching. The transport counters run regardless; what moved while Pelican was away is counted, though not timed.")
                    limit("Reading the log needs an administrator account. Pelican never asks for Bluetooth permission and never talks to bluetoothd.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func limit(_ text: String) -> some View {
        Text(text)
            .font(.pelicanMono(9.5))
            .foregroundStyle(Color.pelicanInk.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Sidebar and menubar

/// The sidebar's dot for the Radios screen.
package struct RadioDot: View {
    @ObservedObject var store: RadioStore

    package init(store: RadioStore) { _store = ObservedObject(wrappedValue: store) }

    package var body: some View {
        switch store.standing {
        case .contradiction(let count):
            StatusDot(color: .pelicanError).help("\(count) contradiction\(count == 1 ? "" : "s")")
        case .lockedDown, .blind:
            StatusDot(color: .pelicanGold).help(store.summaryLine)
        default:
            EmptyView()
        }
    }
}

/// One menubar line for the radios.
package struct RadioMenuStatus: View {
    @ObservedObject var store: RadioStore

    package init(store: RadioStore) { _store = ObservedObject(wrappedValue: store) }

    package var body: some View { Text(store.summaryLine) }
}
