import AppKit
import Testing
@testable import Ghostty

// slimer: tests for SplitTree+Arrange.swift (Window > Arrange Panes).
struct SplitTreeArrangeTests {
    typealias Tree = SplitTree<MockView>
    typealias Node = Tree.Node

    static let eps = 1e-9

    static func split(_ direction: Tree.Direction, _ ratio: Double, _ left: Node, _ right: Node) -> Node {
        .split(.init(direction: direction, ratio: ratio, left: left, right: right))
    }

    static func views(_ count: Int) -> [MockView] {
        (0..<count).map { _ in MockView() }
    }

    /// An uneven tree shaped like repeated upstream splits: four columns, each
    /// split top/bottom with different ratios, so row edges do not line up.
    /// Reading order is v[0..3] on top, v[4..7] below.
    static func unevenEight(_ v: [MockView]) -> Tree {
        func column(_ top: MockView, _ bottom: MockView, _ ratio: Double) -> Node {
            split(.vertical, ratio, .leaf(view: top), .leaf(view: bottom))
        }
        let root = split(
            .horizontal, 0.3,
            column(v[0], v[4], 0.5),
            split(
                .horizontal, 0.6,
                column(v[1], v[5], 0.42),
                split(
                    .horizontal, 0.45,
                    column(v[2], v[6], 0.58),
                    column(v[3], v[7], 0.5))))
        return Tree(root: root, zoomed: nil)
    }

    /// Mixed directions with non-default ratios on both axes.
    static func mixed(_ v: [MockView]) -> Tree {
        let root = split(
            .horizontal, 0.7,
            split(
                .vertical, 0.2, .leaf(view: v[0]),
                split(.vertical, 0.9, .leaf(view: v[1]), .leaf(view: v[2]))),
            split(
                .horizontal, 0.35, .leaf(view: v[3]),
                split(.vertical, 0.65, .leaf(view: v[4]), .leaf(view: v[5]))))
        return Tree(root: root, zoomed: nil)
    }

    /// Panes split one at a time, alternating right and down, the way a user
    /// builds splits.
    static func builtUp(_ v: [MockView]) throws -> Tree {
        var tree = Tree(view: v[0])
        for i in v.indices.dropFirst() {
            tree = try tree.inserting(view: v[i], at: v[i - 1], direction: i.isMultiple(of: 2) ? .down : .right)
        }
        return tree
    }

    static func bounds(_ tree: Tree, _ rect: CGRect) -> [ObjectIdentifier: CGRect] {
        var result: [ObjectIdentifier: CGRect] = [:]
        for (view, frame) in tree.root?.paneFrames(in: rect) ?? [] {
            result[ObjectIdentifier(view)] = frame
        }
        return result
    }

    /// Upstream's y-up bounds. Its vertical ratios are mirrored relative to
    /// what SplitView draws, but edges shared by a whole row still coincide.
    static func upstreamBounds(_ tree: Tree, _ rect: CGRect) -> [ObjectIdentifier: CGRect] {
        var result: [ObjectIdentifier: CGRect] = [:]
        for (view, b) in tree.root?.calculateViewBounds(in: rect) ?? [] {
            result[ObjectIdentifier(view)] = b
        }
        return result
    }

    static func ids(_ views: [MockView]) -> [ObjectIdentifier] { views.map(ObjectIdentifier.init) }

    /// Calls `visit` for each pair of corresponding splits in two trees of the
    /// same shape. Records an issue if the shapes differ.
    static func zipSplits(_ a: Node, _ b: Node, _ visit: (Node.Split, Node.Split) -> Void) {
        switch (a, b) {
        case (.leaf(let x), .leaf(let y)):
            #expect(x === y)
        case (.split(let x), .split(let y)):
            #expect(x.direction == y.direction)
            visit(x, y)
            zipSplits(x.left, y.left, visit)
            zipSplits(x.right, y.right, visit)
        default:
            Issue.record("tree shapes differ")
        }
    }

    // MARK: - Grid shape

