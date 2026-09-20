#!/bin/sh
#
# test-mgmt-harden.sh — behaviour tests for
# files/etc/init.d/rasputin-mgmt-harden.
#
# WHY
#   The init script re-asserts two management-plane floors on every boot so
#   they reach OTA-upgraded boxes, not only fresh flashes:
#     - uhttpd (LuCI + the /ubus endpoint) bound to loopback only
#       (geekdojo/geekdojo-brain#559);
#     - a non-empty, unusable root password field when it is empty
#       (geekdojo/geekdojo-brain#503), leaving a real delivered hash or an
#       existing lock alone.
#   Both must be IDEMPOTENT: a steady-state boot must change nothing (so it
#   does not thrash uhttpd or clobber a control-plane-delivered root hash).
#   None of this is visible to a syntax check. Pinned here case by case.
#
#   This is a white-box test: it sources the init script (whose rc.common
#   shebang is a comment when sourced) and drives its functions directly, with
#   a faithful mock `uci` and the sourced SHADOW pointed at a scratch file. The
#   uhttpd transformation is also verified end to end against the real OpenWrt
#   userland on the bench (recorded on the PR).
#
# Usage: sh scripts/test-mgmt-harden.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/files/etc/init.d/rasputin-mgmt-harden"
[ -f "$SUT" ] || { echo "missing: $SUT" >&2; exit 2; }

pass=0
fail=0
ok()   { pass=$((pass + 1)); }
no()   { fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3" >&2; }

SCRATCH=$(mktemp -d 2>/dev/null || mktemp -d -t mgmtharden)
trap 'rm -rf "$SCRATCH"' EXIT

# --- a faithful-enough mock `uci` --------------------------------------------
# State lives in $UCI_STATE as `key=space-joined-values` lines. Supports the
# exact surface the script uses: `-q get <key>` and `-q batch` reading
# delete/add_list/commit from stdin.
UCI_STATE="$SCRATCH/uci-state"
uci() {
	# drop a leading -q
	[ "${1:-}" = "-q" ] && shift
	_cmd=${1:-}; shift 2>/dev/null || true
	case "$_cmd" in
		get)
			# Exact prefix match, not grep: a UCI key holds regex
			# metacharacters — `dropbear.@dropbear[0]` would match
			# `dropbear.@dropbear0` as a character class and miss the real
			# line, which is how a mock quietly reports "no such section" for
			# every section there is.
			_key=$1
			_line=$(awk -v k="$_key=" 'index($0, k) == 1 { print; exit }' "$UCI_STATE" 2>/dev/null)
			[ -n "$_line" ] || return 1
			printf '%s\n' "${_line#*=}"
			;;
		batch)
			while IFS= read -r _l; do
				case "$_l" in
					delete\ *)
						_k=${_l#delete }
						awk -v k="$_k=" 'index($0, k) != 1' "$UCI_STATE" > "$UCI_STATE.n" 2>/dev/null || true
						mv -f "$UCI_STATE.n" "$UCI_STATE"
						;;
					add_list\ *)
						_kv=${_l#add_list }
						_k=${_kv%%=*}
						_v=${_kv#*=}
						_v=$(printf '%s' "$_v" | sed "s/^'//; s/'\$//")
						_cur=$(awk -v k="$_k=" 'index($0, k) == 1 { print; exit }' "$UCI_STATE" 2>/dev/null)
						if [ -n "$_cur" ]; then
							_old=${_cur#*=}
							awk -v k="$_k=" 'index($0, k) != 1' "$UCI_STATE" > "$UCI_STATE.n" 2>/dev/null || true
							mv -f "$UCI_STATE.n" "$UCI_STATE"
							printf '%s=%s %s\n' "$_k" "$_old" "$_v" >> "$UCI_STATE"
						else
							printf '%s=%s\n' "$_k" "$_v" >> "$UCI_STATE"
						fi
						;;
					commit\ *) : ;;
				esac
			done
			;;
		set)
			# `set key=value`, the form harden_dropbear uses.
			_kv=$1
			_k=${_kv%%=*}
			_v=${_kv#*=}
			awk -v k="$_k=" 'index($0, k) != 1' "$UCI_STATE" > "$UCI_STATE.n" 2>/dev/null || true
			mv -f "$UCI_STATE.n" "$UCI_STATE"
			printf '%s=%s\n' "$_k" "$_v" >> "$UCI_STATE"
			;;
		commit) : ;;
		*) : ;;
	esac
}

