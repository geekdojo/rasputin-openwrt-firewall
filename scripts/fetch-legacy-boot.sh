#!/usr/bin/env bash
#
# fetch-legacy-boot.sh — stage the 2026.10.3 field kernel and its FAT modules
# from the signed 2026.10.3 release, for scripts/assemble-ab-image.sh
# (geekdojo/geekdojo-brain#893).
#
#   usage: scripts/fetch-legacy-boot.sh <root-ca.pem> <out-dir>
#
# WHY
#   Every firewall flashed from 2026.08.1 to 2026.10.3 has ONE kernel on its
#   ESP, /boot/vmlinuz = 6.12.94, shared by both slots. From #893 on, each
#   release's rootfs carries its own kernel and GRUB boots it from the slot's
#   squashfs; a slot whose rootfs has no kernel (any release before #893)
#   boots that shared file. So the shared kernel must stay the 2026.10.3
#   kernel for good, on field boxes AND in every fresh image, or a downgrade to
#   an older release would boot a kernel it was not built for. This script
#   provides those bytes:
#     <out-dir>/vmlinuz             the 2026.10.3 ESP kernel; assemble puts it
#                                   on the fresh image's ESP as /boot/vmlinuz
#     <out-dir>/kernel-id           its "uname -r uname -v"
#     <out-dir>/6.12.94/<name>.ko   fat, vfat, nls_cp437, nls_iso8859-1 and
#                                   nls_utf8 from the 2026.10.3 rootfs
#   The modules go into the rootfs at /boot/legacy-kmods: when a box's old agent
#   installs this release, its first boot runs the shared 6.12.94 kernel with
#   none of this rootfs's modules loadable, and the kernel-match guard needs
#   vfat in THAT kernel to reach the ESP and repair the boot. The agent loads
#   them only when the running kernel's id equals kernel-id.
#
# WHAT IT TRUSTS, AND HOW IT FAILS
#   It downloads only the published 2026.10.3 manifest.json, manifest.json.sig,
#   -ab.img.gz and -ab.img.gz.sig (about 61 MB), and refuses (exit 1, with a
#   sentence naming the file and the cause) unless:
#     - both signatures verify against <root-ca.pem>, with the published verify
#       command, at their signing time;
#     - the -ab.img.gz sha256 equals the signed manifest's;
#     - the ESP kernel's sha256 equals image/legacy-kernel.sha256, and its id
#       equals image/legacy-kernel-id;
#     - each module's sha256 equals image/legacy-kmods.sha256.
#   The pins are the real gate: a published release can be re-signed, and these
#   must be the exact bytes every field box runs.
#
# TEST SEAMS (scripts/test-fetch-legacy-boot.sh): RASPUTIN_LEGACY_SRC=<dir>
# reads the four release files from a directory instead of downloading them;
# RASPUTIN_LEGACY_PINS=<file> and RASPUTIN_LEGACY_KERNEL_PIN=<file> replace
# image/legacy-kmods.sha256 and image/legacy-kernel.sha256, because a fixture
# cannot carry the real kernel and modules. Otherwise the files come from
# `gh release download`, which needs GH_TOKEN.
#
# Needs: openssl, jq, gunzip, sfdisk, mtools, unsquashfs (4.5 or later, for -o).
set -euo pipefail

CA="${1:?usage: $0 <root-ca.pem> <out-dir>}"
OUT="${2:?usage: $0 <root-ca.pem> <out-dir>}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS="${RASPUTIN_LEGACY_PINS:-$REPO_ROOT/image/legacy-kmods.sha256}"
KPIN="${RASPUTIN_LEGACY_KERNEL_PIN:-$REPO_ROOT/image/legacy-kernel.sha256}"
LEGACY_ID_FILE="$REPO_ROOT/image/legacy-kernel-id"

LEGACY_RELEASE=2026.10.3
LEGACY_KVER=6.12.94
LEGACY_REPO=geekdojo/rasputin-openwrt-firewall
IMG="rasputin-fw-n100-${LEGACY_RELEASE}-ab.img.gz"

die() { echo "fetch-legacy-boot: $*" >&2; exit 1; }
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

[ -s "$CA" ] || die "the root CA $CA is missing or empty, so nothing can verify the $LEGACY_RELEASE release."
[ -s "$PINS" ] || die "the module pins $PINS are missing or empty."
[ -s "$KPIN" ] || die "the kernel pin $KPIN is missing or empty."
[ -s "$LEGACY_ID_FILE" ] || die "the pinned legacy kernel id $LEGACY_ID_FILE is missing or empty."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DL="$WORK/dl"
mkdir -p "$DL"

files="manifest.json manifest.json.sig $IMG $IMG.sig"
if [ -n "${RASPUTIN_LEGACY_SRC:-}" ]; then
	for f in $files; do
		cp "$RASPUTIN_LEGACY_SRC/$f" "$DL/$f" 2>/dev/null || die "$f is missing from $RASPUTIN_LEGACY_SRC."
	done
