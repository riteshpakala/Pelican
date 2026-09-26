import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarBody(monitor: appState.rao, openMain: {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        })
    }
}

private struct MenuBarBody: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var monitor: TrustMonitor
    let openMain: () -> Void
    @State private var loginEnabled = LoginItem.isEnabled

    var body: some View {
        let assessment = monitor.assessment
        Text("\(monitor.app.name): \(monitor.observing ? assessment.level.displayName : "not watching")")
        Text(assessment.summary)
        if let reason = assessment.reasons.first {
            Text(reason)
        }
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
