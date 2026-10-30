# Status bar (Phase 4B)

A thin bar (26pt at the default text size) attached to every terminal surface (each split leaf, in normal
windows and the drawer). Code: `macos/Sources/Features/StatusBar/`, tests:
`macos/Tests/Features/StatusBar/`. Git data comes from the Phase 4A service
(`docs/slimer/GIT.md`).

## Config

`slimer-status-bar-font-size` (default 13, clamped to 9–24; also in Settings ▸ Appearance and Git & Status Bar) sets the text size, and the bar's height follows it. The branch name is drawn in the primary text color, semibold, so it stands out from the dimmer chips.

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
| `Ghostty/Ghostty.App.swift` | 1 line in `commandFinished`: `SlimerCommandFinished.post(...)`; 1 line in `initialSize`: add the bar height so `window-height` rows are kept. |
| `src/apprt/embedded.zig`, `include/ghostty.h` | `ghostty_surface_slimer_idle_prompt` (logic in `src/slimer/prompt.zig`, tests imported from `src/main_ghostty.zig`). |
| `App/AppDelegate.swift` | 1 line: `SlimerClaudeMenu.install()` (see `CLAUDE-LAUNCHER.md`). |
| `src/config/Config.zig` | `slimer-status-bar` key and `SlimerStatusBar` enum. |

The modifier wraps the leaf in a `VStack`, so the bar takes layout space and the
terminal grid shrinks once by the bar height (twice `slimer-status-bar-font-size`); it never overlays cells. Leaves shorter than
three bar heights hide the bar. Setting `slimer-status-bar = hidden` at runtime
also frees each surface's model (and its git subscription). The bar's background
follows the surface's own background (runtime OSC 11 color, else its config), so
per-tab themes match.

## Data flow

`SlimerStatusBarModel` (one per surface, stored as an associated object so it
survives split-tree rebuilds) is the only thing the bar observes. The surface
retains the model, so no model subscription may retain the surface:
`NotificationCenter.publisher(for:object:)` is not used (it holds `object`
strongly); notifications are filtered against a weak owner instead
(`SlimerStatusBarModelTests` checks the surface deallocates). The
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
- **Run**: types the command and presses Enter.
- **Cancel** (Esc).

Both depend on `ghostty_surface_slimer_idle_prompt` (`src/slimer/prompt.zig`),
which is true only when the child is alive, the surface is not read-only, OSC 133
shell integration shows the cursor in a primary prompt's input area (not a PS2
continuation), and no input text is on the prompt rows. When it is false, Run is
disabled with a tooltip explaining why, and Insert becomes **Insert Anyway**, an
explicit confirmation that types the command after whatever is there (never with
Enter). The state is re-checked on click; if it changed, nothing is typed and the
popover says so. Nothing ever clears the user's input line (no Ctrl-U).

Insertion uses `ghostty_surface_binding_action` with `text:`. The parameter is a
Zig string literal body (`src/config/string.zig`), so backslashes are doubled and
nothing else needs escaping. Commands containing characters rejected by
`SlimerUnsafeText` (Unicode Cc, Cf including bidi controls, Zl, Zp) are refused,
and the popover shows an error instead of closing. Branch names with `'` or `\`
are rejected by `GitShellQuoting` (fish interprets them inside single quotes).
Branch names are shown with unsafe characters replaced by U+FFFD, and "Copy
Branch Name" is offered only for safe names.

Links:

- **Copy Branch Name**.
- **Open on GitHub / Open Pull Request**: only when `origin` is a github.com
  remote (`https://github.com/o/r`, `ssh://git@github.com/o/r`,
  `git@github.com:o/r`; everything else is rejected). The URL comes from a
  read-only `git remote get-url origin` through the service's restricted runner.
  The PR link is `https://github.com/<owner>/<repo>/pull/new/<branch>` with the
  branch percent-encoded. Only `https://github.com` URLs are opened.

The popover adds three read-only git invocations to those listed in `GIT.md`:
`for-each-ref --format=%(refname) refs/heads refs/remotes`, `remote` (remote
names, so remotes containing `/` are stripped correctly from remote branch
names) and `remote get-url origin`.
