# shellcheck shell=sh
# console.sh — reading a serial-console log for test/update-smoke.sh, and
# running commands over it (geekdojo/geekdojo-brain#888). Sourced, not run.
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

# con_began <log> <from-line> <tag> — true iff the begin marker of <tag> is a
# line of its own from <from-line> on: the guest received the command's start.
con_began() {
	con_has "$1" "$2" "^@@B:$3@@\$"
}

# --- running commands on the console ----------------------------------------
# These type into the guest, so they use the caller's I/O: send <line>,
# wait_for <ERE> <deadline-s> <what> [from-line], lines, say, die, and $LOG and
# $CMD_DEADLINE. test/update-smoke.sh defines them over QEMU's serial pipe;
# scripts/test-update-smoke-console.sh defines them over a fixture.
#
# LOST INPUT (F-888-29). Typed right after the boot's root prompt, while the
# kernel is still printing to the console, a command line can reach the shell
# with its first byte gone: `echo @@B:t@@; ...` runs as `cho @@B:t@@; ...`,
# the begin marker never prints, but the end marker does. Release run
# 40633612615 failed this way, silently.

# con_cmd <tag> <command> — type <command> between begin and end markers and
# wait for the end marker. Sets CON_T (the unique tag) and CON_FROM (the
# console line it started from). The tag carries the console's length, not a
# counter, because callers run this inside $(...).
con_cmd() {
	CON_FROM=$(lines)
	CON_T="$1-$CON_FROM"
	send "echo @@B:$CON_T@@; $2; echo @@E:$CON_T:\$?@@"
	wait_for "^@@E:$CON_T:[0-9]+@@" "$CMD_DEADLINE" "the end of '$2'" "$CON_FROM"
}

# con_ready — return once the console takes a line intact: a no-op probe's
# begin and end markers both come back. A probe whose start was lost is sent
# again, up to $CMD_DEADLINE: it has no side effect. Real commands never are.
con_ready() {
	con_ready_end=$(( $(date +%s) + CMD_DEADLINE ))
	while :; do
		con_cmd ready ':'
		con_began "$LOG" "$CON_FROM" "$CON_T" && return 0
		[ "$(date +%s)" -lt "$con_ready_end" ] \
			|| die "lost console input: every readiness probe for ${CMD_DEADLINE}s lost its start (end marker printed, begin marker did not)"
		say "lost console input on the readiness probe (boot output still on the console); probing again"
	done
}

# run <tag> <command> — run in the guest; prints its output; returns its status.
# Lost input is a FAIL, never a silent status: the command is not resent,
# because it may have side effects and part of the line may have run.
run() {
	con_cmd "$1" "$2"
	con_began "$LOG" "$CON_FROM" "$CON_T" \
		|| die "lost console input: the guest did not receive the start of '$2' (end marker printed, begin marker did not)"
	# Output only, with terminal colour codes stripped (the image's ip colours).
	out=$(tail -n +"$CON_FROM" "$LOG" | tr -d '\r' | sed -n "/^@@B:$CON_T@@\$/,/^@@E:$CON_T:/p" | sed 's/\x1b\[[0-9;]*m//g')
	printf '%s\n' "$out" | sed '1d;$d'
	rc=$(printf '%s\n' "$out" | sed -n "s/^@@E:$CON_T:\([0-9]*\)@@\$/\1/p")
	return "${rc:-1}"
}
