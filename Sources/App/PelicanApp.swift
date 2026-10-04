import AppKit
import PelicanKit
import PelicanRao
import ServiceManagement
import SwiftUI

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

/// Keeps Pelican watching with its window closed, writes the ledger on quit, and has Rao turn
/// trust changes into a Dock badge and notifications.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let state = AppState.shared
            state.rao.postAlerts()
            state.launch()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.flushNow()
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
