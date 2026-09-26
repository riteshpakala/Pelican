import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

struct PelicanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        Window("Pelican", id: "main") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1440, height: 860)
        .windowStyle(.titleBar)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(appState)
        } label: {
            TrustShieldLabel(monitor: appState.rao)
        }
    }
}

/// Keeps Pelican watching with its window closed, writes the ledger on quit, and turns trust
/// changes into a Dock badge and notifications.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let state = AppState.shared
            state.rao.onLevelChange = { assessment, previous in
                TrustAlerts.levelChanged(assessment, from: previous, app: state.rao.app)
            }
            state.launch()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.rao.flushNow()
        }
    }
}

@MainActor
enum TrustAlerts {
    static func levelChanged(_ assessment: TrustAssessment, from previous: TrustLevel, app: RaoApp) {
        NSApp.dockTile.badgeLabel = assessment.level == .breach ? "\(max(1, assessment.unexpectedConnections))" : nil
        // Notify only when things get worse, and only from an installed .app — a bare
        // executable has no bundle for the notification centre to attach to.
        guard assessment.level > previous, BuildInfo.isBundled else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "\(app.name): \(assessment.level.displayName)"
            content.body = assessment.reasons.first ?? assessment.summary
            content.sound = assessment.level == .breach ? .default : nil
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

/// Starts Pelican at login. Needs the installed .app (SMAppService registers the bundle).
enum LoginItem {
    static var isAvailable: Bool { BuildInfo.isBundled }

    static var isEnabled: Bool {
        isAvailable && SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) {
        guard isAvailable else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Pelican: login item change failed: \(error.localizedDescription)")
        }
    }
}
