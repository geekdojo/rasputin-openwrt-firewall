#!/bin/sh
#
# test-set-root-hash.sh — behaviour tests for
# files/usr/lib/rasputin/set-root-hash.
#
# WHY
#   set-root-hash installs a control-plane-delivered root password HASH into
#   /etc/shadow (geekdojo/geekdojo-brain#558). Two properties must hold and
#   neither is visible to a syntax check or the build:
#     - it accepts a real crypt hash (and an explicit lock token) and rewrites
#       ONLY root's password field, leaving every other field and every other
#       row byte-intact;
#     - it fails closed on anything that is not a hash — empty, a plaintext, or
#       a value that would corrupt the shadow row (':' or whitespace) — leaving
#       /etc/shadow exactly as it was, and it never echoes the candidate value.
#
#   A regression in either silently either bricks console/root login or stores
#   a plaintext where a hash belongs. So each case is pinned here.
#
# SHELLS
#   The script runs under busybox ash on the box. Every case runs under each
#   shell in TEST_SHELLS (default: whichever of sh, dash, bash and `busybox sh`
#   exist). REQUIRE_BUSYBOX=1 (CI sets it) makes a missing busybox a failure.
#
# Usage: sh scripts/test-set-root-hash.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/files/usr/lib/rasputin/set-root-hash"
[ -f "$SUT" ] || { echo "missing: $SUT" >&2; exit 2; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi
if [ "${REQUIRE_BUSYBOX:-0}" = 1 ]; then
	case " $TEST_SHELLS " in *" busybox_sh "*) : ;; *) echo "REQUIRE_BUSYBOX=1 but busybox not found" >&2; exit 2 ;; esac
fi

pass=0
fail=0

# A representative stock shadow file. The root row is the empty-password default
# OpenWrt ships; the other rows are system accounts that must never be touched.
STOCK='root:::0:99999:7:::
daemon:*:0:0:99999:7:::
nobody:*:0:0:99999:7:::
ntp:x:0:0:99999:7:::'

# A real crypt hash produced by openssl if available, else a fixed literal of
# the same shape (the script only inspects the shape, never verifies the hash).
if command -v openssl >/dev/null 2>&1; then
	SAMPLE_HASH=$(openssl passwd -6 -salt rasputintest hunter2 2>/dev/null)
fi
[ -n "${SAMPLE_HASH:-}" ] || SAMPLE_HASH='$6$rasputintest$0123456789abcdefABCDEF0123456789abcdefABCDEF0123456789abcdef01234567890.'

# run_sut SHELL [ARG...] — run set-root-hash under SHELL against a fresh scratch
# shadow, with the candidate passed as $1 (or, if ARG is the literal @stdin,
# on stdin). Prints "<rc>|<root-field-after>|<whole-file-changed?>".
SCRATCH=""
cleanup() { [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"; }
trap cleanup EXIT
SCRATCH=$(mktemp -d 2>/dev/null || mktemp -d -t setroothash)

_n=0
run_sut() {
	_sh=$1; shift
	_mode=$1; shift          # arg | stdin
	_val=$1
	_n=$((_n + 1))
	sf="$SCRATCH/shadow.$$.$_n"
	printf '%s\n' "$STOCK" > "$sf"
	before=$(cat "$sf")

	case "$_sh" in busybox_sh) set -- busybox sh ;; *) set -- "$_sh" ;; esac
	if [ "$_mode" = stdin ]; then
		out=$(RASPUTIN_SHADOW_FILE="$sf" printf '%s' "$_val" | RASPUTIN_SHADOW_FILE="$sf" "$@" "$SUT" 2>/dev/null)
		rc=$?
	else
		out=$(RASPUTIN_SHADOW_FILE="$sf" "$@" "$SUT" "$_val" 2>/dev/null)
		rc=$?
	fi
	rootf=$(awk -F: '$1=="root"{print $2; exit}' "$sf")
	after=$(cat "$sf")
	[ "$before" = "$after" ] && changed=no || changed=yes
	# Guard: the error path must never print the candidate value.
	leaked=no
	if [ -n "$_val" ] && printf '%s' "$out" | grep -qF -- "$_val" 2>/dev/null; then leaked=yes; fi
	printf '%s|%s|%s|%s' "$rc" "$rootf" "$changed" "$leaked"
	rm -f "$sf"
}

