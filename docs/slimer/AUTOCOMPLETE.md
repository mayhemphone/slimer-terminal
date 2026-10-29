# Autocomplete

Slimer's Warp-style autocomplete popup. Phase 6A built the plumbing:
capture (shell to terminal), routing and gating in the core, the apprt
action and C API, and acceptance (terminal to shell). Phase 6C added the
suggestion engine, the popup UI, and fixes from a security review of 6A.

It is on by default in Slimer (upstream-style opt-in features default
off; this one is a deliberate fork default): the `autocomplete`
shell-integration feature defaults on, so `GHOSTTY_SHELL_FEATURES`
contains `autocomplete`. Either `autocomplete = false` or an explicit
`no-autocomplete` in `shell-integration-features` turns it off, and with
it the shell reports and history recording. zsh (5.3 or newer) and
PowerShell (see `src/shell-integration/powershell/`).

Config:

| Key | Default | Meaning |
|---|---|---|
| `autocomplete` | `true` | Turn the popup and the shell reports on or off |
| `autocomplete-max-items` | `8` | Rows shown, clamped to 1-8 |
| `autocomplete-enter` | `navigated` | `navigated`: Enter runs the command unless you moved the selection (Warp-like). `accept`: Enter inserts the selected or top row (never runs it). `passthrough`: Enter always goes to the shell |

## Capture: OSC 7704 (shell to terminal)

```
ESC ] 7704 ; v=1 ; n=<SECRET> ; p=<PGID> ; [i=1 ;] [d=1 ; [h=<0|1> ;]] c=<CURSOR> ; k=<KEYMAP> ; t=<0|1> ; b=<payload> BEL
```

Written without the spaces. The fields are:

| Field | Meaning | Rules |
|---|---|---|
| `v` | protocol version | must be `1`, otherwise the report is dropped |
| `n` | per-surface secret | hex, at most 64 chars. The core drops reports whose secret doesn't match (see the gate) |
| `p` | the shell's process group (`$$`) | decimal. Compared with the pty foreground group before accepting |
| `i` | `1`: first report after zle `line-init` (a new line starts) | optional, `0` or `1` |
| `d` | `1`: the shell left the line editor (zle `line-finish`, or the history hook) | optional, `0` or `1` |
| `h` | with `d=1`: history verdict from `zshaddhistory`. `1`: `b` is the full command line to record; `0`: record nothing | optional |
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
prompt. A `line-init` hook marks the next report `i=1`; a `line-finish`
hook sends a `d=1` report; a `zshaddhistory` hook sends `d=1;h=1` with
the full command line (all physical lines of a multi-line command), or
`d=1;h=0` when the line must not be recorded: a leading space, a match
of `HISTORY_IGNORE`, or no `HISTFILE` (`fc -p` incognito). The hook
always returns 0, so zsh's own history is unaffected. Reports go to the
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

