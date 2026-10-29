# Settings window (Phase 7)

The app menu's **Settings…** item (Cmd+,) opens a native settings window with a sidebar of panes.
Code: `macos/Sources/Features/Settings/`. Tests: `macos/Tests/Features/Settings/`.

Only the selected pane is built, so opening the window is cheap. Git version, theme names
and the monospaced font list load in the background the first time their pane appears.

## Panes

| Pane | What it edits | Where it is stored |
|---|---|---|
| General | Global hotkeys for `toggle_quick_terminal`, `new_window`, `toggle_command_palette` (key recorder); Accessibility status with a button to System Settings; `window-inherit-working-directory`, `confirm-close-surface` | Ghostty config |
| Drawer | `quick-terminal-position` (with a schematic preview), `-size` (primary/secondary, % or px), `-screen`, `-animation`, `-animation-easing`, `-animation-duration` (0–1 s), `-autohide`, `-tab-bar`; **Preview Drawer** toggles the drawer | Ghostty config |
| Appearance | `theme` (searchable list of theme files), `font-family`, `font-size`, `background-opacity`, `background-blur`, `macos-titlebar-style`, `slimer-status-bar` | Ghostty config |
| Themes & Tabs | Slimer themes (strict `#RRGGBB` colors) and rules (kind, value, theme, priority; drag to reorder) | `themes.json` (`ThemeStore`) |
| Locations & Commands | Locations, commands (shortcut via the recorder, checked with the Workspace shortcut policy), recent directories (promote, clear) | `workspace.json` (`WorkspaceStore`) |
| Git & Status Bar | `slimer-status-bar`; read-only git binary, version, and last refresh time per watched repository | Ghostty config |
| Claude | Detected `claude` binary; default open mode for the status bar button (tab or split) | `UserDefaults` key `SlimerClaudeDefaultPlacement` |
| Advanced | Open/reveal/reload the config, show Slimer's block, Ghostty's diagnostics (`ConfigurationErrorsView`), open `workspace.json` / `themes.json` | — |

Theme names come from the same directories the per-terminal theme resolver uses (and
`ghostty +list-themes` lists): `$XDG_CONFIG_HOME/ghostty/themes` (default
`~/.config/ghostty/themes`), then the app bundle's `Contents/Resources/ghostty/themes`.

## Writing the Ghostty config

### Which file

The file "Open Config" opens: the app's `--config-file` override if one was given,
otherwise `ghostty_config_open_path()` (on macOS the Application Support config if it exists
and is non-empty, else the XDG one; the file is created if missing).

### The managed block

Settings never edits your own lines. Every Ghostty key it manages lives in one block:

```
# >>> slimer managed (edit in Settings) >>>
quick-terminal-position = right
font-family = ""
font-family = JetBrains Mono
keybind = global:cmd+backquote=unbind
keybind = global:cmd+f1=toggle_quick_terminal
# <<< slimer managed <<<
```

- `GhosttyConfigWriter.render` replaces the block in place, or appends it at the end of
  the file after a blank line. With nothing left to manage it removes the block.
- Line endings follow the file (CRLF files get CRLF lines). A last line without a newline
  gets one before the block is appended.
- A damaged block (begin without end, end first, or two blocks) is reported and the file is
  **not written** until you fix it by hand.
- `font-family` is written as `""` then the name, so it replaces earlier lines instead of
  adding a fallback.
- **"Use value from my config"** under a control removes that key from the block.

### Later lines win

Ghostty applies lines in order, so the block overrides anything set **before** it (shown as
an info note once Settings manages the key). A line **after** the block wins over Settings:

- the control shows "Your config sets X on line N after Slimer's block; Settings can't
  change it" and is disabled;
- `keybind` lines after the block are matched by trigger (same trigger or `keybind = clear`
  overrides) or by action (another trigger for the same action is an info note);
- `font-family` after the block adds a fallback (info), unless it is `""` (override);
- `config-file` includes are loaded after the file and can override anything (info).

### Global hotkeys

The General pane shows your own `keybind = global:…=<action>` line for each action
("from your config, line N") until you change it. Settings never edits that line. When you
record a different trigger (or clear the hotkey) the block **unbinds** your trigger and binds
the new one, which works because the block comes later. Triggers outside the recorder's
grammar (for example `super+grave_accent`) can't be echoed safely; Settings leaves them
alone and says so. Global hotkeys need a modifier or an F-key, and Accessibility access.

### Validation

Values are validated before anything is scheduled (`SettingsValidator`):

- Every key is on an allowlist (`SettingsKeySpec.all`); anything else is refused.
- Enums against their allowed values, booleans `true`/`false`.
- Numbers: plain POSIX decimals only (no exponents, `nan`, `inf`), range-checked
  (`quick-terminal-animation-duration` 0–1, `background-opacity` 0–1, `font-size` 4–200),
  written with at most three decimals.
