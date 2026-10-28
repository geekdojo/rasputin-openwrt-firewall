#!/usr/bin/env bash
#
# fetch-legacy-kmods.sh — stage the 6.12.94 FAT modules every field firewall's
# kernel needs to reach its ESP, taken from the signed 2026.10.3 release, for
# scripts/assemble-ab-image.sh to bake into the rootfs (geekdojo/geekdojo-brain#888).
#
#   usage: scripts/fetch-legacy-kmods.sh <root-ca.pem> <out-dir>
#
# WHY
#   A box in the field has one shared kernel on its ESP (6.12.94, every stable
#   from 2026.08.1 to 2026.10.3) and an agent that copies no kernel. When that
#   agent installs a rootfs built for a newer kernel, the new slot first boots
#   the OLD kernel, with none of its own modules loadable, vfat included. The
#   kernel-match guard in the new rootfs then has the agent write the slot's
#   own kernel to the ESP, and to mount the ESP it must load vfat into the
#   kernel that is actually running. These are those modules: fat, vfat,
#   nls_cp437, nls_iso8859-1 and nls_utf8, byte for byte the ones 2026.10.3
#   shipped. The agent loads them only when the running kernel's id equals
#   <out-dir>/kernel-id (the field kernel has its vermagic check compiled out,
#   so that id is the only check on which build a module is for).
#
# WHAT IT TRUSTS, AND HOW IT FAILS
#   It downloads the published 2026.10.3 manifest.json, manifest.json.sig,
#   .rootfs and .rootfs.sig, and refuses (exit 1, naming the file) unless:
#     - both signatures verify against <root-ca.pem> (the root CA this build
#       bakes into the image), with the published verify command, at their
#       signing time;
#     - the .rootfs sha256 equals the signed manifest's rootfsSha256;
#     - each module's sha256 equals image/legacy-kmods.sha256.
#   The pins are the real gate: a published release can be re-signed, and the
#   modules must be the exact bytes the field kernel was built with.
#
# THE KERNEL ID IS A CONSTANT (F-888-08)
#   The id the modules belong to is the field kernel's "uname -r uname -v",
#   6.12.94 #0 SMP Mon Jun 29 12:59:20 2026, measured from the 2026.10.3 ESP
#   kernel. None of the files fetched here contains that kernel (it lives only
#   on the ESP inside the -ab.img.gz), so it is pinned in image/legacy-kernel-id
#   beside the module hashes and copied out from there.
#
# OUTPUT
#   <out-dir>/kernel-id            the pinned legacy kernel id
#   <out-dir>/6.12.94/<name>.ko    the five modules
#
# TEST SEAMS (scripts/test-fetch-legacy-kmods.sh): RASPUTIN_LEGACY_SRC=<dir>
# reads the four release files from a directory instead of downloading them,
# and RASPUTIN_LEGACY_PINS=<file> replaces image/legacy-kmods.sha256, because a
# fixture cannot carry the real modules. Otherwise the files come from
# `gh release download`, which needs GH_TOKEN.
set -euo pipefail

CA="${1:?usage: $0 <root-ca.pem> <out-dir>}"
OUT="${2:?usage: $0 <root-ca.pem> <out-dir>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS="${RASPUTIN_LEGACY_PINS:-$REPO_ROOT/image/legacy-kmods.sha256}"
LEGACY_ID_FILE="$REPO_ROOT/image/legacy-kernel-id"

LEGACY_RELEASE=2026.10.3
LEGACY_KVER=6.12.94
LEGACY_REPO=geekdojo/rasputin-openwrt-firewall
ROOTFS="rasputin-fw-n100-${LEGACY_RELEASE}.rootfs"

die() { echo "fetch-legacy-kmods: $*" >&2; exit 1; }
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

[ -s "$CA" ] || die "the root CA $CA is missing or empty, so nothing can verify the $LEGACY_RELEASE release."
[ -s "$PINS" ] || die "the module pins $PINS are missing or empty."
[ -s "$LEGACY_ID_FILE" ] || die "the pinned legacy kernel id $LEGACY_ID_FILE is missing or empty."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DL="$WORK/dl"
mkdir -p "$DL"

