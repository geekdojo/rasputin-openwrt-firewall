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

# Pinned OpenWrt release. Today (2026-05-30) 24.10 is the current stable
# (EOL ~Sep 2026 per the design). Bump to 25.12.x once it's released and
# the design's apk-feed migration is wired in — at that point also revisit
# packages.txt for any apk-name shifts.
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.0}"
TARGET="x86/64"
TARGET_DIR="$(echo "$TARGET" | tr / -)"   # x86-64
IB_TARBALL="openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET_DIR}.Linux-x86_64.tar.xz"
IB_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET}/${IB_TARBALL}"

# The release dir publishes sha256sums for everything. Pull + verify.
SUMS_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET}/sha256sums"

cd "$(dirname "$0")/.."

if [ -d imagebuilder ]; then
	echo "imagebuilder/ already present (delete to re-init)"
	exit 0
fi

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
tar -xJf ".imagebuilder-dl/$IB_TARBALL"
mv "openwrt-imagebuilder-${OPENWRT_VERSION}-${TARGET_DIR}.Linux-x86_64" imagebuilder
rm -rf .imagebuilder-dl

echo "ImageBuilder ready at $(pwd)/imagebuilder (OpenWrt ${OPENWRT_VERSION}, target ${TARGET})"