# logger is not present off-box; stub it.
logger() { :; }

# Source the init script: the `#!/bin/sh /etc/rc.common` line is a comment when
# sourced, and no top-level code runs boot(). Function defs + SHADOW/LOCK come in.
# shellcheck source=/dev/null
. "$SUT"

reset_uci_stock() {
	: > "$UCI_STATE"
	printf 'uhttpd.main.listen_http=0.0.0.0:80 [::]:80\n'  >> "$UCI_STATE"
	printf 'uhttpd.main.listen_https=0.0.0.0:443 [::]:443\n' >> "$UCI_STATE"
}
reset_uci_loopback() {
	: > "$UCI_STATE"
	printf 'uhttpd.main.listen_http=127.0.0.1:80 [::1]:80\n'   >> "$UCI_STATE"
	printf 'uhttpd.main.listen_https=127.0.0.1:443 [::1]:443\n' >> "$UCI_STATE"
}

echo "== uhttpd loopback binding"

# stock 0.0.0.0 -> rewritten to loopback, returns 0 (changed)
reset_uci_stock
harden_uhttpd; rc=$?
got_http=$(uci -q get uhttpd.main.listen_http)
got_https=$(uci -q get uhttpd.main.listen_https)
[ "$rc" = 0 ] && ok || no "stock: returns changed(0)" "0" "$rc"
[ "$got_http" = "127.0.0.1:80 [::1]:80" ] && ok || no "stock: listen_http -> loopback" "127.0.0.1:80 [::1]:80" "$got_http"
[ "$got_https" = "127.0.0.1:443 [::1]:443" ] && ok || no "stock: listen_https -> loopback" "127.0.0.1:443 [::1]:443" "$got_https"

# already loopback -> no change, returns 1 (idempotent, no thrash)
reset_uci_loopback
harden_uhttpd; rc=$?
[ "$rc" = 1 ] && ok || no "loopback: returns unchanged(1)" "1" "$rc"

echo "== root shadow floor"

STOCK='root:::0:99999:7:::
daemon:*:0:0:99999:7:::
nobody:*:0:0:99999:7:::'

# empty root field -> set to '*', returns 0; other rows byte-intact
sf="$SCRATCH/shadow.empty"; printf '%s\n' "$STOCK" > "$sf"
SHADOW="$sf" harden_root_shadow; rc=$?
rf=$(awk -F: '$1=="root"{print $2}' "$sf")
others=$(grep -v '^root:' "$sf")
[ "$rc" = 0 ] && ok || no "empty: returns changed(0)" "0" "$rc"
[ "$rf" = '*' ] && ok || no "empty: root field -> '*'" "*" "$rf"
[ "$others" = "$(printf 'daemon:*:0:0:99999:7:::\nnobody:*:0:0:99999:7:::')" ] && ok || no "empty: other rows intact" "unchanged" "$others"
# a well-formed 9-field root row is preserved (count ':' == 8)
colons=$(awk -F: '$1=="root"{print NF-1}' "$sf")
[ "$colons" = 8 ] && ok || no "empty: root row still 8 colons" "8" "$colons"

# already-locked '*' -> untouched, returns 1
sf="$SCRATCH/shadow.locked"; printf 'root:*:0:99999:7:::\n' > "$sf"
SHADOW="$sf" harden_root_shadow; rc=$?
rf=$(awk -F: '$1=="root"{print $2}' "$sf")
[ "$rc" = 1 ] && ok || no "locked: returns unchanged(1)" "1" "$rc"
[ "$rf" = '*' ] && ok || no "locked: left as '*'" "*" "$rf"

