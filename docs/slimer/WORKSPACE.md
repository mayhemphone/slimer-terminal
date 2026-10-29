# Workspace: locations, saved commands and recent directories

The Workspace feature gives you fast access to the directories you live in and
the commands you run all day, from the command palette, a top-level
**Workspace** menu with per-item keyboard shortcuts, and pins. It also learns
the directories you visit from the shell's working-directory reports.

Your locations and commands are stored in one JSON file so it can be synced
between machines (dotfiles repo, cloud folder), including a Windows PC:

```
$XDG_CONFIG_HOME/slimer/workspace.json      (if XDG_CONFIG_HOME is an absolute path)
~/.config/slimer/workspace.json             (otherwise)
```

What a machine learns by itself (recent directories, usage counts) is kept
next to it in per-machine files that are **not** meant to be synced (see
[Per-machine files](#per-machine-files)).

Code lives in `macos/Sources/Features/Workspace/`.

## The file

- Created on first launch with a few example locations and commands.
- Written atomically (temp file + rename) with mode `0600`; the directory is
  `0700`. Symlinks are followed, so a symlinked `workspace.json` keeps pointing
  at your dotfiles repo.
- Reloaded automatically when it changes on disk (editor save, sync tool).
  **Workspace > Reload Workspace** forces a reload.
- Reading and writing are **lossless** (see [Syncing](#syncing-between-machines)):
  unknown keys and entries Slimer can't use are kept and written back.
  Missing fields take defaults. If the whole file fails to parse, Slimer
  keeps running with an empty workspace, logs the error, shows a disabled
  "workspace.json could not be read" item in the menu, and **never overwrites
  the file** until it parses again.
- Slimer only rewrites the file (pretty printed, sorted keys) when you edit
  locations or commands in Settings, or to create it on first run. Using a
  location or command, or visiting a directory, never touches it.

### Schema

```jsonc
{
  "version": 1,
  "locations": [
    {
      "id": "6C0B5D54-7E2B-4B5B-9F6B-6A7B6B9C4E11", // UUID; generated if missing
      "name": "league-view-backend",               // defaults to the last path component
      "path": "~/Dev/league-view-backend",         // portable path; "~" is expanded
      "paths": {                                    // optional per-OS overrides
        "macos": "~/Dev/league-view-backend",
        "windows": "C:\\Users\\zach\\dev\\league-view-backend",
        "linux": "~/dev/league-view-backend"
      },
      "icon": "server.rack",                        // optional SF Symbol name
      "color": "#FF8800",                           // optional #RRGGBB
      "pinned": true,                               // default false
      "shortcut": "cmd+shift+3",                    // optional, Ghostty style
      "startupCommand": "claude",                   // optional; typed into NEW tabs/splits/windows
      "startupConfirm": true                        // default true: typed, you press Enter
    }
  ],
  "commands": [
    {
      "id": "0F0E4A2E-0B3F-4D3F-8C6B-2A4C9B1D7E22",
      "name": "Claude (continue)",                  // defaults to the command text
      "command": "claude --continue",               // required
      "cwd": "~/Dev/league-view-backend",           // optional; prepends `cd '<cwd>' && `
      "cwds": { "windows": "C:\\Users\\zach\\dev" },  // optional per-OS overrides of cwd
      "pinned": true,
      "shortcut": "cmd+shift+c",
      "confirm": true                               // default true, see below
    }
  ]
}
```

A location needs `path` or at least one `paths` value; a command needs
`command`. Each entry needs an `id` (a UUID) so this machine's usage
statistics can refer to it; Slimer adds one when it next saves the file
(until then an id is derived from the entry's content, so it is stable).

**Per-OS paths.** On macOS a location uses `paths.macos` if it is set,
otherwise `path` (and a command uses `cwds.macos`, otherwise `cwd`). Keep
`path`/`cwd` as the portable default (`~/Dev/app` works everywhere) and add
`paths`/`cwds` only where an OS needs something else, such as
`C:\Users\zach\dev\app` or `\\wsl$\Ubuntu\home\zach\dev\app` on Windows.
The path must be absolute after `~` expansion (`~user` is not expanded).
Entries with no usable path on this OS (only `paths.windows`, or a `path`
like `C:\...`) and commands whose only directory is for another OS are
**hidden** on this machine: not in the menu, palette or Settings lists, but
kept in the file.

Files written by older versions may contain `useCount`/`lastUsed` on
entries and a top-level `recent` array. They are kept as they are (never
rewritten or removed); see [Per-machine files](#per-machine-files).

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
| Go to location (current terminal) | Types `cd '<path>'` and presses Enter in the focused terminal, but only when its shell sits at an empty prompt (see below). Otherwise, or when the path contains `'` or `\`, it opens a **new tab** there instead. If no terminal is focused, opens a new window. |
| Open location in new tab / split / window | Creates a surface with `working_directory` set. If `startupCommand` is set it is typed into the new shell; Enter is pressed only with `startupConfirm: false`. |
| Run command | Types the command (prefixed with `cd '<cwd>' && ` when `cwd` is set) into the focused terminal. With `confirm: true` (default) nothing runs until **you** press Enter; with `confirm: false` Enter is pressed for you, but only at an empty prompt. Otherwise the text is inserted without Enter, after whatever is already typed. If `cwd` contains `'` or `\`, a new tab is opened in `cwd` instead and the command is typed there. |
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
- **Enter only at an empty prompt.** Slimer presses Enter for you only when
  `ghostty_surface_slimer_idle_prompt` says the shell is at an empty primary
  prompt: shell integration (OSC 133) is active, the cursor is in the prompt's
  input area, it is not a continuation (PS2) prompt, and nothing is typed yet.
  Without shell integration this is never true, so commands are only inserted
  and "go to here" opens a new tab.
- **Your input line is never cleared.** Slimer sends no Ctrl-U or other
  line-kill key (they differ between shells and keymaps, and leftover text
  would be executed). Inserted text goes after whatever you had typed.
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
symbols. Only entries usable on this OS are listed.

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

## Per-machine files

Recent directories and usage statistics are specific to one machine (they
would mix `/Users/...` with `C:\...` and change on every use, causing sync
conflicts), so they live outside the synced file:

```
$XDG_STATE_HOME/slimer/                     (if XDG_STATE_HOME is an absolute path)
~/Library/Application Support/Slimer/      (otherwise)
  recent.json   {"version": 1, "recent": [{"path": "/Users/me/Dev/other", "count": 7, "lastVisited": "2026-10-27T09:12:00Z"}]}
  usage.json    {"version": 1, "usage": {"<entry id>": {"useCount": 12, "lastUsed": "2026-10-28T14:03:11Z"}}}
```

Both are written atomically with mode `0600` (directory `0700`), like
`workspace.json`. They are a cache: an unreadable one is logged and
replaced. **Settings > Workspace > Recent > Clear Recent** empties
`recent.json`.

- **Migration.** The first time Slimer runs without a `recent.json` and
  `workspace.json` has a `recent` array (written by an older version), it
  copies this machine's entries (absolute `/...` paths that pass the
  learning rules above) into `recent.json`. The `recent` array stays in
  `workspace.json` untouched, because it may hold other machines' entries.
- **Usage seed.** `useCount`/`lastUsed` left on an entry by an older version
  are used until the entry is first used on this machine; from then on
  `usage.json` counts (starting from that seed). They are never rewritten.

## Syncing between machines

`workspace.json` can be shared by several Macs and PCs (the Windows port
will use the same schema, see `WINDOWS.md`):

- **Lossless.** Keys Slimer doesn't know (on the document or any entry, for
  example from a newer Slimer or the Windows build) are written back
  unchanged. A known key whose value has the wrong type (`"pinned": "yes"`)
  takes its default in memory and its original value is written back until
  you change that field in Settings. An entry that can't be used at all (not
  an object, no path, no command) is never shown but stays in its position
  in the array. Slimer logs how many such entries it kept each time it reads
  a changed file. JSON formatting is not preserved (files are written pretty
  printed with sorted keys) and `1.0` may be written as `1`.
- **Newer files are read-only.** If `version` is greater than what this
  Slimer understands (currently `1`), its entries are shown but the file is
  never written: Settings disables editing, as for an unreadable file. Usage
  and recent directories still go to the per-machine files.
- **Writes only on edits.** Only editing locations or commands rewrites the
  file, so syncing it causes no churn.
- **Settings edits this OS's path.** The location editor's Path field edits
  `paths.macos` when the location has one, otherwise `path` (the command
  editor's "Run in" field does the same for `cwds.macos`/`cwd`). Other OS
  values are never changed from a Mac.

## Saving

Before every write Slimer re-reads `workspace.json`. If it changed on disk
since Slimer last read or wrote it (an edit the file watcher has not delivered
yet), the disk version is loaded first and the edit is re-applied on top, so
hand edits and synced changes are not overwritten.

When the app runs as an XCTest host it uses a throwaway `workspace.json` and
per-machine directory in the temporary directory and does not watch them, so
running tests never touches your real files.

## Tests

`macos/Tests/Features/Workspace/WorkspaceTests.swift` covers JSON round
trips, tolerant parsing, the seed, frecency ordering and cap, shell quoting
and the insert-safety check, `~` expansion and XDG resolution, shortcut
parsing, and the store's disk behaviour (seeding, permissions, invalid-file
handling, usage persistence, reload, the file watcher, and symlink-preserving
atomic writes). `WorkspaceSyncModelTests` and the sync tests in
`WorkspaceStoreTests` cover the lossless round trip (unknown keys, unusable
entries in position), newer-version read-only mode, per-OS path resolution
and hiding, the `recent` migration, local usage statistics, and Settings
edits of `paths.macos`. Run them with `macos/build.nu --action test`.
