# Autocomplete: wire protocol and security model

Phase 6, part A: the core plumbing for the Warp-style autocomplete popup.
This covers capture (shell to terminal), routing and gating in the core,
the apprt action and C API, and acceptance (terminal to shell). The
suggestion engine and the popup UI are separate pieces.

Enable it with `autocomplete = true` in the Ghostty config. That adds the
`autocomplete` shell-integration feature, so `GHOSTTY_SHELL_FEATURES`
contains `autocomplete`. The feature can also be listed explicitly in
`shell-integration-features`. zsh only for now (zsh 5.3 or newer).

## Capture: OSC 7704 (shell to terminal)

```
ESC ] 7704 ; v=1 ; c=<CURSOR> ; k=<KEYMAP> ; t=<0|1> ; b=<payload> BEL
```

Written without the spaces. The fields are:

| Field | Meaning | Rules |
|---|---|---|
| `v` | protocol version | must be `1`, otherwise the report is dropped |
| `c` | zle `$CURSOR`, a character index | decimal digits only, fits in u32 |
| `k` | keymap | `[A-Za-z0-9_-]{1,16}`. The shell maps `main` to `emacs` or `viins` and sends `other` for anything else |
| `t` | `1` if the shell truncated the buffer | `0` or `1` |
| `b` | `$BUFFER`, percent-encoded | must be the last field. Everything after `b=` is payload |

Payload encoding: the bytes `%`, `;`, every C0 control (0x00-0x1F) and DEL
(0x7F) become `%XX` with uppercase hex. Everything else passes through
raw, including UTF-8. The shell truncates the raw buffer to 4096 bytes
before encoding and then sets `t=1`. The decoder accepts either hex case.

The shell sends a report from a `line-pre-redraw` zle hook (installed
with `add-zle-hook-widget`), but only when `$BUFFER`, `$CURSOR` or
`$KEYMAP` changed since the last report. The cache is reset at each
prompt. Reports go to the integration's tty fd.

Parser (`src/terminal/osc/parsers/autocomplete_buffer.zig`):

- The body after `7704;` is at most 8192 bytes. That is above the
  parser's 2048-byte fixed buffer, so OSC 7704 uses the parser's existing
  allocating capture path, the same one OSC 52/7501/5522 use, and
  enforces its own 8192 cap. Without an allocator, anything past 2048
  bytes is dropped.
- The decoded buffer is at most 4096 bytes.
- Missing, duplicate or malformed fields, a bad `%` escape, or any
  version other than 1 drop the whole report. Unknown keys are skipped.
- The payload is percent-decoded in place, so `Command.autocomplete_buffer.buffer`
  holds the decoded bytes. They are only valid until the next parser call.

## Routing and the gate

`osc.zig` → `stream.zig` action `autocomplete_buffer` →
`termio/stream_handler.zig`. The stream handler copies the borrowed
slices into an owned `autocomplete.Update` and posts the surface message
`autocomplete_buffer`. On the app thread, `Surface.autocompleteBuffer`
applies the gate, and accepts the report only if all of these hold:

1. **Shell integration seen**: `Screen.semantic_prompt.seen` on the
   active screen. Upstream sets it the first time an OSC 133 prompt mark
   is applied.
2. **Prompt-input state**, after OSC 133 B and before OSC 133 C. The
   check is `Screen.cursor.semantic_content == .input`: 133 B sets
   `.input`, and 133 C and D set `.output`. The alternate screen never
   qualifies.
3. **Rate limit**: at most 200 accepted reports per surface in a fixed
   one-second window.

A dropped report is logged at debug level and changes nothing. An
accepted report is copied into surface-owned `autocomplete.State`
(`buffer`, `cursor` clamped to the buffer length, keymap
`emacs|viins|vicmd|other`). The surface then bumps `generation` and emits
the apprt action `autocomplete_update { generation }`. When a command
starts (OSC 133 C), a live state is cleared and another
`autocomplete_update` is emitted so the popup hides.

The first report at a new prompt usually arrives before zle draws the
prompt's 133 B, so the gate drops it. That costs nothing: the next
keystroke reports again.

Not yet implemented from PLAN.md 6a: the screen cross-check (compare the
last 64 bytes before the cursor with the screen row). The plan allows
cutting it from the MVP. The state gate and the rate limit are in place.

## Action and C API

