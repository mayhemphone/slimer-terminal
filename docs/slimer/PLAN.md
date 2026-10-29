# Slimer: custom Ghostty fork plan

## Context

**Name:** Slimer. App "Slimer", bundle id `top.mayhem.slimer` (adjust if you prefer), config dir `~/.config/slimer/`, repo `<you>/slimer`. Env vars and OSC names keep the `GHOSTTY_` prefix where upstream shell integration depends on them; our additions use `SLIMER_`.

**Shells in scope:** zsh on macOS (first-class), PowerShell 7 on Windows (Phase 8). bash/fish get upstream behavior only.

You want to replace Warp with a fast, secure, native terminal that keeps the few things Warp does well (labels, clickable branch, autocomplete) and adds iTerm2-style slide-out terminals, per-tab theming, a locations/commands system, UI-based git, and easy Claude launching. Targets: two Macs now, one Windows PC later.

Decisions already made (from our Q&A):
- **macOS first; Windows is phase 2** built on the GhosttyWin32 community host, not a port of the Swift app.
- **Warp-style native autocomplete popup** is in scope (largest single feature).
- **Git = status bar + actions popover**, not a full GUI client.
- **Paid Apple Developer account exists** → Developer ID signing, notarization, Sparkle updates.

### What upstream already gives us (verified against `main`, Oct 2026, v1.4.0)

| Need | Upstream status | Our work |
|---|---|---|
| Slide-out terminal from the right | `quick-terminal-position = right`, `quick-terminal-size`, `quick-terminal-animation-duration`, `quick-terminal-screen`, autohide | Add tabs inside it (currently alerts "Tabs aren't supported in the Quick Terminal"), vertical stacking preset, easing/animation options |
| System-wide hotkeys | `keybind = global:...` via CGEventTap + Accessibility permission (`GlobalEventTap.swift`) | Expose in Settings UI; add per-action global binds for drawer, new window, palette, locations |
| Normal windows via Cmd+N | `new_window`, native AppKit tabs (`TerminalController.swift`) | Nothing |
| Splits/tabs | Full `SplitTree` support | Nothing core; theming hooks |
| Tab colors | `TerminalTabColor` enum (10 fixed macOS system colors, context menu only) | Replace with full per-tab/per-terminal theme (any color, background/accent/titlebar tint), persisted, scriptable |
| Command palette | `toggle_command_palette`, `command-palette-entry` config | Extend with Locations, Saved Commands, Git actions, Claude |
| Shell integration | zsh/bash/fish/nushell/elvish; OSC 133 prompt marks, OSC 7 cwd | Extend to stream the live command line (for autocomplete) and git state |
| Settings UI | `SettingsView.swift` is a "Coming Soon" placeholder | Build a real SwiftUI settings window for our features |
| Windows | None upstream (port on hiatus, discussion locked Oct 10 2026); only libghostty-vt builds on Windows | Phase 2 on GhosttyWin32 |

