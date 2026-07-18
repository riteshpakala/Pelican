import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: FlowKey?
    @State private var showClosed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            controls
            if appState.flows.isEmpty && !appState.monitorRunning {
                EmptyHero(
                    title: "The wire is quiet",
                    subtitle: "Start the monitor to watch every process's incoming and outgoing connections, polled from nettop — no kernel extensions, no injection."
                )
            } else {
                flowTable
                if let flow = selectedFlow {
                    detailCard(flow)
                }
            }
        }
        .padding(24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Connections")
                .font(.pelicanSerif(26, weight: .light, italic: true))
                .foregroundStyle(Color.pelicanInk)
            Text("live per-process network flows")
                .font(.pelicanSans(12))
                .foregroundStyle(Color.pelicanInk.opacity(0.45))
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(appState.monitorRunning ? "Stop monitor" : "Start monitor") {
                appState.monitorRunning ? appState.stopMonitor() : appState.startMonitor()
            }
            .buttonStyle(appState.monitorRunning ? .pelicanQuiet : .pelican)

            if appState.monitorRunning {
                HStack(spacing: 6) {
                    StatusDot(color: .pelicanGreen)
                    Text("polling every \(Int(appState.pollInterval))s")
                        .font(.pelicanSans(11))
                        .foregroundStyle(Color.pelicanInk.opacity(0.5))
                }
            }

            Spacer()

            Toggle("Show closed", isOn: $showClosed)
                .toggleStyle(.checkbox)
                .font(.pelicanSans(11))
                .foregroundStyle(Color.pelicanInk.opacity(0.6))

            Text("\(appState.flows.count) active · \(appState.recentClosed.count) recent")
                .font(.pelicanMono(10))
                .foregroundStyle(Color.pelicanInk.opacity(0.4))

            if appState.parseSkips > 0 {
                Text("\(appState.parseSkips) unparsed")
                    .font(.pelicanMono(10))
                    .foregroundStyle(Color.pelicanError.opacity(0.6))
                    .help("Lines from nettop that Pelican's parser skipped this tick")
            }
        }
    }

    private var displayedFlows: [Flow] {
        showClosed ? appState.flows + appState.recentClosed : appState.flows
    }

    private var selectedFlow: Flow? {
        guard let selection else { return nil }
        return displayedFlows.first { $0.id == selection }
    }

    private var flowTable: some View {
        Table(displayedFlows, selection: $selection) {
            TableColumn("Process") { flow in
                HStack(spacing: 6) {
                    Text(flow.processName)
                        .font(.pelicanSans(12, weight: .medium))
                    Text("\(flow.pid)")
                        .font(.pelicanMono(10))
                        .foregroundStyle(Color.pelicanInk.opacity(0.4))
                }
            }
            .width(min: 140, ideal: 180)

            TableColumn("Dir") { flow in
                Image(systemName: directionSymbol(flow.direction))
                    .font(.system(size: 11))
                    .foregroundStyle(flow.direction == .outbound ? Color.pelicanGold : Color.pelicanInk.opacity(0.55))
                    .help(flow.direction.rawValue)
            }
            .width(34)

            TableColumn("Remote") { flow in
                VStack(alignment: .leading, spacing: 1) {
                    Text(flow.resolvedHost ?? (flow.hasConcreteRemote ? flow.remoteAddress : "—"))
                        .font(.pelicanMono(11))
                    if flow.resolvedHost != nil {
                        Text(flow.remoteAddress)
                            .font(.pelicanMono(9))
                            .foregroundStyle(Color.pelicanInk.opacity(0.4))
                    }
                }
            }
            .width(min: 200, ideal: 280)

            TableColumn("Port") { flow in
                Text(flow.remotePort.map(String.init) ?? "—")
                    .font(.pelicanMono(11))
            }
            .width(50)

            TableColumn("Proto") { flow in
                Text(flow.proto.rawValue)
                    .font(.pelicanMono(11))
                    .foregroundStyle(Color.pelicanInk.opacity(0.6))
            }
            .width(50)

            TableColumn("In") { flow in
                Text(formatBytes(flow.bytesIn))
                    .font(.pelicanMono(11))
            }
            .width(70)

            TableColumn("Out") { flow in
                Text(formatBytes(flow.bytesOut))
                    .font(.pelicanMono(11))
            }
            .width(70)

            TableColumn("State") { flow in
                HStack(spacing: 5) {
                    StatusDot(color: stateColor(flow.state))
                    Text(flow.state == .other ? "—" : flow.state.rawValue)
                        .font(.pelicanSans(10))
                        .foregroundStyle(Color.pelicanInk.opacity(0.55))
                }
            }
            .width(100)

            TableColumn("Verdict") { flow in
                if let verdict = flow.verdict {
                    VerdictBadge(verdict: verdict)
                }
            }
            .width(min: 90, ideal: 110)
        }
        .scrollContentBackground(.hidden)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.pelicanBorder, lineWidth: 1))
        )
    }

    private func detailCard(_ flow: Flow) -> some View {
        PelicanCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(flow.processName)
                        .font(.pelicanSerif(15, weight: .regular, italic: true))
                        .foregroundStyle(Color.pelicanInk)
                    Text("pid \(flow.pid) · \(flow.interface.isEmpty ? "?" : flow.interface) · \(flow.proto.rawValue)")
                        .font(.pelicanMono(10))
                        .foregroundStyle(Color.pelicanInk.opacity(0.45))
                    Spacer()
                    if let verdict = flow.verdict {
                        VerdictBadge(verdict: verdict)
                    }
                }
                HStack(spacing: 20) {
                    labeled("local", flow.localAddress + (flow.localPort.map { ":\($0)" } ?? ""))
                    labeled("remote", (flow.resolvedHost ?? flow.remoteAddress) + (flow.remotePort.map { ":\($0)" } ?? ""))
                    labeled("first seen", flow.firstSeen.formatted(date: .omitted, time: .standard))
                    labeled("last seen", flow.lastSeen.formatted(date: .omitted, time: .standard))
                    labeled("Δ in/out", "\(formatBytes(flow.deltaIn)) / \(formatBytes(flow.deltaOut))")
                }
                if let verdict = flow.verdict, !verdict.reason.isEmpty {
                    Text("\(verdict.presetName): \(verdict.reason)")
                        .font(.pelicanSans(11))
                        .foregroundStyle(verdict.label == .suspicious ? Color.pelicanError : Color.pelicanInk.opacity(0.6))
                }
            }
        }
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(label)
            Text(value)
                .font(.pelicanMono(11))
                .foregroundStyle(Color.pelicanInk)
        }
    }

    private func directionSymbol(_ direction: FlowDirection) -> String {
        switch direction {
        case .outbound: return "arrow.up.right"
        case .inbound: return "arrow.down.left"
        case .listening: return "ear"
        }
    }

    private func stateColor(_ state: FlowState) -> Color {
        switch state {
        case .established: return .pelicanGreen
        case .listen: return .pelicanGold
        case .other: return Color.pelicanInk.opacity(0.3)
        case .closed: return Color.pelicanInk.opacity(0.2)
        }
    }
}
