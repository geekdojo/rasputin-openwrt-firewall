#!/usr/bin/env bash
#
# fetch-snort-rules.sh — download the Snort3 Community ruleset and stage
# it into files/etc/snort/ for the ImageBuilder overlay.
#
# Rationale: Cisco Talos-maintained, snort3-native, free, no oinkcode.
# It's also what the OpenWrt snort-rules helper script downloads by
# default when no oinkcode is configured — so we're aligned with the
# package's expectations.
#
# History (worth keeping in mind for future ruleset swaps): the first
# version of this script bundled ET Open from
# https://rules.emergingthreats.net/open/snort-3.0.0/ — despite the
# URL's "snort-3.0.0" path, those rules still use snort2-era keyword
# placement (threshold/distance/within/fast_pattern bareword usage)
# that snort 3.10.0.0 rejects with "unknown rule keyword" — 212,249
# parse errors on the first hardware bring-up, resulting in
# `FATAL: see prior 212249 errors`. Snort3 Community Rules are
# snort3-native and parse cleanly. Swapped 2026-06-08 on the CWWK.
#
# Rule updates ride image releases (sysupgrade cadence); per-deployment
# rule pushes are a backlog item. Bump PINNED_SHA when refreshing.
#
# Usage:
#   ./scripts/fetch-snort-rules.sh           # idempotent — skips if up to date
#   FORCE=1 ./scripts/fetch-snort-rules.sh   # re-fetch even if stamp matches

set -euo pipefail

RULES_URL="https://www.snort.org/downloads/community/snort3-community-rules.tar.gz"
# Bumped 2026-06-09: snort.org refreshed the Community Rules between the
# dev.2 pin (df1de9995bc6...) and dev.4 — Talos publishes new versions
# regularly (~weekly cadence). The SHA mismatch caught dev.4 CI exactly
# as designed; bumping the pin here is the routine refresh path.
PINNED_SHA="bb947bc0253022a58cfa67c0e7957547654a680595dff313027c2e785ad63de5"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_DIR="$REPO_ROOT/files/etc/snort"
RULES_DIR="$STAGE_DIR/rules"
STAMP_FILE="$STAGE_DIR/.snort3-community-stamp"
TMP_TAR="$(mktemp -t snort3-community.tar.gz.XXXXXX)"
trap 'rm -f "$TMP_TAR"' EXIT

if [ "${FORCE:-0}" != "1" ] && [ -f "$STAMP_FILE" ]; then
	if [ "$(cat "$STAMP_FILE")" = "$PINNED_SHA" ]; then
		echo "snort rules already at $PINNED_SHA (stamp matches); skipping"
		exit 0
	fi
	echo "stamp mismatch (have=$(cat "$STAMP_FILE") want=$PINNED_SHA); re-fetching"
fi

echo "fetching $RULES_URL"
curl -fsSL --retry 3 --retry-delay 2 -o "$TMP_TAR" "$RULES_URL"

actual_sha=$(sha256sum "$TMP_TAR" | awk '{print $1}')
if [ "$actual_sha" != "$PINNED_SHA" ]; then
	echo "::error::Snort3 Community Rules tarball SHA mismatch" >&2
	echo "  expected: $PINNED_SHA" >&2
	echo "  actual:   $actual_sha" >&2
	echo "If the upstream ruleset moved on intentionally, update PINNED_SHA in this script." >&2
	exit 1
fi
echo "sha256 verified: $actual_sha"

# Wipe any prior build-fetched content and reseed.
rm -rf "$RULES_DIR"
mkdir -p "$RULES_DIR"
rm -f "$STAGE_DIR"/*.txt "$STAGE_DIR/sid-msg.map" "$STAGE_DIR/AUTHORS" "$STAGE_DIR/LICENSE"

# Snort3 Community tarball layout: snort3-community-rules/{snort3-community.rules,
# sid-msg.map, VRT-License.txt, LICENSE, AUTHORS}. We unpack the whole
# directory; the single .rules file goes into rules/, the rest sits at
# /etc/snort/. Same GNU-vs-BSD-tar-portability principle as before: no
# globs, just whole-dir extraction with --strip-components=1.
tar -xzf "$TMP_TAR" -C "$STAGE_DIR" --strip-components=1 snort3-community-rules/

# Snort3 Community ships rules as a single file at the tarball root; move
# it into rules/ so snort.uc's auto-include glob in /etc/snort/rules/*.rules
# picks it up.
mv "$STAGE_DIR/snort3-community.rules" "$RULES_DIR/"

# Compile-time sanity check.
if [ ! -s "$RULES_DIR/snort3-community.rules" ]; then
	echo "::error::no rule content extracted — tarball structure may have changed" >&2
	exit 1
fi

echo "$PINNED_SHA" > "$STAMP_FILE"
rule_count=$(grep -cE '^(alert|drop|block|reject)' "$RULES_DIR/snort3-community.rules" || true)
echo "staged 1 rule file (~$rule_count rules) into $RULES_DIR"
