#Requires -Version 5.1
# slimer: Slimer shell integration for PowerShell.
#
# UNTESTED. This module was written without access to PowerShell (no pwsh
# was available where it was authored). Read README.md in this folder and
# run tests/slimer.Tests.ps1 with Invoke-Pester before relying on it.
#
# Targets PowerShell 7.2+ with PSReadLine 2.2+. Windows PowerShell 5.1
# gets the prompt marks (OSC 133), OSC 7, the title and the shell report,
# but no autocomplete.
#
# What it does (see docs/slimer/WINDOWS.md and docs/slimer/AUTOCOMPLETE.md):
#   - OSC 133 A/B/C/D prompt marks. The user's prompt function is wrapped,
#     never replaced; C is written from a PSConsoleHostReadLine wrapper.
#   - OSC 7 working directory (kitty-shell-cwd) for FileSystem locations.
#   - OSC 2 title when `title` is in GHOSTTY_SHELL_FEATURES.
#   - OSC 7706 shell self-report (Slimer private): shell, version, edition, os.
#   - Autocomplete (`autocomplete` in GHOSTTY_SHELL_FEATURES): OSC 7704
#     buffer reports from a compiled ICommandPredictor (SlimerPredictor.dll)
#     and an accept key handler that edits the buffer with
#     [PSConsoleReadLine]::Replace. Without the DLL autocomplete is off.
#
# Security rules (docs/slimer/CONVENTIONS.md): nothing received from the
# terminal is ever executed. There is no Invoke-Expression, no network
# access, and the accept handler never calls AcceptLine.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

$script:Esc = [string][char]0x1b
$script:Bel = [string][char]0x07

# Autocomplete wire format limits (keep in sync with AUTOCOMPLETE.md).
$script:AcMaxBufferBytes = 4096
$script:AcMaxAcceptBytes = 4096
# Encoded accept payload: 3 characters per byte, then keep draining to the
# BEL up to this many characters before giving up.
$script:AcMaxPayloadChars = 3 * 4096
$script:AcDrainLimitChars = 65536
# Overall read deadline for an accept payload, and how long to wait for the
# first payload character (a real key press of the chord has no payload).
$script:AcReadDeadlineMs = 1000
$script:AcFirstKeyWaitMs = 50
# Per-surface secret handed over by the core in SLIMER_AUTOCOMPLETE_TOKEN.
$script:AcTokenPattern = '^[0-9a-f]{32}\z'

# Chords the Windows host sends instead of CSI 7705 ~ / CSI 7706 ~, because
# ConPTY delivers input to PSReadLine as key events and an unknown CSI never
# arrives as one key. See README.md, "Accepting a completion".
$script:AcAcceptChords = [ordered]@{
    token = 'Ctrl+Alt+Shift+F12'
    line  = 'Ctrl+Alt+Shift+F11'
}

# Keys whose built-in function can leave the buffer empty or whitespace-only.
# PSReadLine never queries predictors for such a buffer, so these are wrapped
# to send that state from PowerShell. Only built-in bindings are wrapped.
# Handlers are literal script blocks (not GetNewClosure(), which would bind
# them to a new dynamic module that cannot see this module's functions).
# Ctrl+c is deliberately absent: CancelLine unwinds ReadLine, and the
# PSConsoleHostReadLine wrapper already sends a deactivate for it.
$script:AcEmptyingHandlers = [ordered]@{
    'Backspace'      = { param($key, $arg) Invoke-SlimerWrappedKey -Chord 'Backspace' -Key $key -Arg $arg }
    'Ctrl+Backspace' = { param($key, $arg) Invoke-SlimerWrappedKey -Chord 'Ctrl+Backspace' -Key $key -Arg $arg }
    'Escape'         = { param($key, $arg) Invoke-SlimerWrappedKey -Chord 'Escape' -Key $key -Arg $arg }
    'Ctrl+u'         = { param($key, $arg) Invoke-SlimerWrappedKey -Chord 'Ctrl+u' -Key $key -Arg $arg }
    'Ctrl+w'         = { param($key, $arg) Invoke-SlimerWrappedKey -Chord 'Ctrl+w' -Key $key -Arg $arg }
}

$script:AcAcceptHandlers = @{
    token = { param($key, $arg) Invoke-SlimerAcceptKey -Mode token }
    line  = { param($key, $arg) Invoke-SlimerAcceptKey -Mode line }
}

# ---------------------------------------------------------------------------
# Pure helpers (covered by tests/slimer.Tests.ps1)
# ---------------------------------------------------------------------------

function Remove-SlimerControlChars {
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    # C0, DEL and C1. A directory name must never smuggle its own escape
    # sequence into ours.
    return ($Text -replace '[\x00-\x1F\x7F-\x9F]', '')
}

function Test-SlimerFeature {
    param(
        [AllowNull()][AllowEmptyString()][string]$Features,
        [Parameter(Mandatory)][string]$Name
    )
    if ([string]::IsNullOrEmpty($Features)) { return $false }
    foreach ($f in ($Features -split ',')) {
        if ($f.Trim() -ceq $Name) { return $true }
    }
    return $false
}

function New-SlimerOsc {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Body)
    return $script:Esc + ']' + $Body + $script:Bel
}

function Get-SlimerPromptMark {
    param(
        [Parameter(Mandatory)][ValidateSet('A', 'B', 'C', 'D')][string]$Kind,
        [AllowNull()]$ExitCode = $null
    )
    if ($Kind -eq 'D' -and $null -ne $ExitCode) {
        return New-SlimerOsc ('133;D;' + [int]$ExitCode)
    }
    return New-SlimerOsc ('133;' + $Kind)
}