    static func shape(_ n: Int, _ aspect: Double) -> [Int] {
        let s = Tree.gridShape(count: n, aspectRatio: aspect)
        return [s.rows, s.columns]
    }

    @Test func gridShapeExamples() {
        #expect(Self.shape(8, 1.6) == [2, 4])
        #expect(Self.shape(8, 16.0 / 9.0) == [2, 4])
        #expect(Self.shape(8, 0.6) == [4, 2])
        #expect(Self.shape(4, 1.0) == [2, 2])
        #expect(Self.shape(6, 1.6) == [2, 3])
        #expect(Self.shape(9, 1.0) == [3, 3])
        #expect(Self.shape(5, 1.6) == [2, 3])
        #expect(Self.shape(2, 1.6) == [1, 2])
        #expect(Self.shape(3, 0.5) == [3, 1])
        #expect(Self.shape(1, 1.6) == [1, 1])
        // Bad input falls back to 1.6.
        #expect(Self.shape(8, 0) == [2, 4])
        #expect(Self.shape(8, .nan) == [2, 4])
    }

    @Test(arguments: [0.4, 1.0, 1.6, 2.5])
    func gridShapeHasNoEmptyRows(aspect: Double) {
        for n in 1...9 {
            let shape = Tree.gridShape(count: n, aspectRatio: aspect)
            #expect(shape.rows * shape.columns >= n)
            #expect((shape.rows - 1) * shape.columns < n)
        }
    }

    // MARK: - Reading order

    @Test func readingOrderGroupsMisalignedRows() {
        let v = Self.views(8)
        #expect(Self.ids(Self.unevenEight(v).readingOrder()) == Self.ids(v))
    }

    @Test func readingOrderTallLeftPane() {
        let v = Self.views(3)
        let tree = Tree(
            root: Self.split(
                .horizontal, 0.5, .leaf(view: v[0]),
                Self.split(.vertical, 0.5, .leaf(view: v[1]), .leaf(view: v[2]))),
            zoomed: nil)
        #expect(Self.ids(tree.readingOrder()) == Self.ids(v))
    }

    // MARK: - Even grid

    @Test(arguments: [0.5, 1.0, 1.6, 2.5])
    func evenGridOneToNine(aspect: Double) throws {
        for n in 1...9 {
            let v = Self.views(n)
            let tree = try Self.builtUp(v)
            let order = tree.readingOrder()
            let grid = tree.arrangedEvenGrid(aspectRatio: aspect)

            // Same leaves, same instances, reading order preserved.
            #expect(order.count == n)
            #expect(Set(Self.ids(order)) == Set(Self.ids(v)))
            #expect(Self.ids(grid.root?.leaves() ?? []) == Self.ids(order))
            #expect(Self.ids(grid.readingOrder()) == Self.ids(order))
            if n == 1 {
                #expect(grid.root == tree.root)
                continue
            }
            #expect(grid.zoomed == nil)

            // Ratios exact: identical to what upstream Equalize computes.
            #expect(grid.root == grid.equalized().root)

            let shape = Tree.gridShape(count: n, aspectRatio: aspect)
            let rect = CGRect(x: 0, y: 0, width: 1000 * aspect, height: 1000)
            let b = Self.bounds(grid, rect)
            let upstream = Self.upstreamBounds(grid, rect)
            let cellHeight = rect.height / Double(shape.rows)
            var fullRowXEdges: [[CGFloat]] = []
            for r in 0..<shape.rows {
                let row = order[(r * shape.columns)..<min(n, (r + 1) * shape.columns)]
                let rowBounds = row.compactMap { b[ObjectIdentifier($0)] }
                #expect(rowBounds.count == row.count)
                guard let first = rowBounds.first else { continue }
                // Row dividers line up: every pane in a row has identical y edges.
                for cell in rowBounds {
                    #expect(cell.minY == first.minY)
                    #expect(cell.maxY == first.maxY)
                    #expect(abs(cell.height - cellHeight) < Self.eps)
                    #expect(abs(cell.width - rect.width / Double(row.count)) < Self.eps)
                }
                // Rows go top to bottom (top-left origin).
                #expect(abs(first.minY - Double(r) * cellHeight) < Self.eps)
                // Same alignment through upstream's calculateViewBounds.
                let upstreamRow = row.compactMap { upstream[ObjectIdentifier($0)] }
                for cell in upstreamRow {
                    #expect(cell.minY == upstreamRow[0].minY)
                    #expect(cell.maxY == upstreamRow[0].maxY)
                }
                if row.count == shape.columns {
                    fullRowXEdges.append(rowBounds.map(\.minX) + rowBounds.map(\.maxX))
                }
            }
            // Column dividers of full rows line up exactly across rows.
            for edges in fullRowXEdges {
                #expect(edges == fullRowXEdges[0])
            }
        }
    }

