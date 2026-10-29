# Status bar (Phase 4B)

A thin (22pt) bar attached to every terminal surface (each split leaf, in normal
windows and the drawer). Code: `macos/Sources/Features/StatusBar/`, tests:
`macos/Tests/Features/StatusBar/`. Git data comes from the Phase 4A service
(`docs/slimer/GIT.md`).

## Config

`slimer-status-bar = bottom | top | hidden` (default `bottom`), reloadable at
runtime. Swift reads it through `Ghostty.Config.slimerStatusBar`
(`Ghostty.Config+StatusBar.swift`).

## Layout

Left to right: cwd chip, `user@host` chip, git chip, last-command chip; right side:
Claude glyph (when Claude is the foreground process) and the Claude button.

- **cwd:** OSC 7 pwd, `~`-abbreviated, deep paths shortened to `~/…/a/b/c`. Click:
  Copy Path, Open in Finder, Open in New Tab.
- **user@host:** shown only when the surface title starts with `user@host`
  (optionally followed by `:` or a space). Titles are untrusted and only displayed.
- **git:** branch (or short SHA when detached), `+staged ~unstaged ?untracked
  !conflicted ⇡ahead ⇣behind`, stash count, and an orange MERGING / REBASING /
  CHERRY-PICKING / REVERTING / BISECTING badge. Hidden outside a repository.
- **last command:** `✓ 1.2s`, `✗ 1 3.4s`, or `• 3.4s` when no exit code was reported.

## Hooks into upstream files

| File | Hunk |
| --- | --- |
| `Features/Splits/TerminalSplitTreeView.swift` | 1 line: `.slimerStatusBar(surfaceView)` on `TerminalSplitLeaf`'s `InspectableSurface`. |
| `Ghostty/Ghostty.App.swift` | 1 line in `commandFinished`: `SlimerCommandFinished.post(...)`. |
| `App/AppDelegate.swift` | 1 line: `SlimerClaudeMenu.install()` (see `CLAUDE.md`). |
| `src/config/Config.zig` | `slimer-status-bar` key and `SlimerStatusBar` enum. |

The modifier wraps the leaf in a `VStack`, so the bar takes layout space and the
terminal grid shrinks once by 22pt; it never overlays cells.

## Data flow

`SlimerStatusBarModel` (one per surface, stored as an associated object so it
survives split-tree rebuilds) is the only thing the bar observes. The
`SurfaceView` publishes on mouse movement and cursor changes, so the bar never
observes it directly. Inputs:

- `$pwd` (de-duplicated): updates the cwd chip and moves the single git
  subscription (`GitStatusService.observe(directory:)`) to the new directory.
  Git states are compared without `updatedAt`, so an unchanged repository never
  re-renders.
- `$title` (de-duplicated, throttled to 1/s): updates `user@host` and re-checks
  whether Claude is the foreground process.
- `SlimerCommandFinished` notification: Ghostty's `COMMAND_FINISHED` action
  (OSC 133 D via shell integration) reaches Swift in `Ghostty.App.commandFinished`,
  which upstream only uses for `notify-on-command-finish`. The slimer line posts
  every surface event first. The model stores it and calls
  `GitStatusService.refresh(directory:)`.

No timers poll anything.

## Git popover

Click the git chip. Sections: actions (`GitActions.available(for:)` plus "New
branch…"), a filterable branch list (local, then remote branches without a local
twin; the current branch is checked), and links.

Choosing an action or branch never runs anything. It shows the exact command line
and three buttons:

- **Insert** (Return): types the command.
- **Run**: types the command and presses Enter. Disabled while the surface has a
  foreground process (`needsConfirmQuit`).
- **Cancel** (Esc).

Insertion uses `ghostty_surface_binding_action` with `text:`. The parameter is a
Zig string literal body (`src/config/string.zig`), so backslashes are doubled and
nothing else needs escaping. At an idle prompt the text is prefixed with Ctrl-U
(`\x15`) to clear the line; with a foreground process there is no Ctrl-U and never
Enter (`SlimerTerminalInput.plan`). Commands with control characters, DEL,
U+2028/2029 or bidi controls are rejected.

Links:

- **Copy Branch Name**.
- **Open on GitHub / Open Pull Request**: only when `origin` is a github.com
  remote (`https://github.com/o/r`, `ssh://git@github.com/o/r`,
  `git@github.com:o/r`; everything else is rejected). The URL comes from a
  read-only `git remote get-url origin` through the service's restricted runner.
  The PR link is `https://github.com/<owner>/<repo>/pull/new/<branch>` with the
  branch percent-encoded. Only `https://github.com` URLs are opened.

The popover adds two read-only git invocations to those listed in `GIT.md`:
`for-each-ref --format=%(refname) refs/heads refs/remotes` and
`remote get-url origin`.
