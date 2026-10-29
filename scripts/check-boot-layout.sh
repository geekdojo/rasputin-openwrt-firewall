#!/usr/bin/env bash
#
# check-boot-layout.sh — check a built firewall release boots each slot's own
# kernel, and that every piece the boot depends on agrees
# (geekdojo/geekdojo-brain#893).
#
#   usage: scripts/check-boot-layout.sh <-ab.img or -ab.img.gz> <.rootfs>
#
# WHY
#   GRUB boots each slot's kernel straight from the slot's squashfs, falling
#   back to the ESP's shared 2026.10.3 kernel for a rootfs that carries none
#   (image/grub.cfg). That works only while all of these hold, and each one
#   failing is a box that boots the wrong kernel or none. This runs in the
#   build job, before anything is uploaded, and fails the build on any of them.
#
# CHECKS (each failure names its cause; all are reported, then exit 1)
#   - the rootfs's /boot is exactly {vmlinuz, kernel-id, bootx64.efi,
#     grub.cfg, legacy-kmods/{kernel-id, 6.12.94/<the five pinned modules>}};
#   - the ESP's EFI/BOOT/bootx64.efi equals the rootfs's /boot/bootx64.efi, and
#     the ESP's boot/grub/grub.cfg equals the rootfs's /boot/grub.cfg, which
#     equals image/grub.cfg (the agent's one-time repair copies the rootfs
#     pair to a field box's ESP, so the two layouts must be the same pair);
#   - the ESP's shared boot/vmlinuz matches image/legacy-kernel.sha256, and
#     there is no boot/vmlinuz-A or boot/vmlinuz-B;
#   - /boot/kernel-id equals scripts/kernel-id.sh run on /boot/vmlinuz, and
#     /lib/modules holds exactly one tree, named for that kernel's release;
#   - the legacy modules match image/legacy-kmods.sha256 and the legacy
#     kernel-id equals image/legacy-kernel-id;
#   - GPT partitions 3 and 4 are named rootfs-0 and rootfs-1, the numbers
#     grub.cfg reads the kernels from;
#   - `grub-fstest <.rootfs> cmp /boot/vmlinuz <kernel>`: GRUB's own squashfs
#     reader returns this build's kernel byte for byte, so every build proves
#     GRUB can boot the artifact it ships.
#
# TEST SEAMS (scripts/test-check-boot-layout.sh): RASPUTIN_LEGACY_PINS=<file>
# and RASPUTIN_LEGACY_KERNEL_PIN=<file> replace image/legacy-kmods.sha256 and
# image/legacy-kernel.sha256, because a fixture cannot carry the real kernel
# and modules.
#
# Needs: sfdisk, jq, mtools, unsquashfs, grub-fstest (grub-common).
set -uo pipefail

usage="usage: $0 <-ab.img or -ab.img.gz> <.rootfs>"
DISK="${1:?$usage}"
ROOTFS="${2:?$usage}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS="${RASPUTIN_LEGACY_PINS:-$REPO_ROOT/image/legacy-kmods.sha256}"
KPIN="${RASPUTIN_LEGACY_KERNEL_PIN:-$REPO_ROOT/image/legacy-kernel.sha256}"
LEGACY_ID_FILE="$REPO_ROOT/image/legacy-kernel-id"
GRUB_CFG="$REPO_ROOT/image/grub.cfg"

fails=0
bad() { echo "check-boot-layout: FAIL $*" >&2; fails=$((fails + 1)); }
die() { echo "check-boot-layout: $*" >&2; exit 1; }
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

[ -f "$DISK" ] || die "no disk image at $DISK"
[ -f "$ROOTFS" ] || die "no rootfs at $ROOTFS"
[ -s "$PINS" ] || die "the module pins $PINS are missing or empty"
[ -s "$KPIN" ] || die "the kernel pin $KPIN is missing or empty"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- the disk -----------------------------------------------------------------
case "$DISK" in
	*.gz)
		rc=0
		gunzip -c "$DISK" > "$WORK/disk.img" || rc=$?
		# OpenWrt-derived images carry trailing NUL padding: gunzip exits 2.
		[ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || die "gunzip failed with rc=$rc on $DISK"
		IMG="$WORK/disk.img" ;;
	*) IMG="$DISK" ;;
