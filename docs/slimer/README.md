# Slimer

Slimer is a fork of [Ghostty](https://github.com/ghostty-org/ghostty) that adds a slide-out drawer with tabs, per-terminal themes, saved locations and commands, a git status bar, a Claude Code launcher, Warp-style autocomplete, and a Settings window. The terminal core and renderer are upstream Ghostty.

## Build and run (macOS)

```sh
zig build -Demit-macos-app=false        # core library (after any change outside macos/)
macos/build.nu                          # Debug app -> macos/build/Debug/Ghostty.app
macos/build.nu --configuration Release  # Release app -> macos/build/Release/Ghostty.app
macos/build.nu --action test            # Swift tests
zig build test -Demit-macos-app=false   # Zig tests (its wrapped xcodebuild step fails; use build.nu for Swift tests)
zsh -f test/slimer/zsh-autocomplete.zsh src/shell-integration/zsh/ghostty-integration emacs   # and: vi
```

Requires Zig 0.17, Xcode 26+ with the Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`), Nushell, and SwiftLint.

## Documents

| Doc | What it covers |
|---|---|
| [PLAN.md](PLAN.md) | The phased plan and decisions |
| [CONVENTIONS.md](CONVENTIONS.md) | Fork rules: merge hygiene, security, speed |
| [MANUAL-TEST.md](MANUAL-TEST.md) | Hands-on checklist for things only a person can verify |
| [DRAWER.md](DRAWER.md) | Slide-out terminal, tabs, stacks, animation |
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
