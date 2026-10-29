# Per-terminal themes

Slimer lets every terminal (surface) have its own colors, and every tab its own accent.
Code: `macos/Sources/Features/Theme/`. Core hook: `ghostty_config_load_arg` in
`src/config/CApi.zig`.

## Where it lives

`$XDG_CONFIG_HOME/slimer/themes.json` (default `~/.config/slimer/themes.json`). The app
creates it with eight presets only if the file does not exist. It writes atomically and
reloads the file when it changes on disk (edits are picked up about 250 ms after saving).
The file is safe to sync between machines: preset ids are fixed, and rules refer to themes
by id.

```json
{
  "version": 1,
  "themes": [
    {
      "id": "5A11AE00-0000-4000-8000-000000000001",
      "name": "Slimer Green",
      "background": "#0B1A12",
      "foreground": "#D7F5DC",
      "cursorColor": "#5CF28A",
      "selectionBackground": "#1E4D32",
      "accent": "#3DDC84"
    },
    {
      "id": "0E7C3C55-2F47-4C3A-9A3D-1B7C2A5E9F10",
      "name": "Nord, hot cursor",
      "ghosttyTheme": "Nord",
      "cursorColor": "#FF5577"
    }
  ],
  "rules": [
    {
      "id": "B0B5D0F3-8B1C-4E36-9A57-2D9E3C1F7A11",
      "match": { "kind": "pathPrefix", "value": "~/Dev/league-view-backend" },
      "themeId": "5A11AE00-0000-4000-8000-000000000001",
      "priority": 0
    },
    {
      "id": "C1A2E3F4-1111-4222-8333-444455556666",
      "match": { "kind": "hostname", "value": "prod-db" },
      "themeId": "5A11AE00-0000-4000-8000-000000000003",
      "priority": 10
    }
  ]
}
```

### Theme fields

| Field | Type | Effect |
|---|---|---|
| `id` | UUID | Stable identity, referenced by rules. |
| `name` | string | Shown in menus. Never passed to a shell or config. |
| `ghosttyTheme` | string? | A Ghostty theme **name** (from `ghostty +list-themes`), or `light:X,dark:Y`. Only its colors are used; see below. |
| `background`, `foreground`, `cursorColor`, `selectionBackground` | `#RRGGBB`? | The matching Ghostty keys. |
| `accent` | `#RRGGBB`? | Tab indicator color only. It never changes terminal colors. |

Colors must be exactly `#RRGGBB`. Anything else (`#RGB`, alpha, names, whitespace) is
dropped when the file loads. Theme names with control characters are dropped too.

### Parsing is tolerant; writing is conservative

A malformed theme or rule is skipped instead of failing the whole file. Unknown keys are
ignored, and rules that refer to an unknown theme are skipped. Warnings go to the log
(subsystem = the bundle id, category `themes`).

The app never rewrites the file in a way that loses data:

| File state | In memory | In-app edits |
|---|---|---|
| Missing | Presets | Written (the file is created). |
| Not valid JSON | Presets (or the last good state) | The first edit moves the file to `themes.json.broken-<unix time>`, then writes. |
| Unreadable (permissions, not a regular file, over 4 MiB) | Presets | Never written. |
| Parsed, but something was skipped or changed (unknown keys or rule kinds, invalid colors, duplicate ids, a `version` newer than this app) | What parsed | Never written. Kept in memory only, and the Terminal Theme menu says so. |

So a file synced from a newer Slimer, or a hand edit with a typo, is never clobbered.

## How a theme is applied

The theme is applied to one surface with `ghostty_surface_update_config`. Other surfaces
don't change.

1. Start from a clone of the app's already-loaded config. Nothing is re-read from your
   config files.
2. If `ghosttyTheme` is set, resolve it to **colors only** (see the next section).
3. Apply the named theme's colors first, then the theme's explicit `background`,
   `foreground`, `cursor-color` and `selection-background`, each through
   `ghostty_config_load_arg`.
   - Later args override earlier ones, so explicit hex values beat the named theme.
   - These args are recorded after your own config lines, so they also beat your config
     file. That includes your own `theme=` and a light/dark switch, because Ghostty replays
     your lines first and these last.
4. `ghostty_config_finalize`, then push to the surface.

The finalized config is cached per theme (and light/dark appearance) until the app config
is replaced or themes.json changes. All surfaces using the same theme share one build, and
the cache is freed on the next config reload.

Choosing "None (use config)" pushes the app's base config back to the surface.

### Named Ghostty themes are reduced to colors

A Ghostty theme file is a full config file. It could set keybinds, clipboard access,
commands, title reporting, and so on. A synced or tampered themes.json must not be able to
do that, so **no theme name or path is ever passed to libghostty**:

- The name must be a plain file name: no `/`, `\`, `..`, leading `~` or `.`, or control
  characters, and at most 128 bytes. Absolute paths and `light:/a,dark:/b` style paths are
  rejected.
- It is looked up in `$XDG_CONFIG_HOME/ghostty/themes` (default `~/.config/ghostty/themes`),
  then in the app bundle's `Contents/Resources/ghostty/themes`.
- The file is opened non-blocking and must be a regular file of at most 256 KiB, so a FIFO
  or device can't hang the app.
- Slimer parses it itself and keeps only these entries, each with a strict `#RRGGBB` value
  (or bare `RRGGBB`): `background`, `foreground`, `cursor-color`, `cursor-text`,
  `selection-background`, `selection-foreground`, and `palette` entries 0–15. Every other
  line is ignored.
- `light:X,dark:Y` picks a name from the app's current appearance.

As a second layer, `ghostty_config_load_arg` itself only accepts those same color keys
(a compile-time allowlist in `src/config/CApi.zig`). Anything else, including `theme`,
`config-file` and `keybind`, is refused.

