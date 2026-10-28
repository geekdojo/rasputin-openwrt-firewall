#!/usr/bin/env bash
#
# test-update-smoke-console.sh — test/console.sh, the update smoke's console
# searches, against a saved CI console (geekdojo/geekdojo-brain#888, F-888-24).
#
# The fixture is the generic leg's console from release run 40623523907, the
# run where the harness timed out on lines this console already held. It runs
# the searches the way the runner does: under `set -euo pipefail`, with
# SIGPIPE ignored, so a writer that outlives its reader gets EPIPE. The first
# case shows that the old pipeline shape misses a line that is there on this
# fixture; the rest show that console.sh finds what is there, finds nothing
# when nothing is there, and returns the right line.
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

# The premise: on this fixture the old shape reads a present line as absent.
# The first kernel command line is at byte ~21k of ~105k, so tr still has more
# than a pipe buffer to write when grep exits.
if tail -n +1 "$LOG" | tr -d '\r' 2>/dev/null | grep -qE 'Kernel command line:'; then
	no "the old 'tail | tr | grep -q' shape misses a present line (the fixture reproduces F-888-24)" \
		"it found the line, so this fixture no longer reproduces the defect"
else
	ok "the old 'tail | tr | grep -q' shape misses a present line (the fixture reproduces F-888-24)"
fi

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

printf '\nupdate-smoke-console: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
