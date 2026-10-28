# Slimer fork conventions

Slimer is a fork of Ghostty. Upstream is tracked on `main` (remote `upstream`); all Slimer work lives on `fork`.

## Keep merges cheap
- Prefer new files and new folders over edits to upstream files. New Swift features go in `macos/Sources/Features/<Feature>/`; new Zig code goes in `src/slimer/` or a dedicated module folder (e.g. `src/autocomplete/`).
- When an upstream file must change, keep the diff minimal and mark the hunk with a `// slimer:` comment so merges are easy to reason about.
- Never rename upstream config keys, env vars (`GHOSTTY_*`), or `TERM=xterm-ghostty`. New config keys are plain Ghostty keys (added to `src/config/Config.zig`, documented like upstream keys). New env vars use `SLIMER_`.

## Where our data lives
- Ghostty's config file stays authoritative for Ghostty keys.
- Slimer's own data (locations, saved commands, per-tab themes, pins, usage stats) lives in `~/.config/slimer/workspace.json`, owned by the Workspace feature. It must be safe to sync between machines.

## Security rules (non-negotiable)
- Never execute anything derived from terminal output, shell-reported state, or a new OSC payload. Those channels are untrusted: length-capped, sanitized, and only ever used as data.
- UI actions that run commands do so visibly in the terminal (insert text, then Enter only after an explicit user click), never via a hidden subprocess, except read-only queries (e.g. `git status`) run by the app with timeouts.
- Candidate text inserted into the terminal is rejected (not stripped) if it contains control characters, DEL, U+2028/2029, or bidi overrides.

## Speed rules
- Nothing new on the render or IO path. Work happens in response to events on the main thread or on background queues, coalesced.
- Any new per-keystroke work must stay under 2 ms on the main thread.

## Building and testing
- Core: `zig build -Demit-macos-app=false` (needed after any change outside `macos/`).
- App: `macos/build.nu` (Debug) or `macos/build.nu --configuration Release`. Output: `macos/build/<configuration>/Ghostty.app`.
- Tests: `zig build test -Dtest-filter=<name>`; `macos/build.nu --action test`.
- Lint: `zig fmt .`, `swiftlint lint --strict`.