files="manifest.json manifest.json.sig $ROOTFS $ROOTFS.sig"
if [ -n "${RASPUTIN_LEGACY_SRC:-}" ]; then
	for f in $files; do
		cp "$RASPUTIN_LEGACY_SRC/$f" "$DL/$f" 2>/dev/null || die "$f is missing from $RASPUTIN_LEGACY_SRC."
	done
else
	for f in $files; do
		gh release download "$LEGACY_RELEASE" --repo "$LEGACY_REPO" --pattern "$f" --dir "$DL" \
			|| die "could not download $f from release $LEGACY_RELEASE of $LEGACY_REPO."
	done
fi

# signed_at <file> — the signature's signingTime, as a Unix epoch. It is a
# signed attribute, so the verify below also proves it was not altered.
signed_at() {
	# To a file first: awk stops reading at its match, and under pipefail the
	# writer's broken pipe would fail the pipeline.
	openssl cms -cmsout -print -inform DER -in "$DL/$1.sig" > "$WORK/cms.txt" 2>/dev/null \
		|| die "$1.sig is not a readable CMS signature."
	t=$(awk '/object: signingTime/ {f = 1; next} f && /TIME:/ {sub(/.*TIME:/, ""); print; exit}' "$WORK/cms.txt")
	[ -n "$t" ] || die "$1.sig carries no signingTime, so there is no time to verify it at."
	jq -rn --arg t "$t" '$t | gsub(" +"; " ") | strptime("%b %d %H:%M:%S %Y GMT") | mktime' 2>/dev/null \
		|| die "$1.sig has a signingTime '$t' this script cannot read."
}

# The published verify command (README, release notes): no -purpose, so the
# S/MIME default every deployed agent applies. It checks the certificates at
# the time the release was signed, not today (F-888-21): these signatures never
# change, and the leaf that made them expires (leaf-003, 2028-08-20), after
# which a today-check would fail every build. The sha256 pins stay the gate.
verify_sig() {
	at=$(signed_at "$1") || exit 1
	openssl cms -verify -binary -inform DER -in "$DL/$1.sig" -content "$DL/$1" \
		-CAfile "$CA" -attime "$at" -out /dev/null 2>"$WORK/cms.err" \
		|| die "$1.sig does not verify against $CA: $(tr '\n' ' ' < "$WORK/cms.err")"
	echo "fetch-legacy-kmods: $1.sig verified (at its signing time, epoch $at)"
}
verify_sig manifest.json
verify_sig "$ROOTFS"

want=$(jq -r --arg r "$ROOTFS" '.artifacts[] | select(.rootfs == $r) | .rootfsSha256' "$DL/manifest.json")
[ -n "$want" ] && [ "$want" != null ] || die "manifest.json names no rootfsSha256 for $ROOTFS."
got=$(sha256_of "$DL/$ROOTFS")
[ "$got" = "$want" ] || die "$ROOTFS has sha256 $got, but the signed manifest says $want."
echo "fetch-legacy-kmods: $ROOTFS sha256 matches the manifest"

mods=$(awk 'NF == 2 {print $2}' "$PINS")
[ "$(printf '%s\n' "$mods" | grep -c .)" -eq 5 ] || die "$PINS must pin exactly five modules."
paths=""
for m in $mods; do paths="$paths lib/modules/$LEGACY_KVER/$m"; done
# shellcheck disable=SC2086 # one argument per module path
unsquashfs -no-progress -d "$WORK/x" "$DL/$ROOTFS" $paths >/dev/null \
	|| die "could not extract the modules from $ROOTFS."

while read -r sum m; do
	[ -n "$m" ] || continue
	f="$WORK/x/lib/modules/$LEGACY_KVER/$m"
	[ -f "$f" ] || die "$ROOTFS has no lib/modules/$LEGACY_KVER/$m."
	got=$(sha256_of "$f")
	[ "$got" = "$sum" ] || die "$m has sha256 $got, but $PINS pins $sum."
done < "$PINS"

mkdir -p "$OUT/$LEGACY_KVER"
for m in $mods; do cp "$WORK/x/lib/modules/$LEGACY_KVER/$m" "$OUT/$LEGACY_KVER/$m"; done
cp "$LEGACY_ID_FILE" "$OUT/kernel-id"
echo "fetch-legacy-kmods: staged $(printf '%s\n' "$mods" | tr '\n' ' ')for kernel '$(cat "$OUT/kernel-id")' in $OUT"
