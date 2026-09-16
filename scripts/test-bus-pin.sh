#!/bin/sh
#
# test-bus-pin.sh — table tests for files/usr/lib/rasputin/bus-pin.sh.
#
# WHY
#   apply-seed refuses a seed whose RASPUTIN_BUS_PIN is malformed, and writes a
#   valid one into UCI for the agent (geekdojo/geekdojo-brain#448). Its check
#   has to agree with the agent's proto.ParseBusPin in both directions: a pin
#   this accepts and the agent refuses reaches the box and silently dials
#   plaintext, and a pin this refuses and the agent would accept leaves a box
#   unprovisioned for nothing. The refusal vectors below are the agent's own
#   (proto/buspin_test.go in rasputin-control-plane), plus the strict-base64
#   case that a character-class check alone would miss.
#
#   The acceptance side is not hand-written: real pins are computed with
#   openssl, the way the contract tells an operator to check one by hand, over
#   64 fixed inputs, so every one of the 16 characters a canonical pin can end
#   on is exercised. Each is then altered into the non-canonical sibling a
#   lenient decoder would still accept, which must be refused.
#
# SHELLS
#   As scripts/test-node-id.sh: every case runs under each shell in
#   TEST_SHELLS (default: whichever of sh, dash, bash and `busybox sh` are
#   installed). REQUIRE_BUSYBOX=1 (CI) fails the run if busybox, the box's
#   shell, is missing.
#
# Usage: sh scripts/test-bus-pin.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/files/usr/lib/rasputin/bus-pin.sh"
[ -f "$LIB" ] || { echo "missing: $LIB" >&2; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo "openssl is required (it computes the reference pins)" >&2; exit 2; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi

pass=0
fail=0

# run SHELL FUNCTION ARG — print the function's output, then "|rc=<status>".
run() {
	_sh=$1; shift
	case "$_sh" in
		busybox_sh) set -- busybox sh -c '. "$0"; "$@"; printf "|rc=%s" "$?"' "$LIB" "$@" ;;
		*)          set -- "$_sh" -c '. "$0"; "$@"; printf "|rc=%s" "$?"' "$LIB" "$@" ;;
	esac
	"$@" 2>&1
}

