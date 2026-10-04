import AppKit
import PelicanKit
import SwiftUI

/// A floating card surface in the warm design language.
package struct PelicanCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    package init(padding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    package var body: some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.pelicanCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .strokeBorder(Color.pelicanBorder, lineWidth: 1))
            )
            .shadow(color: Color.pelicanInk.opacity(0.06), radius: 5, y: 2)
    }
}

/// Small uppercase section label.
package struct SectionLabel: View {
    let text: String
    package init(_ text: String) { self.text = text }
    package var body: some View {
        Text(text.uppercased())
            .font(.pelicanSans(10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.pelicanInk.opacity(0.45))
    }
}

/// Gold primary-action button style.
package struct PelicanButtonStyle: ButtonStyle {
    var prominent: Bool = true
    package func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, prominent: prominent)
    }
}

private struct StyledButton: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.pelicanSans(13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .foregroundStyle(prominent ? Color.white : Color.pelicanInk)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(prominent ? Color.pelicanGold : Color.pelicanFill)
                    .opacity(configuration.isPressed ? 0.8 : 1)
            )
            .shadow(
                color: prominent && isEnabled ? Color.pelicanGold.opacity(0.30) : .clear,
                radius: 4, y: 2)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

package extension ButtonStyle where Self == PelicanButtonStyle {
    static var pelican: PelicanButtonStyle { PelicanButtonStyle(prominent: true) }
    static var pelicanQuiet: PelicanButtonStyle { PelicanButtonStyle(prominent: false) }
}

/// Colored status dot.
package struct StatusDot: View {
    let color: Color
    package init(color: Color) { self.color = color }
    package var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}

/// Empty-state hero with the Pelican emblem.
package struct EmptyHero: View {
    let title: String
    let subtitle: String
    package init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }
    package var body: some View {
        VStack(spacing: 16) {
            PelicanEmblem(iconSize: 56)
            Text(title)
                .font(.pelicanSerif(20, weight: .light, italic: true))
                .foregroundStyle(Color.pelicanInk)
            Text(subtitle)
                .font(.pelicanSans(12))
                .foregroundStyle(Color.pelicanInk.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Verdict pill shown next to a flow once the model has judged it.
package struct VerdictBadge: View {
    let verdict: Verdict

    package init(verdict: Verdict) { self.verdict = verdict }

    private var tint: Color {
        switch verdict.label {
        case .suspicious: return .pelicanError
        case .ok: return .pelicanGreen
        case .unknown: return Color.pelicanInk.opacity(0.5)
        }
    }

    package var body: some View {
        HStack(spacing: 4) {
            Text(verdict.label.rawValue)
                .font(.pelicanSans(10, weight: .semibold))
            if verdict.label == .suspicious {
                Text("\(verdict.score)")
                    .font(.pelicanMono(10))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(tint)
        .background(Capsule().fill(tint.opacity(0.12)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .help(verdict.reason)
    }
}
