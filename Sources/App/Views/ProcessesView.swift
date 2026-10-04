import PelicanKit
import PelicanUI
import SwiftUI

struct ProcessesView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Processes")
                    .font(.pelicanSerif(26, weight: .light, italic: true))
                    .foregroundStyle(Color.pelicanInk)
                Text("flows grouped by owning process, heaviest talkers first")
                    .font(.pelicanSans(12))
                    .foregroundStyle(Color.pelicanInk.opacity(0.45))
            }

            if appState.processRollups.isEmpty {
                EmptyHero(
                    title: "No processes on the wire",
                    subtitle: "Start the monitor from the Connections tab and processes with network activity will gather here."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(appState.processRollups) { rollup in
                            ProcessRow(rollup: rollup)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .padding(24)
    }
}

private struct ProcessRow: View {
    let rollup: ProcessRollup
    @State private var expanded = false

    var body: some View {
        PelicanCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.pelicanInk.opacity(0.4))
                        Text(rollup.name)
                            .font(.pelicanSans(13, weight: .semibold))
                            .foregroundStyle(Color.pelicanInk)
                        Text("pid \(rollup.pid)")
                            .font(.pelicanMono(10))
                            .foregroundStyle(Color.pelicanInk.opacity(0.4))
                        if let verdict = rollup.worstVerdict {
                            VerdictBadge(verdict: verdict)
                        }
                        Spacer()
                        Text("\(rollup.flows.count) flow\(rollup.flows.count == 1 ? "" : "s")")
                            .font(.pelicanSans(11))
                            .foregroundStyle(Color.pelicanInk.opacity(0.45))
                        Text("↓ \(formatBytes(rollup.totalIn))  ↑ \(formatBytes(rollup.totalOut))")
                            .font(.pelicanMono(11))
                            .foregroundStyle(Color.pelicanInk.opacity(0.6))
                    }
                }
                .buttonStyle(.plain)

                if expanded {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(rollup.flows) { flow in
                            HStack(spacing: 10) {
                                Image(systemName: flow.direction == .outbound ? "arrow.up.right"
                                      : flow.direction == .inbound ? "arrow.down.left" : "ear")
                                    .font(.system(size: 10))
                                    .foregroundStyle(flow.direction == .outbound ? Color.pelicanGold : Color.pelicanInk.opacity(0.5))
                                    .frame(width: 14)
                                Text(flow.resolvedHost ?? (flow.hasConcreteRemote ? flow.remoteAddress : "listening"))
                                    .font(.pelicanMono(11))
                                    .foregroundStyle(Color.pelicanInk)
                                if let port = flow.remotePort {
                                    Text(":\(port)")
                                        .font(.pelicanMono(11))
                                        .foregroundStyle(Color.pelicanInk.opacity(0.5))
                                }
                                Text(flow.proto.rawValue)
                                    .font(.pelicanMono(9))
                                    .foregroundStyle(Color.pelicanInk.opacity(0.4))
                                Spacer()
                                if let verdict = flow.verdict {
                                    VerdictBadge(verdict: verdict)
                                }
                                Text("↓ \(formatBytes(flow.bytesIn))  ↑ \(formatBytes(flow.bytesOut))")
                                    .font(.pelicanMono(10))
                                    .foregroundStyle(Color.pelicanInk.opacity(0.5))
                            }
                            .padding(.leading, 24)
                        }
                    }
                }
            }
        }
    }
}
