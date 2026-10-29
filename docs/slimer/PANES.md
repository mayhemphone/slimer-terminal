# Arrange Panes

Window ▸ Arrange Panes evens out the panes (splits) in the current tab. It works
in normal windows and in each drawer tab. Every item is disabled when the tab
has fewer than two panes.

| Item | What it does | Shortcut |
| --- | --- | --- |
| Equalize All | Upstream Equalize Splits: every split gets a ratio by leaf count. | `equalize_splits` (default `cmd+ctrl+=`), shown on Resize Split ▸ Equalize Splits |
| Equal Widths | Equalizes only side-by-side splits. Stacked splits keep their ratios. | none |
| Equal Heights | Equalizes only stacked splits. Side-by-side splits keep their ratios. | none |
| Even Grid | Rebuilds the tab into an even rows × columns grid. | `cmd+ctrl+G` |
| Columns | All panes side by side, equal widths. | none |
| Rows | All panes stacked, equal heights. | none |

Each item also appears in the command palette as "Arrange Panes: …" when the
tab has two or more panes.

## Even Grid

- **Order.** Panes keep their reading order: rows top to bottom, left to right
  within a row, by where they are on screen now. A row starts at the highest
  remaining pane and takes every pane whose vertical center lies within that
  pane's height, so slightly misaligned rows stay together.
- **Shape.** For `n` panes and a tab area of width / height `a`, every column
  count `c` from 1 to `n` is tried with `r = ceil(n / c)` rows. The last row
  holds the remainder at equal widths. The winner minimizes the mean
  `|ln(cell width / cell height)|` over all panes (0 is a square cell). Ties
  go to more columns. Examples: 8 panes in a 16:10 window → 2 rows × 4
  columns; 8 panes in a tall drawer (0.6) → 4 rows × 2 columns; 5 panes at
  16:10 → 3 on top, 2 below.
- **Structure.** The tree is built as rows of columns. Every row spans the
  full width, so row dividers line up across columns. Ratios are `1/k` chains,
  identical to what Equalize computes, so Equalize after Even Grid changes
  nothing.

## Behavior

- **No new terminals.** The transforms only rebuild the split tree around the
  existing terminal views. Shells and programs keep running.
- **Undo.** Every item is one undo step (`cmd+z`, "Undo Arrange Panes" or
  "Undo Equalize Splits"). This also makes upstream Equalize Splits (menu,
  keybind, divider double-click) undoable. In the drawer, split undo is
  dropped on tab switch (see DRAWER.md).
- **Focus.** The focused pane stays focused.
- **Zoom.** Even Grid, Columns and Rows unzoom a zoomed pane. Equal Widths and
  Equal Heights keep the zoom, like upstream Equalize.
- **No-op.** An item that would not change the tree does nothing and adds no
  undo entry.
- **Shortcuts.** Only Even Grid has a shortcut. `cmd+ctrl+G` is not a Ghostty
  default keybind or a standard macOS shortcut. A Ghostty `keybind` on the
  same keys wins over the menu. Bind the others in System Settings ▸ Keyboard
  ▸ Keyboard Shortcuts ▸ App Shortcuts using the exact menu title (they are
  not Ghostty actions, so a Ghostty `keybind` cannot target them).

## Code

| File | Role |
| --- | --- |
| `macos/Sources/Features/Splits/SplitTree+Arrange.swift` | Pure transforms, reading order, grid shape, `paneFrames(in:)` |
| `macos/Sources/Features/Splits/BaseTerminalController+Arrange.swift` | Menu actions, validation, applies through `replaceSurfaceTree` |
| `macos/Sources/Features/Splits/ArrangePanesPaletteOptions.swift` | Command palette entries |
| `macos/Tests/Splits/SplitTreeArrangeTests.swift` | Tests |

Upstream edits (merge hotspots):

- `MainMenu.xib`: the Arrange Panes submenu after Resize Split (ids `sLA-pn-*`).
  XIB files cannot keep a `// slimer:` marker.
- `BaseTerminalController.swift`: `ghosttyDidEqualizeSplits` calls
  `arrangePanes(.equalizeAll)`; `validateMenuItem` asks
  `validateArrangePanesMenuItem` (this also disables Equalize Splits with one
  pane).
- `TerminalCommandPalette.swift`: one line adds the palette entries.

`paneFrames(in:)` lays panes out the way `SplitView` draws them (top-left
origin, the top child gets `ratio`). Upstream's unused
`calculateViewBounds(in:)` gives the top child of a stacked split `1 - ratio`,
so it is only used in tests where that does not matter (edges shared by a
whole row).
