import SwiftUI

/// Wraps subviews onto new lines, like words in a paragraph: a byline's parts, tags, a problem's buttons.
/// Something wider than the row on its own (a long date at a large text size, a field) gets a line to
/// itself at the row's width, where it wraps or truncates, rather than running past the edge.
public struct FlowLayout: Layout {
    public var spacing: CGFloat
    /// Between lines; `spacing` when nil.
    public var lineSpacing: CGFloat?
    public var alignment: HorizontalAlignment

    public init(spacing: CGFloat = 6, lineSpacing: CGFloat? = nil, alignment: HorizontalAlignment = .leading) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews.map { Item($0) }, width: proposal.width)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width.map { $0.isFinite ? min($0, width) : width } ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews.map { Item($0) }, width: bounds.width) {
            var x: CGFloat
            switch alignment {
            case .trailing: x = bounds.maxX - row.width
            case .center: x = bounds.minX + (bounds.width - row.width) / 2
            default: x = bounds.minX
            }
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
        }
    }

    /// What arranging needs of a subview: its size for a proposal. Tests stand in plain sizes.
    struct Item {
        let size: (ProposedViewSize) -> CGSize
        init(_ subview: LayoutSubview) { size = { subview.sizeThatFits($0) } }
        init(size: @escaping (ProposedViewSize) -> CGSize) { self.size = size }
    }

    struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
        var y: CGFloat = 0
    }

    /// The rows for a width (nil or infinite: one row).
    func arrange(_ items: [Item], width proposed: CGFloat?) -> [Row] {
        let width = proposed.flatMap { $0.isFinite ? max(0, $0) : nil }
        var rows = [Row()]
        for (index, item) in items.enumerated() {
            var size = item.size(.unspecified)
            if let width, size.width > width {
                // Too wide for any row: offered the row's width, to wrap or truncate within it.
                let fitted = item.size(ProposedViewSize(width: width, height: nil))
                size = CGSize(width: min(fitted.width, width), height: fitted.height)
            }
            var row = rows[rows.count - 1]
            if !row.indices.isEmpty, let width, row.width + spacing + size.width > width {
                rows.append(Row(y: row.y + row.height + (lineSpacing ?? spacing)))
                row = rows[rows.count - 1]
            }
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}