# expect SHELL LABEL WANT FUNCTION ARG
expect() {
	_sh=$1 _label=$2 _want=$3; shift 3
	_got=$(run "$_sh" "$@")
	if [ "$_got" = "$_want" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL [%s] %s\n       want: %s\n       got:  %s\n' "$_sh" "$_label" "$_want" "$_got" >&2
	fi
}

# The contract's example pin: base64 of SHA-256 of the empty string.
good=sha256/47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=
tab=$(printf '\t')
cr=$(printf '\r')
nl='
'

# Reference pins, computed once. The 43rd base64 character of a 32-byte value
# encodes its last 4 bits followed by two zero bits, so the 16 canonical final
# characters are A E I M Q U Y c g k o s w 0 4 8. Its non-canonical sibling is
# the next character in the alphabet (low bits 01), which a lenient decoder
# accepts as the same digest and a strict one refuses.
ALPHABET=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/
REFS=""
i=0
while [ "$i" -lt 64 ]; do
	b64=$(printf 'rasputin-bus-pin-%s' "$i" | openssl dgst -sha256 -binary | openssl base64 -A)
	REFS="$REFS$b64$nl"
	i=$((i + 1))
done
# sibling B64 — the same string with its 43rd character moved up by one.
sibling() {
	_c=$(printf '%s' "$1" | cut -c43)
	_rest=${ALPHABET#*"$_c"}
	_next=$(printf '%s' "$_rest" | cut -c1)
	printf '%s%s=' "$(printf '%s' "$1" | cut -c1-42)" "$_next"
}
finals=$(printf '%s' "$REFS" | cut -c43 | sort -u | tr -d '\n')
if [ "${#finals}" -ne 16 ]; then
	echo "bus-pin: the reference inputs cover ${#finals} of the 16 canonical final characters ($finals); pick more inputs" >&2
	exit 1
fi

for sh in $TEST_SHELLS; do
	echo "== $sh"

	# ---- rasputin_seed_trim ------------------------------------------------
	f=rasputin_seed_trim
	expect "$sh" "trim nothing"          "$good|rc=0" $f "$good"
	expect "$sh" "trim spaces"           "$good|rc=0" $f "  $good  "
	expect "$sh" "trim CR (Windows)"     "$good|rc=0" $f "$good$cr"
	expect "$sh" "trim tab and newline"  "$good|rc=0" $f "$tab$good$nl"
	expect "$sh" "trim keeps inner"      "a b|rc=0"   $f " a b "
	expect "$sh" "trim blank"            "|rc=0"      $f " $tab$cr$nl "
	expect "$sh" "trim empty"            "|rc=0"      $f ""

	# ---- rasputin_bus_pin_valid: refused (the agent's vectors first) --------
	f=rasputin_bus_pin_valid
	expect "$sh" "valid: contract example" "|rc=0" $f "$good"
	expect "$sh" "refuse empty"            "|rc=1" $f ""
	expect "$sh" "refuse no prefix"        "|rc=1" $f "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
	expect "$sh" "refuse curl sha256//"    "|rc=1" $f "sha256//47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
	expect "$sh" "refuse SHA256/"          "|rc=1" $f "SHA256/47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
	expect "$sh" "refuse URL alphabet"     "|rc=1" $f "sha256/47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU="
	expect "$sh" "refuse unpadded"         "|rc=1" $f "sha256/47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU"
	expect "$sh" "refuse short"            "|rc=1" $f "sha256/47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSu"
	expect "$sh" "refuse hex"              "|rc=1" $f "sha256/e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	expect "$sh" "refuse sha1"             "|rc=1" $f "sha1/2jmj7l5rSw0yVb/vlWAYkK/YBwk="
	expect "$sh" "refuse trailing data"    "|rc=1" $f "${good}AA=="
	# ...and the ones only this side can get wrong.
	expect "$sh" "refuse untrimmed"        "|rc=1" $f " $good"
	expect "$sh" "refuse trailing CR"      "|rc=1" $f "$good$cr"
	expect "$sh" "refuse double padding"   "|rc=1" $f "sha256/47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuF=="
	expect "$sh" "refuse = inside"         "|rc=1" $f "sha256/47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3=SuFU="
	expect "$sh" "refuse 45 chars"         "|rc=1" $f "sha256/A47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="
	expect "$sh" "refuse space inside"     "|rc=1" $f "sha256/47DEQpj8HBSa+/TImW 5JCeuQeRkm5NMpJWZG3hSuFU="
	expect "$sh" "refuse newline inside"   "|rc=1" $f "sha256/47DEQpj8HBSa+/TImW${nl}5JCeuQeRkm5NMpJWZG3hSuFU="
	expect "$sh" "refuse quote"            "|rc=1" $f "sha256/47DEQpj8HBSa+/TImW'5JCeuQeRkm5NMpJWZG3hSuFU="
	expect "$sh" "refuse non-ASCII"        "|rc=1" $f "sha256/47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFé="
	expect "$sh" "refuse prefix only"      "|rc=1" $f "sha256/"
	expect "$sh" "refuse strict bits (V)"  "|rc=1" $f "sha256/47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFV="

	# ---- real pins, and their non-canonical siblings ------------------------
	# A here-document, not a pipe, so the loop runs in this shell and its
	# pass/fail counts survive it.
	while IFS= read -r b; do
		[ -n "$b" ] || continue
		expect "$sh" "openssl pin $b"      "|rc=0" $f "sha256/$b"
		sib=$(sibling "$b")
		expect "$sh" "strict sibling $sib" "|rc=1" $f "sha256/$sib"
	done <<EOF
$REFS
EOF
done

echo
if [ -z "$TEST_SHELLS" ]; then
	echo "bus-pin: no shell found to test under" >&2
	exit 1
fi
case " $TEST_SHELLS " in
	*" busybox_sh "*) ;;
	*)
		if [ "${REQUIRE_BUSYBOX:-0}" = "1" ]; then
			echo "bus-pin: REQUIRE_BUSYBOX=1 but busybox is not installed — the target shell was not tested" >&2
			exit 1
		fi ;;
esac
if [ "$fail" -eq 0 ]; then
	echo "bus-pin: $pass check(s) passed"
	exit 0
fi
echo "bus-pin: $fail check(s) FAILED, $pass passed" >&2
exit 1