else
	for f in $files; do
		gh release download "$LEGACY_RELEASE" --repo "$LEGACY_REPO" --pattern "$f" --dir "$DL" \
			|| die "could not download $f from release $LEGACY_RELEASE of $LEGACY_REPO."
		[ -s "$DL/$f" ] || die "$f is missing from release $LEGACY_RELEASE of $LEGACY_REPO."
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
# the time the release was signed, not today (geekdojo/geekdojo-brain#888,
# F-888-21): these signatures never change, and the leaf that made them expires
# (leaf-003, 2028-08-20), after which a today-check would fail every build.
verify_sig() {
	at=$(signed_at "$1") || exit 1
	openssl cms -verify -binary -inform DER -in "$DL/$1.sig" -content "$DL/$1" \
		-CAfile "$CA" -attime "$at" -out /dev/null 2>"$WORK/cms.err" \
		|| die "$1.sig does not verify against $CA: $(tr '\n' ' ' < "$WORK/cms.err")"
	echo "fetch-legacy-boot: $1.sig verified (at its signing time, epoch $at)"
}
verify_sig manifest.json
verify_sig "$IMG"

want=$(jq -r --arg i "$IMG" '.artifacts[] | select(.image == $i) | .sha256' "$DL/manifest.json")
[ -n "$want" ] && [ "$want" != null ] || die "manifest.json names no sha256 for $IMG."
got=$(sha256_of "$DL/$IMG")
[ "$got" = "$want" ] || die "$IMG has sha256 $got, but the signed manifest says $want."
echo "fetch-legacy-boot: $IMG sha256 matches the manifest"

# OpenWrt-derived images carry trailing NUL padding: gunzip exits 2.
rc=0
gunzip -c "$DL/$IMG" > "$WORK/disk.img" || rc=$?
[ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || die "$IMG does not decompress (gunzip exit $rc)."
rm -f "$DL/$IMG"

# part_offset <name> — the byte offset of a GPT partition, by name.
part_offset() {
	sfdisk -J "$WORK/disk.img" 2>/dev/null | jq -r --arg n "$1" \
		'.partitiontable | (.sectorsize // 512) as $s | .partitions[] | select(.name == $n) | .start * $s'
}
esp_off=$(part_offset esp)
root_off=$(part_offset rootfs-0)
[ -n "$esp_off" ] || die "$IMG has no partition named esp."
[ -n "$root_off" ] || die "$IMG has no partition named rootfs-0."

export MTOOLS_SKIP_CHECK=1
mcopy -n -i "$WORK/disk.img@@$esp_off" ::/boot/vmlinuz "$WORK/vmlinuz" 2>/dev/null \
	|| die "$IMG has no /boot/vmlinuz on its ESP."
kwant=$(awk 'NF == 2 && $2 == "vmlinuz" {print $1}' "$KPIN")
[ -n "$kwant" ] || die "$KPIN pins no vmlinuz."
kgot=$(sha256_of "$WORK/vmlinuz")
[ "$kgot" = "$kwant" ] || die "the ESP kernel in $IMG has sha256 $kgot, but $KPIN pins $kwant."
kid=$("$REPO_ROOT/scripts/kernel-id.sh" "$WORK/vmlinuz") || die "the ESP kernel in $IMG carries no readable kernel id."
[ "$kid" = "$(head -n 1 "$LEGACY_ID_FILE")" ] \
	|| die "the ESP kernel in $IMG is '$kid', but $LEGACY_ID_FILE pins '$(head -n 1 "$LEGACY_ID_FILE")'."
echo "fetch-legacy-boot: ESP kernel matches the pin ($kid)"

mods=$(awk 'NF == 2 {print $2}' "$PINS")
[ "$(printf '%s\n' "$mods" | grep -c .)" -eq 5 ] || die "$PINS must pin exactly five modules."
paths=""
for m in $mods; do paths="$paths lib/modules/$LEGACY_KVER/$m"; done
# shellcheck disable=SC2086 # one argument per module path
unsquashfs -no-progress -o "$root_off" -d "$WORK/x" "$WORK/disk.img" $paths >/dev/null 2>&1 \
	|| die "could not extract the modules from the rootfs-0 partition of $IMG."

while read -r sum m; do
	[ -n "$m" ] || continue
	f="$WORK/x/lib/modules/$LEGACY_KVER/$m"
	[ -f "$f" ] || die "the rootfs in $IMG has no lib/modules/$LEGACY_KVER/$m."
	got=$(sha256_of "$f")
	[ "$got" = "$sum" ] || die "$m has sha256 $got, but $PINS pins $sum."
done < "$PINS"

mkdir -p "$OUT/$LEGACY_KVER"
for m in $mods; do cp "$WORK/x/lib/modules/$LEGACY_KVER/$m" "$OUT/$LEGACY_KVER/$m"; done
cp "$WORK/vmlinuz" "$OUT/vmlinuz"
printf '%s\n' "$kid" > "$OUT/kernel-id"
echo "fetch-legacy-boot: staged the kernel and $(printf '%s\n' "$mods" | tr '\n' ' ')for '$kid' in $OUT"
