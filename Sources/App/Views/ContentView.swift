import PelicanAITools
import PelicanGuard
import PelicanKit
import PelicanRao
import PelicanUI
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            detail
                .background(Color.pelicanBG)
        }
        .preferredColorScheme(.light)  // palette is light-only; lock it
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                PelicanMark(size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Pelican")
                        .font(.pelicanSerif(20, weight: .light, italic: true))
                        .foregroundStyle(Color.pelicanInk)
                    Text("network watch")
                        .font(.pelicanSans(9, weight: .medium))
                        .foregroundStyle(Color.pelicanInk.opacity(0.4))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 18)

            ForEach(Screen.allCases) { screen in
                Button {
                    appState.screen = screen
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: screen.symbol)
                            .frame(width: 18)
                            .foregroundStyle(appState.screen == screen ? Color.pelicanGold : Color.pelicanInk.opacity(0.6))
                        Text(screen.rawValue)
                            .font(.pelicanSans(13, weight: appState.screen == screen ? .semibold : .regular))
                            .foregroundStyle(Color.pelicanInk)
                        Spacer()
                        if screen == .rao {
                            TrustDot(monitor: appState.rao)
                        }
                        if screen == .aiTools {
                            AIToolsDot(store: appState.aiTools)
                        }
                        if screen == .connections && appState.monitorRunning {
                            StatusDot(color: .pelicanGreen)
                        }
                        if screen == .model && appState.modelReady {
                            StatusDot(color: .pelicanGreen)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(appState.screen == screen ? Color.pelicanGold.opacity(0.12) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                DaySignals(rao: appState.rao, leakGuard: appState.leakGuard,
                           aiTools: appState.aiTools)
                Divider().opacity(0.4)
                VStack(alignment: .leading, spacing: 3) {
                    Text("observe-only · live socket events · on-device mistral")
                    Text(BuildInfo.current.line)
                        .help(BuildInfo.current.builtAt.map { "Built \($0)" } ?? "Built from source")
                }
                .font(.pelicanMono(8.5))
                .foregroundStyle(Color.pelicanInk.opacity(0.3))
            }
            .padding(12)
        }
        .background(Color.pelicanBG)
    }

    @ViewBuilder
    private var detail: some View {
        switch appState.screen {
        case .rao: RaoView(monitor: appState.rao, host: appState.host)
        case .aiTools: AIToolsScreen(store: appState.aiTools, guard: appState.leakGuard,
                                     host: appState.host)
        case .connections: ConnectionsView()
        case .processes: ProcessesView()
        case .analysis: AnalysisView()
        case .model: ModelView()
        }
    }
}

/// Hands Leak Guard's findings to the AI Tools screen. It lives here, not in the AI tools
/// module, so that module never depends on the guard — and observing the guard here means new
/// findings appear as they are made.
private struct AIToolsScreen: View {
    let store: AIToolsStore
    @ObservedObject var `guard`: LeakGuard
    let host: MonitorHost

    var body: some View {
        AIToolsView(store: store, host: host,
                    exposures: { `guard`.findings(forTool: $0) })
    }
}

/// The day in two lines: how Rao's apps stand against the consent you gave, and what Pelican
/// has noticed the AI tools sending.
///
/// The two say different kinds of thing, and the wording keeps them apart. Rao's is a real
/// verdict: Pelican knows what Ambient promised and can check every connection against it.
/// The AI tools line is not a verdict — Pelican cannot read most of what they send, so the
/// calm state means "nothing noticed", never "nothing happened".
private struct DaySignals: View {
    @ObservedObject var rao: TrustMonitor
    @ObservedObject var leakGuard: LeakGuard
    @ObservedObject var aiTools: AIToolsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SignalRow(symbol: raoSymbol, tint: raoTint, label: "Rao",
                      detail: raoDetail, explanation: raoExplanation)
            SignalRow(symbol: toolsSymbol, tint: toolsTint, label: "AI tools",
                      detail: toolsDetail, explanation: toolsExplanation)
        }
    }

    // MARK: - Rao: a verdict, because there is a promise to check against

    private var raoSymbol: String {
        rao.observing ? rao.assessment.level.symbol : "shield.slash"
    }
    private var raoTint: Color {
        rao.observing ? rao.assessment.level.color : Color.pelicanInk.opacity(0.35)
    }
    private var raoDetail: String {
        guard rao.observing else { return "paused" }
        switch rao.assessment.level {
        case .trusted: return "within consent"
        case .review: return "worth a look"
        case .breach: return "outside consent"
        }
    }
    private var raoExplanation: String {
        guard rao.observing else { return "Pelican is not watching \(rao.app.name) right now." }
        return "\(rao.app.name) today: \(rao.assessment.summary) "
            + "Every connection is judged against the consent in force when it opened."
    }

    // MARK: - AI tools: what was noticed, which is not the same as what happened

    private var toolsStanding: LeakGuard.Standing { leakGuard.standing }

    private var toolsSymbol: String {
        switch toolsStanding {
        case .seen: return "eye.trianglebadge.exclamationmark.fill"
        case .likely: return "eye"
        case .quiet: return "eye"
        case .paused: return "eye.slash"
        }
    }
    private var toolsTint: Color {
        switch toolsStanding {
        case .seen: return .pelicanError
        case .likely: return .pelicanGold
        case .quiet: return .pelicanGreen
        case .paused: return Color.pelicanInk.opacity(0.35)
        }
    }
    private var toolsDetail: String {
        switch toolsStanding {
        case .seen(let count): return "\(count) seen leaving"
        case .likely(let count): return "\(count) likely"
        case .quiet: return runningToolCount > 0 ? "nothing noticed" : "none running"
        case .paused: return "paused"
        }
    }
    private var runningToolCount: Int { aiTools.running.count }

    private var toolsExplanation: String {
        let caveat = "Pelican cannot read what these tools send, so this covers where traffic "
            + "went and what the tools were run with — not the contents. “Nothing noticed” is "
            + "not a promise that nothing personal left."
        switch toolsStanding {
        case .seen(let count):
            return "\(count) thing\(count == 1 ? "" : "s") Pelican could actually read left this Mac today. \(caveat)"
        case .likely(let count):
            return "\(count) inference\(count == 1 ? "" : "s") from encrypted traffic, each saying what it rests on. \(caveat)"
        case .quiet:
            return runningToolCount > 0
                ? "Nothing noticed from the AI tools running today. \(caveat)"
                : "No AI tools have run today."
        case .paused:
            return "Pelican is not watching right now."
        }
    }
}
