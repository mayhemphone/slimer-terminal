# Workspace: locations, saved commands and recent directories

The Workspace feature gives you fast access to the directories you live in and
the commands you run all day, from the command palette, a top-level
**Workspace** menu with per-item keyboard shortcuts, and pins. It also learns
the directories you visit from the shell's working-directory reports.

Everything is stored in one JSON file so it can be synced between machines
with your dotfiles:

```
$XDG_CONFIG_HOME/slimer/workspace.json      (if XDG_CONFIG_HOME is an absolute path)
~/.config/slimer/workspace.json             (otherwise)
```

Code lives in `macos/Sources/Features/Workspace/`.

## The file

- Created on first launch with a few example locations and commands.
- Written atomically (temp file + rename) with mode `0600`; the directory is
  `0700`. Symlinks are followed, so a symlinked `workspace.json` keeps pointing
  at your dotfiles repo.
- Reloaded automatically when it changes on disk (editor save, sync tool).
  **Workspace > Reload Workspace** forces a reload.
- Parsing is tolerant: unknown keys are ignored, missing fields take defaults,
  and a malformed entry is dropped. If the whole file fails to parse, Slimer
  keeps running with an empty workspace, logs the error, shows a disabled
  "workspace.json could not be read" item in the menu, and **never overwrites
  the file** until it parses again.
- Dates are ISO 8601 strings. Slimer rewrites the file (pretty printed, sorted
  keys) when it records usage.

### Schema

```jsonc
{
  "version": 1,
  "locations": [
    {
      "id": "6C0B5D54-7E2B-4B5B-9F6B-6A7B6B9C4E11", // UUID; generated if missing
      "name": "league-view-backend",               // defaults to the last path component
      "path": "~/Dev/league-view-backend",         // required; "~" is expanded
      "icon": "server.rack",                        // optional SF Symbol name
      "color": "#FF8800",                           // optional #RRGGBB
      "pinned": true,                               // default false
      "shortcut": "cmd+shift+3",                    // optional, Ghostty style
      "startupCommand": "claude",                   // optional; runs in NEW tabs/splits/windows
      "useCount": 12,                               // maintained by Slimer
      "lastUsed": "2026-10-28T14:03:11Z"            // maintained by Slimer
    }
  ],
  "commands": [
    {
      "id": "0F0E4A2E-0B3F-4D3F-8C6B-2A4C9B1D7E22",
      "name": "Claude (continue)",                  // defaults to the command text
      "command": "claude --continue",               // required
      "cwd": "~/Dev/league-view-backend",           // optional; prepends `cd '<cwd>' && `
      "pinned": true,
      "shortcut": "cmd+shift+c",
      "confirm": true,                              // default true, see below
      "useCount": 3,
      "lastUsed": "2026-10-28T14:03:11Z"
    }
  ],
  "recent": [                                       // learned automatically, max 50
    { "path": "/Users/me/Dev/other", "count": 7, "lastVisited": "2026-10-27T09:12:00Z" }
  ]
}
```

Shortcut strings use Ghostty's spelling: modifiers `cmd`/`command`/`super`,
`shift`, `ctrl`/`control`, `alt`/`opt`/`option`, joined with `+`, plus one key:
a single character, `one`…`nine`, `enter`, `tab`, `space`, `escape`,
`backspace`, `delete`, arrows (`up`, `down`, `left`, `right`), `home`, `end`,
`page_up`, `page_down`, or `f1`…`f20`. Shortcuts become menu key equivalents,
so avoid keys that Ghostty already binds (for example `cmd+1`…`cmd+9`).

## Actions

| Action | What happens |
| --- | --- |
| Go to location (current terminal) | Types `cd '<path>'` into the focused terminal and presses Enter. If no terminal is focused, opens a new window there instead. |
| Open location in new tab / split / window | Creates a surface with `working_directory` set. If `startupCommand` is set it is typed into the new shell followed by Enter. |
| Run command | Types the command (prefixed with `cd '<cwd>' && ` when `cwd` is set) into the focused terminal. With `confirm: true` (default) nothing runs until **you** press Enter; with `confirm: false` Enter is pressed for you. |
| Recent directory | Same as "go to location" for a learned directory. |

Safety rules (see `CONVENTIONS.md`):

- Only text from your own `workspace.json` is ever typed; nothing derived from
  terminal output is executed.
- Paths are single-quoted (`'` becomes `'\''`).
- Text containing control characters, DEL, U+2028/2029 or bidi overrides is
  rejected (with a beep and a log line), never stripped.
- Nothing runs in a hidden subprocess; every command is visible in the
  terminal.

## Where things show up

**Command palette** (`cmd+shift+p` by default) gains:

- `Go to: <name>` with the path as subtitle. Enter `cd`s in the current
  terminal; hold **⌥** (⌥-Enter or ⌥-click) to open a new tab instead. Pinned
  locations also get an explicit `Go to (new tab): <name>` entry.
- `Run: <name>` with the command text as subtitle. Commands that auto-run show
  an `auto-run` badge.
- `Recent: <path>` for the top 8 learned directories (directories that already
  are locations are skipped).

Pinned items are listed first, then by frecency. Shortcuts are shown as key
symbols.

**Workspace menu** (between View/Terminal and Window):

- Pinned locations and commands at the top level, with their key equivalents.
- **Locations**, **Commands** and **Recent** (top 15) submenus.
- Every location and recent item has an **⌥-alternate** ("… in New Tab").
- **Open workspace.json** (default editor via `NSWorkspace`) and
  **Reload Workspace**.

## Frecency

Locations, commands and recent directories are ranked by
`count × weight(age)` where the weight is 4 (used within the hour), 2 (today),
0.5 (this week) or 0.25 (older), the same shape zoxide uses. Pinned items
always sort before unpinned ones.

Recent directories come from `BaseTerminalController.pwdDidChange(to:)` (the
shell's OSC 7 report for the focused surface). A directory is counted when it
stays current for 1.5 s, exists, is not `/`, `/tmp`, `/private/tmp` or a
`/var/folders` scratch path, and was not already counted in the last minute.
The list is capped at 50 entries; the lowest-scoring ones are dropped.

## Tests

`macos/Tests/Features/Workspace/WorkspaceTests.swift` covers JSON round
trips, tolerant parsing, the seed, frecency ordering and cap, shell quoting
and the insert-safety check, `~` expansion and XDG resolution, shortcut
parsing, and the store's disk behaviour (seeding, permissions, invalid-file
handling, usage persistence, reload, the file watcher, and symlink-preserving
atomic writes). Run them with `macos/build.nu --action test`.
