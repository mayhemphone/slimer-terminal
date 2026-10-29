# Autocomplete

Slimer's Warp-style autocomplete popup. Phase 6A built the plumbing:
capture (shell to terminal), routing and gating in the core, the apprt
action and C API, and acceptance (terminal to shell). Phase 6C added the
suggestion engine, the popup UI, and fixes from a security review of 6A.

It is on by default in Slimer (`autocomplete = true`; upstream-style
opt-in features default off, this one is a deliberate fork default). That
adds the `autocomplete` shell-integration feature, so
`GHOSTTY_SHELL_FEATURES` contains `autocomplete`. The feature can also be
listed explicitly in `shell-integration-features`. zsh only for now (zsh
5.3 or newer).

Config:

| Key | Default | Meaning |
|---|---|---|
| `autocomplete` | `true` | Turn the popup and the shell reports on or off |
| `autocomplete-max-items` | `8` | Rows shown, clamped to 1-8 |
| `autocomplete-enter` | `accept` | `accept`: Enter inserts the selection (never runs it). `passthrough`: Enter goes to the shell |

## Capture: OSC 7704 (shell to terminal)

```
ESC ] 7704 ; v=1 ; n=<SECRET> ; p=<PGID> ; [d=1 ;] c=<CURSOR> ; k=<KEYMAP> ; t=<0|1> ; b=<payload> BEL
```

Written without the spaces. The fields are:

| Field | Meaning | Rules |
|---|---|---|
| `v` | protocol version | must be `1`, otherwise the report is dropped |
| `n` | per-surface secret | hex, at most 64 chars. The core drops reports whose secret doesn't match (see the gate) |
| `p` | the shell's process group (`$$`) | decimal. Compared with the pty foreground group before accepting |
| `d` | `1`: the shell left the line editor (zle `line-finish`) | optional, `0` or `1` |
| `c` | zle `$CURSOR`, a character index | decimal digits only, fits in u32 |
| `k` | keymap | `[A-Za-z0-9_-]{1,16}`. The shell maps `main` to `emacs` or `viins` (resolved at each prompt) and sends `other` for anything else |
| `t` | `1` if the shell truncated the buffer | `0` or `1` |
| `b` | `$BUFFER`, percent-encoded | must be the last field. Everything after `b=` is payload |

Payload encoding: the bytes `%`, `;`, every C0 control (0x00-0x1F) and DEL
(0x7F) become `%XX` with uppercase hex. Everything else passes through
raw, including UTF-8. The shell truncates the raw buffer to 4096 bytes
before encoding and then sets `t=1`. The decoder accepts either hex case.

The shell sends a report from a `line-pre-redraw` zle hook (installed
with `add-zle-hook-widget`), but only when `$BUFFER`, `$CURSOR` or
`$KEYMAP` changed since the last report. The cache is reset at each
prompt. A `line-finish` hook sends a `d=1` report. Reports go to the
integration's tty fd.

Parser (`src/terminal/osc/parsers/autocomplete_buffer.zig`):

- The body after `7704;` is at most 8192 bytes. That is above the
  parser's 2048-byte fixed buffer, so OSC 7704 uses the parser's
  allocating capture path, and the capture limit is set to the body cap
  as soon as capture starts, so a hostile sequence can't buffer more.
  Without an allocator, anything past 2048 bytes is dropped.
- The decoded buffer is at most 4096 bytes.
- Missing, duplicate or malformed fields, a bad `%` escape, or any
  version other than 1 drop the whole report. Unknown keys are skipped.
- The payload is percent-decoded in place. `Command` stores offsets into
  the capture buffer (to keep `osc.Command` small); `buffer()`,
  `keymap()` and `nonce()` are only valid until the next parser call.
- `GHOSTTY_OSC_COMMAND_AUTOCOMPLETE_BUFFER` in `include/ghostty/vt/osc.h`
  is a fork addition and NOT a stable value.

## The secret

