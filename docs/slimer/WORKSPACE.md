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
      "startupCommand": "claude",                   // optional; typed into NEW tabs/splits/windows
      "startupConfirm": true,                       // default true: typed, you press Enter
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

Location paths must be absolute after `~` expansion (`~user` is not
expanded); other paths are rejected with a beep.

Shortcut strings use Ghostty's spelling: modifiers `cmd`/`command`/`super`,
`shift`, `ctrl`/`control`, `alt`/`opt`/`option`, joined with `+`, plus one key:
a single character, `one`…`nine`, `enter`, `tab`, `space`, `escape`,
`backspace`, `delete`, arrows (`up`, `down`, `left`, `right`), `home`, `end`,
`page_up`, `page_down`, or `f1`…`f20`. Shortcuts become menu key equivalents
and must follow two rules, otherwise they are ignored (and logged):

- They must include `cmd`, so they can never take a key a terminal program
  expects (ctrl/alt combinations, function keys).
- They must not already be a Ghostty keybinding (checked against libghostty,
  for example `cmd+t` or `cmd+1`…`cmd+9` with the default config). The check
  needs an open terminal and is redone when the config changes.

## Actions

| Action | What happens |
| --- | --- |
| Go to location (current terminal) | Types Ctrl-U, then `cd '<path>'`, and presses Enter in the focused terminal. Opens a **new tab** there instead when the path contains `'` or `\`, or a program other than the shell is running. If no terminal is focused, opens a new window. |
| Open location in new tab / split / window | Creates a surface with `working_directory` set. If `startupCommand` is set it is typed into the new shell; Enter is pressed only with `startupConfirm: false`. |
| Run command | Types Ctrl-U, then the command (prefixed with `cd '<cwd>' && ` when `cwd` is set), into the focused terminal. With `confirm: true` (default) nothing runs until **you** press Enter; with `confirm: false` Enter is pressed for you. If a program other than the shell is running, the text is inserted without Ctrl-U and without Enter. If `cwd` contains `'` or `\`, a new tab is opened in `cwd` instead and the command is typed there. |
| Recent directory | Always opens a **new tab** in that directory (never typed into a shell). |

Safety rules (see `CONVENTIONS.md`):

- Only text from your own `workspace.json` is ever typed; nothing derived from
  terminal output or the shell's reports is typed or executed. Recent
  directories are opened only through `working_directory`.
- Typed paths are single-quoted and must not contain `'` or `\` (fish
  interprets `\'` and `\\` inside single quotes); such paths are opened in a
  new tab via `working_directory` instead.
- Text containing Unicode control (Cc: C0, DEL, C1) or format (Cf: bidi
  controls, LRM/RLM/ALM, zero-width characters, BOM, soft hyphen, tag
  characters) characters, or U+2028/2029, is rejected (with a beep and a log
  line), never stripped.
- **Enter is never pressed into a busy terminal.** If the focused surface has
  a foreground process other than the shell (Ghostty's "confirm quit" check),
  locations open in a new tab and commands are inserted without Enter.
- **Ctrl-U before typing.** At an idle prompt, Slimer sends a single Ctrl-U
  (generated by the app, not taken from your data) before the text, so a
  half-typed line is not merged with the command. In zsh (emacs and vi-insert
  keymaps) Ctrl-U kills the whole line and **Ctrl-Y** brings it back; in bash
  it kills from the cursor to the start of the line (also recoverable with
  Ctrl-Y). Shells that bind Ctrl-U differently will do whatever it is bound to.
- Nothing runs in a hidden subprocess; every command is visible in the
  terminal.

## Where things show up

**Command palette** (`cmd+shift+p` by default) gains:

- `Go to: <name>` with the path (and startup command, if any) as subtitle. Enter `cd`s in the current
  terminal; hold **⌥** (⌥-Enter or ⌥-click) to open a new tab instead. Pinned
  locations also get an explicit `Go to (new tab): <name>` entry.
- `Run: <name>` with the command text as subtitle. When the command does not
  start with its name, the title is `name — command` (truncated to 60
  characters) so a friendly name cannot hide what will be typed. Commands
  that auto-run end in `⏎` and show an `auto-run` badge; locations whose
  startup command auto-runs end in `⏎` too.
- `Recent: <path>` for the top 8 learned directories (directories that already
  are locations are skipped); these open a new tab.

Pinned items are listed first, then by frecency. Shortcuts are shown as key
symbols.

**Workspace menu** (between View/Terminal and Window):

- Pinned locations and commands at the top level, with their key equivalents.
- **Locations**, **Commands** and **Recent** (top 15) submenus.
- Titles follow the same `name — command` / `⏎` rules as the palette;
  tooltips show the path, startup command, or full command.
- Every location has an **⌥-alternate** ("… in New Tab"). With a shortcut,
  the alternate's key is the shortcut plus ⌥, and it is only registered if
  that combination is also free in Ghostty. Recent items always open a new
  tab.
- **Open workspace.json** (default editor via `NSWorkspace`) and
  **Reload Workspace**.

## Frecency

Locations, commands and recent directories are ranked by
`count × weight(age)` where the weight is 4 (used within the hour), 2 (today),
0.5 (this week) or 0.25 (older), the same shape zoxide uses. Pinned items
always sort before unpinned ones.

Recent directories come from `BaseTerminalController.pwdDidChange(to:)` (the
shell's OSC 7 report for the focused surface), and only from the key window.
These reports are untrusted, so at learning time a path must be absolute, at
most 1024 bytes, pass the same control/format-character check as typed text,
and not be `/`, a scratch path (`/tmp`, `/private/tmp`, `/var/folders`), or on
a network or removable volume (`/net`, `/Network`, `/Volumes`). It is counted
when it stays current for 1.5 s and exists; the existence check runs off the
main thread. Using a location counts as a visit, and the shell's report right
after it is not counted again; a directory is counted at most once a minute.
The list is capped at 50 entries; the lowest-scoring ones are dropped, never
the directory that was just visited.

## Saving

Before every write Slimer re-reads `workspace.json`. If it changed on disk
since Slimer last read or wrote it (an edit the file watcher has not delivered
yet), the disk version is loaded first and the usage update is re-applied on
top, so hand edits and synced changes are not overwritten.

When the app runs as an XCTest host it uses a throwaway file in the temporary
directory and does not watch it, so running tests never touches your real
`workspace.json`.

## Tests

`macos/Tests/Features/Workspace/WorkspaceTests.swift` covers JSON round
trips, tolerant parsing, the seed, frecency ordering and cap, shell quoting
and the insert-safety check, `~` expansion and XDG resolution, shortcut
parsing, and the store's disk behaviour (seeding, permissions, invalid-file
handling, usage persistence, reload, the file watcher, and symlink-preserving
atomic writes). Run them with `macos/build.nu --action test`.
