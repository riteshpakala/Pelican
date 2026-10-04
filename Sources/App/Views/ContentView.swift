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

            VStack(alignment: .leading, spacing: 3) {
                Text("observe-only · live socket events · on-device mistral")
                Text(BuildInfo.current.line)
                    .help(BuildInfo.current.builtAt.map { "Built \($0)" } ?? "Built from source")
            }
            .font(.pelicanMono(8.5))
            .foregroundStyle(Color.pelicanInk.opacity(0.3))
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