# a real delivered hash -> NEVER clobbered by the floor, returns 1
real='$6$abcdefgh$0123456789abcdefABCDEF.hashhashhashhashhashhashhashhash0'
sf="$SCRATCH/shadow.real"; printf 'root:%s:0:99999:7:::\n' "$real" > "$sf"
SHADOW="$sf" harden_root_shadow; rc=$?
rf=$(awk -F: '$1=="root"{print $2}' "$sf")
[ "$rc" = 1 ] && ok || no "delivered hash: returns unchanged(1)" "1" "$rc"
[ "$rf" = "$real" ] && ok || no "delivered hash: preserved" "$real" "$rf"

echo ""

echo "== dropbear key-only, unconditional"

reset_uci_dropbear() {
	: > "$UCI_STATE"
	printf 'dropbear.@dropbear[0]=dropbear\n' >> "$UCI_STATE"
	# Stock OpenWrt: password auth ON.
	printf 'dropbear.@dropbear[0].PasswordAuth=on\n' >> "$UCI_STATE"
	printf 'dropbear.@dropbear[0].RootPasswordAuth=on\n' >> "$UCI_STATE"
}

# Stock: both options flipped off, reported as changed(0).
reset_uci_dropbear
harden_dropbear; rc=$?
[ "$rc" = 0 ] && ok || no "dropbear stock: returns changed(0)" "0" "$rc"
[ "$(uci -q get dropbear.@dropbear[0].PasswordAuth)" = off ] && ok \
	|| no "dropbear stock: PasswordAuth off" "off" "$(uci -q get dropbear.@dropbear[0].PasswordAuth)"
[ "$(uci -q get dropbear.@dropbear[0].RootPasswordAuth)" = off ] && ok \
	|| no "dropbear stock: RootPasswordAuth off" "off" "$(uci -q get dropbear.@dropbear[0].RootPasswordAuth)"

# Steady state: nothing changes, so an ordinary boot neither writes nor reloads.
harden_dropbear; rc=$?
[ "$rc" = 1 ] && ok || no "dropbear steady state: returns unchanged(1)" "1" "$rc"

# THE case the old condition skipped: no authorized key anywhere. Password auth
# must still be turned off — with no key there is simply no network shell,
# which is the intended state; with password auth on it is a root login prompt.
reset_uci_dropbear
rm -f "$SCRATCH/authorized_keys"
harden_dropbear; rc=$?
[ "$rc" = 0 ] && ok || no "dropbear with no key: still hardens" "0" "$rc"
[ "$(uci -q get dropbear.@dropbear[0].PasswordAuth)" = off ] && ok \
	|| no "dropbear with no key: PasswordAuth off" "off" "$(uci -q get dropbear.@dropbear[0].PasswordAuth)"

# Only one of the two flipped back (an operator, a package): the other is left
# alone and the section still ends up fully hardened.
reset_uci_dropbear
uci -q set dropbear.@dropbear[0].RootPasswordAuth=off
harden_dropbear; rc=$?
[ "$rc" = 0 ] && ok || no "dropbear half-flipped: returns changed(0)" "0" "$rc"
[ "$(uci -q get dropbear.@dropbear[0].PasswordAuth)" = off ] && ok \
	|| no "dropbear half-flipped: PasswordAuth off" "off" "$(uci -q get dropbear.@dropbear[0].PasswordAuth)"

# A second dropbear section — dropbear listens on every one, so every one is
# hardened, not just the first.
reset_uci_dropbear
printf 'dropbear.@dropbear[1]=dropbear\n' >> "$UCI_STATE"
printf 'dropbear.@dropbear[1].PasswordAuth=on\n' >> "$UCI_STATE"
printf 'dropbear.@dropbear[1].RootPasswordAuth=on\n' >> "$UCI_STATE"
harden_dropbear; rc=$?
[ "$rc" = 0 ] && ok || no "dropbear two sections: returns changed(0)" "0" "$rc"
[ "$(uci -q get dropbear.@dropbear[1].PasswordAuth)" = off ] && ok \
	|| no "dropbear two sections: the second is hardened too" "off" "$(uci -q get dropbear.@dropbear[1].PasswordAuth)"

# No dropbear section at all: nothing listens, nothing to harden, and it says
# so rather than reporting a change nobody made.
: > "$UCI_STATE"
harden_dropbear; rc=$?
[ "$rc" = 1 ] && ok || no "dropbear absent: returns unchanged(1)" "1" "$rc"

echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
