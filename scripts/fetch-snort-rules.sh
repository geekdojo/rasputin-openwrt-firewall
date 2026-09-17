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
# WHERE THE BYTES COME FROM (geekdojo/geekdojo-brain#208)
#   Every build — the stable tag build included — downloads the tarball from the
#   org mirror, geekdojo/rasputin-snort3-rules-mirror, at the release named for
#   PINNED_SHA:
#     https://github.com/geekdojo/rasputin-snort3-rules-mirror/releases/download/sha256-<PINNED_SHA>/snort3-community-rules.tar.gz
#   Each mirror release is byte-identical to one upstream tarball, content-
#   addressed by its sha256, and never overwritten, so an old pin always
#   resolves. The download is still verified against PINNED_SHA here and a
#   mismatch still fails closed: the mirror is a convenience for
#   REPRODUCIBILITY, never a reason to trust bytes.
#
#   FRESHNESS is a separate check with a separate owner:
#   scripts/rasputin-snort-rules-freshness.sh compares upstream's current SHA
#   with PINNED_SHA. release.yml runs it on workflow_dispatch builds (the
#   pre-flight) and FAILS when they differ; tag builds skip it, so a Talos
#   republish can no longer burn an immutable tag. The tag build instead
#   requires a green pre-flight on its exact commit
#   (scripts/rasputin-release-tag-guard.sh).
#
# Rule updates ride image releases (sysupgrade cadence); per-deployment
# rule pushes are a backlog item. To re-pin: the mirror must already hold
# sha256-<new sha> — its refresh workflow verifies and publishes it:
#   gh workflow run rasputin-refresh.yml --repo geekdojo/rasputin-snort3-rules-mirror
# Then set PINNED_SHA below, add a history entry, and run this script — it must print
# "sha256 verified".
#
# Usage:
#   ./scripts/fetch-snort-rules.sh           # idempotent — skips if up to date
#   FORCE=1 ./scripts/fetch-snort-rules.sh   # re-fetch even if stamp matches
#   REPORT_DRIFT=1 ./scripts/fetch-snort-rules.sh
#                                            # also REPORT upstream drift — see below
#   ./scripts/fetch-snort-rules.sh --print-pin
#                                            # print the pin + mirror location
#                                            # and exit (read by the freshness
#                                            # script, so the pin has ONE home)
#
# SNORT_RULES_MIRROR_BASE overrides the mirror's download base URL. It exists for
# scripts/test-snort-rules-pin.sh, which serves fixture tarballs locally. It
# cannot smuggle bytes in: whatever it serves is verified against PINNED_SHA.
#
# REPORT_DRIFT exists for the weekly canary (.github/workflows/canary.yml) and
# for nothing else. That workflow is the drift detector: it rebuilds the image,
# diffs the package manifest against the last stable's SBOM, and files an issue
# when something moved. Failing closed on upstream drift killed it — Talos
# republishes the tarball on its own schedule, so from 2026-09-07 the canary
# died at this step and never reached the code that files the issue. Two weeks
# of no canary issue read as "no drift" and were actually a dead canary: the
# check meant to warn you was taken down by the very thing it exists to warn
# about.
#
# So with REPORT_DRIFT=1 the rules are staged exactly as on every other path —
# from the mirror at PINNED_SHA, verified, fatal on a mismatch — and THEN
# upstream is compared with the pin in report mode: an upstream move (or an
# upstream that cannot be reached) is printed and written to $GITHUB_OUTPUT as
# rules_drift / rules_pinned_sha / rules_actual_sha / rules_mirror_status, and
# the script exits 0 so the build continues. The canary therefore never bakes
# unverified rules, and never dies on an upstream move either.

set -euo pipefail