# The exit code for OSC 133 D.
#  - $? true: 0, even if $LASTEXITCODE is left over from an earlier native
#    command.
#  - $? false and $LASTEXITCODE non-zero, and either it changed since the
#    command started or no new ErrorRecord appeared (a native failure adds
#    no ErrorRecord unless $PSNativeCommandUseErrorActionPreference is on):
#    $LASTEXITCODE.
#  - Otherwise (cmdlet or script failure): 1.
function Get-SlimerExitCode {
    param(
        [bool]$Success,
        [AllowNull()]$LastExitCode,
        [AllowNull()]$PreviousLastExitCode,
        [bool]$NewErrorRecord
    )
    if ($Success) { return 0 }
    $code = $LastExitCode -as [int]
    if ($null -ne $code -and $code -ne 0) {
        $changed = ($null -eq $PreviousLastExitCode) -or ($code -ne ($PreviousLastExitCode -as [int]))
        if ($changed -or -not $NewErrorRecord) { return $code }
    }
    return 1
}

# Percent-encode a URI path for the `file://` form: unreserved characters,
# '/' and ':' stay; everything else becomes %XX of its UTF-8 bytes.
function ConvertTo-SlimerUriPath {
    param([AllowEmptyString()][string]$Path)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($Path)) {
        $c = [char]$b
        if (($b -lt 0x80) -and ($c -match '[A-Za-z0-9\-._~/:]')) {
            [void]$sb.Append($c)
        }
        else {
            [void]$sb.AppendFormat('%{0:X2}', [int]$b)
        }
    }
    return $sb.ToString()
}

# A filesystem path as an OSC 7 URI.
#  - Default scheme kitty-shell-cwd: the path is sent raw (Ghostty parses this
#    scheme with `raw_path`, see src/termio/stream_handler.zig, exactly like
#    the zsh integration does). Percent-encoding it would show up literally.
#  - Scheme file: the path is percent-encoded.
# Windows drive paths become /C:/Users/me. UNC and \\?\ paths are not
# reported (their server would look like a remote host). Returns $null when
# nothing should be sent.
function ConvertTo-SlimerOsc7Uri {
    param(
        [AllowNull()][AllowEmptyString()][string]$ProviderPath,
        [AllowNull()][AllowEmptyString()][string]$HostName,
        [ValidateSet('kitty', 'file')][string]$Scheme = 'kitty'
    )
    $p = Remove-SlimerControlChars $ProviderPath
    $h = (Remove-SlimerControlChars $HostName) -replace '[/\\@\s]', ''
    if ([string]::IsNullOrEmpty($p)) { return $null }
    if ($p.StartsWith('\\') -or $p.StartsWith('//')) { return $null }
    if ($p -match '^[A-Za-z]:') {
        $p = '/' + ($p -replace '\\', '/')
        if ($p -match '^/[A-Za-z]:\z') { $p += '/' }
    }
    elseif (-not $p.StartsWith('/')) {
        return $null
    }
    if ($Scheme -eq 'file') {
        return 'file://' + $h + (ConvertTo-SlimerUriPath $p)
    }
    return 'kitty-shell-cwd://' + $h + $p
}

function New-SlimerOsc7 {
    param([AllowNull()][string]$ProviderPath, [AllowNull()][string]$HostName)
    $uri = ConvertTo-SlimerOsc7Uri -ProviderPath $ProviderPath -HostName $HostName
    if ($null -eq $uri) { return '' }
    return New-SlimerOsc ('7;' + $uri)
}