esac
sfdisk -J "$IMG" > "$WORK/pt.json" 2>/dev/null || die "cannot read a partition table from $DISK"
# part_name <n> — the GPT name of partition number n ("" when absent).
part_name() {
	jq -r --arg n "$1" '.partitiontable.partitions[] | select(.node | test("[^0-9]" + $n + "$")) | .name // ""' "$WORK/pt.json"
}
for pair in 3:rootfs-0 4:rootfs-1; do
	n=${pair%%:*} want=${pair#*:}
	got=$(part_name "$n")
	[ "$got" = "$want" ] || bad "GPT partition $n is named '$got', want '$want': grub.cfg reads the $want kernel from gpt$n"
done
esp_start=$(jq -r '.partitiontable | (.sectorsize // 512) as $s | .partitions[] | select(.name == "esp") | .start * $s' "$WORK/pt.json")
[ -n "$esp_start" ] || die "no partition named esp in $DISK"
export MTOOLS_SKIP_CHECK=1
ESP="$IMG@@$esp_start"
echo "check-boot-layout: ESP boot/ of $DISK:"
mdir -i "$ESP" ::/boot || die "cannot read the ESP of $DISK"
mkdir -p "$WORK/esp"
mcopy -n -i "$ESP" ::/EFI/BOOT/bootx64.efi "$WORK/esp/bootx64.efi" 2>/dev/null || bad "the ESP has no EFI/BOOT/bootx64.efi"
mcopy -n -i "$ESP" ::/boot/grub/grub.cfg "$WORK/esp/grub.cfg" 2>/dev/null || bad "the ESP has no boot/grub/grub.cfg"
mcopy -n -i "$ESP" ::/boot/vmlinuz "$WORK/esp/vmlinuz" 2>/dev/null || bad "the ESP has no shared boot/vmlinuz"
for f in vmlinuz-A vmlinuz-B; do
	if mdir -i "$ESP" "::/boot/$f" >/dev/null 2>&1; then
		bad "the ESP has a boot/$f; no slot kernel belongs on the ESP"
	fi
done
if [ -f "$WORK/esp/vmlinuz" ]; then
	kwant=$(awk 'NF == 2 && $2 == "vmlinuz" {print $1}' "$KPIN")
	[ "$(sha256_of "$WORK/esp/vmlinuz")" = "$kwant" ] \
		|| bad "the ESP's shared boot/vmlinuz has sha256 $(sha256_of "$WORK/esp/vmlinuz"), but $KPIN pins $kwant"
fi

# --- the rootfs ---------------------------------------------------------------
unsquashfs -l "$ROOTFS" > "$WORK/rootfs.lst" 2>/dev/null || die "cannot list $ROOTFS as a squashfs"
legacy_mods=$(awk 'NF == 2 {print $2}' "$PINS")
sed -n 's|^squashfs-root/boot|/boot|p' "$WORK/rootfs.lst" | sort > "$WORK/boot.lst"
{
	printf '%s\n' /boot /boot/bootx64.efi /boot/grub.cfg /boot/kernel-id /boot/legacy-kmods \
		/boot/legacy-kmods/6.12.94 /boot/legacy-kmods/kernel-id /boot/vmlinuz
	for m in $legacy_mods; do echo "/boot/legacy-kmods/6.12.94/$m"; done
} | sort > "$WORK/want.lst"
if ! diff -u "$WORK/want.lst" "$WORK/boot.lst" > "$WORK/boot.diff"; then
	bad "the rootfs's /boot is not exactly the payload (- missing, + extra): $(grep -E '^[-+]/' "$WORK/boot.diff" | tr '\n' ' ')"
fi

unsquashfs -no-progress -d "$WORK/r" "$ROOTFS" boot >/dev/null 2>&1 || true
B="$WORK/r/boot"

if [ -f "$B/vmlinuz" ]; then
	if computed=$("$REPO_ROOT/scripts/kernel-id.sh" "$B/vmlinuz"); then
		if [ -f "$B/kernel-id" ]; then
			stored=$(head -n 1 "$B/kernel-id")
			[ "$stored" = "$computed" ] \
				|| bad "/boot/kernel-id says '$stored' but the kernel beside it is '$computed'"
		fi
		release="${computed%% *}"
		trees=$(sed -n 's|^squashfs-root/lib/modules/\([^/]*\)$|\1|p' "$WORK/rootfs.lst")
		n=$(printf '%s\n' "$trees" | grep -c .)
		if [ "$n" -ne 1 ]; then
			bad "/lib/modules holds $n trees ($(echo "$trees" | tr '\n' ' ')), want exactly one: $release"
		elif [ "$trees" != "$release" ]; then
			bad "/lib/modules/$trees does not belong to the kernel the rootfs carries ($release)"
		fi
	else
		bad "the rootfs's /boot/vmlinuz carries no readable kernel id"
	fi
	# GRUB's own reader (squash4 + xzio, the modules in our EFI) on the real
	# .rootfs. The ESP's EFI is checked equal to the payload's above.
	if ! grub-fstest "$ROOTFS" cmp /boot/vmlinuz "$B/vmlinuz" > "$WORK/fstest.out" 2>&1; then
		bad "grub-fstest cannot read /boot/vmlinuz back out of $ROOTFS byte for byte, so GRUB could not boot it: $(tr '\n' ' ' < "$WORK/fstest.out")"
	fi
fi

if [ -f "$B/bootx64.efi" ] && [ -f "$WORK/esp/bootx64.efi" ]; then
	cmp -s "$B/bootx64.efi" "$WORK/esp/bootx64.efi" \
		|| bad "the ESP's EFI/BOOT/bootx64.efi differs from the rootfs's /boot/bootx64.efi"
fi
if [ -f "$B/grub.cfg" ]; then
	cmp -s "$B/grub.cfg" "$GRUB_CFG" || bad "the rootfs's /boot/grub.cfg differs from image/grub.cfg"
	if [ -f "$WORK/esp/grub.cfg" ]; then
		cmp -s "$WORK/esp/grub.cfg" "$B/grub.cfg" || bad "the ESP's boot/grub/grub.cfg differs from the rootfs's /boot/grub.cfg"
	fi
fi

while read -r sum m; do
	[ -n "$m" ] || continue
	f="$B/legacy-kmods/6.12.94/$m"
	[ -f "$f" ] || continue
	got=$(sha256_of "$f")
	[ "$got" = "$sum" ] || bad "/boot/legacy-kmods/6.12.94/$m has sha256 $got, but $PINS pins $sum"
done < "$PINS"
if [ -f "$B/legacy-kmods/kernel-id" ]; then
	got=$(head -n 1 "$B/legacy-kmods/kernel-id")
	want=$(head -n 1 "$LEGACY_ID_FILE")
	[ "$got" = "$want" ] || bad "/boot/legacy-kmods/kernel-id says '$got', but image/legacy-kernel-id pins '$want'"
fi

if [ "$fails" -ne 0 ]; then
	echo "check-boot-layout: $fails problem(s) in $ROOTFS / $DISK" >&2
	exit 1
fi
echo "check-boot-layout: OK — kernel '$(head -n 1 "$B/kernel-id")' in the rootfs, read back by grub-fstest; the ESP has the same EFI and grub.cfg and the pinned shared kernel"