# expect SHELL LABEL WANT MODE VAL
expect() {
	_sh=$1 _label=$2 _want=$3 _mode=$4 _val=$5
	_got=$(run_sut "$_sh" "$_mode" "$_val")
	if [ "$_got" = "$_want" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL [%s] %s\n       want: %s\n       got:  %s\n' "$_sh" "$_label" "$_want" "$_got" >&2
	fi
}

for sh in $TEST_SHELLS; do
	echo "== $sh"

	# --- accepted: a real crypt hash, via arg and via stdin -------------------
	expect "$sh" "sha512 hash (arg) applied"   "0|$SAMPLE_HASH|yes|no" arg   "$SAMPLE_HASH"
	expect "$sh" "sha512 hash (stdin) applied" "0|$SAMPLE_HASH|yes|no" stdin "$SAMPLE_HASH"

	# CR-terminated (delivered/edited on Windows) still applies, trimmed.
	expect "$sh" "hash with trailing CR trimmed" "0|$SAMPLE_HASH|yes|no" arg  "$(printf '%s\r' "$SAMPLE_HASH")"

	# other crypt families and explicit lock tokens
	expect "$sh" "md5crypt (\$1\$) accepted"    "0|\$1\$abcdefgh\$0123456789abcdefghijk.|yes|no" arg '$1$abcdefgh$0123456789abcdefghijk.'
	expect "$sh" "yescrypt (\$y\$) accepted"    "0|\$y\$j9T\$saltsalt\$hashhashhash|yes|no"       arg '$y$j9T$saltsalt$hashhashhash'
	expect "$sh" "lock token '*' accepted"      "0|*|yes|no"  arg '*'
	expect "$sh" "lock token '!' accepted"      "0|!|yes|no"  arg '!'

	# --- rejected: fail closed, shadow unchanged ------------------------------
	# root field stays the stock empty value, nothing changed.
	expect "$sh" "empty value refused"          "1||no|no"  arg   ''
	expect "$sh" "plaintext (no \$) refused"    "1||no|no"  arg   'hunter2'
	expect "$sh" "value with ':' refused"       "1||no|no"  arg   '$6$salt$ab:cd'
	expect "$sh" "value with space refused"     "1||no|no"  arg   '$6$sa lt$abcd'
done

# --- the console login prompt goes on WITH the password, never before --------
#
# Stock OpenWrt leaves system.@system[0].ttylogin unset, and
# /usr/libexec/login.sh then runs `exec /bin/login -f root` (verified in
# OpenWrt v25.12.5's package/base-files): the serial port and the BMC
# serial-over-LAN session hand out a root shell with no prompt. The prompt is
# only an improvement once there is a password to answer it with, so the flip
# rides on a successful hash apply and NOT on a lock token — a locked account
# plus a prompt is an operator locked out of the last channel that works when
# the network does not (#587, Bryce 2026-09-19).
#
# `uci` does not exist off-box, so these cases put a recording stub on PATH.
echo "== console login prompt (ttylogin)"

UCIBIN="$SCRATCH/bin"
mkdir -p "$UCIBIN"
cat > "$UCIBIN/uci" <<'UCIEOF'
#!/bin/sh
# Records `set`/`commit` into $UCI_LOG and answers `get` from $UCI_STATE.
[ "${1:-}" = "-q" ] && shift
case "${1:-}" in
	get)   [ -f "$UCI_STATE" ] && cat "$UCI_STATE" || exit 1 ;;
	set)   printf 'set %s
' "${2:-}" >> "$UCI_LOG"
	       printf '%s' "${2#*=}" | tr -d "'" > "$UCI_STATE" ;;
	commit) printf 'commit %s
' "${2:-}" >> "$UCI_LOG" ;;
	*)     : ;;
esac
exit 0
UCIEOF
chmod 755 "$UCIBIN/uci"

# tty_case LABEL VALUE WANT_TTYLOGIN_SET(yes|no)
tty_case() {
	_label=$1 _val=$2 _want=$3
	_sf="$SCRATCH/shadow.tty.$$"
	printf '%s
' "$STOCK" > "$_sf"
	_log="$SCRATCH/uci.log.$$"; : > "$_log"
	_st="$SCRATCH/uci.state.$$"; rm -f "$_st"
	PATH="$UCIBIN:$PATH" UCI_LOG="$_log" UCI_STATE="$_st" 		RASPUTIN_SHADOW_FILE="$_sf" sh "$SUT" "$_val" >/dev/null 2>&1
	if grep -q 'ttylogin=' "$_log" 2>/dev/null; then _got=yes; else _got=no; fi
	if [ "$_got" = "$_want" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL %s
       want ttylogin set: %s
       got:  %s
' "$_label" "$_want" "$_got" >&2
	fi
	# And the hash itself must never appear in what was handed to uci.
	if [ -s "$_log" ] && grep -qF -- "$_val" "$_log" 2>/dev/null; then
		fail=$((fail + 1))
		printf '  FAIL %s: the hash reached the uci call
' "$_label" >&2
	else
		pass=$((pass + 1))
	fi
	rm -f "$_sf" "$_log" "$_st"
}

tty_case "a delivered hash turns the console prompt on" "$SAMPLE_HASH" yes
tty_case "lock token '*' leaves the console alone"      '*'            no
tty_case "lock token '!' leaves the console alone"      '!'            no

# Already on: no second commit, so a re-apply does not thrash the config.
_sf="$SCRATCH/shadow.tty.again"; printf '%s\n' "$STOCK" > "$_sf"
_log="$SCRATCH/uci.log.again"; : > "$_log"
_st="$SCRATCH/uci.state.again"; printf '1' > "$_st"
PATH="$UCIBIN:$PATH" UCI_LOG="$_log" UCI_STATE="$_st" \
	RASPUTIN_SHADOW_FILE="$_sf" sh "$SUT" "$SAMPLE_HASH" >/dev/null 2>&1
if [ -s "$_log" ]; then
	fail=$((fail + 1))
	printf '  FAIL ttylogin already 1: committed anyway\n' >&2
else
	pass=$((pass + 1))
fi
# The password still applied, which is the part that must never depend on uci.
_rf=$(awk -F: '$1=="root"{print $2; exit}' "$_sf")
if [ "$_rf" = "$SAMPLE_HASH" ]; then pass=$((pass + 1)); else
	fail=$((fail + 1)); printf '  FAIL ttylogin already 1: the hash was not applied\n' >&2
fi

# No uci at all (a box mid-upgrade, or any off-box run): the password STILL
# applies. The prompt is best-effort by design — rasputin-mgmt-harden
# re-asserts it on the next boot from root's shadow field — and a uci that is
# missing or failing must never fail the delivery the control plane is
# waiting on.
#
# The `expect` cases above already run with no uci on PATH and all of them
# apply the hash, so that IS the coverage. This guard keeps the claim true:
# if a runner ever grows a uci, those cases stop proving it and this says so
# instead of passing quietly.
if command -v uci >/dev/null 2>&1; then
	fail=$((fail + 1))
	printf '  FAIL this runner has uci on PATH, so the cases above no longer cover the no-uci path\n' >&2
else
	pass=$((pass + 1))
fi

echo ""
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
