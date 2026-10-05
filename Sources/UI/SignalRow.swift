import SwiftUI

/// One line of the sidebar's day-at-a-glance: a symbol, what it is about, and where it stands.
///
/// Deliberately small and quiet. It is a prompt to look, not a verdict in itself, so the detail
/// says what Pelican actually knows and the tooltip says what it does not.
package struct SignalRow: View {
    private let symbol: String
    private let tint: Color
    private let label: String
    private let detail: String
    private let explanation: String

    package init(symbol: String, tint: Color, label: String, detail: String, explanation: String) {
        self.symbol = symbol
        self.tint = tint
        self.label = label
        self.detail = detail
        self.explanation = explanation
    }

    package var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 14)
            Text(label)
                .font(.pelicanSans(10.5, weight: .medium))
                .foregroundStyle(Color.pelicanInk.opacity(0.75))
                .frame(width: 52, alignment: .leading)
            Text(detail)
                .font(.pelicanSans(10.5))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .help(explanation)
    }
}