Each surface generates a 128-bit secret (32 lowercase hex chars) from
the OS's secure random source (`randomSecure`) when the `autocomplete`
shell feature is on; if that source fails, no secret is made and
autocomplete stays off for the surface (fail closed). The secret is passed
as `SLIMER_AUTOCOMPLETE_TOKEN` only to shells that use it: when the zsh
integration is actually injected, or when the command is PowerShell
(`pwsh`, `powershell`), which loads the Slimer module from its profile.
Every other shell's environment never contains it. The zsh integration copies it into a
non-exported global and unsets the variable the moment it is sourced, so
child processes never inherit it. Every report carries it as `n=`; the
core compares it in constant time and drops reports without it. This is
what stops `cat evil.txt` (or any program's output) from printing
`OSC 133;B` followed by a forged 7704.

Residual risk, out of scope: anything already running code as the user
can read the secret (from the shell's memory, or the environment of a
shell started before the integration ran) and forge reports. Such code
can type into the terminal directly anyway.

A manually sourced zsh integration (`shell-integration = none` plus
sourcing the script yourself) gets no secret and never reports.

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
4. **Line not ended**: after a `d=1` report the gate refuses reports
   until the next line starts (OSC 133 A or B, or a report with `i=1`).
5. **Rate limit**: at most 200 reports per surface in a fixed one-second
   window.

The first report forwarded after a line start is marked `line_start`.

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
  ^C, ^D or ^Z, and when a `text:` binding, `ghostty_surface_text` or an
  unbracketed paste contains CR or LF, so Enter-then-Tab typed fast can't
  accept into the command that just started.

Ending the line also sets a "line ended" latch on the surface: reports
still in flight for the old line are ignored until a `line_start` report
arrives, which also drops a stashed line that never reached 133 C (for
example after ^C).

History recording at 133 C uses, in order: the line from `d=1;h=1` (the
shell's full command line), nothing after `d=1;h=0`, else the last
reported buffer stashed on Enter/line-finish (PowerShell, or shells
without the hook).

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
surface (specs, history and caches are process-wide) and is owned by the
**worker thread** (`Worker.zig`): queries, history loading/recording and
all filesystem reads run there, never on the main thread.

Query flow: the app calls `ghostty_surface_autocomplete_query` on the
main thread. If the worker has delivered a result for the current
generation it is copied out; otherwise a query is queued (once per
generation; a newer query replaces one from the same surface that hasn't
started) and `pending` is set. When the worker finishes, it hands the
result to the surface through the app mailbox; the surface keeps it only
if its generation is still current and emits `autocomplete_update` again,
and the app reads it. Stale results are dropped.

Filesystem safety: files (package.json, Makefile, packed-refs, HEAD,
config, history files) are opened `O_NONBLOCK` and must be regular files
(`fstat`), so a FIFO can't block. Directory listings and generators skip
non-local and automounted filesystems (`statfs` without `MNT_LOCAL` or
with `MNT_AUTOMOUNTED`; anything under `/net`, `/Network`, `/Volumes` must
prove it is local). Listings don't `stat` symlinks; only links among the
final shown items are resolved (one `stat` each). packed-refs is read up
to 8 MB and only complete lines are parsed. package.json and Makefile
results are reused past the 1 s cache while the file's mtime is
unchanged.

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

Candidates whose text equals the current token are dropped.

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
created with mode 0600 and written with `O_APPEND`; at load, a log with
more than 10k entries is rewritten (temp file + rename) to keep the
newest 10k. One entry per line:
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
queries): about **91 µs/query in ReleaseFast** and about 1 ms/query in
Debug, all on the worker thread. The test `autocomplete engine: query
latency with warm caches` only asserts a very generous bound (< 30 s)
because wall-clock limits flake on a loaded machine; measure in
ReleaseFast for real numbers.

## C API

```c
GHOSTTY_ACTION_AUTOCOMPLETE_UPDATE   // ghostty_action_autocomplete_update_s { uint64_t generation; }

bool ghostty_surface_autocomplete_buffer(ghostty_surface_t, ghostty_autocomplete_buffer_s*);
bool ghostty_surface_autocomplete_query(ghostty_surface_t, ghostty_autocomplete_result_s*);  // never blocks
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
  `replace_cols` (cells), `generation` and `pending` (no result yet: keep
  the popup and wait for the next update). Strings are surface-owned
  until the next autocomplete update. `kind` is a `ghostty_autocomplete_kind_e`
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
- Keys (Warp-like). Nothing is selected until the user navigates.
  `SurfaceView_AppKit.swift` `keyDown` and `performKeyEquivalent` ask
  the controller first:
  - Down / Ctrl-N next, Up / Ctrl-P / Shift-Tab previous (this is
    "navigation"; it resets whenever the line changes).
  - Tab, or Right at the end of the line: insert the row the user
    navigated to, else the top row. The top row is the first one that is
    neither dangerous nor a whole-line history entry; if there is none,
    Tab goes to the shell.
  - Enter (`autocomplete-enter = navigated`, the default): insert the
    navigated row; without navigation Enter runs the command as typed and
    the popup hides. `accept`: insert the navigated or top row.
    `passthrough`: always run.
  - Esc hides the popup until the buffer changes. In vi keymaps (`viins`,
    `vicmd`) it also passes through to the shell.
  - While an input method is composing (marked text), every key goes to
    the IME and the popup hides.
  - An empty token (right after a space) doesn't open the popup by
    itself; Tab opens it when suggestions are waiting.
  - When hidden, every other key flows exactly as before. Accepting never
    synthesizes Enter. If the line changed and its result hasn't arrived
    yet, accept keys pass through instead of inserting a stale row.
- History rows use a clock icon and show the whole line, truncated in the
  middle so its end stays visible.

## Upstream merge hotspots

Edits to upstream files that are most likely to conflict:

- `src/termio/stream_handler.zig`: one call at the top of
  `semanticPrompt` (`autocompleteSemanticPrompt`), one line in each of the
  three alternate-screen mode cases, the `autocomplete_buffer` action
  dispatch, and the gate field. Upstream's 133 case list is untouched.
- `src/termio/shell_integration.zig` tests: `.autocomplete = false` added
  to four `setupFeatures` struct literals (the feature now defaults on).
- `src/termio/Exec.zig`: the secret is removed from the child env unless
  zsh is injected or the command is PowerShell.
- `src/Surface.zig`: key path (`endsLine`), `text:` binding and paste
  (`submitsLine`), init (secret), deinit (cancel), and the message
  handlers.
- `src/config/Config.zig` `finalize`: `autocomplete` and the feature are
  ANDed.

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
  bold-prefix splitting, top-row choice, selection, visibility incl. the
  empty token, Enter/Tab/Right/Esc/IME-free key mapping in every Enter
  mode and vi keymaps, C result conversion, data directory).
- `zsh -f test/slimer/zsh-autocomplete.zsh src/shell-integration/zsh/ghostty-integration [emacs|vi]`:
  drives a real interactive zsh through `zpty`. It checks that the secret
  is removed from the environment and carried in reports, the emitted
  OSC, token replacement, quoting, rejection of an encoded newline, a
  zero-width space and a non-hex payload, fd redirections kept, `~/` kept
  raw, line accept (prefix only), the `d=1` report on line-finish ending
  in a real BEL, `i=1` on the first report of a line, the history hook
  (`h=0` without `HISTFILE` or for `HISTORY_IGNORE`, `h=1` with the line),
  dedupe on redraw, and that nothing runs before Enter. Keep payloads
  small: `zpty -wn` silently loses writes over about 1 KB.