# The title for a directory: its leaf name, '~' for the home directory, the
# path itself for a root (C:\ or /).
function Get-SlimerDirectoryTitle {
    param([AllowNull()][AllowEmptyString()][string]$ProviderPath, [AllowNull()][string]$HomePath)
    if ([string]::IsNullOrEmpty($ProviderPath)) { return '' }
    $trimmed = $ProviderPath.TrimEnd('\', '/')
    if (-not [string]::IsNullOrEmpty($HomePath) -and
        [string]::Equals($trimmed, $HomePath.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase)) {
        return '~'
    }
    if ($trimmed.Length -eq 0 -or $trimmed -match '^[A-Za-z]:\z') { return $ProviderPath }
    $i = $trimmed.LastIndexOfAny([char[]]@('\', '/'))
    if ($i -lt 0) { return $trimmed }
    return $trimmed.Substring($i + 1)
}

function New-SlimerTitleSequence {
    param([AllowNull()][AllowEmptyString()][string]$Title)
    $t = Remove-SlimerControlChars $Title
    if ($t.Length -gt 256) { $t = $t.Substring(0, 256) }
    return New-SlimerOsc ('2;' + $t)
}

# OSC 7706 shell self-report (Slimer private; Ghostty ignores unknown OSCs).
#   ESC ] 7706 ; shell=pwsh ; version=7.4.6 ; edition=Core ; os=windows BEL
# Keys are [a-z]+; values keep only [A-Za-z0-9._+-] and at most 64 chars.
function New-SlimerShellReport {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Fields)
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $Fields.Keys) {
        $key = [string]$k
        if ($key -cnotmatch '^[a-z]{1,16}\z') { continue }
        $value = ([string]$Fields[$k]) -replace '[^A-Za-z0-9._+\-]', ''
        if ($value.Length -gt 64) { $value = $value.Substring(0, 64) }
        $parts.Add($key + '=' + $value)
    }
    return New-SlimerOsc ('7706;' + ($parts -join ';'))
}

function Get-SlimerShellReportFields {
    $os = 'windows'
    $isWin = Get-Variable -Name IsWindows -ValueOnly -ErrorAction Ignore
    $isMac = Get-Variable -Name IsMacOS -ValueOnly -ErrorAction Ignore
    $isLinux = Get-Variable -Name IsLinux -ValueOnly -ErrorAction Ignore
    if ($isMac) { $os = 'macos' }
    elseif ($isLinux) { $os = 'linux' }
    elseif ($null -ne $isWin -and -not $isWin) { $os = 'unknown' }
    $edition = $PSVersionTable.PSEdition
    if ([string]::IsNullOrEmpty($edition)) { $edition = 'Desktop' }
    return [ordered]@{
        shell   = 'pwsh'
        version = [string]$PSVersionTable.PSVersion
        edition = $edition
        os      = $os
    }
}

# --- Autocomplete wire format ----------------------------------------------
# Everything that knows the OSC 7704 / accept format is in this block (and
# mirrored in SlimerPredictor/SlimerPredictor.cs). Adjust both together.

# Percent-encode like the zsh integration: '%', ';', C0 controls and DEL
# become %XX (uppercase hex); other characters pass through as UTF-8.
# Two additions, both decoded identically by the core (it decodes any %XX):
#  - C1 controls (U+0080-U+009F) are encoded too, so no 8-bit control can
#    ever reach the terminal's parser inside the OSC.
#  - With -AsciiOnly every non-ASCII character is sent as %XX of its UTF-8
#    bytes. Used when the console output encoding is not UTF-8 (the Windows
#    default is the OEM code page, which would turn them into '?').
function ConvertTo-SlimerPercentEncoding {
    param([AllowNull()][AllowEmptyString()][string]$Text, [switch]$AsciiOnly)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $sb = [System.Text.StringBuilder]::new($Text.Length + 16)
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        $code = [int]$c
        $n = 1
        if ([char]::IsHighSurrogate($c) -and ($i + 1) -lt $Text.Length -and [char]::IsLowSurrogate($Text[$i + 1])) {
            $n = 2
        }
        if ($n -eq 1 -and ($code -lt 0x20 -or $code -eq 0x7F -or $code -eq 0x25 -or $code -eq 0x3B)) {
            [void]$sb.AppendFormat('%{0:X2}', $code)
        }
        elseif (($n -eq 1 -and $code -ge 0x80 -and $code -le 0x9F) -or ($AsciiOnly -and ($n -eq 2 -or $code -ge 0x80))) {
            foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($Text.Substring($i, $n))) {
                [void]$sb.AppendFormat('%{0:X2}', [int]$b)
            }
        }
        else {
            [void]$sb.Append($Text, $i, $n)
        }
        $i += $n
    }
    return $sb.ToString()
}

# Decode %XX escapes (either hex case) and raw characters into a string.
# The bytes must be valid UTF-8. Returns $null on a malformed escape or
# invalid UTF-8.
function ConvertFrom-SlimerPercentEncoding {
    param([AllowNull()][AllowEmptyString()][string]$Payload)
    if ($null -eq $Payload) { return $null }
    $bytes = [System.Collections.Generic.List[byte]]::new()
    $i = 0
    while ($i -lt $Payload.Length) {
        $c = $Payload[$i]
        if ($c -eq [char]'%') {
            if (($i + 2) -ge $Payload.Length) { return $null }
            $hex = $Payload.Substring($i + 1, 2)
            if ($hex -notmatch '^[0-9A-Fa-f]{2}\z') { return $null }
            $bytes.Add([Convert]::ToByte($hex, 16))
            $i += 3
            continue
        }
        $n = 1
        if ([char]::IsHighSurrogate($c) -and ($i + 1) -lt $Payload.Length) { $n = 2 }
        foreach ($b in [System.Text.Encoding]::UTF8.GetBytes($Payload.Substring($i, $n))) { $bytes.Add($b) }
        $i += $n
    }
    $strict = [System.Text.UTF8Encoding]::new($false, $true)
    try {
        return $strict.GetString($bytes.ToArray())
    }
    catch {
        return $null
    }
}

# UTF-8 length of one UTF-16 unit or surrogate pair.
function Get-SlimerUtf8Length {
    param([int]$Code, [int]$Units)
    if ($Units -eq 2) { return 4 }
    if ($Code -lt 0x80) { return 1 }
    if ($Code -lt 0x800) { return 2 }
    return 3
}

# Truncate to at most MaxBytes of UTF-8, on a code point boundary. zsh cuts
# raw bytes; a .NET string cannot hold half a code point, so this cuts at
# the last whole code point instead. Sets Truncated when anything was cut.
function Limit-SlimerUtf8 {
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$MaxBytes = 4096)
    if ([string]::IsNullOrEmpty($Text)) {
        return [pscustomobject]@{ Text = ''; Truncated = $false }
    }
    $bytes = 0
    $i = 0
    while ($i -lt $Text.Length) {
        $c = $Text[$i]
        $n = 1
        if ([char]::IsHighSurrogate($c) -and ($i + 1) -lt $Text.Length -and [char]::IsLowSurrogate($Text[$i + 1])) {
            $n = 2
        }
        $len = Get-SlimerUtf8Length -Code ([int]$c) -Units $n
        if (($bytes + $len) -gt $MaxBytes) {
            return [pscustomobject]@{ Text = $Text.Substring(0, $i); Truncated = $true }
        }
        $bytes += $len
        $i += $n
    }
    return [pscustomobject]@{ Text = $Text; Truncated = $false }
}

