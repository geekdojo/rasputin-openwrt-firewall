#!/usr/bin/env bash
#
# init-imagebuilder.sh — download + verify the pinned OpenWrt ImageBuilder
# for the Rasputin firewall (Node N, x86/64).
#
# ImageBuilder is a *prebuilt* toolchain — no compilation. Drop it into
# ./imagebuilder/ and `make image` from there with a PACKAGES list + FILES
# overlay produces the .img.gz. ~200 MB download; reproducible from the
# pinned version below, so we don't commit it.
#
# See: os-images/firewall-image.md §2
set -euo pipefail

# Pinned OpenWrt release. 25.12 line (released Dec 2025, multiple stable
# point releases; 25.12.5 current as of 2026-08-07). We migrated off the
# 24.10 line in 2026-06 — 24.10 EOLs ~Sep 2026 and design-partner units
# would have shipped already by then. 25.12 brings the apk packaging
# migration (vs opkg/ipk in 24.10), which is forward-relevant when we
# wire the custom signed agent feed; for now the image overlay delivers
# the agent so the package format is transparent to us.
#
# Bump the point release here when 25.12.5+ ships; the canary workflow
# will flag the divergence so it's not silent.
OPENWRT_VERSION="${OPENWRT_VERSION:-25.12.5}"
TARGET="x86/64"
TARGET_DIR="$(echo "$TARGET" | tr / -)"   # x86-64
# OpenWrt switched ImageBuilder distribution from .tar.xz → .tar.zst in 24.10
# (https://forum.openwrt.org/t/openwrt-24-10-0-stable-released/ — zstd is
# faster and smaller). xz upstream artifacts no longer exist for 24.10+.
IB_TARBALL="openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET_DIR}.Linux-x86_64.tar.zst"
IB_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET}/${IB_TARBALL}"

# The release dir publishes sha256sums for everything. Pull + verify.
SUMS_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET}/sha256sums"

cd "$(dirname "$0")/.."

# Belt-and-suspenders cache hygiene: the CI workflow's `restore-keys: ib-`
# falls back to ANY cache with the `ib-` prefix when the exact key
# (hash of this script + packages.txt) doesn't match. That's intentional
# for partial reuse of the dl/ subdir's package downloads, but it also
# pulls in any leftover imagebuilder/ from a prior OPENWRT_VERSION.
# Without this check, bumping OPENWRT_VERSION builds against the stale
# cached imagebuilder — silently, because the dir exists so we skip
# re-download. Discovered on the 24.10.0 → 25.12.4 bump 2026-06-07
# (2026.07.0-dev.1 shipped as 24.10.0 despite claiming 25.12.4).
STAMP_MATCH=false
if [ -d imagebuilder ]; then
	stamped=""
	[ -f imagebuilder/.rasputin_openwrt_version ] && \
		stamped=$(cat imagebuilder/.rasputin_openwrt_version)
	if [ "$stamped" = "$OPENWRT_VERSION" ]; then
		echo "imagebuilder/ already at $OPENWRT_VERSION (stamp matches); skipping download"
		STAMP_MATCH=true
	else
		echo "imagebuilder/ stamp mismatch (have='$stamped' want='$OPENWRT_VERSION'); re-initializing"
		rm -rf imagebuilder
	fi
fi

if [ "$STAMP_MATCH" = "true" ]; then
	# Cache-hit path. Skip straight to the partition-size adjustment at
	# the end — that's idempotent and survives a cache restore that
	# pulled an older .config back in (e.g. one built before we started
	# bumping the partsize, or with a different value).
	:
else

mkdir -p .imagebuilder-dl
cd .imagebuilder-dl

echo "→ downloading $IB_TARBALL"
curl -fL --retry 3 -o "$IB_TARBALL" "$IB_URL"

echo "→ verifying sha256 against upstream sha256sums file"
curl -fL --retry 3 -o sha256sums "$SUMS_URL"
# The sums file lists `<sha>  ./<filename>`; grep the line we want, verify.
expected=$(awk -v f="*${IB_TARBALL}" '$2 == f { print $1 }' sha256sums)
if [ -z "$expected" ]; then
	# Some OpenWrt mirrors omit the `*` prefix; fall back to the unstarred form.
	expected=$(awk -v f="${IB_TARBALL}" '$2 == f { print $1 }' sha256sums)
fi
if [ -z "$expected" ]; then
	echo "ERROR: no sha256 entry for $IB_TARBALL in $SUMS_URL" >&2
	exit 1
fi
actual=$(shasum -a 256 "$IB_TARBALL" 2>/dev/null | awk '{print $1}' || sha256sum "$IB_TARBALL" | awk '{print $1}')
if [ "$expected" != "$actual" ]; then
	echo "ERROR: sha256 mismatch for $IB_TARBALL"      >&2
	echo "  expected: $expected"                       >&2
	echo "  actual:   $actual"                         >&2
	exit 1
fi
echo "  sha256 ok"

echo "→ extracting to ./imagebuilder/"
cd ..
# --zstd needs the `zstd` binary on PATH (GNU tar passes it as the compress
# program). ubuntu-latest ships it; on macOS install via `brew install zstd`.
if ! command -v zstd >/dev/null 2>&1; then
	echo "ERROR: zstd not installed (needed to extract OpenWrt 24.10+ ImageBuilder)" >&2
	echo "  Linux: apt-get install -y zstd     macOS: brew install zstd"            >&2
	exit 1
fi
tar --zstd -xf ".imagebuilder-dl/$IB_TARBALL"
mv "openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET_DIR}.Linux-x86_64" imagebuilder
echo "$OPENWRT_VERSION" > imagebuilder/.rasputin_openwrt_version
rm -rf .imagebuilder-dl

fi  # end STAMP_MATCH == false (cold path)

# Bump CONFIG_TARGET_ROOTFS_PARTSIZE. The OpenWrt 25.12 x86/generic
# ImageBuilder defaults to 104 MB, which was generous when the image
# was just OpenWrt-base + rasputin-agent (~50 MB) but is too tight once
# we add snort3 + libdaq + hyperscan + ET Open rules (~80 MB combined).
# 512 MB is room to grow: comfortable headroom for the ruleset growing
# with image updates, plus any additional defensive packages design
# partners ask for. The squashfs build compresses to ~30-40 MB regardless;
# this is the ext4 partition image size on disk.
#
# Caught: CI run 27168495058 — "ext4_allocate_best_fit_partial: failed
# to allocate 432 blocks, out of space?" — when ET Open landed.
#
# Idempotent + runs on BOTH stamp-match cache-hits and cold extractions
# so a stale cache that holds an older .config gets corrected.
TARGET_PARTSIZE=512
sed -i.bak -E "s/^(CONFIG_TARGET_ROOTFS_PARTSIZE=).*/\1${TARGET_PARTSIZE}/" imagebuilder/.config && rm -f imagebuilder/.config.bak
grep -q "^CONFIG_TARGET_ROOTFS_PARTSIZE=${TARGET_PARTSIZE}$" imagebuilder/.config || {
	echo "ERROR: failed to set CONFIG_TARGET_ROOTFS_PARTSIZE=${TARGET_PARTSIZE} in imagebuilder/.config" >&2
	grep "ROOTFS_PARTSIZE" imagebuilder/.config >&2 || true
	exit 1
}
echo "  rootfs partition size set to ${TARGET_PARTSIZE} MB"

echo "ImageBuilder ready at $(pwd)/imagebuilder (OpenWrt ${OPENWRT_VERSION}, target ${TARGET})"
