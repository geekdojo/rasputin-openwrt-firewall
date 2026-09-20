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

echo ""
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
