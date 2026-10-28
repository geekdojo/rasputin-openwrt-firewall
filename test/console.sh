# shellcheck shell=sh
# console.sh — reading a serial-console log for test/update-smoke.sh
# (geekdojo/geekdojo-brain#888). Sourced, not run.
#
# WHY A FILE AND NOT A PIPE (F-888-24). The harness runs under
# `set -euo pipefail`, and the runners ignore SIGPIPE. In
# `tail | tr -d '\r' | grep -q RE`, grep exits at its first match, tr's next
# write fails with EPIPE, tr exits non-zero, and pipefail turns a line that IS
# there into a miss. So every search here copies the log, CRs stripped, to a
# snapshot file first, and grep reads that file: its status is its own.
#
# The snapshot path is $CON_SNAP, which the caller sets. Tested by
# scripts/test-update-smoke-console.sh against a saved CI console.

# con_snap <log> <from-line> — lines <from-line> on, CRs stripped, to $CON_SNAP.
con_snap() {
	tail -n +"$2" "$1" | tr -d '\r' > "${CON_SNAP:?CON_SNAP is not set}"
}

# con_has <log> <from-line> <ERE> — true iff a line from <from-line> on matches.
con_has() {
	con_snap "$1" "$2" || return 2
	grep -qE -- "$3" "$CON_SNAP"
}

# con_first <log> <from-line> <fixed-string> — print the first line from
# <from-line> on that contains the string; print nothing if none does.
con_first() {
	con_snap "$1" "$2" || return 2
	grep -m1 -F -- "$3" "$CON_SNAP" || true
}
