import SwiftUI

/// Lays subviews out left to right at their natural size, wrapping onto a new
/// line when the next one would overflow.
///
/// `LazyVGrid` can't do this: its adaptive columns are uniform, so a row of
/// chips as different as "Rock" and "Alternative Hip-Hop" is either clipped or
/// padded out to the widest one. Genre chips are the only place the app needs
/// intrinsic-width wrapping.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.replacingUnspecifiedDimensions().width
        let rows = Self.rows(of: sizes(of: subviews), availableWidth: available, spacing: spacing)
        guard !rows.isEmpty else { return .zero }
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(rows.count - 1)
        return CGSize(width: min(available, rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = sizes(of: subviews)
        var y = bounds.minY
        for row in Self.rows(of: sizes, availableWidth: bounds.width, spacing: spacing) {
            var x = bounds.minX
            for index in row.indices {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func sizes(of subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    /// One line of the flow.
    struct Row: Equatable {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Packs `sizes` into rows that fit `availableWidth`.
    ///
    /// Split out from the layout itself so the wrapping rules can be tested
    /// directly. A subview wider than the available width still gets its own
    /// row rather than being dropped or looping forever.
    static func rows(of sizes: [CGSize], availableWidth: CGFloat, spacing: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for (index, size) in sizes.enumerated() {
            if current.indices.isEmpty {
                current = Row(indices: [index], width: size.width, height: size.height)
                continue
            }
            let extended = current.width + spacing + size.width
            if extended > availableWidth {
                rows.append(current)
                current = Row(indices: [index], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.width = extended
                current.height = max(current.height, size.height)
            }
        }

        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