# The mirror. Release tag = "sha256-<full sha>", one asset of this name.
MIRROR_REPO="geekdojo/rasputin-snort3-rules-mirror"
MIRROR_BASE="${SNORT_RULES_MIRROR_BASE:-https://github.com/$MIRROR_REPO/releases/download}"
TARBALL_NAME="snort3-community-rules.tar.gz"
# Upstream publishes new Community Rules ~weekly, so this pin goes stale; the
# release PRE-FLIGHT (a workflow_dispatch build) fails on that by design, and
# the canary REPORTS it. Tag builds never fetch upstream at all.
# History: dev.2 (df1de9995bc6...) → dev.4 (bb947bc02530...) → dev.8
# (d891178755d7..., 2026-06-12, ~4017 rules) → dev.13 (643dfc20e363...,
# 2026-06-17) → e913e956ce1e... → 2026-06-29 (11b59e5041af..., ~4017
# rules; caught by the weekly canary run) → 2026-07-01 (83991b679e68...,
# ~4017 rules; independently re-fetched from snort.org HTTPS + tarball
# structure confirmed unchanged, while unblocking the first A/B build) →
# 2026-07-19 (cb8374c81524..., independently re-fetched + structure
# confirmed, while cutting the first 2026.07.4 dev build) → 2026-08-19
# (eff40760b4e2..., ~4017 rules; independently re-fetched from snort.org
# over HTTPS and the tarball structure confirmed unchanged rather than
# copying the SHA the failed build printed, while cutting the dev image
# that carries the #154 signature verification) → 2026-08-21
# (4c923f34936a..., 4017 active rules; independently re-fetched from
# snort.org over HTTPS and the tarball structure confirmed unchanged --
# same five members under snort3-community-rules/ -- rather than copying
# the SHA the failed build printed. The two agreed. Blocked the release
# cut that was validating the rotated signing leaf; the weekly canary did
# NOT flag it, having last run 2026-08-17 before Talos republished)
# -> 89b9b94cf3a6... (a Talos weekly republish; re-pinned in the commit
# preceding the 2026.08.4 stable, per agent-version.txt's dev.130 entry --
# recorded here late, from that changelog rather than first-hand)
# -> 1df6500c9dd9... (2026-09-10, 4017 active rules, Talos republished
# 2026-09-08; re-fetched over HTTPS and the five-member tarball structure
# confirmed before pinning, rather than copying the SHA a failed run
# printed. The canary had been FAILING at this step since 2026-09-07
# rather than filing a drift issue -- it dies on the mismatch before
# reaching the code that opens the issue -- so two weeks of silence read
# as "no drift". That is what REPORT_DRIFT below now fixes: the detector
# reports a stale pin instead of being taken down by one).
# -> b68a24f265ff... (2026-09-10 again, 4017 active rules; verified before
# pinning: the five-member tarball structure and rule count). It went live
# on snort.org at 11:54 UTC (the S3 object's Last-Modified) -- about 7.5h
# after the 1df6500c pin was committed at 04:17 UTC, which dev.104 built
# clean against minutes later -- and dev.105 failed on it at 14:35 UTC. Its
# gzip header reads 2026-09-09 21:20 UTC; that is when Talos built the
# archive, not when it went live, so don't date a republish from it. Weekly
# is Talos's usual rhythm, not a promise).
# -> 5a388fa78203... (2026-09-15, 4017 active rules; verified before
# pinning: two separate HTTPS downloads hashed identical, the five-member
# tarball structure and rule count unchanged). It went live on snort.org at
# 13:34 UTC (the S3 object's Last-Modified); its gzip header reads
# 2026-09-14 19:14 UTC, the archive build time. Found while preparing the
# 2026.09.2-dev.159 agent pin, before any build failed on it; re-pinned in
# the same PR.
# -> c50913e21539... (2026-09-16, 4017 active rules; verified before pinning
# to the standard above: two separate HTTPS downloads hashed identical, the
# five-member tarball structure and rule count unchanged). It went live on
# snort.org at 2026-09-16 01:30 UTC (the S3 object's Last-Modified); its gzip
# header reads 2026-09-15 23:59 UTC, the archive build time.
# THIS ONE COST A RELEASE. Talos republished ~12h after the 5a388fa7 pin --
# which a dispatch build had validated GREEN at 20:36 UTC -- and the
# 2026.09.2 STABLE tag build hit the new bytes at 04:00 UTC and failed.
# Release tags are immutable, so that burned the firewall's 2026.09.2 and the
# whole lockstep line had to be withdrawn and re-cut as 2026.09.3. A green
# build five hours ago proves nothing about the build you are about to tag:
# the os-release skill now requires a pre-flight image build immediately
# before any stable tag.
# -> SOURCE SWITCH, same c50913e21539... pin (2026-09-16,
# geekdojo/geekdojo-brain#208). No new bytes: this script stopped downloading
# from snort.org and now fetches the pinned tarball from the org mirror
# (geekdojo/rasputin-snort3-rules-mirror, release sha256-<sha>), still verified
# against this SHA. The pre-flight freshness gate in release.yml now owns
# "upstream moved", and a tag build only runs on a commit with a green
# pre-flight — so upstream moving between the pre-flight and the tag no longer
# changes what the tag builds. Re-pins still happen at upstream's cadence, but
# they are caught at pre-flight, where re-pinning is cheap.
# -> ae74ed6dc03a... (2026-09-17, 4017 active rules; a Talos republish). It
# went live on snort.org at 2026-09-17 13:03 UTC (the S3 object's
# Last-Modified); its gzip header reads 2026-09-16 22:36 UTC, the archive
# build time. Found while preparing the 2026.09.4-dev.167 agent pin, before
# any build failed on it. Two separate HTTPS downloads hashed identical
# before the refresh ran; the mirror's rasputin-refresh.yml then verified it
# (two downloads, five-member layout, 4017 active rules, snort-mgr -v check
# under Snort 3.10.0.0 in firewall 2026.09.3) and published
# sha256-ae74ed6dc03a..., the first mirror entry tagged by its release-target
# guard.
PINNED_SHA="ae74ed6dc03a95cda54931de284d1b73c5dbe660deec02c2e080f904a82303a0"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_DIR="$REPO_ROOT/files/etc/snort"
RULES_DIR="$STAGE_DIR/rules"
STAMP_FILE="$STAGE_DIR/.snort3-community-stamp"
RULES_URL="$MIRROR_BASE/sha256-$PINNED_SHA/$TARBALL_NAME"