    @Test func evenGridEightWideIsTwoByFour() throws {
        let v = Self.views(8)
        let grid = Self.unevenEight(v).arrangedEvenGrid(aspectRatio: 1.6)
        let b = Self.bounds(grid, CGRect(x: 0, y: 0, width: 1600, height: 1000))
        for i in 0..<4 {
            let top = try #require(b[ObjectIdentifier(v[i])])
            let bottom = try #require(b[ObjectIdentifier(v[i + 4])])
            #expect(abs(top.minX - Double(i) * 400) < Self.eps)
            #expect(top.minX == bottom.minX)
            #expect(top.minY == 0)
            #expect(top.maxY == 500)
            #expect(bottom.minY == 500)
            #expect(bottom.maxY == 1000)
        }
    }

    @Test func arrangeIsIdempotent() throws {
        let v = Self.views(7)
        let tree = Self.mixed(Array(v.prefix(6)))
        let grid = tree.arrangedEvenGrid(aspectRatio: 1.6)
        #expect(grid.arrangedEvenGrid(aspectRatio: 1.6).root == grid.root)
        #expect(grid.arrangedGrid(columns: 3).root == grid.root)
        let cols = tree.arrangedColumns()
        #expect(cols.arrangedColumns().root == cols.root)
        let rows = tree.arrangedRows()
        #expect(rows.arrangedRows().root == rows.root)
        let widths = tree.equalized(axis: .horizontal)
        #expect(widths.equalized(axis: .horizontal).root == widths.root)
        let heights = tree.equalized(axis: .vertical)
        #expect(heights.equalized(axis: .vertical).root == heights.root)
        let built = try Self.builtUp(v)
        let builtGrid = built.arrangedEvenGrid(aspectRatio: 0.6)
        #expect(builtGrid.arrangedEvenGrid(aspectRatio: 0.6).root == builtGrid.root)
    }

    // MARK: - Columns and rows

    @Test func columnsAndRows() {
        let v = Self.views(6)
        let tree = Self.mixed(v)
        let order = Self.ids(tree.readingOrder())
        let rect = CGRect(x: 0, y: 0, width: 1200, height: 600)

        let cols = tree.arrangedColumns()
        #expect(Self.ids(cols.root?.leaves() ?? []) == order)
        #expect(cols.root == cols.equalized().root)
        for cell in Self.bounds(cols, rect).values {
            #expect(abs(cell.width - 200) < Self.eps)
            #expect(cell.height == 600)
        }

        let rows = tree.arrangedRows()
        #expect(Self.ids(rows.root?.leaves() ?? []) == order)
        #expect(rows.root == rows.equalized().root)
        for cell in Self.bounds(rows, rect).values {
            #expect(abs(cell.height - 100) < Self.eps)
            #expect(cell.width == 1200)
        }
    }

    // MARK: - Axis-only equalize

