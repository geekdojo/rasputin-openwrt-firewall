#!/usr/bin/env bash
#
# test-snort-rules-pin.sh — unit tests for the Snort rules pin:
#   scripts/fetch-snort-rules.sh              (mirror fetch + SHA verification)
#   scripts/rasputin-snort-rules-freshness.sh (pre-flight gate + canary report)
#
# WHY
#   Both are hand-rolled gates on a supply-chain path (geekdojo/geekdojo-brain#208).
#   Their failure modes are silent in the direction that matters: a verification
#   that stops verifying still builds, and a freshness gate that stops failing
#   still goes green. Each case below pins one decision.
#
# HOW
#   No network. A throwaway repo tree gets copies of the two scripts, with
#   PINNED_SHA rewritten to the SHA of a fixture tarball shaped like the real one
#   (the five-member snort3-community-rules/ layout). A local `python3 -m
#   http.server` plays both snort.org and the mirror, so HEAD and 404 behave like
#   real HTTP. The URL overrides the scripts accept (SNORT_RULES_MIRROR_BASE,
#   SNORT_RULES_UPSTREAM_URL) point them at it.
#
# NEEDS: bash, python3, curl, tar, gzip, sha256sum.
#
# Usage: ./scripts/test-snort-rules-pin.sh

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t rasputin-rules-pin-test.XXXXXX)"
SERVER_PID=""
cleanup() {
	[ -z "$SERVER_PID" ] || kill "$SERVER_PID" 2>/dev/null || true
	rm -rf "$TMP"
}
trap cleanup EXIT

pass=0
fail=0
ok()  { printf '  ✓ %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  ✗ %s\n' "$*" >&2; fail=$((fail + 1)); }

for tool in python3 curl tar gzip sha256sum; do
	command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 2; }
done

# --- fixtures -----------------------------------------------------------------
# make_tarball OUT RULE_MSG — a tarball in the real layout; RULE_MSG varies the bytes.
make_tarball() {
	local out="$1" msg="$2" d
	d="$(mktemp -d "$TMP/tarball.XXXXXX")"
	mkdir -p "$d/snort3-community-rules"
	printf 'alert tcp any any -> any any ( msg:"%s"; sid:1000001; rev:1; )\n# alert tcp any any -> any any ( msg:"disabled"; sid:1000002; rev:1; )\n' \
		"$msg" > "$d/snort3-community-rules/snort3-community.rules"
	echo "1000001 || $msg" > "$d/snort3-community-rules/sid-msg.map"
	echo "fixture license" > "$d/snort3-community-rules/VRT-License.txt"
	echo "fixture license" > "$d/snort3-community-rules/LICENSE"
	echo "fixture authors" > "$d/snort3-community-rules/AUTHORS"
	(cd "$d" && tar -czf "$out" snort3-community-rules)
	rm -rf "$d"
}
sha_of() { sha256sum "$1" | awk '{print $1}'; }

WWW="$TMP/www"
mkdir -p "$WWW/upstream" "$WWW/mirror"
make_tarball "$TMP/pinned.tar.gz" "pinned rules"
make_tarball "$TMP/newer.tar.gz" "newer upstream rules"
make_tarball "$TMP/tampered.tar.gz" "tampered rules"
PIN="$(sha_of "$TMP/pinned.tar.gz")"
NEWER="$(sha_of "$TMP/newer.tar.gz")"
TAMPERED="$(sha_of "$TMP/tampered.tar.gz")"
[ "$PIN" != "$NEWER" ] && [ "$PIN" != "$TAMPERED" ] || { echo "fixture tarballs are not distinct" >&2; exit 2; }

mirror_put() { mkdir -p "$WWW/mirror/sha256-$1"; cp "$2" "$WWW/mirror/sha256-$1/snort3-community-rules.tar.gz"; }
mirror_clear() { rm -rf "$WWW/mirror"; mkdir -p "$WWW/mirror"; }
upstream_put() { cp "$1" "$WWW/upstream/snort3-community-rules.tar.gz"; }

# --- local HTTP server, bounded start ------------------------------------------
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$WWW" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!
disown "$SERVER_PID" 2>/dev/null || true
PORT=""
deadline=$(( $(date +%s) + 15 ))
while [ -z "$PORT" ]; do
	PORT="$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$TMP/server.log" | head -n 1)"
	[ -n "$PORT" ] && break
	if ! kill -0 "$SERVER_PID" 2>/dev/null || [ "$(date +%s)" -ge "$deadline" ]; then
		echo "local HTTP server never reported a port within 15s:" >&2
		cat "$TMP/server.log" >&2
		exit 2
	fi
	sleep 0.2