Each surface generates a 128-bit random secret (32 lowercase hex chars)
when the `autocomplete` shell feature is on and passes it to the shell
as `SLIMER_AUTOCOMPLETE_TOKEN`. The zsh integration copies it into a
non-exported global and unsets the variable the moment it is sourced, so
child processes never inherit it. Every report carries it as `n=`; the
core compares it in constant time and drops reports without it. This is
what stops `cat evil.txt` (or any program's output) from printing
`OSC 133;B` followed by a forged 7704.

Residual risk, out of scope: anything already running code as the user
can read the secret (from the shell's memory, or the environment of a
shell started before the integration ran) and forge reports. Such code
can type into the terminal directly anyway.

Shells other than zsh don't run the integration and so never unset the
variable; children of those shells inherit it. They also never report,
so the popup never shows there.

## Routing and the gate (IO thread)

`osc.zig` -> `stream.zig` action `autocomplete_buffer` ->
`termio/stream_handler.zig`. The stream handler applies the gate on the
IO thread, in stream order and with the terminal locked, so the
prompt-input check sees exactly the state the report was written in. A
report is forwarded only if all of these hold:

1. **Secret** matches (`autocomplete.Gate`, `Token.matches`).
2. **Primary screen**, and **shell integration seen**
   (`Screen.semantic_prompt.seen`).
3. **Prompt-input state**: after OSC 133 B and before 133 C
   (`Screen.cursor.semantic_content == .input`).
4. **Rate limit**: at most 200 reports per surface in a fixed one-second
   window.

A forwarded report is copied once into an `autocomplete.Update` and the
surface takes ownership of the buffer (`State.take`). The surface bumps
`generation` and emits the apprt action `autocomplete_update`.

The state ends (and the action is emitted so the popup hides):

- on OSC 133 C (the command starts; the line is recorded to history first),
- on OSC 133 A (new prompt) and 133 D, and on entering the alternate
  screen (the core posts a deactivate),
- on a `d=1` report from zle `line-finish` (accepted, interrupted, or
  handed to `edit-command-line`'s editor),
- synchronously in the key path when a key the user types encodes CR, LF,
  ^C, ^D or ^Z, so Enter-then-Tab typed fast can't accept into the
  command that just started.

Not implemented from PLAN.md 6a: the screen cross-check (compare the
last 64 bytes before the cursor with the screen row). The secret makes it
redundant for spoofing; it remains a possible consistency check.

## Acceptance (terminal to shell)

```
ESC [ 7705 ~ <every byte as %XX> BEL     replace the current word
ESC [ 7706 ~ <every byte as %XX> BEL     replace the whole line (history)
```

Every byte of the text is hex-encoded, so if the widget is not reached
(vi mode with `KEYTIMEOUT=1` and split delivery, or a late BEL) the bytes
that leak into zle as keystrokes are only `%`, digits and `A`-`F`.

`ghostty_surface_autocomplete_accept(surface, generation, text, len)`
(and `_accept_line`) send nothing and return false unless all of these
hold, checked on the main thread:

- the state is live and `generation` is the one the popup was built from;
- the terminal is still at prompt input on the primary screen with shell
  integration seen;
- the pty's foreground process group (`tcgetpgrp`) equals the reporting
  shell's (`p=`), so nothing reaches vim, a password prompt, fzf, or an
  `edit-command-line` editor;
- the text passes `isSafeAcceptText`: not empty, at most 4096 bytes,
  valid UTF-8, and no C0/C1 control, DEL, noncharacter, or code point in
  the Unicode categories Cf (format: bidi controls, zero-width
  characters), Zl, Zp, Cs, Cn (unassigned) or Co (private use). Unsafe
  text is rejected, not stripped.

The text goes to the pty through the surface IO queue, the same path key
input uses, so readonly mode blocks it.

In the shell, `_ghostty_ac_accept` (7705) and `_ghostty_ac_accept_line`
(7706) are bound in the `emacs`, `viins` and `vicmd` keymaps:

1. Read the payload one key at a time with `read -k 1 -t 0.1` up to the
   BEL, with an overall 1 s deadline (not a single gap). Past 12288
   characters keep draining up to the BEL and then discard everything.
2. Require the payload to be nothing but `%XX` escapes, then decode it in
   one pass.
3. Refuse control characters and the common invisible/reordering
   characters again (defense in depth; the core check is authoritative).
4. Word mode: find the current token, the last word of `${(z)LBUFFER}`.
   It is empty if LBUFFER is empty, ends in whitespace, or ends in an
   operator (`; | & ( ) < >`) or an fd redirection (`2>`, `2>&1`); those
   are never deleted. Replace it with the text, raw if it matches
   `[A-Za-z0-9_./:@%+=,-]+` (a leading `~` or `~/` stays raw so it still
   expands), otherwise `${(q)}`-quoted.
5. Line mode: only if the cursor is at the end and LBUFFER is a prefix of
   the text; then LBUFFER becomes the text. So a history suggestion can
   only extend what the user typed.
6. `zle redisplay`. Neither widget calls `accept-line` or inserts a
   newline.

## Suggestion engine (`src/autocomplete/`)

Portable Zig, no apprt or macOS APIs. One `Engine` is shared by every
surface (specs, history and caches are process-wide); queries run on the
main thread.

| File | Role |
|---|---|
| `Tokenizer.zig` | Shell-like tokenizer up to the cursor: quotes, escapes, `;` `&&` `\|\|` `\|` `&` newline and `(` reset the command, redirections mark the next word as a filename, `$(...)`/backticks/`<(...)` are opaque (cursor inside an open one: no suggestions). Converts the character cursor to bytes. |
| `Spec.zig` | Parses converter-format JSON into plain structs (one arena per spec), lazily on first use, LRU cache of 64. Specs are `@embedFile`d with `index.json` (aliases). Generator scripts are mapped to native generators at parse time and never run. |
| `Engine.zig` | Walks the spec (subcommands, options incl. combined short flags and `--opt=value`, persistent options, option args, positional args, `isCommand` recursion for `sudo`/`exec`), skips env assignments and precommands, and collects candidates from all sources. |
| `Fs.zig` | Directory listings for `filepaths`/`folders`, `cd`/`pushd`, commands without a spec, and redirection targets. 1 s cache, 2000 entries, dotfiles only when the partial starts with `.`, `~` expansion. |
| `Generators.zig` | Native generators, no subprocess: git branches/remotes/tags (reads `HEAD`, `refs/`, `packed-refs`, `config`, follows worktree `.git` files and `commondir`, walking up from the cwd), package.json scripts (nearest one up), make targets (`^target:` scan of the cwd Makefile, cap 200). 1 s cache. |
| `History.zig` | `history.log` store plus one-time (per process) import of `~/.zsh_history` (plain and EXTENDED_HISTORY, metafied bytes, multi-line entries). In-memory cap 10k entries. Line stats and per-command word stats (count, last use, cwd). |
| `Rank.zig` | Score = match quality (exact prefix > case-insensitive prefix > fuzzy) + spec priority + spec order + generator hint + history frequency + recency (one-week decay) + cwd affinity. Fuzzy (subsequence, anchored at the first character) only for subcommands and options. |
| `glue.zig` | Lazy shared engine, C result layout, history recording. |

Sources by position:

- **First word** of a command: spec command names, command words seen in
  history, and (only for the first command in the buffer with the cursor
  at the end) whole history lines, which accept with `CSI 7706 ~`.
  Multi-line history entries are never offered.
- **Later words**: the spec walk. Options only when the token starts with
  `-`. Arg suggestions, native generators, and path templates.
- Candidate text that would fail `isSafeAcceptText` is dropped.

History: `history.log` lives in the data directory the app passes to
`ghostty_autocomplete_set_paths` (macOS: `$XDG_DATA_HOME/slimer`, default
`~/.local/share/slimer`; a temporary directory under XCTest). It is
created with mode 0600 and only appended to. One entry per line:
`<unix seconds>;<percent-encoded cwd>;<percent-encoded command>`. A line
is recorded at OSC 133 C: the line stashed when the user pressed Enter
(or zle `line-finish` fired), else the live buffer. Lines starting with a
space and truncated buffers are never recorded. zsh entries are imported
only if older than the first `history.log` entry, so commands aren't
counted twice.

Starter specs: the full Fig corpus is not converted yet (it needs owner
approval). `tools/autocomplete-specs/starter/` holds hand-written
Fig-format modules for git, cd, ls, npm, pnpm, yarn, docker, kubectl,
brew, make, ssh, claude, cargo, zig and gh, converted with the real
converter into `src/autocomplete/data/specs/` and validated with
`validate.mjs`. `Spec.embedded` lists the keys by hand (a test checks it
against `index.json`); generate that list when the corpus lands.

Performance (Apple Silicon, warm caches, a mix of 8 command lines
including a 2000-line history scan and a 200-file directory, 1000
queries): about **85 µs/query in ReleaseFast** and about 1 ms/query in
Debug. The test `autocomplete engine: query latency with warm caches`
asserts 1000 queries < 2 s in Debug.

## C API

```c
GHOSTTY_ACTION_AUTOCOMPLETE_UPDATE   // ghostty_action_autocomplete_update_s { uint64_t generation; }

bool ghostty_surface_autocomplete_buffer(ghostty_surface_t, ghostty_autocomplete_buffer_s*);
bool ghostty_surface_autocomplete_query(ghostty_surface_t, ghostty_autocomplete_result_s*);
bool ghostty_surface_autocomplete_accept(ghostty_surface_t, uint64_t generation, const char*, uintptr_t);
bool ghostty_surface_autocomplete_accept_line(ghostty_surface_t, uint64_t generation, const char*, uintptr_t);
void ghostty_surface_autocomplete_dismiss(ghostty_surface_t);
void ghostty_autocomplete_set_paths(const char* data_dir, uintptr_t, const char* zsh_history, uintptr_t);
```

- All pointer parameters may be null (the call then does nothing and
  returns false). Call everything on the main thread.
- `_buffer` always fills `out` so the generation can be compared; it
  returns false when nothing is live. `out->buffer` is surface-owned
  until the next update or dismiss.
- `_query` fills up to `GHOSTTY_AUTOCOMPLETE_MAX_ITEMS` (8) items
  `{ text, display, description (+ lengths, not NUL-terminated), kind,
  dangerous, match_len }` plus `replace_start`/`replace_len` (characters),
  `replace_cols` (cells) and `generation`. Strings are surface-owned
  until the next query. `kind` is a `ghostty_autocomplete_kind_e`
  (SUBCOMMAND, OPTION, ARG, PATH, HISTORY, GENERATOR); HISTORY items
  replace the whole line.
- `_dismiss` clears the state and bumps the generation without emitting
  an action.
- `_set_paths` is called once at startup, before the first query.

On macOS, `Ghostty.App` posts `Ghostty.Notification.ghosttyAutocompleteDidUpdate`
with the `SurfaceView` as the object. GTK ignores the action silently.

## Popup (macOS, `macos/Sources/Features/Autocomplete/`)

- `AutocompleteController`, one per surface, created on the first key
  press (which always precedes the first report). On each update
  notification it schedules one query per run loop turn, then shows or
  hides the popup.
- `AutocompletePopupView` is a custom-drawn subview of the surface view
  (no child window, no table view). It anchors at the start of the
  replaced token: x = IME point x - `replace_cols` * cell width; below the
  cursor row, or above it when fewer than 9 rows fit below. Rows: kind
  icon, text with the matched prefix in bold, a "dangerous" badge,
  description dimmed. Colors derive from the surface background and the
  configured foreground. Every displayed string is sanitized (control,
  format, separator, private-use and unassigned characters become
  U+FFFD).
- Shown only when focused (key window), the buffer is non-empty, and at
  least one suggestion would change the current token (or line, for
  history). Hidden on focus loss, scroll, resize, and whenever the core
  ends the state (command start, prompt marks, alternate screen).
- Keys, only while visible (`SurfaceView_AppKit.swift` `keyDown` and
  `performKeyEquivalent` ask the controller first): Tab/Down/Ctrl-N next,
  Shift-Tab/Up/Ctrl-P previous, Esc dismisses (stays hidden until the
  buffer changes), Enter accepts when `autocomplete-enter = accept` and
  a row is selected (it does not run the command), Right arrow at the end
  of the line accepts. Dangerous items are never pre-selected; if every
  item is dangerous nothing is selected and Enter goes to the shell.
  When hidden, every key flows exactly as before. Accepting never
  synthesizes Enter.

## Tests

- `zig build test -Dtest-filter=autocomplete`: tokenizer (quotes,
  escapes, separators, substitutions, redirections, unicode cursor),
  specs (parsing, native generator detection, aliases, LRU, every
  embedded spec), engine (spec walk, option args, combined flags,
  `--opt=value`, path completion in a temp dir, git refs in a fake repo
  incl. worktrees, package.json scripts, make targets, precommands,
  history lines, ranking, latency), history (zsh extended format,
  metafied bytes, log round trip with 0600, cap), gate (secret, prompt
  state, rate limit), state stash/clear, accept-text validation (Unicode
  categories), accept encoding (hex only), keys that end the line, and
  config defaults.
- `zig build test -Dtest-filter=7704`: parser tests, including the
  secret/pgid/deactivate fields and the early capture cap.
- `zig build test -Dtest-filter="setup features"`: `GHOSTTY_SHELL_FEATURES`
  carries `autocomplete`.
- `macos/build.nu --action test`: `AutocompleteModelTests` (sanitizing,
  bold-prefix splitting, selection, visibility, key mapping, C result
  conversion, data directory).
- `zsh -f test/slimer/zsh-autocomplete.zsh src/shell-integration/zsh/ghostty-integration [emacs|vi]`:
  drives a real interactive zsh through `zpty`. It checks that the secret
  is removed from the environment and carried in reports, the emitted
  OSC, token replacement, quoting, rejection of an encoded newline, a
  zero-width space and a non-hex payload, fd redirections kept, `~/` kept
  raw, line accept (prefix only), the `d=1` report on line-finish,
  dedupe on redraw, and that nothing runs before Enter. Keep payloads
  small: `zpty -wn` silently loses writes over about 1 KB.