    @Test(arguments: [Tree.Direction.horizontal, Tree.Direction.vertical])
    func axisEqualizeLeavesOtherAxis(axis: Tree.Direction) throws {
        let v = Self.views(8)
        for tree in [Self.mixed(Array(v.prefix(6))), Self.unevenEight(v)] {
            let result = tree.equalized(axis: axis)
            let full = tree.equalized()
            let before = try #require(tree.root)
            let after = try #require(result.root)
            let equal = try #require(full.root)
            #expect(Self.ids(after.leaves()) == Self.ids(before.leaves()))
            // The other axis keeps its ratios exactly.
            Self.zipSplits(before, after) { old, new in
                if old.direction != axis {
                    #expect(new.ratio == old.ratio)
                }
            }
            // This axis matches upstream Equalize exactly.
            Self.zipSplits(equal, after) { eq, new in
                if eq.direction == axis {
                    #expect(new.ratio == eq.ratio)
                }
            }
        }
    }

    @Test func equalWidthsOnUnevenEight() throws {
        let v = Self.views(8)
        let result = Self.unevenEight(v).equalized(axis: .horizontal)
        let b = Self.bounds(result, CGRect(x: 0, y: 0, width: 1600, height: 1000))
        for i in 0..<4 {
            let cell = try #require(b[ObjectIdentifier(v[i])])
            #expect(abs(cell.width - 400) < Self.eps)
        }
        // Heights untouched: column 1 still splits at 0.42.
        let cell = try #require(b[ObjectIdentifier(v[1])])
        #expect(abs(cell.height - 420) < Self.eps)
    }

    // MARK: - Zoom and trivial trees

    @Test func zoomHandling() throws {
        let v = Self.views(6)
        let base = Self.mixed(v)
        let leaf = try #require(base.root?.node(view: v[0]))
        let zoomed = Tree(root: base.root, zoomed: leaf)
        #expect(zoomed.isZoomed)
        #expect(zoomed.equalized(axis: .horizontal).zoomed == leaf)
        #expect(zoomed.equalized(axis: .vertical).zoomed == leaf)
        #expect(zoomed.arrangedEvenGrid(aspectRatio: 1.6).zoomed == nil)
        #expect(zoomed.arrangedColumns().zoomed == nil)
        #expect(zoomed.arrangedRows().zoomed == nil)
    }

    // MARK: - Focus decision

    @Test func refocusOnlyWhenStructureChanges() {
        let v = Self.views(6)
        let tree = Self.mixed(v)
        let focused = v[2]
        let refocus = { (new: Tree) in
            BaseTerminalController.arrangeRefocusTarget(from: tree, to: new, focused: focused)
        }
        // Ratio-only changes must not touch focus.
        #expect(refocus(tree.equalized()) == nil)
        #expect(refocus(tree.equalized(axis: .horizontal)) == nil)
        #expect(refocus(tree.equalized(axis: .vertical)) == nil)
        // Re-parenting changes refocus the focused pane.
        #expect(refocus(tree.arrangedEvenGrid(aspectRatio: 1.6)) === focused)
        #expect(refocus(tree.arrangedColumns()) === focused)
        #expect(refocus(tree.arrangedRows()) === focused)
        // Undo direction is symmetric.
        let grid = tree.arrangedEvenGrid(aspectRatio: 1.6)
        #expect(BaseTerminalController.arrangeRefocusTarget(from: grid, to: tree, focused: focused) === focused)
        // Unzooming is structural; no focus or a foreign view means no refocus.
        let leaf = tree.root?.node(view: v[0])
        let zoomed = Tree(root: tree.root, zoomed: leaf)
        #expect(BaseTerminalController.arrangeRefocusTarget(from: zoomed, to: tree, focused: focused) === focused)
        #expect(BaseTerminalController.arrangeRefocusTarget(from: tree, to: grid, focused: nil) == nil)
        #expect(BaseTerminalController.arrangeRefocusTarget(from: tree, to: grid, focused: MockView()) == nil)
    }

    @Test func emptyAndSingleAreUnchanged() {
        let empty = Tree()
        #expect(empty.arrangedEvenGrid(aspectRatio: 1.6).isEmpty)
        #expect(empty.equalized(axis: .horizontal).isEmpty)
        #expect(empty.readingOrder().isEmpty)
        let single = Tree(view: MockView())
        #expect(single.arrangedColumns().root == single.root)
        #expect(single.arrangedRows().root == single.root)
        #expect(single.equalized(axis: .vertical).root == single.root)
    }
}