done
BASE="http://127.0.0.1:$PORT"
deadline=$(( $(date +%s) + 15 ))
until curl -fsS -o /dev/null "$BASE/"; do
	[ "$(date +%s)" -lt "$deadline" ] || { echo "local HTTP server on $BASE never answered within 15s" >&2; exit 2; }
	sleep 0.2
done
export SNORT_RULES_MIRROR_BASE="$BASE/mirror"
export SNORT_RULES_UPSTREAM_URL="$BASE/upstream/snort3-community-rules.tar.gz"

# --- a throwaway repo tree with the pin rewritten ------------------------------
# new_tree — fresh copy, PINNED_SHA := $PIN; prints the tree's path.
new_tree() {
	local t
	t="$(mktemp -d "$TMP/tree.XXXXXX")"
	mkdir -p "$t/scripts" "$t/files/etc/snort"
	cp "$SRC/scripts/fetch-snort-rules.sh" "$SRC/scripts/rasputin-snort-rules-freshness.sh" "$t/scripts/"
	sed "s/^PINNED_SHA=\"[0-9a-f]\{64\}\"\$/PINNED_SHA=\"$PIN\"/" "$SRC/scripts/fetch-snort-rules.sh" > "$t/scripts/fetch-snort-rules.sh"
	chmod +x "$t/scripts/"*.sh
	printf '%s' "$t"
}
t="$(new_tree)"
if [ "$(grep -c "^PINNED_SHA=\"$PIN\"\$" "$t/scripts/fetch-snort-rules.sh")" = 1 ] \
   && [ "$(grep -c '^PINNED_SHA=' "$t/scripts/fetch-snort-rules.sh")" = 1 ]; then
	ok "fixture: exactly one PINNED_SHA line, rewritten to the fixture pin"
else
	bad "fixture: could not rewrite PINNED_SHA (the pin line's shape changed?)"
	exit 1
fi

# run NAME WANT_EXIT CMD... — output kept in $TMP/NAME.log
run() {
	local name="$1" want="$2" got=0
	shift 2
	"$@" > "$TMP/$name.log" 2>&1 || got=$?
	if [ "$got" -eq "$want" ]; then ok "$name: exit $got"; else bad "$name: exit $got, want $want"; sed 's/^/      | /' "$TMP/$name.log" >&2; fi
}
has()    { if grep -Fq -- "$3" "$TMP/$1.log"; then ok "$1: $2"; else bad "$1: $2 (missing: $3)"; fi; }
hasnt()  { if grep -Fq -- "$3" "$TMP/$1.log"; then bad "$1: $2 (unexpected: $3)"; else ok "$1: $2"; fi; }
file_is() { if [ "$(cat "$3" 2>/dev/null)" = "$4" ]; then ok "$1: $2"; else bad "$1: $2 (got '$(cat "$3" 2>/dev/null)')"; fi; }
output_is() { if grep -qx -- "$3" "$4"; then ok "$1: $2"; else bad "$1: $2 (no '$3' in outputs: $(tr '\n' ' ' < "$4"))"; fi; }

echo "== fetch-snort-rules.sh: mirror fetch + SHA verification"

mirror_clear; mirror_put "$PIN" "$TMP/pinned.tar.gz"; upstream_put "$TMP/pinned.tar.gz"
t="$(new_tree)"
run fetch-verified 0 "$t/scripts/fetch-snort-rules.sh"
has fetch-verified "prints sha256 verified" "sha256 verified: $PIN"
has fetch-verified "downloads from the mirror at the pin" "$BASE/mirror/sha256-$PIN/snort3-community-rules.tar.gz"
hasnt fetch-verified "never touches upstream" "/upstream/"
file_is fetch-verified "stamp records the verified SHA" "$t/files/etc/snort/.snort3-community-stamp" "$PIN"
if grep -q 'pinned rules' "$t/files/etc/snort/rules/snort3-community.rules" 2>/dev/null; then ok "fetch-verified: pinned rules staged into rules/"; else bad "fetch-verified: rules not staged"; fi

run fetch-idempotent 0 "$t/scripts/fetch-snort-rules.sh"
has fetch-idempotent "skips when the stamp matches" "stamp matches); skipping"

