import Foundation

// slimer: Arrange Panes. Pure transforms over a split tree. They only build new
// `Node` values around the existing leaf views, so the same view instances are
// re-parented and nothing is created or destroyed. See docs/slimer/PANES.md.
extension SplitTree {
    /// Equalize only the splits laid out along `axis`, using the same leaf
    /// weighting as `equalized()`. Splits in the other direction keep their ratio.
    /// The zoom state is kept, like upstream `equalized()`.
    func equalized(axis: Direction) -> Self {
        guard let root else { return self }
        return .init(root: root.equalized(axis: axis), zoomed: zoomed)
    }

    /// The leaves sorted the way a person reads the screen: rows top to bottom,
    /// left to right within a row.
    ///
    /// A row starts at the highest remaining pane (leftmost on ties) and takes
    /// every remaining pane whose vertical center lies within that pane's
    /// vertical extent. This keeps slightly misaligned rows together.
    func readingOrder() -> [ViewType] {
        guard let root else { return [] }
        let eps = 1e-9
        var remaining = root.paneFrames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        var result: [ViewType] = []
        result.reserveCapacity(remaining.count)

        while !remaining.isEmpty {
            // Frames have a top-left origin, so the visual top is minY.
            guard let anchor = remaining.min(by: { lhs, rhs in
                if abs(lhs.frame.minY - rhs.frame.minY) > eps {
                    return lhs.frame.minY < rhs.frame.minY
                }
                return lhs.frame.minX < rhs.frame.minX
            }) else { break }

            let band = anchor.frame
            var row: [(view: ViewType, frame: CGRect)] = []
            var rest: [(view: ViewType, frame: CGRect)] = []
            for entry in remaining {
                let mid = entry.frame.midY
                if entry.view === anchor.view ||
                    (mid >= band.minY - eps && mid <= band.maxY + eps) {
                    row.append(entry)
                } else {
                    rest.append(entry)
                }
            }

            row.sort { lhs, rhs in
                if abs(lhs.frame.minX - rhs.frame.minX) > eps {
                    return lhs.frame.minX < rhs.frame.minX
                }
                return lhs.frame.minY < rhs.frame.minY
            }
            result.append(contentsOf: row.map(\.view))
            remaining = rest
        }

        return result
    }

    /// All panes side by side with equal widths, in reading order. Unzooms.
    func arrangedColumns() -> Self {
        guard isSplit else { return self }
        return .init(root: Node.chain(readingOrder().map { .leaf(view: $0) }, direction: .horizontal), zoomed: nil)
    }

    /// All panes stacked with equal heights, in reading order. Unzooms.
    func arrangedRows() -> Self {
        guard isSplit else { return self }
        return .init(root: Node.chain(readingOrder().map { .leaf(view: $0) }, direction: .vertical), zoomed: nil)
    }

    /// An even grid sized for a container with the given width / height ratio.
    /// See `gridShape(count:aspectRatio:)`. Unzooms.
    func arrangedEvenGrid(aspectRatio: Double) -> Self {
        guard isSplit else { return self }
        let views = readingOrder()
        let shape = Self.gridShape(count: views.count, aspectRatio: aspectRatio)
        return arrangedGrid(views: views, columns: shape.columns)
    }

    /// Rows of columns: `columns` panes per row, the last row takes the
    /// remainder. Every row spans the full width, so row dividers line up
    /// across columns. Unzooms.
    func arrangedGrid(columns: Int) -> Self {
        guard isSplit else { return self }
        return arrangedGrid(views: readingOrder(), columns: columns)
    }

    private func arrangedGrid(views: [ViewType], columns: Int) -> Self {
        let cols = Swift.max(1, Swift.min(columns, views.count))
        var rows: [Node] = []
        var start = 0
        while start < views.count {
            let end = Swift.min(start + cols, views.count)
            rows.append(Node.chain(views[start..<end].map { .leaf(view: $0) }, direction: .horizontal))
            start = end
        }
        return .init(root: Node.chain(rows, direction: .vertical), zoomed: nil)
    }

