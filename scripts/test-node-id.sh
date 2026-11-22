#!/bin/sh
#
# test-node-id.sh — table tests for files/usr/lib/rasputin/node-id.sh.
#
# WHY
#   The node id is the NATS username the agent presents to the bus, and the
#   control plane accepts only a DNS label (1-63 of a-z 0-9 -, no leading or
#   trailing -). An id that breaks the rule is not caught by the build, the
#   syntax check or the boot: the box comes up and simply never joins. So the
#   check (and the lowercase/trim applied before it) is pinned here, case by
#   case. The box never derives an id (geekdojo/geekdojo-brain#423).
#   geekdojo/geekdojo-brain#441.
#
# SHELLS
#   The helpers run under busybox ash on the box. Every case is executed under
#   each shell listed in TEST_SHELLS (default: whichever of sh, dash, bash and
#   `busybox sh` are installed), so a construct one shell reads differently
#   fails here rather than on hardware. REQUIRE_BUSYBOX=1 (CI sets it; the
#   hosted runner ships busybox) turns a missing busybox into a failure, so the
#   target shell cannot silently drop out of the run.
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

first63=abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabc
tab=$(printf '\t')
cr=$(printf '\r')
nl='
'
first59=${first63%????}
first60=${first63%???}

# The three cluster-id sentences, word for word as rasputin-os prints them
# (geekdojo/geekdojo-brain#996): S1 too long, S2 the reserved prefix, S3 not a
# DNS label.
s1() { printf "The cluster id '%s' is %s characters, and a cluster id allows at most 59 so that its sign-in name, sso-<cluster id>.local, fits in one DNS label." "$1" "$2"; }
s2() { printf "The cluster id '%s' starts with sso-, which is reserved for sign-in names: every cluster signs in at sso-<cluster id>.local, so this one would publish another cluster's sign-in name." "$1"; }
s3() { printf "The cluster id '%s' is not a DNS label: it may hold only a-z, 0-9 and -, and must not start or end with -." "$1"; }

for sh in $TEST_SHELLS; do
	echo "== $sh"

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
	# rasputin_label_valid is deliberately NOT the cluster-id rule: node ids
	# keep 63, and an id accepted before geekdojo/geekdojo-brain#996 still passes.
	expect "$sh" "valid sso- (label)"    "|rc=0"  $f "sso-x"
	expect "$sh" "valid 60 (label)"      "|rc=0"  $f "$first60"

	# ---- rasputin_cluster_id_check (TC-996-10) -----------------------------
	# geekdojo/geekdojo-brain#996: at most 59 characters, a DNS label, and not
	# starting with sso-, each refusal with its own sentence.
	f=rasputin_cluster_id_check
	expect "$sh" "cluster bench"         "|rc=0"  $f "bench"
	expect "$sh" "cluster rasputin"      "|rc=0"  $f "rasputin"
	expect "$sh" "cluster sso"           "|rc=0"  $f "sso"
	expect "$sh" "cluster sso1"          "|rc=0"  $f "sso1"
	expect "$sh" "cluster 59"            "|rc=0"  $f "$first59"
	expect "$sh" "cluster sso-x (S2)"    "$(s2 sso-x)${nl}|rc=1"      $f "sso-x"
	expect "$sh" "cluster 60 (S1)"       "$(s1 "$first60" 60)${nl}|rc=1" $f "$first60"
	expect "$sh" "cluster a_b (S3)"      "$(s3 a_b)${nl}|rc=1"        $f "a_b"
	expect "$sh" "cluster home.lab (S3)" "$(s3 home.lab)${nl}|rc=1"   $f "home.lab"
	expect "$sh" "cluster sso- (S3)"     "$(s3 sso-)${nl}|rc=1"       $f "sso-"
done

echo
if [ -z "$TEST_SHELLS" ]; then
	echo "node-id: no shell found to test under" >&2
	exit 1
fi
case " $TEST_SHELLS " in
	*" busybox_sh "*) ;;
	*)
		if [ "${REQUIRE_BUSYBOX:-0}" = "1" ]; then
			echo "node-id: REQUIRE_BUSYBOX=1 but busybox is not installed — the target shell was not tested" >&2
			exit 1
		fi ;;
esac
if [ "$fail" -eq 0 ]; then
	echo "node-id: $pass check(s) passed"
	exit 0
fi
echo "node-id: $fail check(s) FAILED, $pass passed" >&2
exit 1