# Tampered mirror: bytes at sha256-<PIN> that hash to something else.
mirror_clear; mirror_put "$PIN" "$TMP/tampered.tar.gz"
t="$(new_tree)"
run fetch-tampered 1 "$t/scripts/fetch-snort-rules.sh"
has fetch-tampered "names the expected SHA" "expected: $PIN"
has fetch-tampered "names the actual SHA" "actual:   $TAMPERED"
has fetch-tampered "says not to copy the actual SHA" "do NOT copy the actual SHA"
if [ ! -e "$t/files/etc/snort/rules" ] && [ ! -e "$t/files/etc/snort/.snort3-community-stamp" ]; then
	ok "fetch-tampered: nothing staged, no stamp written"
else
	bad "fetch-tampered: staged content or a stamp despite the mismatch"
fi

# A stamp that lies must not be trusted past a FORCE re-fetch of tampered bytes.
echo "$PIN" > "$t/files/etc/snort/.snort3-community-stamp"
run fetch-force-tampered 1 env FORCE=1 "$t/scripts/fetch-snort-rules.sh"

# The mirror lacks the pin entirely.
mirror_clear
t="$(new_tree)"
run fetch-mirror-missing 1 "$t/scripts/fetch-snort-rules.sh"
has fetch-mirror-missing "explains the mirror has no such release" "could not download the pinned Snort3 Community Rules from the mirror"

# REPORT_DRIFT must never stage unverified bytes: tampered mirror is still fatal.
mirror_put "$PIN" "$TMP/tampered.tar.gz"; upstream_put "$TMP/tampered.tar.gz"
t="$(new_tree)"
run report-tampered 1 env REPORT_DRIFT=1 GITHUB_OUTPUT="$TMP/report-tampered.out" "$t/scripts/fetch-snort-rules.sh"
[ ! -e "$t/files/etc/snort/rules" ] && ok "report-tampered: nothing staged" || bad "report-tampered: staged unverified rules"

echo "== canary path: REPORT_DRIFT=1 stages the PIN, reports upstream"

mirror_clear; mirror_put "$PIN" "$TMP/pinned.tar.gz"; upstream_put "$TMP/pinned.tar.gz"
t="$(new_tree)"; : > "$TMP/report-fresh.out"
run report-fresh 0 env REPORT_DRIFT=1 GITHUB_OUTPUT="$TMP/report-fresh.out" "$t/scripts/fetch-snort-rules.sh"
output_is report-fresh "rules_drift=false" "rules_drift=false" "$TMP/report-fresh.out"
output_is report-fresh "rules_pinned_sha" "rules_pinned_sha=$PIN" "$TMP/report-fresh.out"
output_is report-fresh "rules_actual_sha" "rules_actual_sha=$PIN" "$TMP/report-fresh.out"

upstream_put "$TMP/newer.tar.gz"; mirror_put "$NEWER" "$TMP/newer.tar.gz"
t="$(new_tree)"; : > "$TMP/report-drift.out"
run report-drift 0 env REPORT_DRIFT=1 GITHUB_OUTPUT="$TMP/report-drift.out" "$t/scripts/fetch-snort-rules.sh"
output_is report-drift "rules_drift=true" "rules_drift=true" "$TMP/report-drift.out"
output_is report-drift "rules_actual_sha is upstream's" "rules_actual_sha=$NEWER" "$TMP/report-drift.out"
output_is report-drift "rules_mirror_status=present" "rules_mirror_status=present" "$TMP/report-drift.out"
has report-drift "warns, both SHAs printed" "upstream today:      $NEWER"
hasnt report-drift "no ::error:: on a deliberate success" "::error::"
if grep -q 'pinned rules' "$t/files/etc/snort/rules/snort3-community.rules" 2>/dev/null \
   && ! grep -q 'newer upstream' "$t/files/etc/snort/rules/snort3-community.rules"; then
	ok "report-drift: staged the verified PIN, not upstream's bytes"
else
	bad "report-drift: staged something other than the pinned rules"
fi
file_is report-drift "stamp is the pin" "$t/files/etc/snort/.snort3-community-stamp" "$PIN"

# Idempotent skip must still report: the stamp says nothing about upstream.
: > "$TMP/report-skip.out"
run report-skip 0 env REPORT_DRIFT=1 GITHUB_OUTPUT="$TMP/report-skip.out" "$t/scripts/fetch-snort-rules.sh"
has report-skip "took the idempotent skip" "stamp matches); skipping"
output_is report-skip "still reported drift after skipping" "rules_drift=true" "$TMP/report-skip.out"

