# Slimer

Slimer is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds a slide-out drawer with tabs, per-terminal themes, saved locations and commands, a git status bar, a Claude Code launcher, Warp-style autocomplete, and a Settings window. The terminal core and renderer are upstream Ghostty.

## Build and run (macOS)

```sh
zig build -Demit-macos-app=false        # core library (after any change outside macos/)
macos/build.nu                          # Debug app -> macos/build/Debug/Ghostty.app
macos/build.nu --configuration Release  # Release app -> macos/build/Release/Ghostty.app
macos/build.nu --action test            # Swift tests
zig build test -Demit-macos-app=false   # Zig tests; see note below
zsh -f test/slimer/zsh-autocomplete.zsh src/shell-integration/zsh/ghostty-integration emacs   # and: vi
```

Known noise in `zig build test`, both pre-existing upstream behavior:
- The `ghostty-test` step is reported as failed because upstream's `src/benchmark/TerminalSnapshot.zig` test prints to stderr, which Zig 0.17's build runner treats as a failure. Run the test binary directly to see the real result (`4170 passed; 26 skipped; 0 failed` at the time of writing).
- The wrapped `xcodebuild test` step fails outside `build.nu`'s clean environment. Use `macos/build.nu --action test` for Swift tests.
- `zig build test` rebuilds `GhosttyKit.xcframework` for the native arch only. Run `zig build -Demit-macos-app=false` again before a universal Release build.

Requires Zig 0.17, Xcode 26+ with the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`), Nushell, and SwiftLint.

## Documents

| Doc | What it covers |
|---|---|
| [PLAN.md](PLAN.md) | The phased plan and decisions |
| [CONVENTIONS.md](CONVENTIONS.md) | Fork rules: merge hygiene, security, speed |
| [MANUAL-TEST.md](MANUAL-TEST.md) | Hands-on checklist for things only a person can verify |
| [DRAWER.md](DRAWER.md) | Slide-out terminal, tabs, stacks, animation |
| [PANES.md](PANES.md) | Window ▸ Arrange Panes: equalize, even grid, columns, rows |
| [THEMES.md](THEMES.md) | Per-terminal and per-tab themes, rules |
| [WORKSPACE.md](WORKSPACE.md) | Locations, saved commands, recent dirs, syncing |
| [GIT.md](GIT.md) | Read-only git status service |
| [STATUSBAR.md](STATUSBAR.md) | Per-terminal status bar and git popover |
| [CLAUDE-LAUNCHER.md](CLAUDE-LAUNCHER.md) | Starting Claude Code |
| [AUTOCOMPLETE.md](AUTOCOMPLETE.md) | Autocomplete protocol, engine, popup, security model |
| [SETTINGS.md](SETTINGS.md) | Settings window and how it edits the Ghostty config |
| [RELEASE.md](RELEASE.md) | Signing, notarization, Sparkle, CI secrets |
| [WINDOWS.md](WINDOWS.md) | Windows porting guide (PowerShell integration is untested) |

## Upstream sync

```sh
git fetch upstream
git merge upstream/main   # on branch fork
```

Merge hotspots are listed in AUTOCOMPLETE.md and SETTINGS.md.