```c
GHOSTTY_ACTION_AUTOCOMPLETE_UPDATE   // ghostty_action_autocomplete_update_s { uint64_t generation; }

typedef struct {
  const char* buffer;   // decoded bytes, NOT NUL-terminated
  uintptr_t len;
  uint32_t cursor;      // character index, clamped to len
  uint8_t keymap;       // ghostty_autocomplete_keymap_e: EMACS=0 VIINS=1 VICMD=2 OTHER=3
  uint64_t generation;
} ghostty_autocomplete_buffer_s;

bool ghostty_surface_autocomplete_buffer(ghostty_surface_t, ghostty_autocomplete_buffer_s*);
void ghostty_surface_autocomplete_accept(ghostty_surface_t, const char* text, uintptr_t len);
void ghostty_surface_autocomplete_dismiss(ghostty_surface_t);
```

- `_buffer` always fills `out`, so the generation can be compared. It
  returns false when nothing is live (nothing received yet, dismissed, or
  the command was submitted). `out->buffer` points at surface-owned memory
  that stays valid until the next update or dismiss on that surface. Call
  it on the main thread and copy what you keep.
- `_dismiss` clears the state and bumps the generation without emitting
  an action.
- `_accept` is described in the next section.

On macOS, `Ghostty.App` posts `Ghostty.Notification.ghosttyAutocompleteDidUpdate`
with the `SurfaceView` as the object and the generation (`UInt64`) under
`Ghostty.Notification.AutocompleteGenerationKey`. GTK ignores the action
for now.

## Acceptance: CSI 7705 ~ (terminal to shell)

```
ESC [ 7705 ~ <percent-encoded text> BEL
```

The encoding is the same as the OSC payload's. `ghostty_surface_autocomplete_accept`
first validates the text and **rejects** it (it does not strip) if any of
these is true:

- it is empty or longer than 4096 bytes
- it is not valid UTF-8
- it contains a C0 control (< 0x20), DEL, a C1 control (U+0080-U+009F),
  U+2028, U+2029, U+202A-U+202E or U+2066-U+2069

It then writes the sequence to the pty through the surface IO queue, the
same path key input uses, so readonly mode blocks it.

In the shell, the zle widget `_ghostty_ac_accept` is bound to `\e[7705~`
in the `emacs`, `viins` and `vicmd` keymaps. It works in these steps:

1. Reads the payload one key at a time with `read -k 1 -t 0.2`, up to the
   BEL. This differs from the plan's `read -d $'\a'`: reading through zle's
   key path also sees bytes that zle has already buffered. Past 12288
   encoded characters it keeps draining up to the BEL and then discards
   everything, so leftover payload is never taken as keystrokes.
2. Percent-decodes the payload and refuses any control character again.
3. Finds the current token itself: the last word of `${(z)LBUFFER}`. The
   token is empty if LBUFFER is empty, ends in whitespace, or ends in an
   operator (`; | & ( ) < >`). An operator is never deleted.
4. Replaces the token with the text. The text goes in raw if it matches
   `[A-Za-z0-9_./:@%+=,-]+`; otherwise it is quoted with `${(q)}`.
5. Sets `LBUFFER`, which puts the cursor at the end of the inserted text,
   and calls `zle redisplay`. RBUFFER is untouched.

The widget never calls `accept-line` and never inserts a newline.

## Security model

- Every report is untrusted. A program can print OSC 7704 with
  `cat evil.txt`. The caps, the prompt-input gate, and the rate limit
  bound what it can do. The buffer is stored as bytes and returned only
  through the C API, as a match prefix. It is never executed, inserted,
  or interpreted.
- Acceptance cannot run anything. The terminal sends no CR or LF, the
  accept text is validated, the shell computes the replaced range itself
  (so a spoofed report cannot cause over-deletion), and the text is
  shell-quoted.
- Overload is bounded: 8 KiB per OSC, 4 KiB stored per surface, and 200
  reports per second per surface.

## Tests

- `zig build test -Dtest-filter=7704`: parser tests (happy path, ST
  terminator, truncated flag, encoded `;`/`%` round trip, missing
  fields, bad version, malformed numbers/keymaps/escapes/duplicates,
  oversized payload, larger than the fixed buffer, no allocator).
- `zig build test -Dtest-filter=autocomplete`: surface state, rate limit,
  accept-text validation, accept-sequence encoding, and config
  `autocomplete = true` implying the shell feature.
- `zig build test -Dtest-filter="setup features"`: `GHOSTTY_SHELL_FEATURES`
  carries `autocomplete`.
- `zsh -f test/slimer/zsh-autocomplete.zsh src/shell-integration/zsh/ghostty-integration [emacs|vi]`:
  drives a real interactive zsh through `zpty`. It checks the emitted
  OSC, token replacement, quoting, rejection of an encoded newline,
  dedupe on redraw, and that nothing runs before Enter.
