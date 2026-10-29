# Slimer on Windows (Phase 8): porting guide

This is the plan for bringing Slimer to Windows on top of the GhosttyWin32
community host. It was written on macOS without a Windows machine, so
**nothing in it has been built or run on Windows yet**. The PowerShell
integration in `src/shell-integration/powershell/` is untested too (no
PowerShell was available when it was written); see its `README.md`.

Contents:

1. [The base: GhosttyWin32](#1-the-base-ghosttywin32)
2. [Bringing Slimer's core into the host](#2-bringing-slimers-core-into-the-host)
3. [Core gaps to check on Windows](#3-core-gaps-to-check-on-windows)
4. [Shell integration](#4-shell-integration)
5. [Feature-by-feature mapping](#5-feature-by-feature-mapping)
6. [Shell-type indicator](#6-shell-type-indicator)
7. [Order and effort](#7-order-and-effort)

## 1. The base: GhosttyWin32

[`i999rri/GhosttyWin32`](https://github.com/i999rri/GhosttyWin32) (MIT) is a
native Windows host for libghostty: WinUI 3 with C++/WinRT, a DirectX 11
renderer, ConPTY for child processes. The Zig core is the submodule
`external/ghostty`, pinned to the `windows-port` branch of
[`i999rri/ghostty`](https://github.com/i999rri/ghostty). The app links
`ghostty.dll` and reads the C API from `external/ghostty/include`, so the
submodule pin controls header and binary together.

### Toolchain

- Visual Studio 2022 **17.10+** with the workloads *Desktop development with
  C++* and *Universal Windows Platform development*.
- Windows SDK **10.0.22621.0+**.
- Windows App SDK (comes in through the projects' NuGet packages).
- Zig: the host's `windows-port` branch needs **0.16+**, but Slimer's core
  follows upstream `main`, which needs **0.17**. Use 0.17 once Slimer's core
  is in the submodule.
- .NET SDK (installed with Visual Studio) to build
  `SlimerPredictor.dll` for PowerShell autocomplete.
- PowerShell 7.4+ and Pester 5 to run `src/shell-integration/powershell/tests`.

### Build order

MSBuild does not run the Zig build, so after any change in the submodule
repeat step 1.

```
git submodule update --init --recursive        # first clone only
cd external\ghostty
zig build -Doptimize=ReleaseSafe -Drenderer=directx
cd ..\..
msbuild GhosttyWin32.slnx /p:Configuration=Release /p:Platform=x64 /t:App
```

Without `-Drenderer=directx` you get the OpenGL backend, which the host does
not link. Output: `external/ghostty/zig-out/lib/ghostty-internal.dll`
(deployed as `ghostty.dll`), the app in `x64/Release/App/`. When the
parent's submodule pin moves, upstream's BUILD.md says to fetch and check
out the recorded commit in `external/ghostty` instead of running
`git submodule update --init` again (that re-clones and rebuilds from
scratch).

### Signing

The upstream host signs its MSIX with a self-signed certificate (its issue
#46 tracks the lack of a CA signature). For Slimer, use a real code-signing
certificate: an OV/EV certificate on a hardware token, or Azure Trusted
Signing (cheapest for a single developer, works from CI). Sign the MSIX
with `signtool sign /fd SHA256 /tr <timestamp-url> /td SHA256`, and also
sign `ghostty.dll`, `SlimerPredictor.dll` and the app exe. The MSIX
publisher (`CN=…`) must match the certificate subject exactly. Change the
package identity to Slimer's (`top.mayhem.slimer`) so it installs beside
any GhosttyWin32 build.

## 2. Bringing Slimer's core into the host

### What has to move

These are every non-merge commit on `fork` that touches the core
(`git log --reverse --no-merges main..fork -- src include test`):

| Commit | What | Files |
|---|---|---|
| `df205fbdb` | Config keys `quick-terminal-animation`, `-animation-easing`, `-tab-bar` | `src/config/Config.zig` |
| `2aabf8d45` | `ghostty_config_load_arg` (per-surface theme overrides) | `src/config/CApi.zig`, `include/ghostty.h` |
| `7cf009363` | Fig spec license (the converter itself is Node tooling under `tools/`, not needed to build) | `src/autocomplete/data/LICENSE-withfig` |
| `ce269d226` | OSC 7704 parser | `src/terminal/osc.zig`, `osc/parsers.zig`, `osc/parsers/autocomplete_buffer.zig`, `stream.zig`, `stream_terminal.zig`, `include/ghostty/vt/osc.h` |
| `95a0815e1` | Route OSC 7704 to the surface, gate, state | `src/Surface.zig`, `src/apprt/surface.zig`, `src/autocomplete/main.zig`, `src/main_ghostty.zig`, `src/termio/stream_handler.zig` |
| `c8b4bba00` | `GHOSTTY_ACTION_AUTOCOMPLETE_UPDATE`, `ghostty_surface_autocomplete_*` | `src/apprt/action.zig`, `src/apprt/embedded.zig`, `include/ghostty.h`, `src/apprt/gtk/class/application.zig` |
| `db2eb0003` | `autocomplete` config key and shell feature | `src/config/Config.zig`, `src/termio/shell_integration.zig` |
| `c7a06f8eb`, `15e37de98` | zsh capture/accept and its test harness | `src/shell-integration/zsh/ghostty-integration`, `test/slimer/` |
| `3389beb03` | Doc comment fix | `src/config/Config.zig` |
| `9ed24c25f` | `slimer-status-bar` key | `src/config/Config.zig` |
| `2be2c603c` | `ghostty_config_load_arg` color-key allowlist | `src/config/CApi.zig`, `include/ghostty.h` |
| `00ab5b42e` | `ghostty_surface_slimer_idle_prompt` | `src/slimer/prompt.zig`, `src/apprt/embedded.zig`, `include/ghostty.h`, `src/main_ghostty.zig` |
| this branch | PowerShell integration | `src/shell-integration/powershell/` |

Still in progress at the time of writing (land them on `fork` first, then
they come along): the autocomplete engine (`src/autocomplete/{Engine,Spec,
Tokenizer,History,glue}.zig`), the report secret (`n=`), process group
(`p=`) and deactivate (`d=1`) fields, hex-encoded accept payloads and
`CSI 7706 ~` line accept. Every hunk in an upstream file is marked
`// slimer:` (or `# slimer:`), so `git grep -n 'slimer:'` lists them.

### Recommended: merge the Windows port into Slimer, not the other way

Slimer's core follows upstream `main` and uses Zig 0.17 APIs (`std.Io`,
`std.Io.Timestamp`, …). `windows-port` is based on an older upstream (its
minimum is Zig 0.16), so cherry-picking Slimer's commits onto it would
mean back-porting them to older APIs. Bring the Windows port forward
instead:

1. In the Slimer repository:
   ```
   git remote add win https://github.com/i999rri/ghostty.git
   git fetch win windows-port
   git switch -c windows fork
   git merge win/windows-port
   ```
2. Resolve conflicts. Expect them where the port touches the same areas
   as upstream changes since its base: `build.zig`/`src/build/*`, the
   DirectX renderer, `src/termio/Exec.zig` and the Windows pty code,
   `src/apprt/embedded.zig`, `include/ghostty.h`. Keep both sides of
   `include/ghostty.h`: the host compiles against the port's additions and
   Slimer's.
3. Build and test the core on Windows:
   `zig build -Doptimize=ReleaseSafe -Drenderer=directx`, then
   `zig build test -Dtest-filter=7704`, `-Dtest-filter=autocomplete`,
   `-Dtest-filter="setup features"`, `-Dtest-filter=slimer`.
4. Push `windows` to your Slimer remote, fork GhosttyWin32, and point its
   submodule at it:
   ```
   git -C external/ghostty remote set-url origin <your slimer repo>
   git -C external/ghostty fetch origin windows
   git -C external/ghostty checkout <commit>
   git add external/ghostty && git commit
   ```
5. Keep it current: merge `fork` into `windows` whenever `fork` moves, and
   merge new `windows-port` commits when the community port moves.

If the merge turns out much larger than expected, the fallback is the
opposite direction: rebase only the core commits above onto
`windows-port` and fix API differences by hand. The table is the list to
cherry-pick, in that order. The `macos/`, `docs/` and `tools/` commits do
not need to move.

## 3. Core gaps to check on Windows

Things in the core that Slimer relies on and that may not work on Windows
today. Check each one after the merge.

- **OSC 7 is ignored on Windows.** `StreamHandler.reportPwd` in upstream
  `src/termio/stream_handler.zig` logs `reportPwd unimplemented on windows`
  and returns. The port may already handle it; if not, it needs a Windows
  branch: parse `kitty-shell-cwd://host/C:/Users/me` (raw path), check the
  host against the local computer name (`GetComputerNameExW`), turn
  `/C:/…` back into `C:\…`. Without it there is no cwd chip, no git chip,
  no theme `pathPrefix` rules, no recent directories and no "new tab here".
- **ConPTY passthrough.** Child output goes through conhost, which
  re-renders its buffer and historically dropped OSC sequences it did not
  know. Recent ConPTY versions pass most VT through (Windows Terminal relies
  on OSC 133 reaching it), but verify that OSC 133, 7, 7704 and 7706 reach
  the core with the conhost the host uses. If the system conhost strips
  them, ship the newer `conpty.dll` + `OpenConsole.exe` from
  `microsoft/terminal` releases (MIT) next to the app and load
  `CreatePseudoConsole` from it, as Windows Terminal does. Check what the
  host does today (its FEATURES.md notes conhost answers OSC 52 itself,
  issue #226, which shows conhost is in the path).
- **Autocomplete accept trigger.** `ghostty_surface_autocomplete_accept`
  writes `CSI 7705 ~ <payload> BEL`. Under ConPTY that reaches PSReadLine
  as key events, and conhost does not turn an unknown CSI into a key. On
  Windows the core must write `CSI 24 ; 8 ~` (Ctrl+Alt+Shift+F12) for a
  token accept and `CSI 23 ; 8 ~` (Ctrl+Alt+Shift+F11) for a line accept,
  followed by the hex payload and BEL, in one write. A comptime switch on
  `builtin.target.os.tag` in `src/autocomplete/main.zig`
  (`AcceptMode.csi()`) is enough. If ConPTY is put in win32-input-mode
  (`CSI ? 9001 h`), the chord must use that encoding instead. Details and
  tradeoffs: `src/shell-integration/powershell/README.md`.
- **Autocomplete foreground check.** The in-progress accept gate compares
  the report's `p=` with the pty's foreground process group. Windows has no
  process groups. The pwsh module sends `$PID`; on Windows the check
  should instead confirm that the reporting PID is the deepest shell in the
  ConPTY's process tree (see the process walk in section 6), or be
  skipped there with the other gates (token, prompt-input state) kept.
- **Report secret.** The core hands the secret to the shell in
  `SLIMER_AUTOCOMPLETE_TOKEN`. The pwsh module reads it once and removes it
  from its environment. For WSL, the variable only crosses into Linux if
  it is listed in `WSLENV`; leave it out (WSL zsh autocomplete is not
  planned).
- **Shell integration injection.** `src/termio/shell_integration.zig`
  knows bash, zsh, fish, elvish and nushell, not PowerShell, and the
  default Windows command is `cmd.exe`. `GHOSTTY_SHELL_FEATURES` and
  `TERM_PROGRAM=ghostty` are always set, so the module works when imported
  from `$PROFILE`. For automatic injection, add a `pwsh` case (a
  `// slimer:` hunk) that recognises `pwsh`, `pwsh.exe` and
  `powershell.exe` with no `-Command`/`-File`/`-NoExit` of their own, and
  appends
  `-NoExit -Command "Import-Module '<resources>\shell-integration\powershell\slimer.psm1'"`.
  (`-NoExit -Command` runs after the user's profile, so the module wraps
  their prompt.) Alternatively the host's shell profiles do it themselves.
- **Resources.** `src/build/GhosttyResources.zig` installs all of
  `src/shell-integration` except `.md` files, so the PowerShell sources,
  tests and C# project get installed too. Exclude `.cs`, `.csproj` and
  `tests/` there, and add the built `SlimerPredictor.dll` next to
  `slimer.psm1` in the MSIX.
- **Foreground process.** `ghostty_surface_foreground_pid` is
  Unix-only. Windows needs a process-tree walk (section 6); GhosttyWin32
  tracks this as issue #199 (tab titles from the running program).

## 4. Shell integration

| Shell | What exists | Gets |
|---|---|---|
| PowerShell 7 | `src/shell-integration/powershell/slimer.psm1` (untested) | OSC 133 A/B/C/D, OSC 7, title, OSC 7706, autocomplete with `SlimerPredictor.dll` |
| Windows PowerShell 5.1 | same module | marks, OSC 7, title, 7706; no autocomplete |
| WSL bash/zsh | Ghostty's own integration, if the Linux side sources it from the Windows install (`/mnt/c/...`), plus the 7706 snippet in the PowerShell README | marks, OSC 7 (with the Linux host name, see section 6), 7706 with `distro=` |
| cmd.exe | `PROMPT` snippet in the PowerShell README | 7706, A and B only (no C/D: cmd has no command hooks) |
| Git Bash | Ghostty's bash integration sourced from `~/.bashrc`, plus a 7706 line (`shell=bash;os=windows;msystem=$MSYSTEM`) | marks, OSC 7 with `/c/Users/...` paths (the Windows OSC 7 parser must map `/c/` to `C:\`) |

The module's design (why a `PSConsoleHostReadLine` wrapper for C, how D's
exit code is chosen, why autocomplete needs a compiled predictor, how
accept works under ConPTY) is in its README.

## 5. Feature-by-feature mapping

For each feature: the macOS code to read, what carries over unchanged, what
must be rewritten in C++/WinRT, and the GhosttyWin32 gaps it runs into.
"Portable" here means data formats and C APIs, which are shared; all UI is
rewritten.

### 5.1 Drawer (quick terminal) with tabs

- **Read:** `macos/Sources/Features/QuickTerminal/` (`QuickTerminalController.swift`,
  `+Tabs.swift`, `QuickTerminalTabs.swift`, `QuickTerminalTabBar.swift`,
  `QuickTerminalPosition.swift`, `QuickTerminalSize.swift`,
  `QuickTerminalAnimation.swift`, `QuickTerminalScreen.swift`), `DRAWER.md`.
- **Portable:** config keys `quick-terminal-position`, `-size`, `-screen`,
  `-animation`, `-animation-easing`, `-animation-duration`, `-autohide`,
  `-tab-bar`; the `toggle_quick_terminal` action; tab semantics (each tab
  is a split tree, last tab never closes, background tabs unfocused and
  occluded with `ghostty_surface_set_occlusion`).
- **Rewrite:**
  - A borderless, topmost, tool window (`WS_EX_TOOLWINDOW |
    WS_EX_TOPMOST`, no taskbar button) hosting the same XAML terminal
    content as a normal window. Frame from the work area of the chosen
    monitor (`MonitorFromPoint` for `mouse`, `MonitorFromWindow` for the
    main one; `GetMonitorInfo().rcWork`).
  - Slide/fade with composition: animate the root `Visual`'s `Offset` and
    `Opacity` with a `Vector3KeyFrameAnimation` and a
    `CubicBezierEasingFunction` matching the easing key; size the window to
    its final frame first and slide the content, not the window (moving an
    HWND every frame stutters).
  - Autohide on deactivate (`WM_ACTIVATE` / `WindowActivated`), return
    focus to the previous foreground window on hide.
  - Tab strip: a XAML `TabView` (or a custom strip) along the drawer edge.
- **Global hotkey:** GhosttyWin32 never registers `global:` binds. Use
  `RegisterHotKey` (no Accessibility-style prompt on Windows, and unlike a
  low-level keyboard hook it never sees other keystrokes). The host needs
  the list of global triggers: add a small Slimer C API (for example
  `ghostty_config_global_trigger(config, index, out)`) that enumerates
  `global:` keybinds, convert each to `MOD_*` + virtual key, register them
  on the main window, and dispatch `WM_HOTKEY` to the bound action.
  `RegisterHotKey` fails when another app owns the chord; show that in
  Settings. Settings' `GlobalKeybindPlanner.swift` has the conflict logic.
- **GhosttyWin32 gaps:** quick terminal not implemented (#153,
  `TOGGLE_QUICK_TERMINAL` answered but does nothing); `global:` binds never
  fire; inheritance flags ignored (`tab-inherit-working-directory`,
  `split-inherit-working-directory`), so new drawer tabs start in the
  default directory until the host passes the surface kind and
  `working_directory`; splits/new tabs from a WSL pane open the default
  shell (#220).
- **Effort:** 2 to 3 weeks (window + animation 1 week, tabs 1 week, hotkey
  2 to 3 days).

### 5.2 Per-terminal and per-tab theming

- **Read:** `macos/Sources/Features/Theme/` (`SurfaceTheme.swift`,
  `ThemeStore.swift`, `ThemeRuleMatcher.swift`, `GhosttyThemeResolver.swift`,
  `ThemeApplier.swift`, `ThemeController.swift`), `THEMES.md`.
- **Portable:** `themes.json` (same schema, same preset ids, so the file
  syncs between Mac and PC); the rule semantics; the C API path:
  `ghostty_config_clone` → `ghostty_config_load_arg` (color keys only) →
  `ghostty_config_finalize` → `ghostty_surface_update_config`; the
  "reduce named themes to colors" parser and its limits.
- **Rewrite:** store with tolerant parsing and the never-clobber rules
  (`themes.json.broken-<time>`, lossy files kept in memory only), the rule
  matcher (path prefix compared component-wise and case-insensitively on
  Windows, `~` = `%USERPROFILE%`, both `\` and `/`), the resolver's theme
  directories (`%XDG_CONFIG_HOME%\ghostty\themes` or the host's config dir,
  then the app's `share\ghostty\themes`), the per-surface cache, a file
  watcher (`ReadDirectoryChangesW`, 250 ms debounce), pins keyed by surface
  id, the tab context menu.
- **GhosttyWin32 gaps:** no menus at all (no tab, context or app menu), so
  "Theme ▸" and "Tab Accent ▸" need a `MenuFlyout` on the tab and on the
  terminal; tab colors do not exist.
- **Effort:** 1.5 weeks.

### 5.3 Status bar

- **Read:** `macos/Sources/Features/StatusBar/` (`SlimerStatusBar.swift`,
  `SlimerStatusBarModel.swift`, `StatusBarFormatting.swift`,
  `GitPopoverView.swift`, `GitHubRemote.swift`, `SlimerTerminalInput.swift`,
  `SlimerCommandFinished.swift`), `STATUSBAR.md`.
- **Portable:** `slimer-status-bar` config key; the `PWD`, title and
  `COMMAND_FINISHED` actions; `ghostty_surface_slimer_idle_prompt` for
  Run/Insert; `ghostty_surface_binding_action` with `text:` for typing
  commands; the unsafe-text rules and GitHub remote parsing (port the
  tests too).
- **Rewrite:** a 22 px XAML bar per split leaf (in the leaf's layout, so
  the grid shrinks instead of being overlaid), the per-surface model, chip
  formatting (`~` abbreviation becomes `%USERPROFILE%` → `~`), the git
  popover as a `Flyout`. Add the shell-type chip (section 6).
- **GhosttyWin32 gaps:** "nothing in the host writes OSC 133 marks", so
  `COMMAND_FINISHED` never fires today; the PowerShell module fixes that
  once marks pass through ConPTY. OSC 7 needs the core fix in section 3.
- **Effort:** 1.5 to 2 weeks (including the shell chip).

### 5.4 Git service

- **Read:** `macos/Sources/Features/Git/` (`GitProcessRunner.swift`,
  `GitStatusService.swift`, `GitPorcelainParser.swift`,
  `GitOperationDetector.swift`, `GitRepoWatcher.swift`, `GitPathPolicy.swift`,
  `GitActions.swift`), `GIT.md`.
- **Portable:** the `GitRepoState` JSON shape, the porcelain v2 parser
  logic and its test vectors, the operation markers, the debounce and
  coalescing rules, the action list (all mutating commands are typed into
  the terminal, never run by the app).
- **Rewrite, keeping the runner's guarantees:**
  - Locate git from a fixed list, never the user's `PATH`:
    `HKLM\SOFTWARE\GitForWindows\InstallPath` (and `HKCU`), then
    `%ProgramFiles%\Git\cmd\git.exe`, `%LOCALAPPDATA%\Programs\Git\cmd\git.exe`,
    `%USERPROFILE%\scoop\apps\git\current\cmd\git.exe`. Require a regular
    file, not a reparse point into a user-writable directory.
  - `CreateProcessW` with `CREATE_NO_WINDOW` (no console flash),
    `CREATE_UNICODE_ENVIRONMENT`, an explicit environment block built from
    scratch (`PATH` = git's own `cmd` and `mingw64\bin` dirs plus
    `%SystemRoot%\System32`, `HOME`/`USERPROFILE`, `SystemRoot`, `LANG=C`,
    `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`; no `GIT_DIR`,
    `GIT_WORK_TREE`), stdin `NUL`, stdout/stderr pipes read on a worker
    thread, `bInheritHandles` limited with
    `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`.
  - Put each process in a job object with
    `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`; on the 2 s timeout,
    `TerminateJobObject` (Windows has no SIGTERM; the job also kills
    git's children such as `fsmonitor--daemon`).
  - Always pass `-c core.fsmonitor=false` (Git for Windows ships a
    built-in fsmonitor, and a hostile repo's config must not start
    anything), and on Windows also `-c core.useBuiltinFSMonitor=false`
    for older Git for Windows versions.
  - Path policy: skip network drives (`GetDriveTypeW == DRIVE_REMOTE`),
    UNC paths, `%SystemRoot%`, `%ProgramFiles%`, `%APPDATA%`,
    `%LOCALAPPDATA%`, and `\\wsl$\`/`\\wsl.localhost\` (WSL repositories
    are slow over 9P; a later version could run `wsl.exe git` instead).
  - Watch with `ReadDirectoryChangesW` on the git dir (one handle per
    root, overlapped I/O), re-armed the same way as the macOS watcher.
- **Effort:** 1 week.

### 5.5 Workspace (locations, commands, recent directories)

- **Read:** `macos/Sources/Features/Workspace/` (`JSONValue.swift`,
  `WorkspaceModels.swift`, `WorkspaceLocalModels.swift`,
  `WorkspaceStore.swift`, `WorkspacePath.swift`, `WorkspaceShell.swift`,
  `WorkspaceShortcut.swift`, `WorkspaceActions.swift`,
  `WorkspacePaletteOptions.swift`), `WORKSPACE.md` ("Syncing between
  machines" and "Per-machine files").
- **Portable:** the `workspace.json` schema, frecency, the safety rules
  (only text from your own file is typed, Enter only at an idle prompt,
  never clear the input line).
- **Where the files live on Windows:** the synced files (`workspace.json`,
  `themes.json`) in `%XDG_CONFIG_HOME%\slimer\` when `XDG_CONFIG_HOME` is
  set to an absolute path, otherwise `%APPDATA%\slimer\` (roaming, so it
  follows a roaming profile). The per-machine files (`recent.json`,
  `usage.json`) in `%XDG_STATE_HOME%\slimer\` when set to an absolute path,
  otherwise `%LOCALAPPDATA%\Slimer\` (not roaming). Write atomically with
  `ReplaceFileW` (keeps the target's ACL; follow a symlinked file to its
  target first so a dotfiles symlink survives).
- **Sharing `workspace.json` between Mac and PC (decided, implemented on
  macOS):**
  - Lossless round trip: keep unknown keys on the document and on every
    entry, keep a known key's original value when it has the wrong type
    until the field is edited, and keep unusable entries verbatim at their
    array position (never shown). A `version` newer than the build
    understands makes the file read-only. The Windows store must do the
    same, or it will delete what macOS wrote (and vice versa).
  - Paths: `path`/`cwd` is the portable default (`~/Dev/app` works on
    both); optional `paths`/`cwds` objects with `macos`, `windows`,
    `linux` keys override it per OS. Windows resolves `paths.windows`,
    else `path`. An entry with no usable path on the running OS
    (`/Users/...` on Windows, `C:\...` or only `paths.windows` on macOS)
    is **hidden but kept**. Expand `~` to `%USERPROFILE%`; accept drive
    paths (`C:\...`) and `\\wsl$\`/`\\wsl.localhost\` UNC paths as
    absolute. Settings edits only `paths.windows` when it exists, else
    `path`.
  - Recent directories and usage counts are per machine (`recent.json`,
    `usage.json`, keyed by entry id) so the synced file only changes when
    the user edits it. Migrate this machine's entries (drive-letter paths
    on Windows) from a legacy `recent` array once and leave the array in
    `workspace.json` untouched; use legacy `useCount`/`lastUsed` as a seed
    only. Entries without an `id` derive a stable one from their content
    (SHA-256 of the canonical JSON, see `derivedID` in
    `WorkspaceModels.swift`); matching that derivation keeps usage stable
    on both platforms until an id is saved.
  - Shortcuts: the macOS rule "must include `cmd`" has no Windows
    equivalent. Proposal: on Windows `cmd` means `ctrl+alt`, or add an
    optional `shortcutWindows` field.
  - Quoting: commands are typed into whatever shell the tab runs. The
    macOS quoting is POSIX (`cd '<path>'`). On Windows choose by the
    tab's shell type (section 6): PowerShell `Set-Location -LiteralPath
    '<path>'` with `'` doubled; cmd `cd /d "<path>"` (reject `"`, `%`,
    `^`, `&`, `|`, `<`, `>`); WSL/Git Bash POSIX quoting with a converted
    path. When the type is unknown, open a new tab with
    `working_directory` instead of typing.
- **Rewrite:** store, watcher, palette entries (the host has a command
  palette only if the port wired `toggle_command_palette`; otherwise this
  is new UI), a Workspace menu (no menus exist in the host).
- **Effort:** 1 to 1.5 weeks.

### 5.6 Autocomplete popup

- **Read:** `AUTOCOMPLETE.md`, `src/autocomplete/` (engine, shared), the
  macOS popup in `macos/Sources/Features/Autocomplete/` once it lands.
- **Portable:** everything in the core: OSC 7704 parsing and gating, the
  engine, `GHOSTTY_ACTION_AUTOCOMPLETE_UPDATE`,
  `ghostty_surface_autocomplete_buffer/accept/dismiss`. The pwsh side is
  `slimer.psm1` + `SlimerPredictor.dll`.
- **Rewrite:** a popup anchored at `ghostty_surface_ime_point` (a XAML
  `Popup` in the window's visual tree, not a separate HWND, so it moves with
  the window); key interception in the host's key handler before it calls
  `ghostty_surface_key` (Tab, Up/Down, Ctrl+N/P, Esc, Enter when visible).
- **Windows-specific:** the accept trigger and foreground check in
  section 3.
- **Effort:** 2 to 3 weeks for the popup, plus 1 week of pwsh testing and
  fixes.

### 5.7 Settings

- **Read:** `macos/Sources/Features/Settings/` (`Config/GhosttyConfigWriter.swift`,
  `GhosttyConfigFile.swift`, `EffectiveConfigReader.swift`,
  `GlobalKeybindPlanner.swift`, `KeyTrigger.swift`, `SettingsValidators.swift`,
  `Panes/*`), `SETTINGS.md`.
- **Portable:** the managed block format
  (`# >>> slimer managed (edit in Settings) >>>` … `# <<< slimer managed <<<`),
  its rules (replace in place, never touch user lines, refuse to write a
  damaged block, CRLF files get CRLF lines, `font-family = ""` before the
  name), `reload_config` after writing.
- **Rewrite:** a WinUI `NavigationView` with the same panes; the config
  path comes from `ghostty_config_open_path()` in the port; a key recorder
  that produces Ghostty trigger strings for Windows keys (`super` = Win).
- **GhosttyWin32 gaps:** config errors are not reported after a reload
  (the host applies what parsed and says nothing), so the Advanced pane's
  diagnostics need `ghostty_config_diagnostics_count/get` wired.
- **Effort:** 2 weeks.

### 5.8 Claude launcher

- **Read:** `macos/Sources/Features/Claude/` (`ClaudeLauncher.swift`,
  `ClaudeMenu.swift`, `ClaudeProcessDetector.swift`), `CLAUDE-LAUNCHER.md`.
- **Portable:** the behaviour (new tab or split in the surface's
  directory, `--continue`, `--resume`, install hint).
- **Detection on Windows**, by `GetFileAttributesW`, no shell: the native
  installer's `%USERPROFILE%\.local\bin\claude.exe`, then npm's
  `%APPDATA%\npm\claude.cmd`, then each absolute directory of the app's
  own `PATH` (`claude.exe`, then `claude.cmd`).
- **Launching:** `claude.exe` directly as the surface `command`. A
  `.cmd` shim must run through `cmd.exe /d /s /c "..."`; cmd re-parses
  that line, so refuse paths containing `"`, `%`, `^`, `&`, `|`, `<`, `>`
  or `!`, and pass no user text. Prepend the binary's directory to `PATH`
  (npm shims call `node` next to them).
- **Claude glyph:** needs the foreground process (section 6's process
  walk): match `claude.exe`, or `node.exe` whose command line names
  `@anthropic-ai\claude-code` (read with `NtQueryInformationProcess`
  `ProcessCommandLineInformation`, same user only).
- **Effort:** 3 to 4 days.

### 5.9 Packaging and CI

- GitHub Actions `windows-latest`: install Zig 0.17, build the DLL, build
  `SlimerPredictor`, MSBuild the app, run the Zig tests and Pester, sign
  with Azure Trusted Signing, upload the MSIX. Auto-update via
  App Installer (`.appinstaller` file) or winget.
- **Effort:** 3 to 5 days.

## 6. Shell-type indicator

The owner's explicit Windows ask: every tab and status bar shows what it
is running: PowerShell, Windows PowerShell, WSL (with the distro), cmd,
Git Bash.

### Sources, in order of trust

1. **Self-report (OSC 7706).** The integration scripts send
   `ESC ] 7706 ; shell=pwsh ; version=7.4.6 ; edition=Core ; os=windows BEL`
   at load and at every prompt (README in
   `src/shell-integration/powershell/`). It is the only source that sees
   *inside* WSL (`shell=zsh;distro=Ubuntu-24.04`) and nested shells, and it
   is re-sent at each prompt, so exiting a nested shell restores the outer
   one at its next prompt.
2. **Process tree (fallback and cross-check).** The host knows the PID it
   started with `CreatePseudoConsole`. On title change,
   `COMMAND_FINISHED` and OSC 133 C (never on a timer), take a Toolhelp
   snapshot (`CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS)`), walk the
   descendants of that PID, and pick the deepest process whose image is a
   known shell: `pwsh.exe`, `powershell.exe`, `cmd.exe`, `wsl.exe` /
   `wslhost.exe` (→ WSL; distro from its `-d` argument or the default
   distro), `bash.exe` under a `Git\usr\bin` or `Git\bin` directory (→ Git
   Bash), `bash.exe` in `System32` (→ WSL legacy launcher). This also
   gives the "foreground process" for the Claude glyph and tab titles
   (GhosttyWin32 #199).
3. **Launch profile.** The command the tab was started with (the host's
   profile list, or `command` in the config), classified by the same
   image rules. Used before anything else has arrived.

Resolution: show the latest self-report unless the process walk finds a
deeper known shell that started after that report (for example `cmd`
typed inside PowerShell without cmd's PROMPT snippet); then show the walk's
result. With no report, show the walk; with neither, the launch profile.

### Presentation

| Type | Label | Icon | Default accent |
|---|---|---|---|
| PowerShell 7 (`shell=pwsh`, `edition=Core`) | `PowerShell 7.4` | PowerShell chevron | blue `#2671BE` |
| Windows PowerShell (`edition=Desktop`) | `Windows PowerShell 5.1` | PowerShell chevron | navy `#012456` (lightened on dark backgrounds) |
| WSL (`distro=` or `wsl.exe`) | `WSL: Ubuntu-24.04` | Linux/penguin | orange `#E95420` |
| cmd | `cmd` | console | gray `#7A7A7A` |
| Git Bash (`msystem=` or Git's `bash.exe`) | `Git Bash` | git branch | green `#2EA043` |
| unknown / other | image name, e.g. `nu` | generic terminal | none |

- A chip at the left of the status bar (before cwd), icon + label; the
  tooltip shows the full report (shell, version, edition, os, distro).
- The tab shows the icon, and the accent is the tab indicator color.
- **Accent precedence** (extends `THEMES.md`): Tab Color palette choice >
  custom tab accent > theme `accent` > **shell-type accent**. A theme or
  explicit choice always wins; the shell type is the default.
- Offer a Settings switch "Color tabs by shell type" (default on) and let
  the user override each type's color (stored in `themes.json` as an
  optional `"shellAccents": { "pwsh": "#RRGGBB", ... }` map, ignored by
  older readers since unknown keys are skipped).

### Security

OSC 7706 is untrusted: any program can print it. It is only used for
display. Parse at most 256 bytes; accept keys `[a-z]{1,16}` and values
`[A-Za-z0-9._+-]{0,64}`; map `shell` through an allowlist for icon and
color (unknown values get the generic look and their sanitized text);
rate-limit to a few per second per surface. It never chooses how commands
are quoted for typing unless it agrees with the process walk.

## 7. Order and effort

| # | Step | Effort | Depends on |
|---|---|---|---|
| 1 | Merge `windows-port` into Slimer's core, build the host, run core tests | 1 week | — |
| 2 | Core gaps: OSC 7 on Windows, ConPTY passthrough check, pwsh injection | 3 to 5 days | 1 |
| 3 | PowerShell module: run Pester, test by hand, fix | 3 to 5 days | 2 |
| 4 | Status bar + shell-type indicator | 1.5 to 2 weeks | 2, 3 |
| 5 | Git service + popover | 1 week | 4 |
| 6 | Drawer window, animation, tabs, `RegisterHotKey` | 2 to 3 weeks | 1 |
| 7 | Per-terminal themes, tab accents, menus | 1.5 weeks | 4 |
| 8 | Workspace (after deciding the shared-file questions) | 1 to 1.5 weeks | 4 |
| 9 | Claude launcher + process walk reuse | 3 to 4 days | 4 |
| 10 | Autocomplete: Windows accept trigger, predictor, popup | 3 to 4 weeks | 3, engine on `fork` |
| 11 | Settings | 2 weeks | 6, 7, 8 |
| 12 | Signing, MSIX, CI, updates | 3 to 5 days | 1 |

About 14 to 18 weeks for one person, in line with PLAN.md's "2 to 3
months" for the core features, with autocomplete and Settings at the end.
Steps 6 to 9 are independent and can be reordered; do 12 early enough
that every test build is signed.