If a named theme can't be resolved, a warning is logged once. The theme's explicit colors
still apply, and the menu shows "(Ghostty theme not found)". The item is disabled if the
theme has nothing else to apply.

Theme application only happens on events: a pwd or title change (debounced 150 ms), a menu
choice, a themes.json change, or a config reload. Nothing runs per frame or per keystroke.

## Rules

A surface without an explicit choice follows the rules. Each rule has one `match`:

- `pathPrefix`: the surface's working directory (from OSC 7, as the shell reported it) is
  the path or below it.
  - Comparison is component-wise: `~/Dev/app` matches `~/Dev/app/src` but not
    `~/Dev/app2`.
  - `~` is expanded, and `.`, `..` and repeated slashes are normalized lexically.
  - Symlinks are never resolved, so matching cannot be steered by links pointing outside
    your home.
- `hostname`: matches either of two things, case-insensitive.
  - A surface title that contains `@<hostname>` followed by `:`, whitespace, `.` or the end
    of the title. Most prompts and SSH sessions set titles like `user@host: ~`. So `prod`
    matches `me@prod: ~` and `me@prod.example.com`, but not `me@production`. This remote
    match ranks above a local-name match.
  - The local machine's name, short or fully qualified (`.local` is ignored).
- `command`: the surface title names the command. It matches when the title equals the
  command, when its first word does, or when the first word's last path component does.
  For example, `vim`, `vim file` and `/usr/bin/vim file` all match `vim`, but `neovim`
  does not. Case-sensitive.

When several rules match, the winner is decided in this order:

1. Highest `priority`.
2. Within that priority, the earliest matching rule fixes the kind. Among rules of that
   same kind, the most specific wins: deepest path prefix; remote `@host` over local name,
   then longest host; longest command. Specificity is never compared across kinds.
3. Earliest in the file.

Working-directory changes are debounced by 150 ms. Title changes are throttled to at most
one evaluation per 150 ms, using the latest title, so constantly changing titles still get
evaluated.

**Explicit wins.** Picking a theme (or "None") from a menu pins it to that surface, and
rules stop applying to it. "Automatic (follow rules)" removes the pin. Pins are stored in
the app's user defaults, keyed by the surface's stable id. Because of that, they survive
window restoration, undo of a closed tab, and moving a surface between tabs or windows.
A pin's timestamp is refreshed whenever its surface is seen again. Pins for surfaces that
no longer exist expire after 30 days. Surface ids only persist through macOS window
restoration. If restoration is off (or a window isn't restored), its terminals get new ids
on the next launch and their pins are lost. Rules still apply.

A pin to a theme that was removed from themes.json falls back to the base config. A
warning is logged, and the menu shows a disabled, checked "Missing Theme" item.

Titles and paths come from the terminal, so they are treated as untrusted. They are only
compared against your rules and never executed or written into a config.

## Menus

- **Terminal ▸ Terminal Theme ▸** acts on the focused terminal of the key window. It lists:
  - "None (use config)" and "Automatic (follow rules)".
  - Every theme. A checkmark means pinned; a dash means chosen by a rule.
  - "Always Use “X” for ~/path", which adds a `pathPrefix` rule for the current directory
    using the applied theme, and replaces any existing rule for that exact path.
  - "Edit themes.json…" and "Reload Themes".
- **Tab context menu**: right-click a tab. Under the upstream Tab Color palette you get the
  same **Theme ▸** submenu (for that tab's focused terminal) and **Tab Accent ▸** ("Follow
  Theme" / "Custom Color…").

Command palette integration is not wired yet. The palette is owned by another feature.
Entry points it can call: `ThemeController.shared.setExplicitTheme(_:for:)`,
`clearExplicitTheme(for:)`, `addFolderRule(for:themeId:)`.

## Tab accent and tab color

The tab indicator dot (`TabColorIndicatorView`) shows `TerminalWindow.effectiveTabAccentColor`.
That color is the first of these that is set:

1. The upstream **Tab Color** palette choice (`tabColor`, the 10-case enum, kept for upstream
   compatibility).
2. The tab's **custom accent** (`tabAccentHex`, set via Tab Accent ▸ Custom Color…).
   Picking a custom color clears the palette choice, so the custom color shows.
3. The **focused terminal's theme `accent`** (`themeAccentColor`, set by the
   `ThemeController` when focus or the applied theme changes). Only the window's focused
   terminal can set it. If no terminal is focused, a theme change elsewhere in the window
   doesn't change the accent.

"Follow Theme" clears both 1 and 2. Values 1 and 2 are per tab and persist in `UndoState`
and window restoration (`tabAccentHex` is an optional field in the restorable state, so
older saved states still decode). Value 3 is not persisted: it is re-derived from the
surface's pinned theme or rules.

## Config reloads

There are two kinds of reload.

- **Global reload** (`reload_config`, or editing the Ghostty config): resets every surface
  to the new base config. The `ThemeController` listens for the app-level
  `ghosttyConfigDidChange` (object `nil`), drops its cache, and re-applies each themed
  surface on top of the new base.
- **Per-surface reload**: libghostty asks for one when a surface's light/dark color scheme
  changes, and there is also `reload_config` aimed at one surface. Both go through
  `Ghostty.App.reloadConfig(surface:soft:)`. A `// slimer:` hook there asks the
  `ThemeController` for that surface's themed config (built on the app config for soft
  reloads, or on the freshly loaded config for hard reloads) and pushes it instead of the
  plain base config. Surface-targeted config notifications are deliberately not observed,
  because re-applying from them would loop.

Your config edits still show through wherever the theme doesn't set a value.
