#!/usr/bin/env bash
#
# assemble-ab-image.sh — turn a stock OpenWrt combined-efi image into a
# Rasputin A/B disk (os-images/firewall-image.md §5).
#
# The A/B-ness comes from genimage re-laying-out the image, NOT from the build
# system: OpenWrt ImageBuilder produces a single-rootfs combined-efi image; this
# script extracts the kernel + rootfs squashfs from it and hands them to genimage
# with image/genimage.cfg, which assembles our GPT layout:
#
#   [ESP: bootx64.efi + /boot/vmlinuz + /boot/grub/{grub.cfg,grubenv}]
#   [rootfs-0 squashfs] [rootfs-1 squashfs (same at flash)] [rootfs_data]
#
# We build our OWN grub EFI (grub-mkimage) with the loadenv + test modules the
# A/B boot-counter needs baked in, rather than trusting OpenWrt's prebuilt grub
# to include them — this removes a bench-validation unknown and mirrors how the
# compute image pins its grub module set. We take only the KERNEL and ROOTFS
# from ImageBuilder.
#
# Outputs (in $OUT_DIR, default ./ab-out):
#   rasputin-fw-n100-<ver>-ab.img.gz   — full A/B disk, initial flash
#   rasputin-fw-n100-<ver>.rootfs      — bare rootfs squashfs, the OTA artifact
#                                        the agent OpenWrtABBackend dd's into a slot
#   rasputin-fw-n100-<ver>.rootfs.version  — version sidecar the agent reads
#
# Runner deps (ubuntu-latest): apt-get install -y genimage mtools fdisk \
#   util-linux grub-common grub2-common grub-efi-amd64-bin
#
# Usage:
#   ./scripts/assemble-ab-image.sh <path/to/openwrt-*-combined-efi.img> [version]
#   (pass the UNCOMPRESSED .img; the release workflow gunzips ImageBuilder's
#    artifact first, same as the old patch-image-cmdline step did.)

set -euo pipefail

IMG="${1:?usage: $0 <combined-efi.img> [version]}"
VERSION="${2:-${RASPUTIN_VERSION:-0.0.0-dev}}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/ab-out}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$IMG" ] || { echo "assemble-ab: $IMG not found" >&2; exit 1; }
mkdir -p "$OUT_DIR"

echo "assemble-ab: input image $IMG"
echo "assemble-ab: version    $VERSION"

# --- 1. locate the ESP (p1) and rootfs (p2) in the combined image -----------
# sfdisk -d dumps the partition table from a plain image file (no loop device),
# one `... : start=<N>, size=<M>, ...` line per partition, sizes in 512B sectors.
# OpenWrt x86 combined-efi = p1 EFI FAT, p2 squashfs.
mapfile -t PARTS < <(sfdisk -d "$IMG" 2>/dev/null | grep -E '^\S+[[:space:]]*:[[:space:]]*start=')
[ "${#PARTS[@]}" -ge 2 ] || { echo "assemble-ab: expected >=2 partitions in $IMG" >&2; sfdisk -d "$IMG" >&2 || true; exit 1; }
field() { printf '%s\n' "$1" | sed -n "s/.*$2=[[:space:]]*\([0-9][0-9]*\).*/\1/p"; }
P1_START=$(field "${PARTS[0]}" start)
P2_START=$(field "${PARTS[1]}" start)
P2_SECTORS=$(field "${PARTS[1]}" size)
[ -n "$P1_START" ] && [ -n "$P2_START" ] && [ -n "$P2_SECTORS" ] || {
	echo "assemble-ab: could not parse p1/p2 geometry from $IMG" >&2; printf '%s\n' "${PARTS[@]}" >&2; exit 1
}
ESP_OFF=$((P1_START * 512))
echo "assemble-ab: ESP at sector $P1_START (offset $ESP_OFF); rootfs at sector $P2_START ($P2_SECTORS sectors)"

# --- 2. extract the rootfs squashfs (p2) — this IS the OTA artifact ----------
INPUT="$WORK/input"
mkdir -p "$INPUT"
dd if="$IMG" of="$INPUT/rootfs.squashfs" bs=512 skip="$P2_START" count="$P2_SECTORS" status=none
echo "assemble-ab: extracted rootfs.squashfs ($(du -h "$INPUT/rootfs.squashfs" | cut -f1))"

# --- 3. extract the kernel from the ESP -------------------------------------
# OpenWrt x86-64 EFI keeps the kernel on the FAT ESP at /boot/vmlinuz.
export MTOOLS_SKIP_CHECK=1
mkdir -p "$INPUT/esp-stage/boot/grub" "$INPUT/esp-stage/EFI/BOOT"
mcopy -i "$IMG@@$ESP_OFF" ::/boot/vmlinuz "$INPUT/esp-stage/boot/vmlinuz" || {
	echo "assemble-ab: no ::/boot/vmlinuz on the ESP — layout changed?" >&2
	mdir -i "$IMG@@$ESP_OFF" ::/boot/ >&2 || true
	exit 1
}
echo "assemble-ab: extracted kernel ($(du -h "$INPUT/esp-stage/boot/vmlinuz" | cut -f1))"