# Upstream unreachable: the canary must not die.
rm -f "$WWW/upstream/snort3-community-rules.tar.gz"
t="$(new_tree)"; : > "$TMP/report-unreachable.out"
run report-unreachable 0 env REPORT_DRIFT=1 GITHUB_OUTPUT="$TMP/report-unreachable.out" "$t/scripts/fetch-snort-rules.sh"
output_is report-unreachable "rules_drift=unknown" "rules_drift=unknown" "$TMP/report-unreachable.out"
output_is report-unreachable "rules_actual_sha=unavailable" "rules_actual_sha=unavailable" "$TMP/report-unreachable.out"

echo "== rasputin-snort-rules-freshness.sh: pre-flight gate"

mirror_clear; mirror_put "$PIN" "$TMP/pinned.tar.gz"; upstream_put "$TMP/pinned.tar.gz"
t="$(new_tree)"
run gate-match 0 "$t/scripts/rasputin-snort-rules-freshness.sh"
has gate-match "says fresh" "pin is fresh"

upstream_put "$TMP/newer.tar.gz"; mirror_put "$NEWER" "$TMP/newer.tar.gz"
run gate-stale-mirror-has 1 "$t/scripts/rasputin-snort-rules-freshness.sh"
has gate-stale-mirror-has "::error:: annotation" "::error::Snort3 Community Rules pin is stale"
has gate-stale-mirror-has "prints the pinned SHA" "pinned (PINNED_SHA): $PIN"
has gate-stale-mirror-has "prints the upstream SHA" "upstream today:      $NEWER"
has gate-stale-mirror-has "says the mirror already has it, re-pin now" "mirror: ALREADY HAS sha256-$NEWER (HTTP 200) — re-pin now"
hasnt gate-stale-mirror-has "does not say refresh the mirror" "refresh the mirror FIRST"
hasnt gate-stale-mirror-has "does not print the refresh command" "rasputin-refresh.yml"

rm -rf "$WWW/mirror/sha256-$NEWER"
run gate-stale-mirror-lacks 1 "$t/scripts/rasputin-snort-rules-freshness.sh"
has gate-stale-mirror-lacks "prints the pinned SHA" "pinned (PINNED_SHA): $PIN"
has gate-stale-mirror-lacks "prints the upstream SHA" "upstream today:      $NEWER"
has gate-stale-mirror-lacks "says refresh the mirror first" "mirror: does NOT have sha256-$NEWER yet (HTTP 404) — refresh the mirror FIRST"
has gate-stale-mirror-lacks "names the exact refresh command" "    gh workflow run rasputin-refresh.yml --repo geekdojo/rasputin-snort3-rules-mirror"
hasnt gate-stale-mirror-lacks "does not say re-pin now" "re-pin now"

# The mirror cannot be asked at all (nothing listens on port 9 of localhost here).
run gate-stale-mirror-unknown 1 env SNORT_RULES_MIRROR_BASE="http://127.0.0.1:9/mirror" "$t/scripts/rasputin-snort-rules-freshness.sh"
has gate-stale-mirror-unknown "says it could not tell" "mirror: could not tell whether it has sha256-$NEWER"
has gate-stale-mirror-unknown "names the exact refresh command" "    gh workflow run rasputin-refresh.yml --repo geekdojo/rasputin-snort3-rules-mirror"

rm -f "$WWW/upstream/snort3-community-rules.tar.gz"
run gate-upstream-unreachable 1 "$t/scripts/rasputin-snort-rules-freshness.sh"
has gate-upstream-unreachable "fails closed, explains why" "freshness cannot be proven"

# The pin must come from fetch-snort-rules.sh, and a broken pin is exit 2, not a verdict.
sed -i.bak 's/^PINNED_SHA="[0-9a-f]\{64\}"$/PINNED_SHA="not-a-sha"/' "$t/scripts/fetch-snort-rules.sh"
run gate-bad-pin 2 "$t/scripts/rasputin-snort-rules-freshness.sh"

echo
if [ "$fail" -eq 0 ]; then
	echo "snort rules pin: $pass check(s) passed"
	exit 0
fi
echo "snort rules pin: $fail check(s) FAILED, $pass passed" >&2
exit 1