### Toolchain facts
- Zig **0.17** required for `main`; Xcode 26+ and macOS 26 SDK (you're on macOS 27, so install current Xcode). Zig is not installed on this Mac yet.
- Build: `zig build -Demit-macos-app=false` (produces GhosttyKit), then `macos/build.nu --configuration Release` (xcodebuild wrapper, output `macos/build/Release/Ghostty.app`). Swift-only changes don't need the zig step.
- Repo layout: `src/` Zig core (`src/terminal/osc.zig`, `src/Surface.zig`, `src/config/Config.zig`, `src/apprt/embedded.zig`, `src/shell-integration/`), `include/ghostty.h` C API, `macos/Sources/{App,Features,Ghostty,Helpers}` Swift app.
- Adding a config key end-to-end: `src/config/Config.zig` → (if the app needs it) `include/ghostty.h` type → `macos/Sources/Ghostty/Ghostty.Config.swift` getter (guard + `ghostty_config_get` + default).

## Architecture principles

1. **Fork, don't rewrite.** Track upstream `main` on a `main` branch; all our work on `fork/*` branches merged into a long-lived `fork` branch. Rebase/merge upstream weekly. Keep diffs to upstream files minimal; put new code in new files/folders (`macos/Sources/Features/<Ours>/`, `src/fork/`) so merges stay cheap.
2. **Put portable logic in the Zig core or a portable helper, UI in Swift.** Anything the Windows shell will also need (git state model, locations/commands model, autocomplete engine, custom OSC parsing) must not live only in Swift.
3. **Our config lives beside Ghostty's, not inside it.** Ghostty's `config` file stays authoritative for Ghostty keys. Our data (locations, saved commands, per-tab themes, pins) lives in `~/.config/slimer/workspace.json` (dotfile-syncable across your machines) and is edited by the Settings UI. Ghostty keys we need are added as real Ghostty config keys so `+show-config` and reload keep working.
4. **Security defaults:** never auto-execute anything derived from terminal output or shell-reported state; everything inserts text or runs visibly in the terminal. Shell→app channels (new OSCs) are length-capped and sanitized. Generators for autocomplete run only from an allowlist with timeouts. Signed, notarized, hardened-runtime builds; Sparkle with EdDSA keys.
5. **Speed budget:** no feature may add work to the render/IO path. Everything we add runs on the main thread in response to events or on background queues; UI updates coalesced. Measure startup and keystroke latency before/after each phase.

## Phase 0: Fork, build, sign, release pipeline (foundation)

- Fork `ghostty-org/ghostty` to your GitHub as `slimer`; clone to `~/Dev/slimer`. Branches: `main` (upstream mirror), `fork` (ours).
- Install Zig 0.17 and Xcode 26+. Build Debug once unmodified to verify the toolchain.
- Rebrand to Slimer: bundle id, app name, green-ghost icon (`macos/Ghostty-Info.plist`, `Assets.xcassets`, `macos-icon` options), so it installs beside stock Ghostty. Keep `TERM=xterm-ghostty` and the terminfo name so remote hosts and shell integration keep working.
- CI (GitHub Actions, macOS runner): `zig build` → `build.nu --configuration Release` → Developer ID sign + notarize + staple → DMG + Sparkle appcast. Secrets: signing cert, notary API key, Sparkle private key.
- Entitlements: keep upstream `Ghostty.entitlements`; global hotkeys need Accessibility (already prompted by `GlobalEventTap`).
- Deliverable: signed, auto-updating app on both Macs with zero feature changes.

## Phase 1: Drawer (slide-out) terminal with tabs and stacking

Files: `macos/Sources/Features/QuickTerminal/*` (`QuickTerminalController.swift` subclasses `BaseTerminalController`; `QuickTerminalPosition.swift` computes frames; `animateWindowIn/Out` use `NSAnimationContext` with `.easeIn`).

- **Tabs in the drawer.** Replace `showNoNewTabAlert()` with a custom tab strip (SwiftUI, vertical or horizontal, configurable) because the drawer window is a borderless `.popUpMenu`/`.floating` panel and can't use native AppKit tabs. Each tab owns a `SplitTree<Ghostty.SurfaceView>`; the controller holds `[DrawerTab]` and swaps the visible tree. Reuse `BaseTerminalController` split/focus/undo logic as-is.
- **Vertical stacking preset.** "New stacked terminal" = `new_split:down` in the drawer plus an "equalize" and a one-key "focus next stack" binding. Add config `quick-terminal-stack-direction = vertical|horizontal` and a Settings toggle. (Splits already set `GHOSTTY_QUICK_TERMINAL=1`.)
- **Animation options.** New config keys `quick-terminal-animation = slide|fade|none`, `quick-terminal-animation-easing = ease-in|ease-out|ease-in-out|spring`; implement in `animateWindowIn/Out`. Keep upstream duration key.
- **Where it lives.** Already configurable (`quick-terminal-position`, `-size`, `-screen`). Expose all in Settings UI with a live preview; fix the "requires restart" for position by tearing down and recreating the controller on reload.
- **Hotkeys.** Defaults: `global:cmd+backquote=toggle_quick_terminal`, `global:cmd+shift+n=new_window` (normal window from anywhere), `cmd+t` in drawer = new drawer tab. All editable in Settings.
- Verify: toggle from any app, stacking 3 terminals, position change without restart, Cmd+N still makes a normal window.

## Phase 2: Per-terminal / per-tab theming

- Model: `SurfaceTheme { background, foreground, accent (tab/titlebar tint), optional full Ghostty theme name }` stored per surface and per tab in `workspace.json`, keyed by a stable id, plus rules (match by cwd prefix, by hostname, by shell/command) so e.g. `~/Dev/league-view-backend` is always green.
- Apply per surface via `ghostty_surface_update_config` with a cloned config (`ghostty_config_clone` + overrides) so renderer colors change without affecting other surfaces. Confirm in `Ghostty.Surface.swift` that per-surface config updates re-derive colors; if not, add a core action.
- Replace `TerminalTabColor` (10 fixed cases) with arbitrary `NSColor` + the rule engine; extend the existing tab context menu and `TerminalWindow.syncAppearance`. Titlebar/tab-bar tint for the normal window styles (`Window Styles/`), and tab-strip tint in the drawer.
- UI: right-click tab → color picker + "Always use for this folder". Settings → Themes → rules table.
- Verify: two tabs with different backgrounds side by side; rule auto-applies on `cd` (via existing PWD action); persists across restart.

## Phase 3: Locations and saved commands (workspace system)

- Data (`workspace.json`): `locations: [{id, name, path, icon, color, pinned, shortcut, startupCommand?, env?}]`, `commands: [{id, name, command, cwd?, pinned, shortcut, confirm: bool}]`, usage counts for frequency ranking.
- Surfaces: (a) command palette sections "Go to…" and "Run…" (extend `TerminalCommandPaletteView.commandOptions` with new option groups); (b) a Locations popover/sidebar in the drawer and normal windows; (c) pinned items in a thin top bar (see Phase 4 bar); (d) hotkeys per item (`cmd+1..9` style, configurable).
- Actions: "open here" (`text:` action to send `cd <quoted path>\n`), "open in new tab/split/window/drawer tab" (new surface with `working_directory` set in `ghostty_surface_config_s`), "run command" (inserts text; executes only if `confirm == false` and the command came from the user's own file, never from terminal output).
- Frequency: learn visited dirs from OSC 7 PWD events (already surfaced as `PWD` action) into a local SQLite/JSON frecency list; suggest "add to locations".
- Settings UI: CRUD tables for locations and commands with drag-reorder, pin, shortcut recorder. Import your current list (`~`, `~/Dev`, `~/Dev/league-view-backend`, …).
- Verify: `cmd+shift+o` opens Locations, Enter cds; pinned chips open new tabs; file survives machine sync.

## Phase 4: Status bar with git integration (UI based)

- **Per-surface status bar** (SwiftUI overlay at bottom or top of each surface, toggleable): cwd chip (click → Locations), shell/host chip, git chip (branch, dirty/staged/untracked counts, ahead/behind, stash count), last command exit status/duration (from `COMMAND_FINISHED` action + OSC 133 D), and a Claude button (Phase 5).
- **Git state source:** read-only `git` invocations run by the app out-of-process (`Process` with `git -C <cwd> status --porcelain=v2 --branch`), debounced, triggered on PWD change, command finished, and FSEvents on `.git/HEAD` and index. Never parse prompt text. Cache per repo root. Hard timeout 2s, skip on network filesystems. Model lives in a small portable module (Swift now; Windows shell reimplements against the same JSON shape).
- **Popover actions:** switch/create branch (list from `git branch --format`), fetch, pull, push, stash/pop, open repo/PR in browser (`gh pr view --web` if `gh` present), copy branch name, open in editor. Every mutating action is executed **visibly in the terminal** by inserting the command text and pressing Enter only after an explicit click on a confirm-styled button; nothing runs silently.
- Verify: status matches `git status` in three repos; branch switch appears in the terminal scrollback; no bar lag when typing.

## Phase 5: Claude Code launcher

- Status bar / palette / location-row button "Claude here": opens a new tab (or split, configurable) at the location with `command = claude` (or `claude --resume`, `claude -p`), using `ghostty_surface_config_s.command` + `working_directory`. Detect `claude` on PATH; offer install hint if missing.
- Saved-command presets ship with `claude`, `claude --continue`, `claude --resume`.
- Optional: surface-title badge when a `claude` process is foreground (`ghostty_surface_foreground_pid` → process name) so Claude tabs are identifiable.

## Phase 6: Autocomplete (Warp-style popup)

(Detailed design from the architecture pass is merged below.)

**Recommendation:** capture the live command line with a shell-side hook that emits a private OSC; run the suggestion engine as a portable Zig module inside libghostty (so Windows reuses it); convert Fig specs to a vendored JSON bundle at build time; accept completions via a shell-side widget, never via synthesized backspaces. Swift side is a thin cursor-anchored popup plus a six-key interceptor.

**6a. Command-line capture (zsh first, pwsh in Phase 8)**
- zsh: add `add-zle-hook-widget line-pre-redraw _slimer_ac_report` to `src/shell-integration/zsh/ghostty-integration`. Emit only when `$BUFFER$CURSOR$KEYMAP` changed. Wire format: `OSC 7704 ; v=1 ; c=<cursor> ; k=<keymap> ; t=<truncated> ; b=<percent-encoded buffer> BEL`, shell-side cap 4 KiB. Rejected alternatives: screen inference (breaks on wraps, RPROMPT, PS2, highlighting) and a pty proxy like inshellisense (adds a hop to every byte).
- Core gate (`src/Surface.zig`): accept only between OSC 133 B and 133 C with shell integration detected; cross-check the last 64 bytes before the cursor against the screen row; on mismatch drop and disable until the next 133 A. Rate limit 200/s. This defeats `cat evil.txt` spoofing the buffer.
- pwsh: a small PSReadLine `ICommandPredictor` shim emits the same OSC 7704; acceptance via `[PSConsoleReadLine]::Replace()`. Same core, same wire format.
- bash/fish: not day-to-day for you; defer (would use screen inference, labelled experimental).

**6b. Engine (Zig, `src/autocomplete/{Engine,Spec,Tokenizer,Rank,History,Fs,Generators}.zig`)**
- C API additions in `include/ghostty.h`: `ghostty_surface_autocomplete_query/accept/dismiss`, new action tag `GHOSTTY_ACTION_AUTOCOMPLETE_UPDATE` (generation id). Routed through `src/terminal/osc.zig` → `src/termio/stream_handler.zig` → `src/Surface.zig` → `src/apprt/action.zig` + `embedded.zig`.
- Specs: `tools/autocomplete-specs/` (Node, run offline) evaluates withfig/autocomplete at a pinned commit (MIT, attribution file), serializes subcommands/options/args/templates/`isDangerous`/descriptions, drops functions (`postProcess`, `custom`), writes a compressed bundle committed under `src/autocomplete/data/` and `@embedFile`d, so `zig build` never needs Node. Lazy per-CLI parse, LRU 64, pre-warm top 50. User specs in `~/.config/slimer/autocomplete/*.json` later.
- Generators, config `autocomplete-generators = off | native (default) | scripted`:
  - native (no exec, sub-ms, mtime-cached): git refs from `.git/HEAD`/`refs`/`packed-refs`, package.json scripts, make/just targets, ssh hosts, docker/kubectl contexts, cargo targets.
  - scripted (opt-in forever): spec `script` run by a separate Zig helper `slimer-ac-helper` under `sandbox-exec` (no network, read-only outside cwd/HOME caches), `/bin/sh -c`, scrubbed env, chdir to surface pwd, 300 ms timeout, 256 KiB cap, concurrency 2, cache keyed by (script, cwd, dir mtime).
- Other sources: cwd listing cache (1 s TTL), our own `history.log` (0600, written on 133 C, honors leading space + ignore patterns) plus one-time `HISTFILE` import. Score = prefix match, history frequency, recency decay, cwd affinity, spec order; fuzzy only for subcommands/options, never paths. Max 8 items.

**6c. Security**
- OSC payload is untrusted: caps, state gate, screen cross-check, rate limit; its bytes are used only as the match prefix, never inserted.
- Candidates containing C0/C1 controls, DEL, U+2028/2029, or bidi overrides are rejected, not stripped. Shell-quote in the widget (`${(q)}`), so hostile filenames can't break out.
- Never auto-execute: no `\r` is sent; the zsh widget edits `BUFFER` only. `isDangerous` items get a badge and are never pre-selected. Descriptions rendered through a control-char-replacing formatter.

**6d. Rendering and keys (Swift, `macos/Sources/Features/Autocomplete/`)**
- AppKit `NSView` subview of `SurfaceView` (not a child window), custom-drawn rows. Anchor x from `ghostty_surface_ime_point` minus `(cursor - replace_start) * cell_width`; flip above if fewer than 9 rows fit below.
- In `SurfaceView_AppKit.swift` `keyDown`/`performKeyEquivalent`, before `keyAction`: when visible, consume Tab/Up/Down/Ctrl-N/Ctrl-P/Esc; Enter = accept without running (config `autocomplete-enter = accept | passthrough`). Not visible → Tab goes to the shell as today. Esc suppresses until the buffer changes.
- Ghost text (later): zsh `POSTDISPLAY` from a sibling widget, so the shell renders the hint with correct wrapping; no renderer change.
- Budget: hook ~0.1 ms, parse+mailbox ~0.3 ms, engine <2 ms, relayout <2 ms, next frame. Generators never block first paint; they arrive as a second update with the same generation id.

**6e. Acceptance**
- Terminal sends `CSI 7705 ~` + encoded replacement + BEL. The zsh widget (bound in emacs/viins/vicmd) reads it with `read -r -s -d $'\a' -t 0.2`, computes its own token range from `${(z)LBUFFER}`, sets `BUFFER[tokenstart,CURSOR]=${(q)text}`, adjusts `CURSOR`, `zle redisplay`. Atomic, undoable, wide-char correct; a spoofed OSC cannot cause over-deletion because the shell computes the range. Backspace+text via `ghostty_surface_text` only as a hidden-flag fallback.

**6f. Phasing**
- MVP (2–3 weeks): zsh only; OSC 7704 parse + gate; Zig engine with subcommands/options/args for all bundled CLIs plus native filepaths/folders/history; AppKit list popup; Tab/arrows/Esc/Enter; accept widget; config on/off. Cut first if over budget: screen cross-check (keep the state gate), history import, descriptions column.
- Then (3–4 weeks): native generators, ghost text, cwd-affinity ranking, user spec dir.
- Then: sandboxed helper + scripted tier, pwsh predictor shim, WinUI host binding to the same C API.

**6g. Risks:** `zsh-syntax-highlighting` doubling redraw emissions (dedupe); users relying on compsys Tab (popup-visible-only rule + hard off switch); Fig `postProcess` loss (native reimplementations for top CLIs); OSC 2 KiB default cap vs long pipelines (allocating path, 8 KiB for this OSC only).

## Phase 7: Settings UI

- Replace the placeholder `SettingsView.swift` with a real SwiftUI settings window: General (hotkeys, startup), Drawer (position/size/animation/stacking with live preview), Themes & Tabs (rules), Locations, Commands, Git, Autocomplete, Updates.
- Ghostty-native keys are written back to the Ghostty config file under a fenced block (`# >>> fork managed >>> … # <<<`) and `reload_config` is triggered; our own data goes to `workspace.json`. Show Ghostty's diagnostics (`ConfigurationErrorsView` exists) when the write produces errors.
- Status: built (General, Drawer, Appearance, Themes & Tabs, Locations & Commands, Git & Status Bar, Claude, Advanced); the block marker is `# >>> slimer managed (edit in Settings) >>>`. Autocomplete and Updates panes are still to do. See `SETTINGS.md`.

## Phase 8: Windows (GhosttyWin32 base)

- Fork `i999rri/GhosttyWin32` (WinUI 3 + C++/WinRT shell, DX11, ConPTY, MIT) and its `i999rri/ghostty` `windows-port` submodule; merge our `fork` branch's Zig-core changes (custom OSCs, config keys, autocomplete engine if in Zig) into that submodule branch.
- Known gaps in that host we must fill for parity: quick terminal/drawer (none exists, issue #153), global hotkeys (none; use `RegisterHotKey`), tab colors, menus, cwd inheritance. Shell-side: a PowerShell 7 integration module (profile-injected) emitting OSC 133 A/B/C/D and OSC 7 (the host notes nothing writes 133 today), plus the PSReadLine predictor shim for autocomplete (Phase 6a) and the git/status hooks.
- **Shell-type indicator (your Windows ask):** status bar chip showing PowerShell 7 / Windows PowerShell / cmd / WSL:<distro> / Git Bash, derived from the launched command plus the integration script's self-report (`OSC <ours>;shell=pwsh`), with distinct icon and accent color per type; also drives tab tint by default.
- Toolchain: VS 2022 17.10+, Windows SDK 22621+, Zig 0.16+ (`zig build -Doptimize=ReleaseSafe -Drenderer=directx`), MSBuild `App`, MSIX. Code-sign with a real certificate (the upstream host uses a self-signed one).
- Reuse: Zig-core features and `workspace.json` carry over unchanged; Swift UI is rewritten in WinUI.

## Critical files (macOS)

- `macos/Sources/Features/QuickTerminal/QuickTerminalController.swift`, `QuickTerminalPosition.swift`, `QuickTerminalWindow.swift`
- `macos/Sources/Features/Terminal/BaseTerminalController.swift`, `TerminalController.swift`, `TerminalTabColor.swift`, `Window Styles/*`
- `macos/Sources/Features/Command Palette/TerminalCommandPalette.swift`, `CommandPalette.swift`
- `macos/Sources/Features/Global Keybinds/GlobalEventTap.swift`
- `macos/Sources/Features/Settings/SettingsView.swift`
- `macos/Sources/Ghostty/Ghostty.App.swift` (action callback switch), `Ghostty.Config.swift`, `Ghostty.Surface.swift`, `Surface View/*`
- `src/config/Config.zig`, `src/terminal/osc.zig`, `src/Surface.zig`, `src/apprt/embedded.zig`, `src/apprt/action.zig`, `include/ghostty.h`
- `src/shell-integration/zsh/ghostty-integration`, `bash/ghostty.bash`, `fish/vendor_conf.d/*.fish`
- New: `macos/Sources/Features/{Drawer,Workspace,StatusBar,Git,Autocomplete,Claude,SettingsUI}/`, `src/autocomplete/`, `src/slimer/` (portable models: workspace.json schema, git state shape), `tools/autocomplete-specs/`, `shell-integration/pwsh/` (Phase 8)

## Immediate next steps (first session after approval)

1. Fork upstream on GitHub, clone to `~/Dev/slimer`, add `upstream` remote, create `fork` branch.
2. Install Zig 0.17 (`brew install zig` if it ships 0.17, else from ziglang.org) and confirm Xcode 26+ with `xcodebuild -version`.
3. `zig build -Demit-macos-app=false && macos/build.nu` and launch the Debug app unmodified.
4. Record baseline numbers (startup, typing latency, memory) into `docs/perf-baseline.md`.
5. Start Phase 0 rebrand and the signing/notarization CI.

## Verification

- Build: `zig build -Demit-macos-app=false && macos/build.nu --configuration Release`; `zig build test -Dtest-filter=osc` for core OSC changes; `macos/build.nu --action test` for Swift.
- Manual per-phase checks listed above. Add XCTest cases for: drawer tab model, theme rule matching, workspace.json round-trip, git porcelain parser, autocomplete tokenizer/ranker. Add Zig tests for each new OSC.
- Performance: record `hyperfine` startup-to-window and a typing-latency sample (Typometer or `ghostty` inspector) on the unmodified build in Phase 0; re-run at the end of each phase; regressions block merge.
- Security: hardened runtime + notarization in CI; `codesign --verify --deep --strict`; audit every new OSC for length caps; fuzz the OSC parsers with `zig build test`.
- Upstream sync: weekly `git merge upstream/main` into `fork`; CI must stay green.

## Sequencing and effort (rough)

| Phase | Effort | Unblocks |
|---|---|---|
| 0 Foundation | 2–3 days | everything |
| 1 Drawer tabs/stacking | 1–2 weeks | daily use |
| 2 Theming | 1 week | |
| 3 Locations/commands | 1–2 weeks | |
| 4 Status bar + git | 2 weeks | |
| 5 Claude | 2 days | |
| 6 Autocomplete | 4–8 weeks | |
| 7 Settings UI | 1–2 weeks (grows with each phase) | |
| 8 Windows | 2–3 months | |

Phases 1–5 and 7 are independent enough to reorder; 6 is the long pole and can run after you're daily-driving the fork.
