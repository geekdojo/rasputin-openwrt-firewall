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
#   REPORT_DRIFT=1 ./scripts/fetch-snort-rules.sh
#                                            # a SHA mismatch is a FINDING, not
#                                            # a failure — see below
#
# REPORT_DRIFT exists for the weekly canary (.github/workflows/canary.yml) and
# for nothing else. That workflow is the drift detector: it rebuilds the image,
# diffs the package manifest against the last stable's SBOM, and files an issue
# when something moved. Failing closed here killed it — Talos republishes the
# tarball on its own schedule, so from 2026-09-07 the canary died at this step
# and never reached the code that files the issue. Two weeks of no canary issue
# read as "no drift" and were actually a dead canary: the check meant to warn
# you was taken down by the very thing it exists to warn about.
#
# So with REPORT_DRIFT=1 a mismatch stages the tarball as downloaded, reports
# both SHAs (stdout, plus $GITHUB_OUTPUT for the workflow to consume), and exits
# 0 so the build continues. WITHOUT the flag — which is every other caller,
# release.yml above all — behaviour is unchanged and a mismatch is still fatal.
# That is deliberate and must stay that way: shipping rules we have not verified
# onto a security appliance is a supply-chain hole, and a release must never be
# able to do it by accident.

set -euo pipefail

RULES_URL="https://www.snort.org/downloads/community/snort3-community-rules.tar.gz"
# Talos publishes new Community Rules ~weekly, so this pin drifts and the
# release build fails closed on it by design (the canary REPORTS it instead —
# see REPORT_DRIFT above); bumping it is the routine refresh path.
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
# Recurring toil; a stable org mirror of the tarball is a backlog item so
# the firewall build stops breaking on upstream's cadence.
PINNED_SHA="5a388fa782031148981f3563eba906f019520ebfc130c04747f166c69caae4cd"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE_DIR="$REPO_ROOT/files/etc/snort"
RULES_DIR="$STAGE_DIR/rules"
STAMP_FILE="$STAGE_DIR/.snort3-community-stamp"
TMP_TAR="$(mktemp -t snort3-community.tar.gz.XXXXXX)"
trap 'rm -f "$TMP_TAR"' EXIT

# REPORT_DRIFT implies FORCE. The idempotent skip below answers "is what is on
# disk what we pinned?", which is not the question the canary is asking — it
# wants to know whether UPSTREAM still matches the pin, and that needs a fetch.
# A stamp left behind by an earlier run would otherwise let the detector skip
# the download and report "no drift" without having looked, which is the same
# silent blind spot this flag was added to close.
if [ "${FORCE:-0}" != "1" ] && [ "${REPORT_DRIFT:-0}" != "1" ] && [ -f "$STAMP_FILE" ]; then
	if [ "$(cat "$STAMP_FILE")" = "$PINNED_SHA" ]; then
		echo "snort rules already at $PINNED_SHA (stamp matches); skipping"
		exit 0
	fi
	echo "stamp mismatch (have=$(cat "$STAMP_FILE") want=$PINNED_SHA); re-fetching"
fi

echo "fetching $RULES_URL"
curl -fsSL --retry 3 --retry-delay 2 -o "$TMP_TAR" "$RULES_URL"

actual_sha=$(sha256sum "$TMP_TAR" | awk '{print $1}')
rules_drift=false
if [ "$actual_sha" != "$PINNED_SHA" ]; then
	if [ "${REPORT_DRIFT:-0}" = "1" ]; then
		# Findings go to stdout, not stderr, and as ::warning:: rather than
		# ::error:: — an ::error:: annotation on a run that deliberately
		# succeeded reads as a broken canary, which is exactly the confusion
		# this whole change is undoing.
		rules_drift=true
		echo "::warning::Snort3 Community Rules pin is stale — upstream tarball SHA no longer matches PINNED_SHA"
		echo "  pinned:   $PINNED_SHA"
		echo "  upstream: $actual_sha"
		echo "REPORT_DRIFT=1: staging the tarball as downloaded and continuing, so the"
		echo "drift-detection build still produces a package manifest to diff. This is a"
		echo "measurement, NOT a releasable image — the rules in it are unverified."
	else
		echo "::error::Snort3 Community Rules tarball SHA mismatch" >&2
		echo "  expected: $PINNED_SHA" >&2
		echo "  actual:   $actual_sha" >&2
		echo "If the upstream ruleset moved on intentionally, update PINNED_SHA in this script." >&2
		exit 1
	fi
else
	echo "sha256 verified: $actual_sha"
fi

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

# The stamp records what is ACTUALLY staged, not what we wanted. On the default
# path those are the same value — a mismatch has already exited 1 by here — so
# this writes exactly what it always did. Under REPORT_DRIFT they differ, and
# writing the pin instead would be a lie with teeth: the next default-mode run
# would see stamp == PINNED_SHA, take the idempotent skip at the top of this
# script, and hand a release build drifted rules while reporting them verified.
echo "$actual_sha" > "$STAMP_FILE"
rule_count=$(grep -cE '^(alert|drop|block|reject)' "$RULES_DIR/snort3-community.rules" || true)
echo "staged 1 rule file (~$rule_count rules) into $RULES_DIR"

# Machine-readable signal, report mode only. GitHub reads $GITHUB_OUTPUT back as
# the step's outputs, which is how canary.yml's "Decide whether to open an issue"
# and "Build issue body" steps see this finding without re-parsing our stdout —
# the same mechanism every other reporting step in that workflow already uses.
# Outside Actions the variable is unset and this is a no-op; setting it by hand
# is also how you exercise this path locally:
#   GITHUB_OUTPUT=/tmp/out REPORT_DRIFT=1 ./scripts/fetch-snort-rules.sh
if [ "${REPORT_DRIFT:-0}" = "1" ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "rules_drift=$rules_drift"
		echo "rules_pinned_sha=$PINNED_SHA"
		echo "rules_actual_sha=$actual_sha"
	} >> "$GITHUB_OUTPUT"
fi
