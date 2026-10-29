# Per-terminal themes

Slimer lets every terminal (surface) have its own colors, and every tab its own accent.
Code: `macos/Sources/Features/Theme/`. Core hook: `ghostty_config_load_arg` in
`src/config/CApi.zig`.

## Where it lives

`$XDG_CONFIG_HOME/slimer/themes.json` (default `~/.config/slimer/themes.json`). The app
creates it with eight presets on first launch, writes it atomically, and reloads it when it
changes on disk (edits are picked up about 250 ms after saving). The file is safe to sync
between machines: preset ids are fixed, and rules refer to themes by id.

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
| `ghosttyTheme` | string? | A Ghostty `theme` value (a name from `ghostty +list-themes`, or `light:X,dark:Y`). |
| `background`, `foreground`, `cursorColor`, `selectionBackground` | `#RRGGBB`? | The matching Ghostty keys. |
| `accent` | `#RRGGBB`? | Tab indicator color only. It never changes terminal colors. |

Colors must be exactly `#RRGGBB`. Anything else (`#RGB`, alpha, names, whitespace) is
dropped when the file loads. Theme names with control characters are dropped too.

### Parsing is tolerant

A malformed theme or rule is skipped instead of failing the whole file. Unknown keys are
ignored. Rules that refer to an unknown theme are dropped. If the file is not valid JSON at
all, the app keeps what it already had and logs a warning (subsystem = the bundle id,
category `themes`).

## How a theme is applied

The theme is applied to one surface with `ghostty_surface_update_config`. Other surfaces
don't change.

1. Base config:
   - Colors only: a clone of the app's current config.
   - With `ghosttyTheme`: a fresh, unfinalized load of your config files. Ghostty resolves
     `theme=` during finalize by replaying your config lines on top of the theme. A
     finalized clone would carry your previous theme's colors over the new one.
2. Then `theme=…`, `background=…`, `foreground=…`, `cursor-color=…`,
   `selection-background=…` are applied in that order through `ghostty_config_load_arg`.
   This means your explicit theme colors beat both your config file and the named theme.
3. `ghostty_config_finalize`, push to the surface, free.

Choosing "None (use config)" pushes the app's base config back to the surface.

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
- `hostname`: matches either of two things.
  - The local machine's name, short or fully qualified, case-insensitive (`.local` is
    ignored).
  - A surface title that contains `@<hostname>`. Most prompts and SSH sessions set titles
    like `user@host: ~`.
- `command`: the surface title names the command. It matches when the title equals the
  command, when its first word does, or when the first word's last path component does.
  For example, `vim`, `vim file` and `/usr/bin/vim file` all match `vim`, but `neovim`
  does not. Case-sensitive.

When several rules match, the winner is decided in this order:

1. Highest `priority`.
2. Most specific match (deepest path prefix, or longest host/command value).
3. Earliest in the file.

**Explicit wins.** Picking a theme (or "None") from a menu pins it to that surface, and
rules stop applying to it. "Automatic (follow rules)" removes the pin. Pins are stored in
the app's user defaults, keyed by the surface's stable id. Because of that, they survive
window restoration, undo of a closed tab, and moving a surface between tabs or windows.
Pins for surfaces that no longer exist expire after 30 days.

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
3. The **focused terminal's theme `accent`** (`themeAccentColor`, set by the
   `ThemeController` when focus or the applied theme changes).

"Follow Theme" clears both 1 and 2. Values 1 and 2 are per tab and persist in `UndoState`
and window restoration (`tabAccentHex` is an optional field in the restorable state, so
older saved states still decode). Value 3 is not persisted: it is re-derived from the
surface's pinned theme or rules.

## Config reloads

A global config reload (`reload_config`, or editing the Ghostty config) resets every
surface to the new base config. The `ThemeController` listens for the app-level
`ghosttyConfigDidChange` (object `nil`) and re-applies each themed surface on top of the
new base. Your config edits still show through wherever the theme doesn't set a value.
