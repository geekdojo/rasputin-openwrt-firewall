#!/usr/bin/env bash
#
# fetch-snort-rules.sh — download the ET Open snort3 ruleset and stage it
# into files/etc/snort/ for the ImageBuilder overlay.
#
# Rationale: ET Open is the free / no-oinkcode community ruleset for
# snort3 (https://rules.emergingthreats.net/open/snort-3.0.0/). We bake
# the rules into the image so the firewall has working detections on
# first boot — operators get value without an extra setup step. Rule
# updates ride image releases (sysupgrade cadence); per-deployment rule
# pushes are a backlog item.
#
# The SHA-256 is pinned so a given image build is reproducible. Bump
# PINNED_SHA when refreshing the bundled ruleset; the script will
# refuse to install an unrecognized tarball.
#
# Usage:
#   ./scripts/fetch-snort-rules.sh           # idempotent — skips if up to date
#   FORCE=1 ./scripts/fetch-snort-rules.sh   # re-fetch even if stamp matches

set -euo pipefail

RULES_URL="https://rules.emergingthreats.net/open/snort-3.0.0/emerging.rules.tar.gz"
PINNED_SHA="3b186eee6be5bafbd33fa5c3688d738949257174a5da50f431fe5dc9ea1b87ee"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_DIR="$REPO_ROOT/files/etc/snort"
RULES_DIR="$STAGE_DIR/rules"
STAMP_FILE="$STAGE_DIR/.et-open-stamp"
TMP_TAR="$(mktemp -t et-open-snort3.tar.gz.XXXXXX)"
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
	echo "::error::ET Open tarball SHA mismatch" >&2
	echo "  expected: $PINNED_SHA" >&2
	echo "  actual:   $actual_sha" >&2
	echo "If the upstream ruleset moved on intentionally, update PINNED_SHA in this script." >&2
	exit 1
fi
echo "sha256 verified: $actual_sha"

# Wipe any prior build-fetched content (operator-added local.rules is in
# keep.d on the device but not in this build dir; we only manage what we
# fetched).
rm -rf "$RULES_DIR"
mkdir -p "$RULES_DIR"
rm -f "$STAGE_DIR/classification.config" "$STAGE_DIR/sid-msg.map"

# Extract the whole `rules/` directory from the tarball. ET Open's tarball
# is `rules/`-prefixed and contains: *.rules + classification.config +
# sid-msg.map + a few license files + compromised-ips.txt + a couple of
# small text files. snort.uc auto-includes any *.rules in /etc/snort/rules/;
# the other files sit next to them in /etc/snort/ for classification refs,
# sid lookups, and operator-visible licensing. Total ~55 MB uncompressed,
# compresses to a few MB in squashfs.
#
# We unpack everything rather than using a glob like 'rules/*.rules' because
# tar glob handling is GNU-vs-BSD divergent (GNU needs --wildcards, BSD
# enables it by default; mixing breaks one or the other) and the few extra
# small files don't justify the portability footgun. Caught in CI run
# 27168062216 when --no-flag globs failed on Ubuntu's GNU tar.
tar -xzf "$TMP_TAR" -C "$STAGE_DIR" --strip-components=1 rules/

# tar with --strip-components=1 drops 'rules/' from the path, putting
# emerging-*.rules at $STAGE_DIR/. Move them into rules/.
shopt -s nullglob
moved=0
for f in "$STAGE_DIR"/*.rules; do
	mv "$f" "$RULES_DIR/"
	moved=$((moved + 1))
done
shopt -u nullglob

if [ "$moved" -eq 0 ]; then
	echo "::error::no *.rules files extracted — tarball structure may have changed" >&2
	exit 1
fi

echo "$PINNED_SHA" > "$STAMP_FILE"
echo "staged $moved rule files into $RULES_DIR"
ls -1 "$RULES_DIR" | head -8
echo "  (...$(ls -1 "$RULES_DIR" | wc -l | tr -d ' ') total)"
