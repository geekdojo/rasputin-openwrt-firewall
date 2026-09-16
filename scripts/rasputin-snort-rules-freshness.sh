#!/usr/bin/env bash
#
# rasputin-snort-rules-freshness.sh — is the pinned Snort3 Community Rules
# tarball still what upstream (snort.org) serves today?
#
# WHY (geekdojo/geekdojo-brain#208)
#   Builds fetch the rules from the org mirror at PINNED_SHA
#   (scripts/fetch-snort-rules.sh), which makes a build REPRODUCIBLE but says
#   nothing about whether the rules are CURRENT. Bryce's principle: break rather
#   than go stale. So the release path keeps a freshness failure, moved to where
#   it is cheap: the pre-flight (workflow_dispatch) build of release.yml runs
#   this in gate mode and fails when upstream has moved. Tag builds do not run
#   it — a Talos republish must never burn an immutable tag — and instead
#   require a green pre-flight on the same commit
#   (scripts/rasputin-release-tag-guard.sh).
#
#   The check is a FACT — the two SHAs match or they do not — never the pin's
#   or the mirror's age.
#
# MODES
#   gate (default)   exit 0 when upstream == PINNED_SHA; exit 1 when it differs
#                    OR cannot be determined (an unreachable upstream proves
#                    nothing about freshness, so the gate fails closed). On a
#                    mismatch it prints both SHAs and whether the mirror already
#                    holds the upstream SHA, which decides the operator's next
#                    step: re-pin now, or refresh the mirror first.
#   REPORT_DRIFT=1   the canary's mode (called by fetch-snort-rules.sh). Never
#                    fails on upstream: a move or an unreachable upstream is
#                    printed as a ::warning:: and written to $GITHUB_OUTPUT as
#                      rules_drift          true | false | unknown
#                      rules_pinned_sha     the pin
#                      rules_actual_sha     upstream's sha, or "unavailable"
#                      rules_mirror_status  present | absent | unknown | n/a
#                    and it exits 0. A detector that dies on the thing it
#                    detects reports nothing (see fetch-snort-rules.sh on the two
#                    silent weeks from 2026-09-07).
#   Exit 2 in either mode means this script could not run at all (the pin could
#   not be read) — a repo bug, never an upstream condition.
#
# ENVIRONMENT
#   SNORT_RULES_UPSTREAM_URL  upstream tarball URL (default: snort.org). Exists
#                             for scripts/test-snort-rules-pin.sh.
#   SNORT_RULES_MIRROR_BASE   passed through to fetch-snort-rules.sh --print-pin.
#
# The pin has ONE home, scripts/fetch-snort-rules.sh; this script reads it via
# `fetch-snort-rules.sh --print-pin` rather than keeping a second copy.
#
# Usage:
#   ./scripts/rasputin-snort-rules-freshness.sh
#   REPORT_DRIFT=1 GITHUB_OUTPUT=/tmp/out ./scripts/rasputin-snort-rules-freshness.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_URL="${SNORT_RULES_UPSTREAM_URL:-https://www.snort.org/downloads/community/snort3-community-rules.tar.gz}"
MIRROR_REFRESH_CMD="gh workflow run rasputin-refresh.yml --repo geekdojo/rasputin-snort3-rules-mirror"
REPORT="${REPORT_DRIFT:-0}"

pin_out="$("$SCRIPT_DIR/fetch-snort-rules.sh" --print-pin)" || {
	echo "::error::could not read the pin from scripts/fetch-snort-rules.sh --print-pin" >&2
	exit 2
}
field() { printf '%s\n' "$pin_out" | sed -n "s/^$1=//p"; }
PINNED_SHA="$(field PINNED_SHA)"
MIRROR_BASE="$(field MIRROR_BASE)"
TARBALL_NAME="$(field TARBALL_NAME)"
if ! printf '%s' "$PINNED_SHA" | grep -Eq '^[0-9a-f]{64}$' || [ -z "$MIRROR_BASE" ] || [ -z "$TARBALL_NAME" ]; then
	echo "::error::fetch-snort-rules.sh --print-pin returned an unusable pin:" >&2
	printf '%s\n' "$pin_out" >&2
	exit 2
fi

