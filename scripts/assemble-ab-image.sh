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
#   [ESP RASPUTINEFI: bootx64.efi + /boot/vmlinuz (shared, 2026.10.3) + /boot/grub/{grub.cfg,grubenv}]
#   [seed RASPUTIN-FW (basic-data FAT, ships empty)]
#   [rootfs-0 squashfs] [rootfs-1 squashfs (same at flash)] [rootfs_data]
#
# We build our OWN grub EFI (grub-mkimage) with the loadenv + test modules the
# A/B boot-counter needs baked in, rather than trusting OpenWrt's prebuilt grub
# to include them — this removes a bench-validation unknown and mirrors how the
# compute image pins its grub module set. We take only the KERNEL and ROOTFS
# from ImageBuilder.
#
# THE KERNEL LIVES IN THE SLOT (geekdojo/geekdojo-brain#893). A kernel and its
# rootfs are one build, so the rootfs carries its kernel and GRUB boots it
# straight from the slot's squashfs (image/grub.cfg). The rootfs squashfs gets a
# new top-level /boot, appended (not repacked) so every ImageBuilder file stays
# byte-identical:
#   /boot/vmlinuz                   this build's kernel, which GRUB boots
#   /boot/kernel-id                 "uname -r uname -v" of that kernel, for the
#                                   kernel-match guard (scripts/kernel-id.sh)
#   /boot/bootx64.efi, /boot/grub.cfg
#                                   this build's GRUB EFI and grub.cfg. A box
#                                   flashed before #893 has a GRUB that cannot
#                                   read a squashfs; the guard has the agent
#                                   copy these two to its ESP, once.
#   /boot/legacy-kmods/kernel-id    the 2026.10.3 field kernel's id, and
#   /boot/legacy-kmods/6.12.94/*.ko its FAT modules: what lets the guard reach
#                                   the ESP from a slot an older agent installed,
#                                   still running the field kernel
# The ESP's shared /boot/vmlinuz is the pinned 2026.10.3 kernel, never this
# build's: it is what a slot whose rootfs has no kernel (any release before
# #893) boots, so a downgrade boots the kernel it was built with. There is no
# vmlinuz-A or vmlinuz-B. The .rootfs keeps the size of ImageBuilder's
# partition, zero-padded. scripts/check-boot-layout.sh checks the result.
#
# Outputs (in $OUT_DIR, default ./ab-out):
#   rasputin-fw-n100-<ver>-ab.img.gz   — full A/B disk, initial flash
#   rasputin-fw-n100-<ver>.rootfs      — bare rootfs squashfs, the OTA artifact
#                                        the agent OpenWrtABBackend dd's into a slot
#   rasputin-fw-n100-<ver>.rootfs.version  — version sidecar the agent reads
#
# Runner deps (ubuntu-latest): apt-get install -y genimage mtools fdisk \
#   util-linux grub-common grub2-common grub-efi-amd64-bin squashfs-tools
#
# Usage:
#   ./scripts/assemble-ab-image.sh <path/to/openwrt-*-combined-efi.img> <version> <legacy-dir>
#   (<legacy-dir> is the output of scripts/fetch-legacy-boot.sh.)
#   (pass the UNCOMPRESSED .img; the release workflow gunzips ImageBuilder's
#    artifact first, same as the old patch-image-cmdline step did.)

set -euo pipefail

USAGE="usage: $0 <combined-efi.img> <version> <legacy-dir>"
IMG="${1:?$USAGE}"
VERSION="${2:?$USAGE}"
LEGACY="${3:?$USAGE}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/ab-out}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$IMG" ] || { echo "assemble-ab: $IMG not found" >&2; exit 1; }
LEGACY_MODS="fat.ko vfat.ko nls_cp437.ko nls_iso8859-1.ko nls_utf8.ko"
for f in vmlinuz kernel-id; do
	[ -s "$LEGACY/$f" ] || { echo "assemble-ab: no legacy $f at $LEGACY/$f; run scripts/fetch-legacy-boot.sh first" >&2; exit 1; }
done
for m in $LEGACY_MODS; do
	[ -s "$LEGACY/6.12.94/$m" ] || { echo "assemble-ab: no legacy module $LEGACY/6.12.94/$m; run scripts/fetch-legacy-boot.sh first" >&2; exit 1; }
done
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