# Number of code points in the first $Length UTF-16 units of $Text. zsh's
# $CURSOR is a character index, so the report uses code points too.
function Get-SlimerCodePointCount {
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$Length)
    if ([string]::IsNullOrEmpty($Text) -or $Length -le 0) { return 0 }
    if ($Length -gt $Text.Length) { $Length = $Text.Length }
    $count = 0
    for ($i = 0; $i -lt $Length; $i++) {
        if ([char]::IsLowSurrogate($Text[$i]) -and $i -gt 0 -and [char]::IsHighSurrogate($Text[$i - 1])) { continue }
        $count++
    }
    return $count
}

# Build one OSC 7704 report.
#   ESC ] 7704 ; v=1 ; n=<token> ; p=<pid> ; [d=1 ;] c=<cursor> ; k=<keymap> ; t=<0|1> ; b=<payload> BEL
# n= is omitted when no token was handed over (older cores ignore unknown
# keys; newer cores drop reports without a valid token). b= must stay last.
function New-SlimerAutocompleteReport {
    param(
        [AllowNull()][AllowEmptyString()][string]$Buffer,
        [int]$Cursor = 0,
        [string]$Keymap = 'emacs',
        [AllowNull()][AllowEmptyString()][string]$Token,
        [int]$ProcessId = 0,
        [switch]$AsciiOnly,
        [switch]$Deactivate
    )
    if ($null -eq $Buffer) { $Buffer = '' }
    if ($Keymap -notmatch '^[A-Za-z0-9_-]{1,16}\z') { $Keymap = 'other' }
    $fields = [System.Collections.Generic.List[string]]::new()
    $fields.Add('v=1')
    if (-not [string]::IsNullOrEmpty($Token)) { $fields.Add('n=' + $Token) }
    if ($ProcessId -gt 0) { $fields.Add('p=' + $ProcessId) }
    if ($Deactivate) {
        $fields.Add('d=1')
        $Buffer = ''
        $Cursor = 0
    }
    if ($Cursor -lt 0) { $Cursor = 0 }
    if ($Cursor -gt $Buffer.Length) { $Cursor = $Buffer.Length }
    $limited = Limit-SlimerUtf8 -Text $Buffer -MaxBytes $script:AcMaxBufferBytes
    $c = Get-SlimerCodePointCount -Text $Buffer -Length $Cursor
    $t = if ($limited.Truncated) { '1' } else { '0' }
    $fields.Add('c=' + $c)
    $fields.Add('k=' + $Keymap)
    $fields.Add('t=' + $t)
    $fields.Add('b=' + (ConvertTo-SlimerPercentEncoding -Text $limited.Text -AsciiOnly:$AsciiOnly))
    return New-SlimerOsc ('7704;' + ($fields -join ';'))
}

# --- end of wire format ----------------------------------------------------

# Accept-text safety check (defense in depth; the core checks too). Rejects,
# never strips: empty, over 4096 UTF-8 bytes, lone surrogates, or any code
# point in Cc, Cf (bidi controls, zero-width), Zl, Zp, Co or Cn.
function Test-SlimerSafeText {
    param([AllowNull()][AllowEmptyString()][string]$Text, [int]$MaxBytes = 4096)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    if ([System.Text.Encoding]::UTF8.GetByteCount($Text) -gt $MaxBytes) { return $false }
    $bad = @('Control', 'Format', 'LineSeparator', 'ParagraphSeparator', 'PrivateUse', 'OtherNotAssigned', 'Surrogate')
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ([char]::IsHighSurrogate($ch)) {
            if (($i + 1) -ge $Text.Length -or -not [char]::IsLowSurrogate($Text[$i + 1])) { return $false }
            $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($Text, $i)
            $i++
        }
        elseif ([char]::IsLowSurrogate($ch)) {
            return $false
        }
        else {
            $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        }
        if ($bad -contains [string]$cat) { return $false }
    }
    return $true
}

# True for tokens that a completion may replace: words, parameters,
# variables, strings, numbers and keywords. Operators (| ; & ( ) { } ,),
# redirections and newlines are never replaced.
function Test-SlimerWordToken {
    param($Token)
    if ($null -eq $Token) { return $false }
    $kind = [string]$Token.Kind
    $words = @('Generic', 'Identifier', 'Parameter', 'Variable', 'SplattedVariable',
        'StringLiteral', 'StringExpandable', 'Number')
    if ($words -contains $kind) { return $true }
    $keyword = [System.Management.Automation.Language.TokenFlags]::Keyword
    return (($Token.TokenFlags -band $keyword) -ne 0)
}

# The range a token completion replaces: the PowerShell token that ends at
# the cursor. Empty (Start = cursor, Length = 0) when the text before the
# cursor is empty, ends in whitespace, or ends in an operator. Computed
# here, never taken from the terminal, so a spoofed report cannot make the
# accept delete more than the current word.
function Get-SlimerTokenRange {
    param([AllowNull()][AllowEmptyString()][string]$Line, [int]$Cursor)
    if ($null -eq $Line) { $Line = '' }
    if ($Cursor -lt 0) { $Cursor = 0 }
    if ($Cursor -gt $Line.Length) { $Cursor = $Line.Length }
    $empty = [pscustomobject]@{ Start = $Cursor; Length = 0 }
    if ($Cursor -eq 0) { return $empty }
    $lbuf = $Line.Substring(0, $Cursor)
    if ([char]::IsWhiteSpace($lbuf[$lbuf.Length - 1])) { return $empty }
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($lbuf, [ref]$tokens, [ref]$errors)
    $last = $null
    foreach ($tok in $tokens) {
        if ([string]$tok.Kind -ne 'EndOfInput') { $last = $tok }
    }
    if ($null -eq $last) { return $empty }
    if ($last.Extent.EndOffset -ne $lbuf.Length) { return $empty }
    if (-not (Test-SlimerWordToken $last)) { return $empty }
    $start = $last.Extent.StartOffset
    return [pscustomobject]@{ Start = $start; Length = $Cursor - $start }
}

