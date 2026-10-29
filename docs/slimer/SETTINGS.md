# Settings window (Phase 7)

The app menu's **Settings…** item (Cmd+,) opens a native settings window with a sidebar of panes.
Code: `macos/Sources/Features/Settings/`. Tests: `macos/Tests/Features/Settings/`.

Only the selected pane is built, and config files are read and parsed off the main thread, so opening the window is cheap. Git version, theme names
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
and is non-empty, else the XDG one; the file is created if missing). The path is resolved
again on every load, so a config created or moved while Settings is open is picked up.

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

- **Only Settings' own lines in the block are rewritten.** Settings owns the lines for keys
  in its registry (`SettingsKeySpec.all`), except `keybind`, where it owns only
  `global:<trigger>=<toggle_quick_terminal|new_window|toggle_command_palette>` and
  `global:<trigger>=unbind` (trigger in the recorder grammar). Comments, blank lines,
  unknown keys (say, from a newer Slimer synced through dotfiles) and any other keybind in
  the block stay verbatim and in place. A key's new values go where its first line was; new
  keys go before the end marker.
- With no block yet, one is appended at the end after a blank line. A block left with only
  blank lines is removed; one with foreign lines is kept.
- **Line endings and BOM:** every existing line keeps its own terminator (LF, CRLF, or a
  lone CR at the very end of the file) and the markers are kept verbatim. New lines use the
  file's majority ending. A UTF-8 BOM is kept.
- A damaged block (begin without end, end first, or two blocks) is reported and the file is
  **not written** until you fix it by hand.
- `font-family` is written as `""` then the name, so it replaces earlier lines instead of
  adding a fallback.
- **"Use value from my config"** under a control removes that key from the block.

### Later lines and other files win

Ghostty loads, in order: XDG `config`, XDG `config.ghostty`, Application Support
(`~/Library/Application Support/com.mitchellh.ghostty/`) `config`, then `config.ghostty`,
then `config-file` includes. Later lines win, so:

- Lines **before** the block (in the same file) are overridden by it (info note once
  Settings manages the key).
- A line **after** the block wins over Settings: the control shows "Your config sets X on
  line N after Slimer's block; Settings can't change it" and is disabled.
  - `keybind` lines after the block are matched by trigger (same trigger or `keybind =
    clear` overrides) or by action (another trigger for the same action is an info note).
  - `font-family` after the block adds a fallback (info), unless it is `""` (override).
- **Other default files** that load after the edited one are scanned, and any managed key
  they set is shown as an override with its file and line. With a `--config-file` override
  Ghostty doesn't load the defaults, so none are scanned.
- **Includes** (`config-file`, one level, at most 8) are scanned the same way. Because they
  load last, every control also shows a note naming them; for `theme`, `font-family` and
  keybinds, which Settings can't read back after a reload, the note is a warning.
- `global:` bindings of the managed actions found in other files or includes are listed in
  the General pane as still active; Settings never unbinds them.
- **Over-long lines:** Ghostty's line reader stops at a line longer than 4094 bytes, so
  such a line before the block (or anywhere, while the block is still to be appended) hides
  the block. Settings shows an error banner for it.

### Global hotkeys

The General pane shows your own `keybind = global:…=<action>` line for each action
("from your config, line N") until you change it. Settings never edits that line. When you
record a different trigger (or clear the hotkey) the block **unbinds** your trigger and binds
the new one, which works because the block comes later. Triggers outside the recorder's
grammar (for example `super+grave_accent`) can't be echoed safely; Settings leaves them
alone and says so.

On every load (when no edit is pending) the block's keybinds are recomputed from your
current lines. If they differ, the block is rewritten. In particular a stale
`global:<t>=unbind` whose line you removed is dropped: Ghostty's unbind removes the trigger
whatever its flags, so it would otherwise kill an unrelated later binding on that key.

