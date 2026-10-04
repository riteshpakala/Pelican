import PelicanKit
import PelicanRao
import SwiftUI

struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarBody(openMain: {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        })
    }
}

private struct MenuBarBody: View {
    @EnvironmentObject private var appState: AppState
    let openMain: () -> Void
    @State private var loginEnabled = LoginItem.isEnabled

    var body: some View {
        RaoMenuStatus(monitor: appState.rao)
        Divider()
        Button("Open Pelican") {
            appState.screen = .rao
            openMain()
        }
        Button(appState.monitorRunning ? "Pause watching" : "Resume watching") {
            appState.monitorRunning ? appState.stopMonitor() : appState.startMonitor()
        }
        Toggle("Start at login", isOn: Binding(
            get: { loginEnabled },
            set: { LoginItem.set($0); loginEnabled = LoginItem.isEnabled }))
            .disabled(!LoginItem.isAvailable)
        Divider()
        Button("Quit Pelican") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