# Quote completion text as one PowerShell argument. Plain words go in raw;
# anything else is single-quoted with every kind of single quote doubled
# (PowerShell also treats U+2018-U+201B as single quotes).
function ConvertTo-SlimerShellWord {
    param([Parameter(Mandatory)][string]$Text)
    if ($Text -cmatch '^[A-Za-z0-9_./:\\~+=-]+\z') { return $Text }
    $escaped = [System.Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($Text)
    return "'" + $escaped + "'"
}

# The edit an accept makes, or $null to do nothing.
#  - token: replace the current token (Get-SlimerTokenRange) with the quoted text.
#  - line:  replace the whole line with the text, unquoted, only if the
#           cursor is at the end and the line is a prefix of the text
#           (history suggestions; mirrors the in-progress CSI 7706 ~).
function Get-SlimerAcceptEdit {
    param(
        [AllowNull()][AllowEmptyString()][string]$Line,
        [int]$Cursor,
        [AllowNull()][AllowEmptyString()][string]$Text,
        [ValidateSet('token', 'line')][string]$Mode = 'token'
    )
    if ($null -eq $Line) { $Line = '' }
    if (-not (Test-SlimerSafeText -Text $Text -MaxBytes $script:AcMaxAcceptBytes)) { return $null }
    if ($Mode -eq 'line') {
        if ($Cursor -ne $Line.Length) { return $null }
        if (-not $Text.StartsWith($Line, [StringComparison]::Ordinal)) { return $null }
        return [pscustomobject]@{ Start = 0; Length = $Line.Length; Replacement = $Text }
    }
    $range = Get-SlimerTokenRange -Line $Line -Cursor $Cursor
    return [pscustomobject]@{
        Start       = $range.Start
        Length      = $range.Length
        Replacement = (ConvertTo-SlimerShellWord -Text $Text)
    }
}

# Collect accept payload characters from a key source until BEL. $ReadKey
# returns the next [char], or $null when the deadline passed. Accepts only
# '%' and hex digits (the core hex-encodes every byte); anything else
# aborts. Past the size cap it keeps draining to the BEL, then discards
# everything. Returns the payload string or $null.
function Read-SlimerAcceptPayloadFrom {
    param([Parameter(Mandatory)][scriptblock]$ReadKey)
    $sb = [System.Text.StringBuilder]::new()
    $n = 0
    $overflow = $false
    while ($true) {
        $ch = & $ReadKey
        if ($null -eq $ch) { return $null }
        if ([char]$ch -eq [char]0x07) {
            if ($overflow) { return $null }
            return $sb.ToString()
        }
        if ([string]$ch -notmatch '^[%0-9A-Fa-f]\z') { return $null }
        $n++
        if ($n -gt $script:AcMaxPayloadChars) {
            $overflow = $true
            if ($n -gt $script:AcDrainLimitChars) { return $null }
            continue
        }
        [void]$sb.Append([char]$ch)
    }
}

# ---------------------------------------------------------------------------
# Runtime state
# ---------------------------------------------------------------------------

$script:State = @{
    Enabled            = $false
    Features           = ''
    HostName           = ''
    OriginalPrompt     = $null
    OriginalReadLine   = $null
    Executing          = $false
    LecAtStart         = $null
    ErrorMarker        = $null
    AcEnabled          = $false
    AcToken            = $null
    AcPredictor        = $false
    AcPredictorId      = $null
    AcBoundChords      = @()
    AcWrappedChords    = @()
    AcOldPredictionSrc = $null
    AcLastPsReport     = $null
}

function Write-SlimerRaw {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    try { [Console]::Write($Text) } catch { }
}

function Test-SlimerAsciiOnly {
    try { return ([Console]::OutputEncoding.CodePage -ne 65001) } catch { return $true }
}

function Get-SlimerKeymap {
    try {
        $mode = [string](Get-PSReadLineOption).EditMode
        if ($mode -eq 'Vi') {
            if ([Microsoft.PowerShell.PSConsoleReadLine]::InViCommandMode()) { return 'vicmd' }
            return 'viins'
        }
        # Emacs and Windows modes are both insert-style line editors.
        return 'emacs'
    }
    catch {
        return 'other'
    }
}

function Get-SlimerErrorMarker {
    if ($global:Error.Count -gt 0) { return $global:Error[0] }
    return $null
}

# Everything written before the user's prompt: D for the previous command,
# the shell report, OSC 7, the title, then A.
function Write-SlimerPromptStart {
    param([bool]$Success, [AllowNull()]$LastExitCode)
    $s = $script:State
    $out = [System.Text.StringBuilder]::new()
    if ($s.Executing) {
        $newError = -not [object]::ReferenceEquals((Get-SlimerErrorMarker), $s.ErrorMarker)
        $code = Get-SlimerExitCode -Success $Success -LastExitCode $LastExitCode `
            -PreviousLastExitCode $s.LecAtStart -NewErrorRecord $newError
        [void]$out.Append((Get-SlimerPromptMark -Kind D -ExitCode $code))
        $s.Executing = $false
    }
    # Re-sent at every prompt so the indicator is right again after a nested
    # shell (wsl, cmd) exits back to PowerShell.
    [void]$out.Append((New-SlimerShellReport -Fields (Get-SlimerShellReportFields)))
    $loc = $ExecutionContext.SessionState.Path.CurrentLocation
    if ($null -ne $loc -and $loc.Provider.Name -eq 'FileSystem') {
        [void]$out.Append((New-SlimerOsc7 -ProviderPath $loc.ProviderPath -HostName $s.HostName))
        if (Test-SlimerFeature -Features $s.Features -Name 'title') {
            $title = Get-SlimerDirectoryTitle -ProviderPath $loc.ProviderPath -HomePath $HOME
            [void]$out.Append((New-SlimerTitleSequence -Title $title))
        }
    }
    [void]$out.Append((Get-SlimerPromptMark -Kind A))
    Write-SlimerRaw $out.ToString()

    if ($s.AcEnabled) {
        $s.AcLastPsReport = $null
        if ($s.AcPredictor) {
            try {
                [Slimer.PowerShell.SlimerReporter]::Update((Get-SlimerKeymap), (Test-SlimerAsciiOnly))
                [Slimer.PowerShell.SlimerReporter]::ResetDedupe()
            }
            catch { }
        }
    }
}

# Called with the accepted line, after PSReadLine rendered it and moved to
# the next line: deactivate autocomplete, set the title, write C.
function Write-SlimerCommandStart {
    param([AllowNull()][AllowEmptyString()][string]$Line)
    $s = $script:State
    $out = [System.Text.StringBuilder]::new()
    if ($s.AcEnabled) {
        [void]$out.Append((New-SlimerAutocompleteReport -Deactivate -Token $s.AcToken -ProcessId $PID))
    }
    if (-not [string]::IsNullOrWhiteSpace($Line)) {
        if (Test-SlimerFeature -Features $s.Features -Name 'title') {
            $first = ($Line.Trim() -split "`n", 2)[0]
            [void]$out.Append((New-SlimerTitleSequence -Title $first))
        }
        [void]$out.Append((Get-SlimerPromptMark -Kind C))
        $s.Executing = $true
        $s.LecAtStart = $global:LASTEXITCODE
        $s.ErrorMarker = Get-SlimerErrorMarker
    }
    Write-SlimerRaw $out.ToString()
}

