# Claude Code launcher (Phase 5)

Code: `macos/Sources/Features/Claude/`, tests: `macos/Tests/Features/Claude/`.

## Detection

`ClaudeLauncher.binary` stats, in order (no shell, no subprocess):
`~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`,
`~/.claude/local/claude`, then `<dir>/claude` for each absolute entry of the app's own
`PATH`. The first executable regular file wins (symlinks are followed but the
unresolved path is kept, so versioned installs keep working after updates). A
found binary is cached until a launch finds the file gone (each launch re-checks it);
a miss is cached for 30 s, so menus built from the cache cost no `stat` calls. A
binary path containing `'`, `\` or control characters is never launched.

## Launching

New surfaces are created through Ghostty's own `ghosttyNewTab` / `ghosttyNewSplit`
notifications, so normal windows (`TerminalController.newTab`) and the drawer
(`QuickTerminalController`) both work. The base config is the surface's inherited
config plus:

- `workingDirectory` = the surface's pwd,
- `command` = the shell-quoted absolute binary path, plus `--continue` or `--resume`,
- `PATH` with the binary's directory prepended (npm installs are
  `#!/usr/bin/env node` scripts and node usually sits next to them).

Closing Claude closes its tab (Ghostty's normal `command` behavior).

## UI

- **Status bar button:** click = new tab, Option-click = split right (swapped when
  Settings ▸ Claude sets the default open mode to "Split to the right"; stored in
  `UserDefaults` as `SlimerClaudeDefaultPlacement`). The chevron
  menu offers Claude Here (New Tab), Claude Here (Split Right), Continue Last
  (`claude --continue`), Resume… (`claude --resume`). When Claude is not installed
  the menu shows a disabled "Claude Code Not Installed" item and "Install Claude
  Code…", which opens `https://claude.com/claude-code`.
- **File > Claude** submenu: the same actions for the focused surface of the key
  window, rebuilt each time it opens. Installed by one `// slimer:` line in
  `AppDelegate.applicationDidFinishLaunching`.

## Claude tab glyph

When the surface title changes (throttled to once a second, never on a timer), the
status bar model reads `ghostty_surface_foreground_pid`, then `proc_pidpath`. It
matches when the executable is named `claude`, lives under `…/claude/versions/`, or
is `node`/`bun` whose first script argument is named `claude` or is inside
`@anthropic-ai/claude-code/` (read with one `KERN_PROCARGS2` sysctl). A small orange
sparkle then shows in that surface's status bar.