# --- 3. extract this build's kernel from ImageBuilder's ESP ------------------
# OpenWrt x86-64 EFI keeps the kernel on the FAT ESP at /boot/vmlinuz. It goes
# into the rootfs (3c), not onto our ESP.
export MTOOLS_SKIP_CHECK=1
mkdir -p "$INPUT/esp-stage/boot/grub" "$INPUT/esp-stage/EFI/BOOT"
KERNEL="$WORK/vmlinuz"
mcopy -i "$IMG@@$ESP_OFF" ::/boot/vmlinuz "$KERNEL" || {
	echo "assemble-ab: no ::/boot/vmlinuz on the ESP — layout changed?" >&2
	mdir -i "$IMG@@$ESP_OFF" ::/boot/ >&2 || true
	exit 1
}
KERNEL_ID="$("$REPO_ROOT/scripts/kernel-id.sh" "$KERNEL")"
echo "assemble-ab: extracted kernel ($(du -h "$KERNEL" | cut -f1)), id '$KERNEL_ID'"

# --- 3b. build OUR grub EFI with the A/B module set embedded ----------------
# Before the payload, because the rootfs carries it too (see the header).
# prefix=/boot/grub → grub reads /boot/grub/grub.cfg from its boot device (the
# ESP). Modules are baked in, so no /boot/grub/x86_64-efi/*.mod needed on the ESP.
# loadenv + test are the load-bearing ones for the boot-counter; squash4 +
# xzio + regexp read each slot's kernel from its squashfs; the rest are the
# minimum to read GPT/FAT, boot a linux kernel, and drive serial.
EFI="$WORK/bootx64.efi"
grub-mkimage \
	-O x86_64-efi \
	-p /boot/grub \
	-o "$EFI" \
	part_gpt fat squash4 xzio regexp loadenv test linux echo \
	configfile normal boot serial terminal all_video gzio
# Module notes (grub-mkimage fails hard on a missing/unknown module, so this set
# is deliberate):
#   - squash4 is GRUB's squashfs reader (the module is squash4, not
#     "squashfs"; Ubuntu's grub-efi-amd64-bin ships it). xzio decodes
#     OpenWrt's xz-compressed squashfs, x86 BCJ filter included. regexp sets
#     $disk from $root in grub.cfg. scripts/check-boot-layout.sh proves on
#     every build, with grub-fstest, that this GRUB reads the kernel back out
#     of this build's .rootfs byte for byte.
#   - `terminal` is the module; terminal_input/terminal_output are COMMANDS it
#     provides (grub.cfg calls them) — not modules, so they're not listed.
#   - NO `search`: grub.cfg finds the slots by partition number on the disk it
#     booted from, and load_env reads from $prefix.
#   - part_gpt + fat are load-bearing: GRUB needs them to locate its /boot/grub
#     prefix on the GPT ESP it booted from.
echo "assemble-ab: built bootx64.efi with loadenv, test and squash4 embedded"

# --- 3c. append the slot's boot payload to the rootfs squashfs ---------------
# Appended, not repacked, so ImageBuilder's files keep their bytes. The extract
# is ImageBuilder's whole partition: cut it to the squashfs's bytes_used (u64
# LE at offset 40 of the superblock) so mksquashfs appends after the real end,
# then pad back to the partition size, as the .rootfs has always been.
ORIG="$WORK/imagebuilder.squashfs"
mv "$INPUT/rootfs.squashfs" "$ORIG"
ORIG_SIZE=$(stat -c%s "$ORIG")
BYTES_USED=$(od -An -t u8 -j 40 -N 8 "$ORIG" | tr -d ' ')
[ -n "$BYTES_USED" ] && [ "$BYTES_USED" -gt 0 ] && [ "$BYTES_USED" -le "$ORIG_SIZE" ] || {
	echo "assemble-ab: unreadable squashfs bytes_used ($BYTES_USED) in a $ORIG_SIZE-byte rootfs" >&2; exit 1
}
PAYLOAD="$WORK/payload"
mkdir -p "$PAYLOAD/boot/legacy-kmods/6.12.94"
cp "$KERNEL" "$PAYLOAD/boot/vmlinuz"
printf '%s\n' "$KERNEL_ID" > "$PAYLOAD/boot/kernel-id"
cp "$EFI" "$PAYLOAD/boot/bootx64.efi"
cp "$REPO_ROOT/image/grub.cfg" "$PAYLOAD/boot/grub.cfg"
cp "$LEGACY/kernel-id" "$PAYLOAD/boot/legacy-kmods/kernel-id"
for m in $LEGACY_MODS; do cp "$LEGACY/6.12.94/$m" "$PAYLOAD/boot/legacy-kmods/6.12.94/$m"; done
head -c "$BYTES_USED" "$ORIG" > "$INPUT/rootfs.squashfs"
mksquashfs "$PAYLOAD" "$INPUT/rootfs.squashfs" -all-root -no-xattrs -no-progress >/dev/null
NEW_SIZE=$(stat -c%s "$INPUT/rootfs.squashfs")
[ "$NEW_SIZE" -le "$ORIG_SIZE" ] || {
	echo "assemble-ab: the rootfs with its /boot payload is $NEW_SIZE bytes, more than the $ORIG_SIZE-byte partition" >&2; exit 1
}
truncate -s "$ORIG_SIZE" "$INPUT/rootfs.squashfs"

