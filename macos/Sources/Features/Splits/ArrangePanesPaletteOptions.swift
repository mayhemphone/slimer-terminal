import AppKit

// slimer: command palette entries for Window > Arrange Panes. Shown only when
// the palette's tab has two or more panes. See docs/slimer/PANES.md.
enum ArrangePanesPaletteOptions {
    static func options(for surfaceView: Ghostty.SurfaceView) -> [CommandOption] {
        guard let controller = surfaceView.window?.windowController as? BaseTerminalController,
              controller.canArrangePanes else { return [] }

        return BaseTerminalController.PaneArrangement.allCases.map { arrangement in
            CommandOption(
                title: "Arrange Panes: \(arrangement.title)",
                description: arrangement.detail,
                leadingIcon: arrangement.symbol
            ) { [weak controller] in
                controller?.arrangePanes(arrangement)
            }
        }
    }
}
