import PelicanKit
import PelicanUI
import SwiftUI

extension TrustLevel {
    var color: Color {
        switch self {
        case .trusted: return .pelicanGreen
        case .review: return .pelicanGold
        case .breach: return .pelicanError
        }
    }

    var symbol: String {
        switch self {
        case .trusted: return "checkmark.shield.fill"
        case .review: return "exclamationmark.shield.fill"
        case .breach: return "xmark.shield.fill"
        }
    }
}

extension RaoFinding.Severity {
    var color: Color {
        switch self {
        case .verified: return .pelicanGreen
        case .info: return Color.pelicanInk.opacity(0.5)
        case .warning: return .pelicanGold
        case .alarm: return .pelicanError
        }
    }

    var symbol: String {
        switch self {
        case .verified: return "checkmark.seal.fill"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .alarm: return "xmark.octagon.fill"
        }
    }
}

extension FlowClassKind {
    var color: Color {
        switch self {
        case .local: return Color.pelicanInk.opacity(0.55)
        case .expected: return .pelicanGold
        case .unexpected: return .pelicanError
        }
    }

    var label: String {
        switch self {
        case .local: return "on this Mac"
        case .expected: return "expected"
        case .unexpected: return "outside consent"
        }
    }
}

/// Pill for a connection's consent classification.
struct ClassBadge: View {
    let classification: FlowClassification

    var body: some View {
        let tint = classification.kind.color
        HStack(spacing: 4) {
            Text(classification.kind.label)
                .font(.pelicanSans(10, weight: .semibold))
            if classification.broad {
                Text("broad").font(.pelicanSans(9))
            }
            if classification.firstRun {
                Text("once").font(.pelicanSans(9))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .help(classification.note)
    }
}

/// The sidebar's status dot for the Rao screen.
package struct TrustDot: View {
    @ObservedObject var monitor: TrustMonitor
    package init(monitor: TrustMonitor) { _monitor = ObservedObject(wrappedValue: monitor) }
    package var body: some View {
        StatusDot(color: monitor.observing ? monitor.assessment.level.color : Color.pelicanInk.opacity(0.25))
            .help(monitor.observing ? monitor.assessment.level.displayName : "Paused")
    }
}

/// The menubar icon: a shield that changes shape with the trust level.
package struct TrustShieldLabel: View {
    @ObservedObject var monitor: TrustMonitor
    package init(monitor: TrustMonitor) { _monitor = ObservedObject(wrappedValue: monitor) }
    package var body: some View {
        Image(systemName: monitor.observing ? monitor.assessment.level.symbol : "shield.slash")
    }
}
