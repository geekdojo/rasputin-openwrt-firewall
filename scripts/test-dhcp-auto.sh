#!/bin/sh
#
# test-dhcp-auto.sh — behaviour tests for files/etc/init.d/rasputin-dhcp-auto.
#
# WHY
#   Who decides whether this box serves LAN DHCP is a security property, not a
#   convenience: before the fix, ANY DHCP OFFER on the LAN at boot could switch
#   off a DHCP server the operator had chosen, because the boot-time probe's
#   input is unauthenticated and it ran unconditionally
#   (geekdojo/geekdojo-brain#543, F52).
#
#   So the rules pinned here are:
#     - a recorded deployment mode decides, and the probe does not run at all;
#     - the probe runs only when no mode has ever been recorded (first boot);
#     - an unreadable or unrecognised mode file is "no mode", never a mode;
#     - dhcp.lan.force=1 is set on every path, because dnsmasq otherwise runs
#       its OWN unauthenticated conflict probe and would silence the interface
#       behind the decision this script just made.
#   None of that is visible to a syntax or mode check.
#
#   White-box, like test-mgmt-harden.sh: the init script is sourced and its
#   functions are driven directly against a mock `uci`, with the side effects
#   (dnsmasq reload, DHCP probe) stubbed and recorded.
#
# Usage: sh scripts/test-dhcp-auto.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/files/etc/init.d/rasputin-dhcp-auto"
[ -f "$SUT" ] || { echo "missing: $SUT" >&2; exit 2; }

pass=0
fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3" >&2; }

SCRATCH=$(mktemp -d 2>/dev/null || mktemp -d -t dhcpauto)
trap 'rm -rf "$SCRATCH"' EXIT

# --- a mock `uci`, holding `key=value` lines, supporting the surface the
# script uses: `-q set k=v`, `-q get k`, `-q commit <config>`.
UCI_STATE="$SCRATCH/uci-state"
: > "$UCI_STATE"
uci() {
	[ "${1:-}" = "-q" ] && shift
	_cmd=${1:-}; shift 2>/dev/null || true
	case "$_cmd" in
		set)
			_k=${1%%=*}; _v=${1#*=}
			grep -v "^$_k=" "$UCI_STATE" > "$UCI_STATE.n" 2>/dev/null || true
			mv -f "$UCI_STATE.n" "$UCI_STATE"
			printf '%s=%s\n' "$_k" "$_v" >> "$UCI_STATE"
			;;
		get)
			_line=$(grep "^$1=" "$UCI_STATE" 2>/dev/null | head -1)
			[ -n "$_line" ] || return 1
			printf '%s\n' "${_line#*=}"
			;;
		commit) printf 'commit %s\n' "${1:-}" >> "$SCRATCH/uci.log" ;;
		*) : ;;
	esac
}

logger() { :; }
sleep() { :; }

MODE_FILE_PATH="$SCRATCH/deployment-mode"
RASPUTIN_DEPLOYMENT_MODE_FILE="$MODE_FILE_PATH"
export RASPUTIN_DEPLOYMENT_MODE_FILE

# shellcheck source=/dev/null
. "$SUT"

# Stubs for the two side effects, defined AFTER sourcing so they win. Each
# records that it ran, which is what the assertions read.
reload_dnsmasq() { printf 'reload\n' >> "$SCRATCH/reloads"; }
PROBE_ANSWER=1   # 0 = another DHCP server answered
another_dhcp_server() { printf 'probe %s\n' "$1" >> "$SCRATCH/probes"; return "$PROBE_ANSWER"; }

reset() {
	: > "$UCI_STATE"
	rm -f "$SCRATCH/reloads" "$SCRATCH/probes" "$SCRATCH/uci.log" "$MODE_FILE_PATH"
	printf 'dhcp.lan.ignore=0\n' >> "$UCI_STATE"
}
ignore_now()  { uci -q get dhcp.lan.ignore; }
force_now()   { uci -q get dhcp.lan.force || printf 'unset\n'; }
probed()      { [ -s "$SCRATCH/probes" ]; }
reload_count() { [ -f "$SCRATCH/reloads" ] && wc -l < "$SCRATCH/reloads" | tr -d ' ' || printf '0'; }

