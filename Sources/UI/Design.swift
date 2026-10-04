import SwiftUI

// MARK: - Palette (ported from Fleet/Client's warm Seer-derived system)

package extension Color {
    static let pelicanBG = Color(red: 250 / 255, green: 249 / 255, blue: 246 / 255)
    static let pelicanInk = Color(red: 45 / 255, green: 49 / 255, blue: 66 / 255)
    static let pelicanGold = Color(red: 174 / 255, green: 144 / 255, blue: 96 / 255)
    static var pelicanBorder: Color { Color.pelicanGold.opacity(0.22) }
    static var pelicanCard: Color { Color.white.opacity(0.62) }
    static var pelicanFill: Color { Color.pelicanInk.opacity(0.05) }
    static let pelicanError = Color(red: 200 / 255, green: 60 / 255, blue: 60 / 255)
    static let pelicanGreen = Color(red: 70 / 255, green: 150 / 255, blue: 90 / 255)
    static let pelicanLabel = Color(red: 12 / 255, green: 12 / 255, blue: 12 / 255)
}

// MARK: - Typography

package extension Font {
    static func pelicanSerif(_ size: CGFloat, weight: Font.Weight = .regular, italic: Bool = false) -> Font {
        let f = Font.system(size: size, weight: weight, design: .serif)
        return italic ? f.italic() : f
    }

    static func pelicanSans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func pelicanMono(_ size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }
}

// MARK: - Pelican mark

/// The Pelican brand glyph — a gold bird watching the wire.
package struct PelicanMark: View {
    var size: CGFloat = 28
    var color: Color = .pelicanGold

    package init(size: CGFloat = 28, color: Color = .pelicanGold) {
        self.size = size
        self.color = color
    }

    package var body: some View {
        Image(systemName: "bird")
            .font(.system(size: size, weight: .light))
            .foregroundStyle(color)
            .symbolRenderingMode(.hierarchical)
    }
}

// MARK: - Orbiting rings (ported)

struct PelicanOrbitRings: View {
    let iconSize: CGFloat
    @State private var outerRotation = 0.0
    @State private var innerRotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    Color.pelicanGold.opacity(0.30),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 3])
                )
                .frame(width: iconSize + 40, height: iconSize + 40)
                .rotationEffect(.degrees(outerRotation))
                .onAppear {
                    withAnimation(.linear(duration: 32).repeatForever(autoreverses: false)) {
                        outerRotation = -360
                    }
                }

            Circle()
                .strokeBorder(Color.pelicanGold.opacity(0.30), lineWidth: 1)
                .frame(width: iconSize + 14, height: iconSize + 14)
                .rotationEffect(.degrees(innerRotation))
                .onAppear {
                    withAnimation(.linear(duration: 20).repeatForever(autoreverses: false)) {
                        innerRotation = 360
                    }
                }

            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.pelicanGold.opacity(0.15), .clear],
                        center: .center, startRadius: 0, endRadius: iconSize * 0.6
                    )
                )
                .frame(width: iconSize + 8, height: iconSize + 8)
        }
        .frame(width: iconSize + 48, height: iconSize + 48)
    }
}

/// The mark inside the orbiting rings — used on landing/empty states.
package struct PelicanEmblem: View {
    var iconSize: CGFloat = 64

    package init(iconSize: CGFloat = 64) {
        self.iconSize = iconSize
    }

    package var body: some View {
        ZStack {
            PelicanOrbitRings(iconSize: iconSize)
            PelicanMark(size: iconSize * 0.7)
        }
    }
}