Global hotkeys need a modifier (or an F-key) and Accessibility access, and they may not be a
standard system or editing shortcut, because a global hotkey takes the key from every app.
Refused: ⌘ plus any single letter, ⌘Tab, ⌘Space, ⌘, and ⌘., ⇧⌘Z, ⇧⌘Tab, ⌥⌘Esc, ⌥⌘Space,
⌃Space, ⌃⇧Space and ⌃+arrow keys. ⌘` stays allowed (it is the drawer's suggested default).

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
- `keybind`: only `global:<trigger>=<one of the three actions>` (trigger allowed as a global
  hotkey, see above) or `[global:]<trigger>=unbind`, where the trigger is in the recorder's
  grammar: `cmd`, `ctrl`, `alt`, `shift` (in that order, each once) and one key (`a`–`z`,
  `0`–`9`, `backquote`, `comma`, `bracket_left`, `enter`, `arrow_up`, `f1`–`f20`, …).
- The writer itself refuses keys outside `[a-z0-9-]+` and values that are empty, padded,
  or contain any control character, DEL, C1 control or U+2028/2029. No value can ever
  start a second line.

### The write

Edits are debounced by 300 ms (sliders don't rewrite the file on every tick). Pending edits
are also flushed when the window closes and when the app quits (the store observes
`NSApplication.willTerminateNotification`). Reading, parsing and writing run on a serial
background queue; published state changes only on the main thread. Each write:

1. Re-reads the file (so a hand edit made meanwhile is kept) and renders the new block.
   If the file existed when Settings last read it but is now gone (an editor's
   rename-write-delete save caught halfway), nothing is written.
2. Refuses a dangling symlink, a read-only file or directory, or anything that isn't a
   regular UTF-8 file up to 1 MiB (files are opened non-blocking, so a FIFO can't hang the
   app). Symlinks are resolved, so a dotfiles symlink stays a symlink.
3. If the write newly adds the block, first copies the file to
   `<name>.slimer-backup-YYYYMMDD-HHMMSS` next to it; the newest three backups are kept.
4. Writes a temp file in the same directory with the original mode, copies the original's
   extended attributes and ACL onto it (best effort), `F_FULLFSYNC`s it, re-checks that the
   target's device, inode, size and mtime still match the read (if not, nothing is written;
   it re-reads and tries once more), `rename(2)`s it over the target and syncs the
   directory.
5. Calls `Ghostty.App.reloadConfig()`. When the reloaded config arrives
   (`ghosttyConfigDidChange`), each written key Ghostty can report through
   `ghostty_config_get` is compared with what was written; a mismatch shows "Ghostty didn't
   apply this; it is using …". `theme`, `font-family` and keybinds can't be read back; for
   those, Ghostty's diagnostics (Advanced pane, and Ghostty's own errors window) and the
   include warnings are the signal.

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

Upstream's `Features/Settings/SettingsView.swift` is unchanged; Slimer's window is
`SlimerSettingsView` (`SlimerSettingsView.swift`), hosted by `SettingsWindowController`.

| File | Hunk |
|---|---|
| `App/MainMenu.xib` | The app menu's "Preferences…" item is renamed "Settings…" and its action changes from `openConfig:` to `openSettings:` (2 lines). A new "Open Config File" item right after it keeps upstream's `openConfig:` reachable (+6 lines). |
| `App/AppDelegate.swift` | +5 lines: `openSettings(_:)` IBAction. |
| `Ghostty/Ghostty.App.swift` | 1 line: `configPath` is `private(set)` instead of `private`. |

Cmd+, now opens Settings instead of the config file. The Settings… item is still the
`menuOpenConfig` outlet, so it takes `open_config`'s trigger as its shortcut: **the
`open_config` keybind (Cmd+, by default, or whatever you bind it to) opens Settings.** To
open the file use **Open Config File** in the app menu, Settings ▸ Advanced, or the command
palette's Open Config (which invokes `open_config` without a key).

## Tests

`macos/build.nu --action test`. All file tests use temp directories (and the store tests a
temp XDG and Application Support directory); nothing touches `~/.config/ghostty` or the real
Application Support config.

- `GhosttyConfigWriterTests`: insert, replace, removal, idempotence, byte-for-byte
  preservation outside the block, foreign lines inside the block kept verbatim and in
  place, per-line terminators (CRLF, mixed, lone trailing CR), BOM, split/join round trip,
  repeatable keybinds, newline/control refusal, malformed blocks, override/append/include
  detection, over-long lines, keybind parsing.
- `KeyTriggerTests`: recorder mapping (layout-aware letters, physical digits and named keys,
  unnameable keys), grammar validation, global hotkey rules including the denied system
  shortcuts, Workspace rules, display strings.
- `SettingsValidatorTests`: every value kind, and that no key accepts a line break.
- `GlobalKeybindPlannerTests`: unbinding the user's old trigger, disable, round trip, reused
  triggers, bindings after the block.
- `GhosttyConfigFileTests`: create, permissions and xattrs kept, timestamped backups (keep
  three), symlink write-through, dangling symlink, read-only refusal, change detected
  between read and rename, directory/FIFO/non-UTF-8 refusal, BOM on disk, end to end.
- `SettingsConfigStoreTests`: validation, write + reload, one backup per added block, block
  removal, foreign block lines through edits, malformed block never written, hand edits
  during the debounce, vanished file never recreated, override warning, hotkey
  replacement, denied hotkey, stale unbind dropped on load, later default file and include
  overrides and left-active bindings, flush on quit, asynchronous load.
- `SettingsStoreEditTests`: `ThemeStore.update/moveRules`, lossy files reject edits,
  `WorkspaceStore.edit`.

## Not yet

- No UI automation; panes were verified by building and reading.
- `theme`, `font-family` and keybinds are not read back after a reload (the C API can't
  report them); only diagnostics and include warnings cover them.
- Includes are scanned one level deep; nested includes aren't.
- Removing the last managed key leaves the blank line that preceded the block.
- Autocomplete and Updates panes (from the plan) are not built.
