# Slimer PowerShell integration

> **Untested.** Everything in this folder was written without access to
> PowerShell or the .NET SDK, and none of it has run yet. Treat it as a
> first draft to test on Windows: run the Pester tests, then try the module
> by hand in a Slimer (or Ghostty) window.

`slimer.psm1` is a PowerShell module that gives Slimer what the zsh
integration gives it on macOS:

| Feature | Sequence | Notes |
|---|---|---|
| Prompt marks | OSC 133 A/B/C/D | Wraps your `prompt` function (never replaces it) and `PSConsoleHostReadLine`. |
| Working directory | OSC 7 `kitty-shell-cwd://<host><path>` | FileSystem locations only. `C:\Users\me` is sent as `/C:/Users/me`. UNC paths are not sent. |
| Title | OSC 2 | Only with `title` in `GHOSTTY_SHELL_FEATURES`: the directory name at the prompt, the command line while it runs. |
| Shell report | OSC 7706 (Slimer private) | `shell=pwsh;version=…;edition=Core\|Desktop;os=windows\|macos\|linux`. Sent on load and at every prompt. |
| Autocomplete | OSC 7704 reports, accept chords | Only with `autocomplete` in `GHOSTTY_SHELL_FEATURES`, pwsh 7.2+, PSReadLine 2.2+, and a built `SlimerPredictor.dll`. |

Requirements: PowerShell 7.2+ with PSReadLine 2.2+ (the defaults in current
pwsh). Windows PowerShell 5.1 gets the marks, OSC 7, the title and the
shell report, but no autocomplete.

## Loading it

The module only activates when `$env:TERM_PROGRAM -eq 'ghostty'` or
`$env:GHOSTTY_RESOURCES_DIR` is set, the host is the normal console host,
and output is not redirected. `$env:SLIMER_PWSH_INTEGRATION = '0'` turns it
off. Anywhere else, importing it only defines functions.

Load it **after** anything else that sets your prompt (oh-my-posh,
starship, posh-git), because it wraps whatever `prompt` exists when it
loads.

From your profile (`$PROFILE`), as the last line:

```powershell
if ($env:GHOSTTY_RESOURCES_DIR) {
    Import-Module (Join-Path $env:GHOSTTY_RESOURCES_DIR 'shell-integration/powershell/slimer.psm1')
}
```

Or have the terminal inject it (the Windows host's shell profile does this,
see `docs/slimer/WINDOWS.md`). `-NoExit -Command` runs after your profile,
so the order above holds:

```
pwsh.exe -NoLogo -NoExit -Command "Import-Module '<resources>\shell-integration\powershell\slimer.psm1'"
```

Check what is active with `Get-SlimerIntegrationStatus`. `Remove-Module
slimer` restores your prompt, `PSConsoleHostReadLine`, key bindings and
PSReadLine's prediction source.

## How the marks are written