function Get-SlimerDefaultPrompt {
    $loc = $ExecutionContext.SessionState.Path.CurrentLocation
    return 'PS ' + $loc + ('>' * ($global:NestedPromptLevel + 1)) + ' '
}

# The global prompt function. Bound to this module, so it can call the
# private functions above.
$script:PromptWrapper = {
    $slimerOk = $?
    $slimerLec = $global:LASTEXITCODE
    try { Write-SlimerPromptStart -Success $slimerOk -LastExitCode $slimerLec } catch { }

    $text = $null
    $original = $script:State.OriginalPrompt
    if ($null -ne $original) {
        # Let the wrapped prompt see the same $? (the trick VS Code's shell
        # integration uses): a failed, ignored Write-Error sets $? to false.
        if (-not $slimerOk) { Write-Error -Message 'slimer' -ErrorAction Ignore }
        try { $text = (& $original) -join '' } catch { $text = $null }
        # Prompts that run native commands (git, starship) must not change
        # the user's $LASTEXITCODE.
        if ($null -eq $slimerLec) {
            Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction Ignore
        }
        else {
            $global:LASTEXITCODE = $slimerLec
        }
    }
    if ([string]::IsNullOrEmpty($text)) { $text = Get-SlimerDefaultPrompt }
    return $text + (Get-SlimerPromptMark -Kind B)
}

# The global PSConsoleHostReadLine function. The PowerShell console host
# calls it to read each command line, after the prompt, and PSReadLine
# returns only once the line is accepted, rendered and followed by a
# newline. Writing C here fires exactly once per accepted line, whatever
# key accepted it (Enter, Ctrl+Enter, vi mode, a custom handler), and never
# for a line PSReadLine kept editing (incomplete input, failed validation).
$script:ReadLineWrapper = {
    $lastRunStatus = $?
    $original = $script:State.OriginalReadLine
    if (-not $lastRunStatus) { Write-Error -Message 'slimer' -ErrorAction Ignore }
    $line = & $original
    try { Write-SlimerCommandStart -Line ([string]$line) } catch { }
    return $line
}

# ---------------------------------------------------------------------------
# Autocomplete
# ---------------------------------------------------------------------------

