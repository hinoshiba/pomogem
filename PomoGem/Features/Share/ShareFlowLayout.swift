import SwiftUI

/// Lays its subviews out left to right and starts a new line when the next
/// one would not fit, so every hashtag stays visible.
///
/// The composer's tag chips sat in a horizontal ScrollView with no indicator:
/// on a 375 pt iPhone the two study tags started off-screen, and at AX5 only
/// the first chip showed (product-06). The card drew its tags on one line at
/// 8 pt (feed) or 11 pt (story) and scaled them down to 72 %, so four chips
/// plus a 30-character custom tag were cut with 「…」 in the exported image
/// while the caption kept them. Both now wrap with this layout.
struct ShareFlowLayout: Layout {
    enum LineAlignment {
        case leading
        case center
    }

    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat
    var alignment: LineAlignment = .leading

    /// Indices of the items on each line, greedily filling `maxWidth`. An
    /// item wider than the line gets a line of its own; the caller proposes
    /// it the line width so its text can shrink or wrap inside it.
    static func lines(
        widths: [CGFloat],
        maxWidth: CGFloat,
        spacing: CGFloat
    ) -> [[Int]] {
        var lines: [[Int]] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let itemWidth = min(width, maxWidth)
            let widthWithItem = current.isEmpty
                ? itemWidth
                : currentWidth + spacing + itemWidth
            if !current.isEmpty, widthWithItem > maxWidth {
                lines.append(current)
                current = [index]
                currentWidth = itemWidth
            } else {
                current.append(index)
                currentWidth = widthWithItem
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let arrangement = arrange(proposal: proposal, subviews: subviews)
        return arrangement.size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let arrangement = arrange(
            proposal: ProposedViewSize(width: bounds.width, height: proposal.height),
            subviews: subviews
        )
        var y = bounds.minY
        for line in arrangement.lines {
            let lineWidth = line.map { arrangement.sizes[$0].width }.reduce(0, +)
                + horizontalSpacing * CGFloat(max(0, line.count - 1))
            let lineHeight = line.map { arrangement.sizes[$0].height }.max() ?? 0
            var x = alignment == .center
                ? bounds.minX + max(0, (bounds.width - lineWidth) / 2)
                : bounds.minX
            for index in line {
                let size = arrangement.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (lineHeight - size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing
            }
            y += lineHeight + verticalSpacing
        }
    }

    private struct Arrangement {
        let sizes: [CGSize]
        let lines: [[Int]]
        let size: CGSize
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> Arrangement {
        let maxWidth = proposal.width ?? .infinity
        let sizes = subviews.map { subview -> CGSize in
            let ideal = subview.sizeThatFits(.unspecified)
            guard ideal.width > maxWidth else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
        let lines = Self.lines(
            widths: sizes.map(\.width),
            maxWidth: maxWidth,
            spacing: horizontalSpacing
        )
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (lineIndex, line) in lines.enumerated() {
            let lineWidth = line.map { sizes[$0].width }.reduce(0, +)
                + horizontalSpacing * CGFloat(max(0, line.count - 1))
            width = max(width, lineWidth)
            height += (line.map { sizes[$0].height }.max() ?? 0)
                + (lineIndex == 0 ? 0 : verticalSpacing)
        }
        return Arrangement(sizes: sizes, lines: lines, size: CGSize(width: width, height: height))
    }
}
