#!/usr/bin/env bash
#
# test-agent-pin.sh — scripts/agent-pin.sh, against synthetic pin files.
#
# WHY (geekdojo/geekdojo-brain#533)
#   agent-pin.sh is the only thing standing between the build and an unpinned
#   binary. Every way it can fail is silent at build time: a lenient parse bakes
#   whatever was downloaded, and a check that returns the empty string instead of
#   exiting is indistinguishable from a check that passed. So the cases here are
#   mostly REFUSALS — a mismatched digest, a hash line naming a different
#   version, a missing hash line, a malformed digest — plus the one acceptance
#   that proves the happy path still works.
#
#   The repo's own agent-version.txt is exercised too: a pin that the shipped
#   parser cannot read would fail the release build, not this test, and by then
#   the tag is burned.
#
# No network. Run: ./scripts/test-agent-pin.sh

set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
PIN="./scripts/agent-pin.sh"

fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  ✗    %s\n' "$*" >&2; fail=$((fail + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/agent-pin-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A payload whose sha256 we know without hardcoding one: compute it here, so the
# fixture and the expectation cannot drift apart.
PAYLOAD="$WORK/rasputin-agent-2026.09.4-linux-amd64.tar.gz"
printf 'not really a tarball, but it has bytes\n' > "$PAYLOAD"
if command -v sha256sum >/dev/null 2>&1; then
	GOOD_SHA="$(sha256sum "$PAYLOAD" | awk '{print $1}')"
else
	GOOD_SHA="$(shasum -a 256 "$PAYLOAD" | awk '{print $1}')"
fi
WRONG_SHA="$(printf '%s' "$GOOD_SHA" | tr '0-9a-f' '1-9a-f0')"

# write_pin <file> <line...> — a pin file with the repo's comment style, so the
# comment-stripping path is exercised rather than bypassed.
write_pin() {
	local f="$1"; shift
	{
		printf '# a comment\n'
		printf '\n'
		for l in "$@"; do printf '%s\n' "$l"; done
		printf '\n'
	} > "$f"
}

# run <pin-file> <args...> -> sets RC and OUT
run() {
	local pf="$1"; shift
	OUT="$(AGENT_PIN_FILE="$pf" "$PIN" "$@" 2>&1)"
	RC=$?
}

echo "1. a well-formed pin reads and verifies"
write_pin "$WORK/good.txt" \
	"2026.09.4" \
	"sha256  $GOOD_SHA  rasputin-agent-2026.09.4-linux-amd64.tar.gz"
run "$WORK/good.txt" version
[ "$RC" = 0 ] && [ "$OUT" = "2026.09.4" ] && ok "version" || bad "version: rc=$RC out=$OUT"
run "$WORK/good.txt" tarball
[ "$RC" = 0 ] && [ "$OUT" = "rasputin-agent-2026.09.4-linux-amd64.tar.gz" ] && ok "tarball" || bad "tarball: rc=$RC out=$OUT"
run "$WORK/good.txt" sha256
[ "$RC" = 0 ] && [ "$OUT" = "$GOOD_SHA" ] && ok "sha256" || bad "sha256: rc=$RC out=$OUT"
run "$WORK/good.txt" verify "$PAYLOAD"
[ "$RC" = 0 ] && ok "verify accepts the matching payload" || bad "verify: rc=$RC out=$OUT"

echo "2. refusals — each of these would otherwise bake an unpinned binary"

# The case the pin exists FOR: the published asset's bytes changed.
write_pin "$WORK/mismatch.txt" \
	"2026.09.4" \
	"sha256  $WRONG_SHA  rasputin-agent-2026.09.4-linux-amd64.tar.gz"
run "$WORK/mismatch.txt" verify "$PAYLOAD"
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "MISMATCH" \
	&& ok "a digest that does not match the download is refused" \
	|| bad "mismatch not refused: rc=$RC out=$OUT"

# The drift case: someone bumped the version and left the old hash line.
write_pin "$WORK/drift.txt" \
	"2026.09.5" \
	"sha256  $GOOD_SHA  rasputin-agent-2026.09.4-linux-amd64.tar.gz"
