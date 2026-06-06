#!/usr/bin/env bash
#
# patch-image-cmdline.sh — inject extra kernel cmdline args into the
# generated OpenWrt combined-efi image's GRUB config.
#
# Why this exists: ImageBuilder bakes the kernel cmdline into grub.cfg on
# the FAT EFI partition during `make image`. There's no first-class
# ImageBuilder knob for "append to cmdline" that's stable across OpenWrt
# versions, so we patch the generated image directly.
#
# What we inject:
#   i915.modeset=0 i915.enable_guc=0
#
#   The OpenWrt 24.10 x86 kernel has i915 built in (not a kmod we can
#   blacklist), and the non-free Intel GuC firmware blob isn't bundled.
#   On N100 / Alder Lake-N the driver wedges trying to fetch
#   i915/tgl_guc_70.bin, framebuffer console waits ~262 s before falling
#   back to efifb, and dmesg fills with [drm] *ERROR* noise.
#
#   For a *built-in* driver, modprobe.blacklist= doesn't apply (the
#   driver is part of the kernel image, not loaded via modprobe). The
#   only lever is per-driver kernel cmdline params:
#     - i915.modeset=0   → skip KMS (driver still binds + tries GuC)
#     - i915.enable_guc=0 → skip GuC firmware load entirely (the bit
#                           actually failing on Alder Lake-N without
#                           the firmware blob)
#   We set both for belt-and-suspenders. enable_guc=0 is the targeted
#   fix; modeset=0 keeps us cleanly on efifb. Discovered + diagnosed
#   on CWWK x86-p5-n100 bring-up 2026-06-07 (dev.2 shipped with only
#   modeset=0 and still showed the GuC error).
#
# Usage:
#   ./scripts/patch-image-cmdline.sh <path/to/openwrt-*-combined-efi.img>
#
# Requires: mtools (mcopy/mdir), fdisk. Both are present on
# ubuntu-latest by default.
#
# Note: this MUST run on the uncompressed .img, before gzip. The CI
# workflow handles unzip → patch → re-gzip ordering.

set -euo pipefail

IMG="${1:?usage: $0 <path-to-combined-efi.img>}"

if [[ ! -f "$IMG" ]]; then
	echo "patch-image-cmdline: $IMG not found" >&2
	exit 1
fi

# Extra args we want to append. Single source of truth — bump here, not
# in the workflow.
EXTRA_CMDLINE="i915.modeset=0 i915.enable_guc=0"

echo "patch-image-cmdline: target image $IMG"
echo "patch-image-cmdline: cmdline to inject: $EXTRA_CMDLINE"

# --- Find the EFI FAT partition (sector offset, sector size 512) ---
# OpenWrt combined-efi image layout (verified against 24.10 x86/64):
#   Partition 1: EFI FAT (boot)     <-- grub.cfg lives here
#   Partition 2: rootfs (squashfs)
# We use `fdisk -l` and parse the first partition's start sector.
START_SECTOR=$(fdisk -l "$IMG" | awk '/^[^ ]*1 / {print $2; exit}')
if [[ -z "${START_SECTOR:-}" ]]; then
	echo "patch-image-cmdline: failed to find EFI partition in $IMG" >&2
	echo "patch-image-cmdline: fdisk output was:" >&2
	fdisk -l "$IMG" >&2
	exit 1
fi
OFFSET=$((START_SECTOR * 512))
echo "patch-image-cmdline: EFI partition starts at sector $START_SECTOR (offset $OFFSET bytes)"

# --- Read grub.cfg via mtools (no mount, no loopback needed) ---
TMPDIR_PATCH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_PATCH"' EXIT

# mtools requires the partition image. We can pass `IMG@@OFFSET` syntax
# to skip past the partition table.
DRIVE_CFG="$TMPDIR_PATCH/mtoolsrc"
cat > "$DRIVE_CFG" <<EOF
drive z: file="$IMG" offset=$OFFSET
mtools_skip_check=1
EOF
export MTOOLSRC="$DRIVE_CFG"

echo
echo "----- before patch -----"
mdir -i "$IMG@@$OFFSET" ::/boot/grub/ 2>&1 | head -20
GRUBCFG="$TMPDIR_PATCH/grub.cfg"
mcopy -i "$IMG@@$OFFSET" ::/boot/grub/grub.cfg "$GRUBCFG"
echo
echo "----- grub.cfg contents before patch -----"
cat "$GRUBCFG"

# --- Idempotent injection: only add if not already there ---
# Sentinel is enable_guc — the *targeted* fix. modeset=0 alone (which
# dev.2/3 shipped with) is detected as stale and re-patched cleanly.
if grep -q 'i915.enable_guc=0' "$GRUBCFG"; then
	echo
	echo "patch-image-cmdline: cmdline already contains the full fix; nothing to do"
	exit 0
fi

# Append our args to every `linux /boot/vmlinuz ...` line. The line ends
# at a newline; we insert just before the newline.
sed -i.bak -E "s|^([[:space:]]*linux[[:space:]]+/boot/vmlinuz[[:space:]].*)$|\1 $EXTRA_CMDLINE|" "$GRUBCFG"

# --- Sanity check the patch landed ---
if ! grep -q "$EXTRA_CMDLINE" "$GRUBCFG"; then
	echo "patch-image-cmdline: failed to inject cmdline — grub.cfg unchanged" >&2
	diff -u "$GRUBCFG.bak" "$GRUBCFG" >&2 || true
	exit 1
fi

echo
echo "----- grub.cfg contents after patch -----"
cat "$GRUBCFG"

# --- Write grub.cfg back via mcopy -o (overwrite) ---
mcopy -i "$IMG@@$OFFSET" -o "$GRUBCFG" ::/boot/grub/grub.cfg
echo
echo "patch-image-cmdline: grub.cfg written back to image"

# --- Verify by reading back what we wrote ---
VERIFY="$TMPDIR_PATCH/grub-verify.cfg"
mcopy -i "$IMG@@$OFFSET" ::/boot/grub/grub.cfg "$VERIFY"
if ! grep -q "$EXTRA_CMDLINE" "$VERIFY"; then
	echo "patch-image-cmdline: read-back verification FAILED" >&2
	exit 1
fi

echo "patch-image-cmdline: read-back verification OK"