- **A, D, OSC 7, title, 7706:** the module's `prompt` function writes them
  with `[Console]::Write` *before* calling your original prompt, so prompts
  that print with `Write-Host` are still inside the A mark. Your prompt's
  return value gets **B** appended. Your prompt sees the real `$?` (the
  module re-creates a failed `$?` with an ignored `Write-Error`, the trick
  VS Code's shell integration uses), and `$LASTEXITCODE` is restored after
  your prompt runs, so prompts that run `git` do not change it.
- **C:** written from a wrapper around `PSConsoleHostReadLine`, the
  function the console host calls to read a command line. PSReadLine
  returns from it only after the line was accepted, rendered, and followed
  by a newline. This is more robust than an `Enter` key handler:
  - It fires exactly once per accepted line, whatever accepted it: Enter,
    Ctrl+Enter, `AcceptAndGetNext`, vi mode, or your own handler.
  - It never fires for a line PSReadLine keeps editing (an incomplete
    statement that continues on the next line, a failed
    `CommandValidationHandler`). An Enter handler would have to write C
    *before* `AcceptLine()` without knowing whether the line is accepted,
    and before PSReadLine's final render, so the mark would land in the
    wrong place.
  - It does not take the Enter key from you or from other modules.
  VS Code's PowerShell shell integration uses the same hook.
- **D exit code:** 0 when `$?` is true. When `$?` is false: `$LASTEXITCODE`
  if it is non-zero and either changed since the command started or no new
  error record appeared (native commands fail without an `ErrorRecord`);
  otherwise 1 (a cmdlet or script failure). An empty line writes no C, so
  the next prompt writes no D, like zsh.

## Shell self-report (OSC 7706)

```
ESC ] 7706 ; shell=pwsh ; version=7.4.6 ; edition=Core ; os=windows BEL
```

(Written without spaces.) A Slimer private OSC for the Windows status bar's
shell-type indicator. The Slimer core does not parse it yet. Ghostty
ignores OSCs it does not know, so sending it is harmless. Keys are
lowercase letters; values keep only `[A-Za-z0-9._+-]` and at most 64
characters. Known keys: `shell` (`pwsh`, `bash`, `zsh`, `cmd`, …),
`version`, `edition`, `os`, `distro` (WSL). It is untrusted data: the host
may show it, never act on it. Not to be confused with `CSI 7706 ~` (the
line-accept sequence in the in-progress autocomplete work).

Equivalents for other shells, for the README of the Windows host:

**WSL bash** (`~/.bashrc`):

```bash
if [ -n "$WSL_DISTRO_NAME" ]; then
  __slimer_report() {
    printf '\033]7706;shell=bash;version=%s;os=linux;distro=%s\007' \
      "$(printf %s "${BASH_VERSION%%(*}" | tr -cd 'A-Za-z0-9._+-')" \
      "$(printf %s "$WSL_DISTRO_NAME" | tr -cd 'A-Za-z0-9._+-')"
  }
  PROMPT_COMMAND="__slimer_report${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
```

**WSL zsh** (`~/.zshrc`):

```zsh
if [[ -n $WSL_DISTRO_NAME ]]; then
  __slimer_report() {
    builtin print -rn -- $'\e]7706;shell=zsh;version='"${ZSH_VERSION//[^A-Za-z0-9._+-]}"';os=linux;distro='"${WSL_DISTRO_NAME//[^A-Za-z0-9._+-]}"$'\a'
  }
  precmd_functions+=(__slimer_report)
fi
```

**cmd.exe** (the `PROMPT` variable; `$E` is ESC and `$E\` is ST). Set it per
user with `setx PROMPT "..."`, or have the Windows host set `PROMPT` in the
environment of cmd tabs it launches:

```
$E]7706;shell=cmd;os=windows$E\$E]133;A$E\$P$G$E]133;B$E\
```

cmd has no hook before or after a command, so it gets A and B but no C or
D (no exit codes, no command durations).

## Autocomplete

### Capturing the buffer: a predictor

PSReadLine has no "buffer changed" event. The options:

| Option | Verdict |
|---|---|
| `Set-PSReadLineKeyHandler` on every key | Rejected. Takes over every binding (yours and other modules'), misses paste, history recall, undo, `Replace` from other handlers, and every function bound to a key we did not list. |
| `PSConsoleHostReadLine` override | Runs once per line, not per edit. |
| `CommandValidationHandler`, `AddToHistoryHandler` | Run on Enter only. |
| `ViModeChangeHandler` | Fires on vi mode changes only. |
| Polling `GetBufferState` from a timer | PSReadLine is not thread-safe; costs CPU while idle. |
| **`ICommandPredictor`** (PowerShell 7.2+ subsystem) | **Chosen.** PSReadLine calls `GetSuggestion` on every edit of the line and hands it the parsed input. It needs a compiled .NET assembly. |

`SlimerPredictor/` is that assembly: a predictor that writes one OSC 7704
report per edit and returns no suggestions. Build it with the .NET SDK
(installed with Visual Studio 2022):

```
cd src\shell-integration\powershell\SlimerPredictor
dotnet build -c Release
copy bin\Release\net6.0\SlimerPredictor.dll ..\
```

The module loads `SlimerPredictor.dll` from its own folder (or from
`SlimerPredictor/bin/Release/net6.0/`) with `Add-Type`, registers it with
`SubsystemManager`, and adds `Plugin` to PSReadLine's `PredictionSource`
(`None` → `Plugin`, `History` → `HistoryAndPlugin`; restored on removal).
The predictor never suggests anything, so nothing changes on screen. If the
DLL is missing or fails to load, autocomplete is silently off.

An alternative that avoids the build step: `Add-Type -TypeDefinition` on
`SlimerPredictor.cs` at load (in-process Roslyn). It costs roughly half a
second at every shell start, so it is not done; it could be cached with
`-OutputAssembly`.

Limits of the predictor hook (from PSReadLine's `Prediction.cs` and
PowerShell's `PredictionContext`):

- It is not called for an empty or whitespace-only buffer, nor for input
  that contains a newline. To avoid a stale popup after you delete
  everything, the module wraps the *built-in* functions bound to
  Backspace, Ctrl+Backspace, Escape, Ctrl+u and Ctrl+w: after the original
  function runs, it reports an empty or multi-line buffer from PowerShell.
  Custom handlers on those keys are left alone. Multi-line editing is
  otherwise not reported.
- `PredictionContext.CursorPosition` is always the end of the input. The
  predictor asks PSReadLine for the real cursor with the public
  `PSConsoleReadLine.GetBufferState` (via reflection) and uses it only if
  PSReadLine's buffer equals the input it was given. Verify on Windows
  whether PSReadLine queries predictors when the cursor is not at the end.
- Moving the cursor without editing does not trigger a query.
- `GetSuggestion` runs on a thread-pool thread while PSReadLine waits about
  20 ms for predictors. The report is one `Console.Out.Write`, which is
  synchronized, so it cannot split PSReadLine's own output.

### Wire format

Matches `docs/slimer/AUTOCOMPLETE.md` plus the in-progress protocol changes:

```
ESC ] 7704 ; v=1 ; n=<token> ; p=<pid> ; [d=1 ;] c=<cursor> ; k=<keymap> ; t=<0|1> ; b=<payload> BEL
```

- `n=`: the per-surface secret. The module reads
  `$env:SLIMER_AUTOCOMPLETE_TOKEN` once at load, keeps it in module scope,
  and deletes the variable so child processes never see it. It must be 32
  lowercase hex characters; otherwise `n=` is omitted.
- `p=`: `$PID`. On Windows there is no process group, so the core's
  foreground-group check needs a Windows equivalent (see `WINDOWS.md`).
- `d=1`: a deactivate report, written when PSReadLine returns a line
  (accepted or cancelled), before OSC 133 C.
- `c=`: cursor in code points (zsh's `$CURSOR` is a character index).
- `k=`: `emacs` for PSReadLine's Emacs and Windows edit modes, `viins` or
  `vicmd` in vi mode.
- `b=`: the buffer, truncated to 4096 UTF-8 bytes on a code point boundary
  (then `t=1`), percent-encoded like zsh: `%`, `;`, C0 and DEL as `%XX`.
  Two additions the core decodes the same way: C1 controls are encoded too,
  and when `[Console]::OutputEncoding` is not UTF-8 (the Windows default is
  the OEM code page) every non-ASCII character is sent as `%XX` UTF-8 bytes
  so nothing turns into `?`.
- Reports are de-duplicated on (cursor, keymap, buffer); the cache is reset
  at every prompt.

All of this lives in a few functions so the format is easy to change:
`New-SlimerAutocompleteReport`, `ConvertTo-SlimerPercentEncoding`,
`ConvertFrom-SlimerPercentEncoding`, `Read-SlimerAcceptPayloadFrom` in
`slimer.psm1`, and `SlimerReporter.BuildReport` / `PercentEncode` in
`SlimerPredictor.cs` (keep the two in sync).

### Accepting a completion

On macOS the terminal sends `ESC [ 7705 ~ <payload> BEL` and a zsh widget
bound to `\e[7705~` reads it. That does not work for PowerShell on
Windows:

- Under ConPTY, the terminal writes VT *input* to conhost, which parses it
  into Win32 `KEY_EVENT` records. PSReadLine reads those with
  `Console.ReadKey`; it does not enable `ENABLE_VIRTUAL_TERMINAL_INPUT`.
  conhost only turns the CSI sequences it knows (arrows, `CSI 24 ~` for
  F12, modifiers) into keys. `CSI 7705 ~` is not one of them: it is
  dropped or arrives as separate characters, and
  `Set-PSReadLineKeyHandler` cannot bind it either way.
- On macOS/Linux pwsh, .NET's console reader decodes escape sequences from
  terminfo; an unknown one also arrives as separate keys.

**Chosen design: a reserved chord plus an in-band payload.**

1. The Windows host sends the key **Ctrl+Alt+Shift+F12** (token accept)
   or **Ctrl+Alt+Shift+F11** (whole-line accept, the in-progress
   `CSI 7706 ~`) immediately followed, in the **same write**, by the
   payload and BEL: `ESC [ 24 ; 8 ~ %67%69%74 BEL` (xterm encoding: 24 =
   F12, 23 = F11, modifier 8 = 1 + Shift 1 + Alt 2 + Ctrl 4). If the host
   has switched ConPTY to win32-input-mode (`CSI ? 9001 h`), it must send
   the chord in that encoding instead (`VK_F12`, all three modifiers).
2. The module binds those chords with `Set-PSReadLineKeyHandler`. The
   handler reads the payload with `[Console]::ReadKey($true)` until BEL.
   - It waits at most 50 ms for the first character. Because the host
     writes chord and payload together, the payload is already queued; a
     person pressing the chord gets an immediate no-op and loses no keys.
   - Overall deadline 1 s. Only `%` and hex digits are accepted (the new
     core hex-encodes every byte), so anything else aborts. Past 12288
     characters it drains to the BEL and discards everything.
3. The text is decoded (strict UTF-8), checked again (no controls, bidi
   overrides, line separators, private-use or unassigned code points),
   and the module computes the token to replace **itself** with
   PowerShell's own tokenizer on the text before the cursor
   (`[PSConsoleReadLine]::GetBufferState`). The token is empty after
   whitespace or an operator, so an operator is never deleted.
4. Plain words go in raw; anything else is single-quoted with every kind
   of single quote doubled. One `[PSConsoleReadLine]::Replace(start,
   length, text)` call makes the edit (one undo step), then the cursor
   moves to the end of the inserted text. It never calls `AcceptLine` and
   never inserts a newline.

Tradeoffs:

- The chord is taken from the user. Ctrl+Alt+Shift+F11/F12 are about as
  unlikely as chords get; change `$script:AcAcceptChords` (and the host)
  if they collide.
- If the chord arrives somewhere other than PSReadLine (a `Read-Host`, a
  native program), that program sees an F12 key and the payload as typed
  `%`/hex characters, never a control character or Enter. The core only
  sends an accept when its state says the shell is at prompt input.
- Rejected alternatives: a temp file named in an environment variable (the
  host cannot change a running shell's environment, so the path must be
  fixed or announced over OSC; it adds file I/O, cleanup and races, and a
  file other processes can write); reading the payload from a side channel
  (named pipe) owned by the host (more moving parts, same trust).

**Core change needed on Windows:** `ghostty_surface_autocomplete_accept`
writes `CSI 7705 ~`; on Windows it must write the chord form above (for
example a comptime switch on the target OS in `src/autocomplete/`, owned
by the autocomplete work). Until then the Windows host can write the same
bytes itself through its key-input path.

## Security

- Nothing received from the terminal is executed. No `Invoke-Expression`,
  no network access, no `AcceptLine` in the accept path.
- Paths and titles have control characters removed before they are put
  in an OSC, so a directory name cannot inject its own escape sequence.
- The accept text is only ever inserted into the edit buffer, as a single
  quoted argument.

## Tests

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser   # once
Invoke-Pester -Path src/shell-integration/powershell/tests
```

`tests/slimer.Tests.ps1` covers the pure functions: percent encoding and
decoding, OSC builders, path to OSC 7 URI, title, exit code choice, UTF-8
truncation and cursor counting, the report format, the safe-text check,
token ranges, quoting, accept edits and the payload reader. The parts that
need a real console (prompt wrapping, the predictor, the accept chord)
need a manual check:

1. In a Slimer/Ghostty window, `Import-Module` the module and run
   `Get-SlimerIntegrationStatus`.
2. Run `cmd /c exit 3`, then `Get-Item nope`, then `echo ok`; the status
   bar's last-command chip should show 3, 1 and success.
3. `cd` into a directory with a space in its name; the cwd chip should
   update.
4. With `autocomplete = true` and the DLL built, type `git ch` and watch
   the popup; delete everything with Backspace and check it hides.