- `quick-terminal-size`: one or two of `1–100%` / `1–10000px`.
- `background-blur`: `true`, `false`, `0–100`, `macos-glass-regular`, `macos-glass-clear`.
- `theme`: a plain file name (no `/`, `\`, `..`, leading `.`/`~`, `,`, `:`, `#`) or
  `light:X,dark:Y` of two such names.
- `font-family`: at most 128 characters, no control characters, `#` or quotes.
- `keybind`: only `global:<trigger>=<one of the three actions>` or `[global:]<trigger>=unbind`,
  where the trigger is in the recorder's grammar: `cmd`, `ctrl`, `alt`, `shift` (in that
  order, each once) and one key (`a`–`z`, `0`–`9`, `backquote`, `comma`, `bracket_left`,
  `enter`, `arrow_up`, `f1`–`f20`, …).
- The writer itself refuses keys outside `[a-z0-9-]+` and values that are empty, padded,
  or contain any control character, DEL, C1 control or U+2028/2029. No value can ever
  start a second line.

### The write

Edits are debounced by 300 ms (sliders don't rewrite the file on every tick; closing the
window flushes). Each write:

1. Re-reads the file (so a hand edit made meanwhile is kept) and renders the new block.
2. Resolves symlinks and writes to the target, so a dotfiles symlink stays a symlink.
3. Before the first write that adds the block, copies the file to
   `<name>.slimer-backup` next to it (never overwritten afterwards).
4. Writes a temp file in the same directory with the original permissions, `fsync`s it and
   `rename(2)`s it over the target.
5. Calls `Ghostty.App.reloadConfig()`. When the reloaded config arrives
   (`ghosttyConfigDidChange`), each written key Ghostty can report through
   `ghostty_config_get` is compared with what was written; a mismatch shows "Ghostty didn't
   apply this; it is using …". `theme`, `font-family` and keybinds can't be read back; for
   those, Ghostty's diagnostics (Advanced pane, and Ghostty's own errors window) are the
   signal.

Only regular UTF-8 files up to 1 MiB are read or written (opened non-blocking, so a FIFO
can't hang the app).

## Themes and workspace data

- **Themes & Tabs** edits through `ThemeStore` (`upsert`, `remove`, `add(rule:)`, plus
  `update(rule:)` and `moveRules` added for Settings). When `themes.json` is *lossy* (keys
  or entries this version doesn't understand, or a newer `version`) or *unreadable*, a
  banner explains why and editing is disabled. When it is *unparseable*, a banner says the
  first edit moves it aside to `themes.json.broken-<time>`.
- **Locations & Commands** edits through `WorkspaceStore.edit`, the same re-read-then-apply
  path as usage updates. Usage counts are kept when an item is edited. Locations need an
  absolute (or `~/`) path; startup commands and commands must pass the same insert-safety
  check as when they are typed. Shortcuts must include ⌘, must not be a Ghostty keybinding
  (checked against a live surface) and must not be used by another item. While
  `workspace.json` is invalid, editing is disabled.

## Hooks into upstream files

| File | Hunk |
|---|---|
| `App/MainMenu.xib` | 2 lines: "Preferences…" → "Settings…", action `openConfig:` → `openSettings:` (same item, so `open_config`'s keybind, Cmd+, by default, still drives it). |
| `App/AppDelegate.swift` | +5 lines: `openSettings(_:)` IBAction. |
| `Ghostty/Ghostty.App.swift` | 1 line: `configPath` is `private(set)` instead of `private`. |

Cmd+, now opens Settings instead of the config file. **Open Config File** is in Settings ▸
Advanced. Because the menu item takes `open_config`'s trigger as its shortcut, that keybind
opens Settings too; invoking `open_config` without a key (e.g. from the command palette)
still opens the file.

## Tests

`macos/build.nu --action test`. All file tests use temp directories; nothing touches
`~/.config/ghostty`.

- `GhosttyConfigWriterTests`: insert, replace, removal, idempotence, byte-for-byte
  preservation outside the block, CRLF and missing trailing newline, repeatable keybinds,
  newline/control refusal, malformed blocks, override/append/include detection, keybind
  parsing.
- `KeyTriggerTests`: recorder mapping (layout-aware letters, physical digits and named keys,
  unnameable keys), grammar validation, global and Workspace rules, display strings.
- `SettingsValidatorTests`: every value kind, and that no key accepts a line break.
- `GlobalKeybindPlannerTests`: unbinding the user's old trigger, disable, round trip, reused
  triggers, bindings after the block.
- `GhosttyConfigFileTests`: create, permissions, single backup, symlink write-through,
  directory/FIFO/non-UTF-8 refusal, end to end.
- `SettingsConfigStoreTests`: validation, write + reload, block removal, malformed block
  never written, hand edits during the debounce, override warning, hotkey replacement.
- `SettingsStoreEditTests`: `ThemeStore.update/moveRules`, lossy files reject edits,
  `WorkspaceStore.edit`.

## Not yet

- No UI automation; panes were verified by building and reading.
- `theme`, `font-family` and keybinds are not read back after a reload (the C API can't
  report them); only diagnostics cover them.
- Removing the last managed key leaves the blank line that preceded the block.
- Autocomplete and Updates panes (from the plan) are not built.
