#!/bin/sh
#
# test-node-id.sh — table tests for files/usr/lib/rasputin/node-id.sh.
#
# WHY
#   The node id is the NATS username the agent presents to the bus, and the
#   control plane accepts only a DNS label (1-63 of a-z 0-9 -, no leading or
#   trailing -). An id that breaks the rule is not caught by the build, the
#   syntax check or the boot: the box comes up and simply never joins. So the
#   derivation and the check are pinned here, case by case.
#   geekdojo/geekdojo-brain#441.
#
# SHELLS
#   The helpers run under busybox ash on the box. Every case is executed under
#   each shell listed in TEST_SHELLS (default: whichever of sh, dash, bash and
#   `busybox sh` are installed), so a construct one shell reads differently
#   fails here rather than on hardware. CI runs dash (as sh) and bash; a
#   developer can add busybox by running this inside an Alpine container.
#
# Usage: sh scripts/test-node-id.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIB="$ROOT/files/usr/lib/rasputin/node-id.sh"
[ -f "$LIB" ] || { echo "missing: $LIB" >&2; exit 2; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi

pass=0
fail=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# run SHELL FUNCTION ARG — print the function's output, then "|rc=<status>".
# The marker keeps an empty output distinguishable from a missing one.
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

long70=abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghij
first63=abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabc
# 62 chars then a space: normalizing turns the space into '-' at position 63,
# which the cut leaves trailing and the final trim must remove.
hyphen_at_63="abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijab cd"
first62=abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijab
tab=$(printf '\t')
cr=$(printf '\r')
nl='
'

for sh in $TEST_SHELLS; do
	echo "== $sh"

	# ---- rasputin_label_normalize: derived ids --------------------------
	f=rasputin_label_normalize
	expect "$sh" "mixed case"            "kitchen-pi|rc=0"   $f "Kitchen-Pi"
	expect "$sh" "spaces"                "abc-123-xyz|rc=0"  $f "ABC 123 XYZ"
	expect "$sh" "hyphens trimmed"       "x|rc=0"            $f "--x--"
	expect "$sh" "70 chars cut to 63"    "$first63|rc=0"     $f "$long70"
	expect "$sh" "hyphen at 63 trimmed"  "$first62|rc=0"     $f "$hyphen_at_63"
	expect "$sh" "wildcard only"         "|rc=0"             $f "*"
	expect "$sh" "gt only"               "|rc=0"             $f ">"
	expect "$sh" "dot"                   "a-b|rc=0"          $f "a.b"
	expect "$sh" "empty"                 "|rc=0"             $f ""
	expect "$sh" "only separators"       "|rc=0"             $f " .-_ "
	expect "$sh" "already valid"         "node-1a2b3c4d|rc=0" $f "node-1a2b3c4d"
	expect "$sh" "uuid unchanged"        "3f2b9c1e-8d4a-4c5b-9e6f-0a1b2c3d4e5f|rc=0" $f "3f2b9c1e-8d4a-4c5b-9e6f-0a1b2c3d4e5f"
	expect "$sh" "runs collapse"         "a-b|rc=0"          $f "a  ..__  b"
	expect "$sh" "tab, CR, newline"      "a-b-c-d|rc=0"      $f "a${tab}b${cr}c${nl}d"
	expect "$sh" "non-ASCII"             "caf-1|rc=0"        $f "café 1"
	expect "$sh" "shell metacharacters"  "a-b-c|rc=0"        $f 'a;$(b)`c`'
	expect "$sh" "leading dash option"   "n|rc=0"            $f "-n"

	# ---- rasputin_label_canon: operator ids (lowercase + trim only) ------
	f=rasputin_label_canon
	expect "$sh" "canon lowercases"      "kitchen-pi|rc=0"   $f "Kitchen-Pi"
	expect "$sh" "canon trims"           "fw-1|rc=0"         $f "  fw-1${tab}"
	expect "$sh" "canon strips CRLF"     "fw-1|rc=0"         $f "fw-1${cr}"
	expect "$sh" "canon trims newlines"  "fw-1|rc=0"         $f "${nl}fw-1${nl}"
	expect "$sh" "canon keeps inner"     "abc 123|rc=0"      $f " ABC 123 "
	expect "$sh" "canon keeps dot"       "a.b|rc=0"          $f "a.b"
	expect "$sh" "canon blank"           "|rc=0"             $f "   "
	expect "$sh" "canon keeps wildcard"  "*|rc=0"            $f "*"

	# ---- rasputin_label_valid ---------------------------------------------
	f=rasputin_label_valid
	expect "$sh" "valid simple"          "|rc=0"  $f "kitchen-pi"
	expect "$sh" "valid one char"        "|rc=0"  $f "a"
	expect "$sh" "valid digits"          "|rc=0"  $f "0123"
	expect "$sh" "valid 63"              "|rc=0"  $f "$first63"
	expect "$sh" "invalid 64"            "|rc=1"  $f "${first63}d"
	expect "$sh" "invalid empty"         "|rc=1"  $f ""
	expect "$sh" "invalid uppercase"     "|rc=1"  $f "Kitchen-Pi"
	expect "$sh" "invalid leading -"     "|rc=1"  $f "-a"
	expect "$sh" "invalid trailing -"    "|rc=1"  $f "a-"
	expect "$sh" "invalid lone -"        "|rc=1"  $f "-"
	expect "$sh" "invalid wildcard"      "|rc=1"  $f "*"
	expect "$sh" "invalid gt"            "|rc=1"  $f ">"
	expect "$sh" "invalid dot"           "|rc=1"  $f "a.b"
	expect "$sh" "invalid space"         "|rc=1"  $f "a b"
	expect "$sh" "invalid underscore"    "|rc=1"  $f "a_b"
	expect "$sh" "invalid tab"           "|rc=1"  $f "a${tab}b"
	expect "$sh" "invalid newline"       "|rc=1"  $f "a${nl}b"
	expect "$sh" "invalid non-ASCII"     "|rc=1"  $f "café"
	expect "$sh" "invalid bracket"       "|rc=1"  $f "a[b]"

	# ---- rasputin_dmi_node_id: the DMI walk -------------------------------
	dmi() {
		d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d"
		[ -n "$2" ] && printf '%s\n' "$2" > "$d/board_serial"
		[ -n "$3" ] && printf '%s\n' "$3" > "$d/product_serial"
		[ -n "$4" ] && printf '%s\n' "$4" > "$d/chassis_serial"
		printf '%s' "$d"
	}
	f=rasputin_dmi_node_id
	expect "$sh" "dmi uppercase serial"      "abc-123-xyz|rc=0" $f "$(dmi a "  ABC   123 XYZ " "" "")"
	expect "$sh" "dmi placeholder skipped"   "pq7|rc=0"         $f "$(dmi b "Default string" "PQ7" "")"
	expect "$sh" "dmi OEM placeholder"       "cs-9|rc=0"        $f "$(dmi c "To Be Filled By O.E.M." "Not Specified" "CS/9")"
	expect "$sh" "dmi unusable -> next"      "real1|rc=0"       $f "$(dmi d "***" "Real1" "")"
	expect "$sh" "dmi nothing usable"        "|rc=0"            $f "$(dmi e "Default string" "..." "None")"
	expect "$sh" "dmi no files"              "|rc=0"            $f "$(dmi f "" "" "")"
	expect "$sh" "dmi deterministic"         "abc-123-xyz|rc=0" $f "$(dmi g "ABC 123 XYZ" "" "")"
done

echo
if [ -z "$TEST_SHELLS" ]; then
	echo "node-id: no shell found to test under" >&2
	exit 1
fi
if [ "$fail" -eq 0 ]; then
	echo "node-id: $pass check(s) passed"
	exit 0
fi
echo "node-id: $fail check(s) FAILED, $pass passed" >&2
exit 1
