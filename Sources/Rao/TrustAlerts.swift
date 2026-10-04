import AppKit
import PelicanKit
import UserNotifications

extension TrustMonitor {
    /// Turn trust changes into a Dock badge and notifications.
    package func postAlerts() {
        let app = self.app
        onLevelChange = { assessment, previous in
            TrustAlerts.levelChanged(assessment, from: previous, app: app)
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