function Send-SlimerBufferReport {
    $s = $script:State
    if (-not $s.AcEnabled) { return }
    $line = $null
    $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    $keymap = Get-SlimerKeymap
    $key = [string]$cursor + ':' + $keymap + ':' + $line
    if ($key -ceq $s.AcLastPsReport) { return }
    $s.AcLastPsReport = $key
    Write-SlimerRaw (New-SlimerAutocompleteReport -Buffer $line -Cursor $cursor -Keymap $keymap `
            -Token $s.AcToken -ProcessId $PID -AsciiOnly:(Test-SlimerAsciiOnly))
}

# Read the accept payload from the console. The host writes the chord and
# the payload in one write, so the payload is already queued when this
# handler runs; a real key press of the chord finds nothing and returns
# without consuming any key.
function Read-SlimerAcceptPayload {
    # A hashtable, so the reader (which runs in a child scope) can update it.
    $st = @{ Clock = [System.Diagnostics.Stopwatch]::StartNew(); First = $true }
    $reader = {
        while ($true) {
            $limit = if ($st.First) { $script:AcFirstKeyWaitMs } else { $script:AcReadDeadlineMs }
            if ([Console]::KeyAvailable) {
                $st.First = $false
                return [Console]::ReadKey($true).KeyChar
            }
            if ($st.Clock.ElapsedMilliseconds -ge $limit) { return $null }
            [System.Threading.Thread]::Sleep(1)
        }
    }
    return Read-SlimerAcceptPayloadFrom -ReadKey $reader
}

function Invoke-SlimerAcceptKey {
    param([ValidateSet('token', 'line')][string]$Mode)
    $payload = Read-SlimerAcceptPayload
    if ($null -eq $payload) { return }
    $text = ConvertFrom-SlimerPercentEncoding -Payload $payload
    if ([string]::IsNullOrEmpty($text)) { return }
    $line = $null
    $cursor = 0
    [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
    $edit = Get-SlimerAcceptEdit -Line $line -Cursor $cursor -Text $text -Mode $Mode
    if ($null -eq $edit) { return }
    # One Replace call is one undo step. Never AcceptLine, never a newline.
    [Microsoft.PowerShell.PSConsoleReadLine]::Replace($edit.Start, $edit.Length, $edit.Replacement)
    [Microsoft.PowerShell.PSConsoleReadLine]::SetCursorPosition($edit.Start + $edit.Replacement.Length)
}

function Get-SlimerBuiltinHandler {
    param([string]$Chord)
    try {
        $h = Get-PSReadLineKeyHandler -Chord $Chord -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        return $null
    }
    if ($null -eq $h -or [string]::IsNullOrEmpty($h.Function)) { return $null }
    $method = [Microsoft.PowerShell.PSConsoleReadLine].GetMethod([string]$h.Function,
        [type[]]@([Nullable[System.ConsoleKeyInfo]], [object]))
    if ($null -eq $method -or -not $method.IsStatic) { return $null }
    return [pscustomobject]@{ Chord = $Chord; Function = [string]$h.Function; Method = $method }
}

# Run the original built-in function for a wrapped chord, then report the
# buffer if it is in a state the predictor never sees (empty, whitespace
# only, or multi-line).
function Invoke-SlimerWrappedKey {
    param([string]$Chord, $Key, $Arg)
    $h = $script:State.AcWrappedChords | Where-Object { $_.Chord -eq $Chord } | Select-Object -First 1
    if ($null -eq $h) { return }
    [void]$h.Method.Invoke($null, @($Key, $Arg))
    try {
        $line = $null
        $cursor = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Contains("`n")) { Send-SlimerBufferReport }
    }
    catch { }
}

function Register-SlimerEmptyingKeys {
    $s = $script:State
    foreach ($chord in @($script:AcEmptyingHandlers.Keys)) {
        $h = Get-SlimerBuiltinHandler -Chord $chord
        if ($null -eq $h) { continue }
        # Recorded before binding, so the handler can find the original.
        $s.AcWrappedChords = @($s.AcWrappedChords) + @($h)
        try {
            Set-PSReadLineKeyHandler -Chord $chord -ScriptBlock $script:AcEmptyingHandlers[$chord] `
                -BriefDescription ('Slimer' + $h.Function) `
                -Description ("$($h.Function), then report the buffer to Slimer autocomplete")
        }
        catch {
            $s.AcWrappedChords = @($s.AcWrappedChords | Where-Object { $_.Chord -ne $chord })
        }
    }
}

function Register-SlimerAcceptKeys {
    $s = $script:State
    $bound = @()
    foreach ($mode in $script:AcAcceptChords.Keys) {
        $chord = $script:AcAcceptChords[$mode]
        try {
            Set-PSReadLineKeyHandler -Chord $chord -ScriptBlock $script:AcAcceptHandlers[$mode] `
                -BriefDescription ('SlimerAccept' + $mode) `
                -Description 'Slimer autocomplete: insert the completion the terminal sends (never runs it)'
            $bound += $chord
        }
        catch { }
    }
    $s.AcBoundChords = $bound
}

