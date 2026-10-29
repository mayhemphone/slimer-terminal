#!/bin/zsh -f
# End-to-end check of the autocomplete hooks in a real interactive zsh,
# driven through zsh/zpty. Slimer addition.
# Usage: zsh -f test/slimer/zsh-autocomplete.zsh \
#          src/shell-integration/zsh/ghostty-integration [emacs|vi]
# Keep every write small: zpty -wn silently loses writes over ~1 KB.
zmodload zsh/zpty || exit 2
script=$1
mode=${2:-emacs}
pass=0 fail=0
check() { if [[ $2 == *$3* ]]; then (( pass++ )); print -r "PASS $1"; else (( fail++ )); print -r "FAIL $1"; print -r -- "  wanted: ${(q+)3}"; print -r -- "  in:     ${(q+)2[-400,-1]}"; fi }
refute() { if [[ $2 != *$3* ]]; then (( pass++ )); print -r "PASS $1"; else (( fail++ )); print -r "FAIL $1"; print -r -- "  unwanted: ${(q+)3}"; print -r -- "  in:       ${(q+)2[-400,-1]}"; fi }

# The terminal hex-encodes every byte of an accept payload.
hex() { emulate -L zsh -o no_multibyte; local s=$1 out= c i; for (( i = 1; i <= ${#s}; i++ )); do c=${s[i]}; out+=%${(l:2::0:)$(( [##16] #c ))}; done; print -rn -- $out }
accept() { zpty -wn Z $'\e[7705~'$(hex "$1")$'\a' }
accept_line() { zpty -wn Z $'\e[7706~'$(hex "$1")$'\a' }

token=0123456789abcdef0123456789abcdef
rc=${TMPDIR:-/tmp}/ac_rc.$$
cat > $rc <<EOF
PS1='> '
unsetopt beep
$( [[ $mode == vi ]] && print 'bindkey -v' )
export GHOSTTY_SHELL_FEATURES=autocomplete
export SLIMER_AUTOCOMPLETE_TOKEN=$token
source ${(q)script}
EOF
# Start an interactive zsh -f and source the rc as the first command.
zpty -b Z "zsh -f -i"
zpty -w Z "source $rc"
# Trigger the deferred init (it runs on the first precmd).
zpty -w Z ""
sleep 0.5
out=; zpty -rt Z out 2>/dev/null; buf=$out
while zpty -rt Z out 2>/dev/null; do buf+=$out; done

typeset km=emacs; [[ $mode == vi ]] && km=viins

# Read everything zsh prints until the pty has been quiet for ~0.5s.
drain() { buf=; local idle=0 o; while (( idle < 5 )); do if zpty -rt Z o 2>/dev/null; then buf+=$o; idle=0; else (( idle++ )); sleep 0.1; fi; done }
clearline() { zpty -wn Z $'\x15'; drain }

# The secret is not inherited by child processes.
zpty -w Z 'print -r ENV-${SLIMER_AUTOCOMPLETE_TOKEN-unset}-$(env | grep -c SLIMER_AUTOCOMPLETE)'
drain
check "secret removed from the environment" "$buf" 'ENV-unset-0'

# Type a buffer with a ; and a % and check the OSC carries the secret.
zpty -wn Z 'echo 50%; git sta'
drain
check "emit carries the secret" "$buf" $'\e]7704;v=1;n='$token';p='
check "emit on change" "$buf" $';c=17;k='$km$';t=0;b=echo 50%25%3B git sta\a'

# Accept: replace the token "sta" with "status".
accept status
drain
check "accept replaces token" "$buf" $'b=echo 50%25%3B git status\a'
check "accept moves cursor"  "$buf" $';c=20;k='$km

# Accept text needing quotes: a filename with a space and a ;.
zpty -wn Z ' '
accept 'my file;.txt'
drain
check "accept quotes unsafe text" "$buf" 'git status my\ file\%3B.txt'

# A control byte smuggled through the encoding is rejected by the widget.
accept $'x\nrm'
drain
refute "reject encoded newline" "$buf" 'xrm'

# A zero-width space is rejected too.
accept $'a​b'
drain
refute "reject zero-width space" "$buf" 'ab'

# A payload that is not all %XX escapes is rejected (and consumed).
zpty -wn Z $'\e[7705~status\a'
drain
refute "reject raw payload" "$buf" 'my\ file\%3B.txtstatus'

# Redirections are never replaced: 2> stays and the text is appended.
clearline
zpty -wn Z 'echo hi 2>'
drain
accept out.txt
drain
check "fd redirection kept" "$buf" 'b=echo hi 2>out.txt'

# A leading ~/ stays unquoted so it still expands.
clearline
zpty -wn Z 'ls ~/D'
drain
accept '~/Documents/'
drain
check "tilde stays raw" "$buf" $'b=ls ~/Documents/\a'

# Whole-line accept (history): only extends what is typed.
clearline
zpty -wn Z 'git st'
drain
accept_line 'rm -rf x'
drain
refute "line accept needs a prefix" "$buf" 'rm -rf'
accept_line 'git status --short'
drain
check "line accept replaces the line" "$buf" $'b=git status --short\a'

# Nothing was executed: clear the line (Ctrl-U) and run a marker command.
# Leaving the line editor reports a deactivate (d=1).
clearline
zpty -w Z 'print -r MARK-$((6*7))'
drain
check "line was never executed before Enter" "$buf" 'MARK-42'
check "line-finish deactivates" "$buf" $';d=1;'
refute "no stray execution" "$buf" 'command not found'

# No re-emit when nothing changed: the first redraw at the fresh prompt may
# report the new (empty) state once; a second identical redraw must not.
zpty -wn Z $'\x0c'
drain
zpty -wn Z $'\x0c'
drain
refute "dedupe on redraw" "$buf" $'\e]7704'

zpty -d Z
rm -f $rc
print "pass=$pass fail=$fail"
(( fail == 0 ))