if [ "${1:-}" = "--print-pin" ]; then
	printf 'PINNED_SHA=%s\nMIRROR_BASE=%s\nTARBALL_NAME=%s\n' "$PINNED_SHA" "$MIRROR_BASE" "$TARBALL_NAME"
	exit 0
fi
if [ "$#" -ne 0 ]; then
	echo "usage: $0 [--print-pin]" >&2
	exit 2
fi

# The upstream comparison, report mode. Called on every REPORT_DRIFT exit path
# that has staged verified rules — including the idempotent skip, because the
# question the canary asks ("has UPSTREAM moved?") does not depend on what is on
# disk, and skipping it there would report nothing without having looked.
report_drift() {
	[ "${REPORT_DRIFT:-0}" = "1" ] || return 0
	REPORT_DRIFT=1 "$REPO_ROOT/scripts/rasputin-snort-rules-freshness.sh"
}

if [ "${FORCE:-0}" != "1" ] && [ -f "$STAMP_FILE" ]; then
	if [ "$(cat "$STAMP_FILE")" = "$PINNED_SHA" ]; then
		echo "snort rules already at $PINNED_SHA (stamp matches); skipping"
		report_drift
		exit 0
	fi
	echo "stamp mismatch (have=$(cat "$STAMP_FILE") want=$PINNED_SHA); re-fetching"
fi

TMP_TAR="$(mktemp -t snort3-community.tar.gz.XXXXXX)"
trap 'rm -f "$TMP_TAR"' EXIT

echo "fetching $RULES_URL"
if ! curl -fsSL --retry 3 --retry-delay 2 -o "$TMP_TAR" "$RULES_URL"; then
	echo "::error::could not download the pinned Snort3 Community Rules from the mirror" >&2
	echo "  url: $RULES_URL" >&2
	echo "  The mirror has no release sha256-$PINNED_SHA, or GitHub is unreachable." >&2
	echo "  A pin must never point at a SHA the mirror does not hold: check" >&2
	echo "  https://github.com/$MIRROR_REPO/releases before re-pinning." >&2
	exit 1
fi

actual_sha=$(sha256sum "$TMP_TAR" | awk '{print $1}')
if [ "$actual_sha" != "$PINNED_SHA" ]; then
	# Fatal on EVERY path, REPORT_DRIFT included. The mirror is content-addressed,
	# so bytes at sha256-<X> that do not hash to X are not drift; they are a
	# corrupted or tampered mirror, and nothing downstream may consume them.
	echo "::error::Snort3 Community Rules tarball SHA mismatch (mirror bytes do not match the pin)" >&2
	echo "  expected: $PINNED_SHA" >&2
	echo "  actual:   $actual_sha" >&2
	echo "  url:      $RULES_URL" >&2
	echo "The mirror release is content-addressed and must never change. Treat this as a" >&2
	echo "supply-chain alarm, not a routine re-pin: do NOT copy the actual SHA into PINNED_SHA." >&2
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

# The stamp is written only after verification, so it always names bytes that
# hashed to PINNED_SHA; the idempotent skip above relies on that.
echo "$actual_sha" > "$STAMP_FILE"
rule_count=$(grep -cE '^(alert|drop|block|reject)' "$RULES_DIR/snort3-community.rules" || true)
echo "staged 1 rule file (~$rule_count rules) into $RULES_DIR"

report_drift
