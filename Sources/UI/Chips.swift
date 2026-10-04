import SwiftUI

/// A capsule button for picking one of a short list — the row of apps or tools above a screen.
package struct SelectorChip: View {
    private let title: String
    private let tag: String?
    private let selected: Bool
    private let action: () -> Void

    package init(_ title: String, tag: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.tag = tag
        self.selected = selected
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.pelicanSans(12, weight: selected ? .semibold : .regular))
                if let tag {
                    Text(tag)
                        .font(.pelicanSans(9, weight: .medium))
                        .foregroundStyle(Color.pelicanInk.opacity(0.45))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.pelicanFill))
                }
            }
            .foregroundStyle(Color.pelicanInk)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(selected ? Color.pelicanGold.opacity(0.14) : Color.pelicanCard)
                    .overlay(Capsule().strokeBorder(
                        selected ? Color.pelicanGold.opacity(0.5) : Color.pelicanBorder, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}

/// A small capsule that narrows a table to one slice, showing how many rows it holds.
package struct FilterChip: View {
    private let title: String
    private let count: Int
    private let selected: Bool
    private let tint: Color?
    private let action: () -> Void

    /// `tint` colours the label when the slice is worth attention and is not empty.
    package init(_ title: String, count: Int, selected: Bool, tint: Color? = nil,
                 action: @escaping () -> Void) {
        self.title = title
        self.count = count
        self.selected = selected
        self.tint = tint
        self.action = action
    }

    package var body: some View {
        Button(action: action) {
            Text("\(title) \(count)")
                .font(.pelicanSans(10.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(count > 0 ? (tint ?? Color.pelicanInk) : Color.pelicanInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? Color.pelicanGold.opacity(0.14) : Color.pelicanFill))
        }
        .buttonStyle(.plain)
    }
}

/// A small label above a monospaced value, as the detail panels use.
package struct LabeledValue: View {
    private let label: String
    private let value: String
    private let width: CGFloat?

    package init(_ label: String, _ value: String, width: CGFloat? = nil) {
        self.label = label
        self.value = value
        self.width = width
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(label)
            Text(value)
                .font(.pelicanMono(10.5))
                .foregroundStyle(Color.pelicanInk)
                .textSelection(.enabled)
        }
        .frame(width: width, alignment: .leading)
    }
}

package extension View {
    /// The pale card a table sits on.
    func pelicanTableBackground(cornerRadius: CGFloat = 10) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.pelicanBorder, lineWidth: 1))
            )
    }
}

/// A page's title and one line saying what it shows.
package struct ScreenHeader: View {
    private let title: String
    private let subtitle: String

    package init(_ title: String, _ subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.pelicanSerif(26, weight: .light, italic: true))
                .foregroundStyle(Color.pelicanInk)
            Text(subtitle)
                .font(.pelicanSans(12))
                .foregroundStyle(Color.pelicanInk.opacity(0.45))
        }
    }
}