# The append must ADD /boot and change nothing else. Checked here, where both
# filesystems exist: the long listings (mode, owner, size, mtime, link target,
# device numbers) differ by exactly the payload, and every extracted file is
# byte-identical. Device nodes cannot be created unprivileged, so they are
# compared by listing only.
# Listing lines with the path made absolute, minus the root directory (its
# own entry gains a child) and /boot (the payload, checked on its own).
listing() { unsquashfs -lln "$1" | sed 's| squashfs-root| |' | grep -vE ' (/boot(/.*)?)?$' || true; }
listing "$ORIG" > "$WORK/orig.lst"
listing "$INPUT/rootfs.squashfs" > "$WORK/new.lst"
diff -u "$WORK/orig.lst" "$WORK/new.lst" || { echo "assemble-ab: the append changed ImageBuilder's file metadata" >&2; exit 1; }
unsquashfs -l "$INPUT/rootfs.squashfs" | sed -n 's|^squashfs-root/boot|/boot|p' | sort > "$WORK/added.lst"
printf '%s\n' /boot /boot/bootx64.efi /boot/grub.cfg /boot/kernel-id /boot/legacy-kmods \
	/boot/legacy-kmods/6.12.94 /boot/legacy-kmods/kernel-id /boot/vmlinuz > "$WORK/want.lst"
for m in $LEGACY_MODS; do echo "/boot/legacy-kmods/6.12.94/$m" >> "$WORK/want.lst"; done
sort -o "$WORK/want.lst" "$WORK/want.lst"
diff -u "$WORK/want.lst" "$WORK/added.lst" || { echo "assemble-ab: the appended /boot is not exactly the payload" >&2; exit 1; }
SPECIAL=$(unsquashfs -lln "$ORIG" | awk '/^[bcps]/ {sub(/^.*squashfs-root\//, ""); print}')
# shellcheck disable=SC2086 # one argument per special file
unsquashfs -no-progress -d "$WORK/orig-tree" -excludes "$ORIG" $SPECIAL >/dev/null
# shellcheck disable=SC2086
unsquashfs -no-progress -d "$WORK/new-tree" -excludes "$INPUT/rootfs.squashfs" $SPECIAL >/dev/null
if [ "$(diff -r --no-dereference "$WORK/orig-tree" "$WORK/new-tree")" != "Only in $WORK/new-tree: boot" ]; then
	diff -r --no-dereference "$WORK/orig-tree" "$WORK/new-tree" | head -20 >&2
	echo "assemble-ab: the append changed the content of ImageBuilder's files" >&2; exit 1
fi
rm -rf "$WORK/orig-tree" "$WORK/new-tree"
echo "assemble-ab: appended /boot to the rootfs ($BYTES_USED -> $NEW_SIZE bytes used, padded to $ORIG_SIZE); every other file unchanged"

# --- 4. stage the ESP ---------------------------------------------------------
# The same EFI and grub.cfg the rootfs carries, and the shared fallback kernel:
# the pinned 2026.10.3 kernel (see the header), never this build's.
cp "$EFI" "$INPUT/esp-stage/EFI/BOOT/bootx64.efi"
cp "$LEGACY/vmlinuz" "$INPUT/esp-stage/boot/vmlinuz"
echo "assemble-ab: ESP gets the shared 2026.10.3 kernel '$(cat "$LEGACY/kernel-id")'"

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

# --- 5c. empty seed placeholder for the RASPUTIN-FW seed FAT -----------------
# The seed lives on its own basic-data FAT now (genimage.cfg `seed.vfat`), not
# the ESP, so it auto-mounts on a laptop like the compute image. genimage's
# vfat `file` entry needs a source: stage an EMPTY rasputin-seed.env. The
# firewall ships unseeded — 98-rasputin-seed's `-s` (non-empty) test skips an
# empty seed, so this reads as "no seed" until the operator or the flasher
# writes a real one onto the partition.
: > "$INPUT/rasputin-seed.env"
echo "assemble-ab: staged empty seed placeholder (RASPUTIN-FW FAT ships unseeded)"

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