run "$WORK/drift.txt" verify "$PAYLOAD"
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "inconsistent" \
	&& ok "a hash line naming another version is refused" \
	|| bad "drift not refused: rc=$RC out=$OUT"
run "$WORK/drift.txt" sha256
[ "$RC" != 0 ] && ok "…and 'sha256' refuses it too, not just 'verify'" \
	|| bad "drift accepted by sha256: rc=$RC out=$OUT"

# No hash line at all — the pre-#533 file shape. It must fail, not fall back.
write_pin "$WORK/nohash.txt" "2026.09.4"
run "$WORK/nohash.txt" verify "$PAYLOAD"
[ "$RC" != 0 ] && printf '%s' "$OUT" | grep -q "no sha256 line" \
	&& ok "a pin with no hash line is refused, not waved through" \
	|| bad "missing hash not refused: rc=$RC out=$OUT"
run "$WORK/nohash.txt" version
[ "$RC" = 0 ] && [ "$OUT" = "2026.09.4" ] \
	&& ok "…while 'version' still reads it (the bump path stays usable)" \
	|| bad "version broke on a hash-less pin: rc=$RC out=$OUT"

# A digest that is the right shape but not lowercase hex of length 64.
write_pin "$WORK/badsum.txt" \
	"2026.09.4" \
	"sha256  DEADBEEF  rasputin-agent-2026.09.4-linux-amd64.tar.gz"
run "$WORK/badsum.txt" sha256
[ "$RC" != 0 ] && ok "a malformed digest is refused" || bad "malformed digest accepted: rc=$RC out=$OUT"

# Wrong algorithm keyword — a sha1 line must not be read as sha256.
write_pin "$WORK/badalgo.txt" \
	"2026.09.4" \
	"sha1  $GOOD_SHA  rasputin-agent-2026.09.4-linux-amd64.tar.gz"
run "$WORK/badalgo.txt" sha256
[ "$RC" != 0 ] && ok "a non-sha256 hash line is refused" || bad "sha1 line accepted: rc=$RC out=$OUT"

# A third payload line is a half-finished edit, not a second pin.
write_pin "$WORK/three.txt" \
	"2026.09.4" \
	"sha256  $GOOD_SHA  rasputin-agent-2026.09.4-linux-amd64.tar.gz" \
	"sha256  $WRONG_SHA  rasputin-agent-2026.09.4-linux-amd64.tar.gz"
run "$WORK/three.txt" sha256
[ "$RC" != 0 ] && ok "a third payload line is refused" || bad "third line ignored: rc=$RC out=$OUT"

# A leading `v` is the shape the release TAG uses; the pin is bare CalVer.
write_pin "$WORK/vprefix.txt" \
	"v2026.09.4" \
	"sha256  $GOOD_SHA  rasputin-agent-v2026.09.4-linux-amd64.tar.gz"
run "$WORK/vprefix.txt" version
[ "$RC" != 0 ] && ok "a v-prefixed version is refused" || bad "v-prefix accepted: rc=$RC out=$OUT"

run "$WORK/good.txt" verify "$WORK/does-not-exist.tar.gz"
[ "$RC" != 0 ] && ok "a missing download is refused" || bad "missing file accepted: rc=$RC out=$OUT"

echo "3. the pin this repo actually ships parses"
V="$("$PIN" version)"; rcv=$?
S="$("$PIN" sha256)";  rcs=$?
T="$("$PIN" tarball)"; rct=$?
if [ "$rcv" = 0 ] && [ "$rcs" = 0 ] && [ "$rct" = 0 ]; then
	ok "agent-version.txt: $V / $T / $S"
else
	bad "agent-version.txt does not parse (version rc=$rcv, sha256 rc=$rcs, tarball rc=$rct)"
	"$PIN" sha256 >/dev/null
fi

echo ""
if [ "$fail" -ne 0 ]; then
	echo "FAILED — $fail problem(s)." >&2
	exit 1
fi
echo "OK — agent-pin.sh refuses every unpinned shape and accepts the pinned one."
