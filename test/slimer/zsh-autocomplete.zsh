#!/bin/zsh -f
# End-to-end check of the autocomplete hooks in a real interactive zsh,
# driven through zsh/zpty. Slimer addition.
# Usage: zsh -f test/slimer/zsh-autocomplete.zsh \
#          src/shell-integration/zsh/ghostty-integration [emacs|vi]
zmodload zsh/zpty || exit 2
script=$1
mode=${2:-emacs}
pass=0 fail=0
check() { if [[ $2 == *$3* ]]; then (( pass++ )); print -r "PASS $1"; else (( fail++ )); print -r "FAIL $1"; print -r -- "  wanted: ${(q+)3}"; print -r -- "  in:     ${(q+)2[-400,-1]}"; fi }

rc=${TMPDIR:-/tmp}/ac_rc.$$
cat > $rc <<EOF
PS1='> '
unsetopt beep
$( [[ $mode == vi ]] && print 'bindkey -v' )
export GHOSTTY_SHELL_FEATURES=autocomplete
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

# Type a buffer with a ; and a % and check the OSC.
zpty -wn Z 'echo 50%; git sta'
drain
check "emit on change" "$buf" $'\e]7704;v=1;c=17;k='$km$';t=0;b=echo 50%25%3B git sta\a'

# Accept: replace the token "sta" with "status".
zpty -wn Z $'\e[7705~status\a'
drain
check "accept replaces token" "$buf" $'b=echo 50%25%3B git status\a'
check "accept moves cursor"  "$buf" $'c=20;k='$km

# Accept text needing quotes: a filename with a space and a ;.
zpty -wn Z $' \e[7705~my file%3B.txt\a'
drain
check "accept quotes unsafe text" "$buf" 'git status my\ file\%3B.txt'

# A control byte smuggled through the encoding is rejected by the widget.
zpty -wn Z $'\e[7705~x%0Arm\a'
drain
[[ $buf != *'xrm'* && $buf != *$'\nrm'* ]] && { (( pass++ )); print "PASS reject encoded newline"; } || { (( fail++ )); print "FAIL reject encoded newline"; print -r -- "  ${(q+)buf}"; }

# Nothing was executed: clear the line (Ctrl-U) and run a marker command.
zpty -wn Z $'\x15'
zpty -w Z 'print -r MARK-$((6*7))'
drain
check "line was never executed before Enter" "$buf" 'MARK-42'
[[ $buf != *'command not found'* ]] && { (( pass++ )); print "PASS no stray execution"; } || { (( fail++ )); print "FAIL stray execution"; }

# No re-emit when nothing changed: the first redraw at the fresh prompt may
# report the new (empty) state once; a second identical redraw must not.
zpty -wn Z $'\x0c'
drain
zpty -wn Z $'\x0c'
drain
[[ $buf != *$'\e]7704'* ]] && { (( pass++ )); print "PASS dedupe on redraw"; } || { (( fail++ )); print "FAIL dedupe on redraw"; print -r -- "  ${(q+)buf}"; }

zpty -d Z
rm -f $rc
print "pass=$pass fail=$fail"
(( fail == 0 ))