TMP_TAR="$(mktemp -t snort3-upstream.tar.gz.XXXXXX)"
trap 'rm -f "$TMP_TAR"' EXIT

emit() {
	# $1 drift, $2 actual sha, $3 mirror status
	[ "$REPORT" = "1" ] && [ -n "${GITHUB_OUTPUT:-}" ] || return 0
	{
		echo "rules_drift=$1"
		echo "rules_pinned_sha=$PINNED_SHA"
		echo "rules_actual_sha=$2"
		echo "rules_mirror_status=$3"
	} >> "$GITHUB_OUTPUT"
}

echo "checking upstream freshness: $UPSTREAM_URL"
if ! curl -fsSL --retry 3 --retry-delay 2 -o "$TMP_TAR" "$UPSTREAM_URL"; then
	if [ "$REPORT" = "1" ]; then
		echo "::warning::could not download the upstream Snort3 Community Rules tarball — freshness UNKNOWN this run"
		echo "  pinned:   $PINNED_SHA"
		echo "  upstream: unavailable ($UPSTREAM_URL)"
		emit unknown unavailable n/a
		exit 0
	fi
	echo "::error::could not download the upstream Snort3 Community Rules tarball, so freshness cannot be proven" >&2
	echo "  pinned:   $PINNED_SHA" >&2
	echo "  upstream: unavailable ($UPSTREAM_URL)" >&2
	echo "The pre-flight fails closed on this. Re-run it once snort.org answers." >&2
	exit 1
fi
upstream_sha="$(sha256sum "$TMP_TAR" | awk '{print $1}')"

if [ "$upstream_sha" = "$PINNED_SHA" ]; then
	echo "snort rules pin is fresh: upstream matches PINNED_SHA $PINNED_SHA"
	emit false "$upstream_sha" n/a
	exit 0
fi

# Stale. Does the mirror already hold upstream's bytes? A HEAD (following the
# redirect to GitHub's asset host) answers that without downloading them.
mirror_url="$MIRROR_BASE/sha256-$upstream_sha/$TARBALL_NAME"
http_code="$(curl -sSIL --retry 2 --retry-delay 2 -o /dev/null -w '%{http_code}' "$mirror_url" 2>/dev/null || true)"
case "$http_code" in
	200) mirror_status=present ;;
	404) mirror_status=absent ;;
	*)   mirror_status=unknown ;;
esac

# Details go to stdout in report mode and stderr in gate mode, via fd 3. Not
# `> /dev/stdout`: on Linux that REOPENS the target, and when stdout is a file
# it truncates everything already written to it.
if [ "$REPORT" = "1" ]; then
	exec 3>&1
	echo "::warning::Snort3 Community Rules pin is stale — upstream tarball SHA no longer matches PINNED_SHA"
else
	exec 3>&2
	echo "::error::Snort3 Community Rules pin is stale — upstream tarball SHA no longer matches PINNED_SHA" >&2
fi
{
	echo "  pinned (PINNED_SHA): $PINNED_SHA"
	echo "  upstream today:      $upstream_sha"
	case "$mirror_status" in
		present)
			echo "  mirror: ALREADY HAS sha256-$upstream_sha (HTTP 200) — re-pin now:"
			echo "    set PINNED_SHA=\"$upstream_sha\" in scripts/fetch-snort-rules.sh, add a"
			echo "    history entry, merge, then re-run the pre-flight on the new commit:"
			echo "    gh workflow run release.yml -f full_build=true --ref main"
			;;
		absent)
			echo "  mirror: does NOT have sha256-$upstream_sha yet (HTTP 404) — refresh the mirror FIRST:"
			echo "    $MIRROR_REFRESH_CMD"
			echo "    and wait for release sha256-$upstream_sha to exist; only then re-pin."
			echo "    Re-pinning before the mirror holds the SHA breaks every build."
			;;
		*)
			echo "  mirror: could not tell whether it has sha256-$upstream_sha (HTTP ${http_code:-none})."
			echo "    Check $mirror_url by hand: if it downloads, re-pin; if not, refresh the mirror first:"
			echo "    $MIRROR_REFRESH_CMD"
			;;
	esac
} >&3

if [ "$REPORT" = "1" ]; then
	emit true "$upstream_sha" "$mirror_status"
	exit 0
fi
exit 1
