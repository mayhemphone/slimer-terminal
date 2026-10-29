# Shortcut sheet

Hold Control on its own for two seconds and Slimer shows every keyboard
shortcut it knows about, centered over the focused window (a normal window or
the drawer). Let go of Control, press any key, click, or switch apps and it
fades away. macOS only.

## Config

```ini
slimer-shortcut-overlay = ctrl        # ctrl | cmd | option | off
slimer-shortcut-overlay-delay = 2s    # any Ghostty duration: 1500ms, 1s, ...
```

Both are plain Ghostty keys and can be changed at runtime. Settings ▸ General ▸
Shortcut Sheet edits them (the delay picker offers 0.5 to 5 seconds; a value
from your own config stays selectable).

## When it shows

- The modifier must be down **alone**. Caps Lock and Fn don't count.
- Pressing any other key, another modifier, a mouse button, or scrolling while
  it is held cancels the timer, and the modifier has to be released before it
  can arm again. Ctrl-C, Ctrl-R and friends never show the sheet.
- Releasing the modifier, pressing a key, clicking, the app deactivating, or
  the key window changing hides it.
- It only appears over terminal windows (not Settings or other panels).

## What it lists

Columns with a header per group, in this order:

1. **Menus.** Every item in the main menu that has a key equivalent, walked
   from `NSApp.mainMenu` when the sheet is shown. One group per top-level menu
   (submenu items included under their top-level menu). Separators and hidden
   items are skipped; items that are disabled right now are shown dimmed. This
   automatically picks up Ghostty's keybind-synced menu shortcuts and Slimer's
   Workspace, Claude, Theme and Arrange items. The Services menu is skipped.
2. **Global** and **Keybinds.** Ghostty keybinds that no menu shows (for
   example `goto_split:*`, `resize_split:*`, `equalize_splits`, extra
   `next_tab` bindings). Global binds (`global:` prefix) are always listed under
   Global, even when a menu shows the same keys, and carry a "Global" badge.
   Titles come from the command palette's entries when one matches the action,
   otherwise from the action name (`goto_split:left` → "Goto split: left").
   `ignore`/`unbind` and actions unsupported on macOS are left out.
3. **In the terminal.** Slimer keys that are neither menu items nor keybinds:
   the autocomplete popup's keys (see `AUTOCOMPLETE.md`).

When everything doesn't fit in 80% of the window, groups split across columns
and a footer says how many entries were left out.

## How keybinds are read

`ghostty_config_keybind_count` / `ghostty_config_keybind_at` in
`src/config/CApi.zig` (slimer additions, declared in `include/ghostty.h`)
walk the top-level entries of the config's keybind set read-only. Each call
returns the trigger (`ghostty_input_trigger_s`), the binding flags, and the
action formatted in config syntax into a caller-owned buffer (NUL-terminated,
truncated to fit). Sequences (`ctrl+a>n`) are skipped; chained bindings report
their first action. The command palette's own path (`ghostty_config_trigger`)
only maps an action to one trigger and has no flags, so it can't list
unbound-from-menu or global binds.

## Speed and safety

- One in-app local event monitor (`NSEvent.addLocalMonitorForEvents`) for
  `flagsChanged`, `keyDown`, mouse-down and scroll. It always returns the event
  unchanged, so nothing is delayed or swallowed. No global monitor, no event
  tap, no Accessibility use. With `off` the monitor is removed.
- Per event the work is one modifier-flag compare and at most starting or
  cancelling a timer (`ShortcutOverlayHoldDetector`, a pure state machine).
- Content is built on show and cached until the config reloads or a menu item
  is added, removed or changed. Menu validation (`NSMenu.update()`) runs on
  show so the dimmed state is current.
- The sheet is a borderless, non-activating child panel that can't become key
  or main and ignores the mouse, so it never takes focus and clicks go to the
  terminal underneath (and dismiss it).
- Titles from menus and config are display-only: control, format and bidi
  characters are removed and long titles are truncated.

## Files

| File | Role |
|---|---|
| `macos/Sources/Features/ShortcutOverlay/ShortcutOverlayHoldDetector.swift` | Hold state machine |
| `macos/Sources/Features/ShortcutOverlay/ShortcutOverlayController.swift` | Event monitor, timer, panel, cache |
| `macos/Sources/Features/ShortcutOverlay/ShortcutCatalog.swift` | Menu walk, keybind grouping, glyphs |
| `macos/Sources/Features/ShortcutOverlay/ShortcutOverlayView.swift` | Column layout, SwiftUI view, panel |
| `macos/Sources/Features/ShortcutOverlay/Ghostty.Config+ShortcutOverlay.swift` | Config getters, keybind enumeration |
| `macos/Sources/Features/ShortcutOverlay/ShortcutOverlaySettingsSection.swift` | Settings ▸ General section |
| `src/config/CApi.zig` | `ghostty_config_keybind_count` / `_at` |

Upstream touch points (marked `// slimer:`): `AppDelegate.swift` (one line to
install the controller), `GeneralPane.swift` (one line), `SettingsValidators.swift`
(two registry entries), `Config.zig`, `CApi.zig`, `ghostty.h`.
