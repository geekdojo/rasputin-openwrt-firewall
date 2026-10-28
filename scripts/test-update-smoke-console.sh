#!/usr/bin/env bash
#
# test-update-smoke-console.sh — test/console.sh, the update smoke's console
# searches, against a saved CI console (geekdojo/geekdojo-brain#888, F-888-24).
#
# The fixture is the generic leg's console from release run 40623523907, the
# run where the harness timed out on lines this console already held. It runs
# the searches the way the runner does: under `set -euo pipefail`, with
# SIGPIPE ignored, so a writer that outlives its reader gets EPIPE. The cases
# show that console.sh finds what is there, finds nothing when nothing is
# there, and returns the right line.
#
# There is no red-before case for the old 'tail | tr | grep -q' shape. Release
# run 40623523907 proves the defect, but whether that shape misses a present
# line depends on scheduling (whether tr is still writing when grep exits), so
# a case asserting the miss is itself flaky (F-888-28).
#
# The lost-input cases (F-888-29) drive the readiness probe and run() over a
# simulated guest: send appends to a console log what the guest printed in
# release run 40633612615 (the second fixture), so they are deterministic.
#
# Usage: bash scripts/test-update-smoke-console.sh
trap '' PIPE
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LOG="$ROOT/test/fixtures/update-smoke-generic-console.log"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
CON_SNAP="$W/snap"
# shellcheck source=test/console.sh
. "$ROOT/test/console.sh"

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2" >&2; }

[ -s "$LOG" ] || { echo "test-update-smoke-console: no fixture at $LOG" >&2; exit 1; }

if con_has "$LOG" 1 'Kernel command line:'; then
	ok "con_has finds the first kernel command line"
else
	no "con_has finds the first kernel command line" "it reported the line absent"
fi

if con_has "$LOG" 1 'Please press Enter to activate this console'; then
	ok "con_has finds the console prompt"
else
	no "con_has finds the console prompt" "it reported the line absent"
fi

if con_has "$LOG" 1200 '^@@E:drv-1203:[0-9]+@@'; then
	ok "con_has finds an end marker from a later start line (the eth1 driver check)"
else
	no "con_has finds an end marker from a later start line" "it reported the marker absent"
fi

if con_has "$LOG" 1 'rasputin-kernel-match: MISMATCH'; then
	no "con_has reports a line that is not there as absent" "it matched 'MISMATCH' in a console with none"
else
	ok "con_has reports a line that is not there as absent"
fi

got=$(con_first "$LOG" 700 'Kernel command line:' | sed -n 's/.*rasputin\.slot=\([AB]\).*/\1/p')
if [ "$got" = B ]; then
	ok "con_first returns the first match from the start line (boot 2 on slot B)"
else
	no "con_first returns the first match from the start line" "slot '$got', want B"
fi

got=$(con_first "$LOG" 1 'no such line in this console')
if [ -z "$got" ]; then
	ok "con_first prints nothing, and does not fail, when nothing matches"
else
	no "con_first prints nothing when nothing matches" "printed '$got'"
fi

# --- lost console input (F-888-29) ---------------------------------------------
LOST="$ROOT/test/fixtures/update-smoke-lost-input-console.log"
[ -s "$LOST" ] || { echo "test-update-smoke-console: no fixture at $LOST" >&2; exit 1; }

if con_has "$LOST" 1 '^@@E:quiet-1595:[0-9]+@@' && ! con_began "$LOST" 1 quiet-1595; then
	ok "con_began reports the start lost in release run 40633612615's console"
else
	no "con_began reports the start lost in the run's console" "end marker missing, or a begin marker found"
fi

# A simulated guest. $W/lose holds how many more lines lose their first byte;
# a lost line prints what the run's console printed (the fixture's last four
# lines, tag swapped); an intact one prints its begin marker, then its end
# marker with status 3. The rest is the caller I/O console.sh documents.
LOG="$W/console.log"
CMD_DEADLINE=60
lines() { wc -l < "$LOG" | tr -d ' '; }
say() { printf 'say: %s\n' "$*"; }
die() { printf 'FAIL %s\n' "$*" >&2; exit 1; }
wait_for() { con_has "$LOG" "${4:-1}" "$1" || die "$3 did not appear"; }
send() {
	tag=$(printf '%s\n' "$1" | sed -n 's/^echo @@B:\([^@]*\)@@;.*/\1/p')
	n=$(cat "$W/lose")
	if [ "$n" -gt 0 ]; then
		echo $((n - 1)) > "$W/lose"
		printf '\n'; tail -n 4 "$LOST" | sed "s/quiet-1595/$tag/g"
	else
		printf '%s\r\n@@B:%s@@\r\n@@E:%s:3@@\r\nroot@OpenWrt:~# ' "$1" "$tag" "$tag"
	fi >> "$LOG"
}
fresh() { head -n 8 "$LOST" > "$LOG"; echo "$1" > "$W/lose"; }

fresh 1
if ( con_ready ) > "$W/out" 2> "$W/err" \
	&& [ "$(grep -c '^cho @@B:ready-' "$LOG")" = 1 ] \
	&& [ "$(grep -c '^@@B:ready-' "$LOG")" = 1 ] \
	&& grep -q 'probing again' "$W/out"; then
	ok "the readiness probe is sent again after it loses its start, and returns once one arrives intact"
else
	no "the readiness probe is sent again after a lost start" "out: $(cat "$W/out") err: $(cat "$W/err")"
fi

fresh 1
CMD_DEADLINE=0
if ( con_ready ) > "$W/out" 2> "$W/err"; then
	no "the readiness probe stops at its deadline" "it returned 0 with every probe lost"
elif grep -q '^FAIL lost console input' "$W/err" && [ "$(grep -c '^cho @@B:ready-' "$LOG")" = 1 ]; then
	ok "the readiness probe stops at its deadline with a lost-console-input FAIL"
else
	no "the readiness probe stops at its deadline" "err: $(cat "$W/err")"
fi
CMD_DEADLINE=60

fresh 1
if ( run quiet 'dmesg -n 1' ) > "$W/out" 2> "$W/err"; then
	no "run() fails on lost input" "it returned 0"
elif grep -q "^FAIL lost console input: the guest did not receive the start of 'dmesg -n 1'" "$W/err" \
	&& [ "$(grep -c 'dmesg -n 1' "$LOG")" = 1 ]; then
	ok "run() fails on lost input with an explicit FAIL, and does not resend the command"
else
	no "run() fails on lost input with an explicit FAIL" "err: $(cat "$W/err")"
fi

fresh 0
rc=0
got=$( run uname 'uname -r' ) || rc=$?
if [ "$rc" = 3 ] && [ -z "$got" ]; then
	ok "run() returns the guest's status when the input arrives intact"
else
	no "run() returns the guest's status" "rc $rc, output '$got'"
fi

printf '\nupdate-smoke-console: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