echo "== a recorded mode decides, and the probe never runs"

# active: serve DHCP, no probe — even though something else is answering.
reset; printf 'active\n' > "$MODE_FILE_PATH"; PROBE_ANSWER=0
boot
[ "$(ignore_now)" = 0 ] && ok || no "active: serves LAN DHCP" "0" "$(ignore_now)"
[ "$(force_now)" = 1 ] && ok || no "active: dnsmasq force set" "1" "$(force_now)"
probed && no "active: probe skipped" "not run" "ran" || ok

# idle: do not serve, no probe — even though nothing else is answering.
reset; printf 'idle\n' > "$MODE_FILE_PATH"; PROBE_ANSWER=1
boot
[ "$(ignore_now)" = 1 ] && ok || no "idle: LAN DHCP off" "1" "$(ignore_now)"
[ "$(force_now)" = 1 ] && ok || no "idle: dnsmasq force set" "1" "$(force_now)"
probed && no "idle: probe skipped" "not run" "ran" || ok

# The mode is re-asserted on a box the probe would have decided differently:
# this is the fix. A hostile (or merely present) DHCP server at boot no longer
# takes the role away from the mode the control plane set.
reset; printf 'active\n' > "$MODE_FILE_PATH"; PROBE_ANSWER=0
printf 'dhcp.lan.ignore=1\n' > "$UCI_STATE"
boot
[ "$(ignore_now)" = 0 ] && ok || no "active after a stray OFFER: role restored" "0" "$(ignore_now)"

# Trailing whitespace / CRLF in the file still reads as the mode.
reset; printf 'active \r\n' > "$MODE_FILE_PATH"; PROBE_ANSWER=0
boot
[ "$(ignore_now)" = 0 ] && ok || no "whitespace: 'active ' still active" "0" "$(ignore_now)"
probed && no "whitespace: probe skipped" "not run" "ran" || ok

echo "== no recorded mode: the first-boot probe"

# Nobody else answering -> serve (Mode A/C bootstrap), force set.
reset; PROBE_ANSWER=1
boot
[ "$(ignore_now)" = 0 ] && ok || no "no mode, no server: serves" "0" "$(ignore_now)"
[ "$(force_now)" = 1 ] && ok || no "no mode, no server: force set" "1" "$(force_now)"
probed && ok || no "no mode, no server: probe ran" "ran" "not run"

# Another server answering -> back off (Mode B), and our own DHCP was silenced
# BEFORE the probe so it cannot detect itself.
reset; PROBE_ANSWER=0
boot
[ "$(ignore_now)" = 1 ] && ok || no "no mode, server present: backs off" "1" "$(ignore_now)"
[ "$(force_now)" = 1 ] && ok || no "no mode, server present: force set" "1" "$(force_now)"
probed && ok || no "no mode, server present: probe ran" "ran" "not run"
[ "$(reload_count)" = 1 ] && ok || no "no mode, server present: one reload (silence only)" "1" "$(reload_count)"

echo "== an unreadable mode is not a mode"

for bad in '' 'ACTIVE' 'enabled' 'active extra' '1'; do
	reset; printf '%s\n' "$bad" > "$MODE_FILE_PATH"; PROBE_ANSWER=1
	boot
	probed && ok || no "mode file '$bad': falls back to the probe" "probe ran" "probe skipped"
done

# A mode file that cannot be read at all (no file) is the first-boot case.
reset; PROBE_ANSWER=1
persisted_mode > "$SCRATCH/out" 2>/dev/null; rc=$?
[ "$rc" != 0 ] && ok || no "absent mode file: persisted_mode fails" "non-zero" "$rc"
[ ! -s "$SCRATCH/out" ] && ok || no "absent mode file: prints nothing" "empty" "$(cat "$SCRATCH/out")"

# A mode file naming a mode prints exactly that and nothing else.
printf 'idle\n' > "$MODE_FILE_PATH"
out=$(persisted_mode)
[ "$out" = idle ] && ok || no "mode file 'idle': persisted_mode prints it" "idle" "$out"

echo ""
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
