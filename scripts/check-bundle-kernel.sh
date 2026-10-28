#!/usr/bin/env bash
#
# check-bundle-kernel.sh — check a built firewall release carries the kernel
# its rootfs was built with, everywhere it has to (geekdojo/geekdojo-brain#888).
#
#   usage: scripts/check-bundle-kernel.sh <-ab.img or -ab.img.gz> <.rootfs>
#
# WHY
#   dev.176 published an OTA artifact that, once installed, booted under a
#   kernel it was not built for, and nothing in the build noticed. The release
#   now has to carry its kernel in three places that must agree: the rootfs's
#   /boot (what the agent copies to the ESP on an OTA), the fresh image's ESP
#   (vmlinuz-A and vmlinuz-B), and the id the kernel-match guard compares with
#   uname. This runs in the build job, before anything is uploaded, and fails
#   the build on any disagreement.
#
# CHECKS (each failure names its cause; all are reported, then exit 1)
#   - the rootfs lists /boot/{vmlinuz,grub.cfg,kernel-id} and
#     /boot/legacy-kmods/{kernel-id,6.12.94/<the five pinned modules>}, and no
#     other legacy module;
#   - the ESP holds boot/vmlinuz-A and boot/vmlinuz-B, both byte-identical to
#     the rootfs's /boot/vmlinuz, and no shared boot/vmlinuz;
#   - /boot/kernel-id equals scripts/kernel-id.sh run on that kernel;
#   - /lib/modules holds exactly one tree, named for that kernel's release;
#   - the rootfs's /boot/grub.cfg and the ESP's boot/grub/grub.cfg both equal
#     image/grub.cfg;
#   - each legacy module's sha256 equals image/legacy-kmods.sha256, and the
#     legacy kernel-id equals image/legacy-kernel-id.
#
# TEST SEAM: RASPUTIN_LEGACY_PINS=<file> replaces image/legacy-kmods.sha256,
# because a fixture cannot carry the real modules
# (scripts/test-check-bundle-kernel.sh).
set -uo pipefail

usage="usage: $0 <-ab.img or -ab.img.gz> <.rootfs>"
DISK="${1:?$usage}"
ROOTFS="${2:?$usage}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PINS="${RASPUTIN_LEGACY_PINS:-$REPO_ROOT/image/legacy-kmods.sha256}"
LEGACY_ID_FILE="$REPO_ROOT/image/legacy-kernel-id"
GRUB_CFG="$REPO_ROOT/image/grub.cfg"

fails=0
bad() { echo "check-bundle-kernel: FAIL $*" >&2; fails=$((fails + 1)); }
die() { echo "check-bundle-kernel: $*" >&2; exit 1; }
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

[ -f "$DISK" ] || die "no disk image at $DISK"
[ -f "$ROOTFS" ] || die "no rootfs at $ROOTFS"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- the ESP ------------------------------------------------------------------
case "$DISK" in
	*.gz)
		rc=0
		gunzip -c "$DISK" > "$WORK/disk.img" || rc=$?
		# OpenWrt-derived images carry trailing NUL padding: gunzip exits 2.
		[ "$rc" -eq 0 ] || [ "$rc" -eq 2 ] || die "gunzip failed with rc=$rc on $DISK"
		IMG="$WORK/disk.img" ;;
	*) IMG="$DISK" ;;
esac
esp_start=$(sfdisk -d "$IMG" 2>/dev/null | sed -n 's/.*start= *\([0-9][0-9]*\),.*name="esp".*/\1/p' | head -1)
[ -n "$esp_start" ] || die "no partition named esp in $DISK"
export MTOOLS_SKIP_CHECK=1
ESP="$IMG@@$((esp_start * 512))"
echo "check-bundle-kernel: ESP boot/ of $DISK:"
mdir -i "$ESP" ::/boot || die "cannot read the ESP of $DISK"
mkdir -p "$WORK/esp"
for f in vmlinuz-A vmlinuz-B; do
	mcopy -n -i "$ESP" "::/boot/$f" "$WORK/esp/$f" 2>/dev/null || bad "the ESP has no boot/$f"
done
mcopy -n -i "$ESP" ::/boot/grub/grub.cfg "$WORK/esp/grub.cfg" 2>/dev/null || bad "the ESP has no boot/grub/grub.cfg"
if mdir -i "$ESP" ::/boot/vmlinuz >/dev/null 2>&1; then
	bad "the ESP still has a shared boot/vmlinuz; each slot must boot its own kernel"
fi

# --- the rootfs ---------------------------------------------------------------
unsquashfs -l "$ROOTFS" > "$WORK/rootfs.lst" 2>/dev/null || die "cannot list $ROOTFS as a squashfs"
legacy_mods=$(awk 'NF == 2 {print $2}' "$PINS")
for p in boot/vmlinuz boot/grub.cfg boot/kernel-id boot/legacy-kmods/kernel-id; do
	grep -qxF "squashfs-root/$p" "$WORK/rootfs.lst" || bad "the rootfs has no /$p"
done
for m in $legacy_mods; do
	grep -qxF "squashfs-root/boot/legacy-kmods/6.12.94/$m" "$WORK/rootfs.lst" \
		|| bad "the rootfs has no /boot/legacy-kmods/6.12.94/$m"
done
extra=$(sed -n 's|^squashfs-root/boot/legacy-kmods/6.12.94/||p' "$WORK/rootfs.lst" | grep -vxF -f <(printf '%s\n' "$legacy_mods") || true)
[ -z "$extra" ] || bad "the rootfs carries unpinned legacy modules: $(echo "$extra" | tr '\n' ' ')"

unsquashfs -no-progress -d "$WORK/r" "$ROOTFS" boot >/dev/null 2>&1 || true
B="$WORK/r/boot"

if [ -f "$B/vmlinuz" ]; then
	ksha=$(sha256_of "$B/vmlinuz")
	for f in vmlinuz-A vmlinuz-B; do
		[ -f "$WORK/esp/$f" ] || continue
		[ "$(sha256_of "$WORK/esp/$f")" = "$ksha" ] \
			|| bad "the ESP's boot/$f differs from the rootfs's /boot/vmlinuz (sha256 $ksha)"
	done
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
fi

if [ -f "$B/grub.cfg" ]; then
	cmp -s "$B/grub.cfg" "$GRUB_CFG" || bad "the rootfs's /boot/grub.cfg differs from image/grub.cfg"
fi
if [ -f "$WORK/esp/grub.cfg" ]; then
	cmp -s "$WORK/esp/grub.cfg" "$GRUB_CFG" || bad "the ESP's boot/grub/grub.cfg differs from image/grub.cfg"
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
	echo "check-bundle-kernel: $fails problem(s) in $ROOTFS / $DISK" >&2
	exit 1
fi
echo "check-bundle-kernel: OK — kernel '$(head -n 1 "$B/kernel-id")' in the rootfs, on the ESP as vmlinuz-A and vmlinuz-B, with its own /lib/modules and the pinned legacy modules"