# Load SlimerPredictor.dll if it was built, configure it and register it as
# a PSReadLine predictor. Returns $true on success. Any failure degrades
# silently: autocomplete reports are then not sent.
function Register-SlimerPredictor {
    $s = $script:State
    if ($PSVersionTable.PSVersion -lt [version]'7.2') { return $false }
    $candidates = @(
        (Join-Path $PSScriptRoot 'SlimerPredictor.dll'),
        (Join-Path $PSScriptRoot 'SlimerPredictor/bin/Release/net6.0/SlimerPredictor.dll')
    )
    $dll = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($null -eq $dll) { return $false }
    try {
        Add-Type -LiteralPath $dll -ErrorAction Stop
        [Slimer.PowerShell.SlimerReporter]::Configure([string]$s.AcToken, [int]$PID, (Get-SlimerKeymap), (Test-SlimerAsciiOnly))
        $kind = [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor
        $id = [Slimer.PowerShell.SlimerPredictor]::PredictorId
        # A forced re-import finds the assembly already loaded and registered.
        try { [System.Management.Automation.Subsystem.SubsystemManager]::UnregisterSubsystem($kind, $id) } catch { }
        [System.Management.Automation.Subsystem.SubsystemManager]::RegisterSubsystem($kind, [Slimer.PowerShell.SlimerPredictor]::new())
        $s.AcPredictorId = $id
    }
    catch {
        try { [Slimer.PowerShell.SlimerReporter]::Disable() } catch { }
        return $false
    }

    # PSReadLine only queries plugin predictors when PredictionSource
    # includes Plugin. Our predictor never returns suggestions, so adding it
    # changes nothing on screen.
    try {
        $src = [string](Get-PSReadLineOption).PredictionSource
        $s.AcOldPredictionSrc = $src
        if ($src -eq 'None') { Set-PSReadLineOption -PredictionSource Plugin }
        elseif ($src -eq 'History') { Set-PSReadLineOption -PredictionSource HistoryAndPlugin }
    }
    catch { }
    return $true
}

function Enable-SlimerAutocomplete {
    $s = $script:State
    # Take the secret out of the environment first, even if autocomplete
    # cannot be enabled, so child processes never inherit it.
    $token = [string]$env:SLIMER_AUTOCOMPLETE_TOKEN
    Remove-Item -Path Env:\SLIMER_AUTOCOMPLETE_TOKEN -ErrorAction Ignore
    if (-not [string]::IsNullOrEmpty($token) -and $token -cmatch $script:AcTokenPattern) {
        $s.AcToken = $token
    }
    if (-not (Test-SlimerFeature -Features $s.Features -Name 'autocomplete')) { return }
    $psrl = Get-Module -Name PSReadLine
    if ($null -eq $psrl -or $psrl.Version -lt [version]'2.2.0') { return }
    if (-not (Register-SlimerPredictor)) { return }
    $s.AcPredictor = $true
    $s.AcEnabled = $true
    Register-SlimerAcceptKeys
    Register-SlimerEmptyingKeys
}

function Disable-SlimerAutocomplete {
    $s = $script:State
    foreach ($chord in $s.AcBoundChords) {
        try { Remove-PSReadLineKeyHandler -Chord $chord } catch { }
    }
    foreach ($h in $s.AcWrappedChords) {
        try { Set-PSReadLineKeyHandler -Chord $h.Chord -Function $h.Function } catch { }
    }
    if ($s.AcPredictor) {
        try { [Slimer.PowerShell.SlimerReporter]::Disable() } catch { }
        try {
            [System.Management.Automation.Subsystem.SubsystemManager]::UnregisterSubsystem(
                [System.Management.Automation.Subsystem.SubsystemKind]::CommandPredictor, $s.AcPredictorId)
        }
        catch { }
        if ($s.AcOldPredictionSrc -in @('None', 'History')) {
            try { Set-PSReadLineOption -PredictionSource $s.AcOldPredictionSrc } catch { }
        }
    }
    $s.AcBoundChords = @()
    $s.AcWrappedChords = @()
    $s.AcPredictor = $false
    $s.AcEnabled = $false
}

# ---------------------------------------------------------------------------
# Enable / disable
# ---------------------------------------------------------------------------

function Test-SlimerShouldActivate {
    if ($env:SLIMER_PWSH_INTEGRATION -eq '0') { return $false }
    $inGhostty = ($env:TERM_PROGRAM -eq 'ghostty') -or -not [string]::IsNullOrEmpty($env:GHOSTTY_RESOURCES_DIR)
    if (-not $inGhostty) { return $false }
    if ($Host.Name -ne 'ConsoleHost') { return $false }
    try { if ([Console]::IsOutputRedirected) { return $false } } catch { return $false }
    return $true
}

function Get-SlimerHostName {
    try { return [System.Net.Dns]::GetHostName() } catch { }
    return [Environment]::MachineName
}

function Enable-SlimerIntegration {
    $s = $script:State
    if ($s.Enabled) { return }
    $s.Features = [string]$env:GHOSTTY_SHELL_FEATURES
    $s.HostName = Get-SlimerHostName

    $s.OriginalPrompt = $function:global:prompt
    $function:global:prompt = $script:PromptWrapper

    $readLine = Get-Command -Name PSConsoleHostReadLine -CommandType Function -ErrorAction Ignore
    if ($null -ne $readLine) {
        $s.OriginalReadLine = $readLine.ScriptBlock
        $function:global:PSConsoleHostReadLine = $script:ReadLineWrapper
    }

    try { Enable-SlimerAutocomplete } catch { }

    $s.Enabled = $true
    Write-SlimerRaw (New-SlimerShellReport -Fields (Get-SlimerShellReportFields))
}

function Disable-SlimerIntegration {
    $s = $script:State
    if (-not $s.Enabled) { return }
    try { Disable-SlimerAutocomplete } catch { }
    # Restore only what still is ours; something loaded later may have
    # replaced it already.
    if ([object]::ReferenceEquals($function:global:prompt, $script:PromptWrapper) -or
        "$function:global:prompt" -eq "$script:PromptWrapper") {
        if ($null -ne $s.OriginalPrompt) { $function:global:prompt = $s.OriginalPrompt }
        else { Remove-Item -Path function:global:prompt -ErrorAction Ignore }
    }
    if ($null -ne $s.OriginalReadLine -and "$function:global:PSConsoleHostReadLine" -eq "$script:ReadLineWrapper") {
        $function:global:PSConsoleHostReadLine = $s.OriginalReadLine
    }
    $s.Enabled = $false
}

# Diagnostics for the owner: what is active in this session.
function Get-SlimerIntegrationStatus {
    $s = $script:State
    $psrl = Get-Module -Name PSReadLine
    [pscustomobject]@{
        Enabled            = $s.Enabled
        Features           = $s.Features
        PromptWrapped      = ("$function:global:prompt" -eq "$script:PromptWrapper")
        ReadLineWrapped    = ("$function:global:PSConsoleHostReadLine" -eq "$script:ReadLineWrapper")
        PSReadLineVersion  = if ($psrl) { [string]$psrl.Version } else { $null }
        AutocompleteActive = $s.AcEnabled
        PredictorLoaded    = $s.AcPredictor
        TokenReceived      = -not [string]::IsNullOrEmpty($s.AcToken)
        AcceptChords       = @($s.AcBoundChords)
        WrappedKeys        = @($s.AcWrappedChords | ForEach-Object { $_.Chord })
        AsciiOnlyEncoding  = Test-SlimerAsciiOnly
    }
}

$ExecutionContext.SessionState.Module.OnRemove = { Disable-SlimerIntegration }

if (Test-SlimerShouldActivate) {
    Enable-SlimerIntegration
}

Export-ModuleMember -Function Get-SlimerIntegrationStatus