    /// Picks rows x columns for `count` panes in a container whose width / height
    /// is `aspectRatio`. Every column count 1...count is tried with
    /// rows = ceil(count / columns); the last row holds the remainder at equal
    /// widths. The winner minimizes the mean |ln(cell width / cell height)| over
    /// all panes (0 = perfectly square cells). Ties go to more columns.
    static func gridShape(count: Int, aspectRatio: Double) -> (rows: Int, columns: Int) {
        guard count > 1 else { return (rows: Swift.max(count, 1), columns: 1) }
        let aspect = (aspectRatio.isFinite && aspectRatio > 0) ? aspectRatio : 1.6

        var best = (rows: count, columns: 1)
        var bestScore = Double.infinity
        for cols in 1...count {
            let rows = (count + cols - 1) / cols
            let fullRows = count / cols
            let remainder = count - fullRows * cols
            // Cell aspect is (aspect / panesInRow) / (1 / rows).
            var score = Double(fullRows * cols) * abs(log(aspect * Double(rows) / Double(cols)))
            if remainder > 0 {
                score += Double(remainder) * abs(log(aspect * Double(rows) / Double(remainder)))
            }
            score /= Double(count)
            if score <= bestScore + 1e-12 {
                best = (rows: rows, columns: cols)
                bestScore = Swift.min(score, bestScore)
            }
        }
        return best
    }
}

extension SplitTree.Node {
    /// Builds a chain of equal-size splits: the first split gives `1/n` to the
    /// first node and the rest to a chain of the remaining nodes. This is the
    /// same shape and ratio `equalize()` produces, so the result is stable
    /// under Equalize. `nodes` must not be empty.
    static func chain(_ nodes: [Self], direction: SplitTree.Direction) -> Self {
        precondition(!nodes.isEmpty, "chain requires at least one node")
        if nodes.count == 1 { return nodes[0] }
        return .split(.init(
            direction: direction,
            ratio: 1.0 / Double(nodes.count),
            left: nodes[0],
            right: chain(Array(nodes.dropFirst()), direction: direction)))
    }

    /// Each leaf's frame within `bounds`, top-left origin with y growing down,
    /// laid out the way `SplitView` draws a split: the left (or top) child gets
    /// `ratio` of the space. Divider thickness and cell snapping are ignored.
    ///
    /// Upstream's `calculateViewBounds(in:)` gives the top child of a vertical
    /// split `1 - ratio` of the height, which does not match what is drawn, so
    /// Arrange Panes uses this instead.
    func paneFrames(in bounds: CGRect) -> [(view: ViewType, frame: CGRect)] {
        switch self {
        case .leaf(let view):
            return [(view, bounds)]

        case .split(let split):
            let left: CGRect
            let right: CGRect
            switch split.direction {
            case .horizontal:
                let width = bounds.width * split.ratio
                left = CGRect(x: bounds.minX, y: bounds.minY, width: width, height: bounds.height)
                right = CGRect(
                    x: bounds.minX + width, y: bounds.minY,
                    width: bounds.width - width, height: bounds.height)
            case .vertical:
                let height = bounds.height * split.ratio
                left = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: height)
                right = CGRect(
                    x: bounds.minX, y: bounds.minY + height,
                    width: bounds.width, height: bounds.height - height)
            }
            return split.left.paneFrames(in: left) + split.right.paneFrames(in: right)
        }
    }

    /// Equalize only splits along `axis`. See `SplitTree.equalized(axis:)`.
    func equalized(axis: SplitTree.Direction) -> Self {
        switch self {
        case .leaf:
            return self

        case .split(let split):
            let ratio: Double
            if split.direction == axis {
                let left = split.left.arrangeWeight(axis)
                let right = split.right.arrangeWeight(axis)
                ratio = Double(left) / Double(left + right)
            } else {
                ratio = split.ratio
            }
            return .split(.init(
                direction: split.direction,
                ratio: ratio,
                left: split.left.equalized(axis: axis),
                right: split.right.equalized(axis: axis)))
        }
    }

    /// Same weighting as upstream's private `weightForDirection`: same-direction
    /// children add their weight, anything else counts as one.
    private func arrangeWeight(_ direction: SplitTree.Direction) -> Int {
        switch self {
        case .leaf:
            return 1
        case .split(let split):
            guard split.direction == direction else { return 1 }
            return split.left.arrangeWeight(direction) + split.right.arrangeWeight(direction)
        }
    }
}