# --- 4. build OUR grub EFI with the A/B module set embedded -----------------
# prefix=/boot/grub → grub reads /boot/grub/grub.cfg from its boot device (the
# ESP). Modules are baked in, so no /boot/grub/x86_64-efi/*.mod needed on the ESP.
# loadenv + test are the load-bearing ones for the boot-counter; the rest are the
# minimum to read GPT/FAT/squashfs, boot a linux kernel, and drive serial.
grub-mkimage \
	-O x86_64-efi \
	-p /boot/grub \
	-o "$INPUT/esp-stage/EFI/BOOT/bootx64.efi" \
	part_gpt fat loadenv test linux echo \
	configfile normal boot serial terminal all_video gzio
# Module notes (grub-mkimage fails hard on a missing/unknown module, so this set
# is deliberate):
#   - NO squashfs / ext2: GRUB only ever reads the FAT ESP (grub.cfg, grubenv,
#     /boot/vmlinuz). The kernel — not GRUB — mounts the squashfs rootfs. And
#     Ubuntu's grub-efi-amd64-bin doesn't even ship squashfs.mod (build failed
#     here on the first run).
#   - `terminal` is the module; terminal_input/terminal_output are COMMANDS it
#     provides (grub.cfg calls them) — not modules, so they're not listed.
#   - NO `search`: grub.cfg roots by PARTLABEL in the kernel cmdline + load_env
#     from $prefix, so no cross-partition search is needed.
#   - part_gpt + fat are load-bearing: GRUB needs them to locate its /boot/grub
#     prefix on the GPT ESP it booted from.
echo "assemble-ab: built bootx64.efi with loadenv+test embedded"

# --- 5. stage grub.cfg + initialise grubenv ---------------------------------
cp "$REPO_ROOT/image/grub.cfg" "$INPUT/esp-stage/boot/grub/grub.cfg"
GRUBENV="$INPUT/esp-stage/boot/grub/grubenv"
grub-editenv "$GRUBENV" create
# ORDER="A B", both slots good (B is a warm fallback pre-populated with the same
# rootfs by genimage), A first so it boots by default. The agent's grubenv codec
# rewrites this IN PLACE at runtime (activate / mark-good / mark-bad).
grub-editenv "$GRUBENV" set ORDER="A B" A_OK=1 A_TRY=0 B_OK=1 B_TRY=0
echo "assemble-ab: initialised grubenv (ORDER='A B', both slots good)"

# --- 5b. build the shared /overlay ext4 (extroot target) --------------------
# x86 OpenWrt won't put /overlay on a labelled partition on its own, so we ship
# a formatted, empty ext4 labelled `rootfs_data` and point extroot at it via
# files/etc/config/fstab. Both A/B slots mount THIS as /overlay, so config
# survives a slot switch. fstools layers overlayfs on it + auto-creates
# upper/work on first boot. mkfs.ext4 (e2fsprogs) is preinstalled on the runner.
ROOTFS_DATA_MB=512
dd if=/dev/zero of="$INPUT/rootfs_data.ext4" bs=1M count="$ROOTFS_DATA_MB" status=none
mkfs.ext4 -q -F -L rootfs_data "$INPUT/rootfs_data.ext4"
echo "assemble-ab: built empty rootfs_data.ext4 (${ROOTFS_DATA_MB}M, label=rootfs_data)"

# --- 6. assemble the A/B disk with genimage ---------------------------------
# genimage insists on a --rootpath even though our layout embeds pre-built
# images only (no rootfs generated from a tree); an empty dir satisfies it.
GENIMAGE_TMP="$WORK/genimage.tmp"
rm -rf "$GENIMAGE_TMP"
mkdir -p "$WORK/empty-root"
genimage \
	--rootpath   "$WORK/empty-root" \
	--tmppath    "$GENIMAGE_TMP" \
	--inputpath  "$INPUT" \
	--outputpath "$INPUT" \
	--config     "$REPO_ROOT/image/genimage.cfg"

# --- 7. emit release-shaped artifacts ---------------------------------------
IMG_OUT="$OUT_DIR/rasputin-fw-n100-${VERSION}-ab.img"
cp "$INPUT/disk.img" "$IMG_OUT"
gzip -f "$IMG_OUT"
cp "$INPUT/rootfs.squashfs" "$OUT_DIR/rasputin-fw-n100-${VERSION}.rootfs"
printf '%s\n' "$VERSION" > "$OUT_DIR/rasputin-fw-n100-${VERSION}.rootfs.version"

echo "assemble-ab: done — artifacts in $OUT_DIR:"
ls -lh "$OUT_DIR"/rasputin-fw-n100-"${VERSION}"* 2>/dev/null || true
