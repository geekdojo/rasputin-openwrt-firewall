#!/bin/sh
# rasputin-growpart (firewall) — one-time grow of the /overlay (rootfs_data)
# partition to fill the disk, and fix the backup GPT header, so the shared
# overlay isn't stuck at its 512 MiB image size on a big NVMe.
#
# Why this matters on the firewall specifically: OTA .rootfs bundles download
# INTO /overlay (= rootfs_data), so a fixed 512 MiB overlay ENOSPCs on the first
# update — the exact un-grown-partition failure that bit the compute nodes.
#
# Ported from rasputin-os' rasputin-growpart.sh (same sfdisk table-rewrite: drop
# last-lba so sfdisk recomputes the real disk end — which ALSO relocates the
# backup GPT header to the disk end, clearing the kernel's "Alt header not at end
# of disk" warning — and drop the partition's explicit size so it fills to the
# end; only the END moves, so the filesystem + data are untouched). Differences
# from compute: OpenWrt has no systemd/x-systemd.growfs, so we grow the ext4
# ourselves with resize2fs; and we do it ONLINE via `partx -u` (BLKPG resize of a
# mounted partition) instead of rebooting — so it can never abort an A/B trial.
#
# IDEMPOTENT: a no-op once the partition fills the disk and the fs fills the
# partition. Safe to run every boot.
set -eu

log() { logger -t rasputin-growpart "$*"; echo "rasputin-growpart: $*"; }

# rootfs_data is mounted at /overlay by extroot (files/etc/config/fstab). If
# extroot didn't take (fell back to the slack loop), /overlay is a /dev/loop* —
# don't touch that; nothing to grow.
PARTDEV="$(awk '$2=="/overlay"{print $1; exit}' /proc/mounts)"
case "${PARTDEV:-}" in
	/dev/loop*|"") log "/overlay not on a real partition (${PARTDEV:-none}) — extroot inactive; nothing to grow"; exit 0 ;;
	/dev/*) : ;;
	*) log "/overlay source '$PARTDEV' unexpected; nothing to do"; exit 0 ;;
esac
[ -b "$PARTDEV" ] || { log "$PARTDEV is not a block device; nothing to do"; exit 0; }

PARTBASE="${PARTDEV##*/}"                                       # nvme0n1p4 / sda4
DISKBASE="$(basename "$(dirname "$(readlink -f "/sys/class/block/$PARTBASE")")")"  # nvme0n1 / sda
DISK="/dev/$DISKBASE"
[ -b "$DISK" ] || { log "cannot resolve parent disk of $PARTDEV; nothing to do"; exit 0; }
PARTNUM="$(cat "/sys/class/block/$PARTBASE/partition")"

DISK_SZ="$(cat "/sys/class/block/$DISKBASE/size")"             # 512-byte sectors
P_START="$(cat "/sys/class/block/$PARTBASE/start")"
P_SZ="$(cat "/sys/class/block/$PARTBASE/size")"
TAIL=$(( DISK_SZ - (P_START + P_SZ) ))                         # unallocated sectors after the partition

# Partition already fills the disk (tail < 32 MiB)? Just make sure the fs fills
# the partition (online resize2fs is a fast no-op when already full), then done.
if [ "$TAIL" -lt 65536 ]; then
	log "$PARTDEV already fills $DISK ($((P_SZ/2048)) MiB); ensuring fs is grown"
	resize2fs "$PARTDEV" >/dev/null 2>&1 || true
	exit 0
fi

log "extending $PARTDEV (part $PARTNUM) into $((TAIL/2048)) MiB on $DISK + fixing backup GPT"
# Drop last-lba (sfdisk recomputes to the real disk end → backup GPT moves to the
# end) + drop this partition's explicit size (it then fills to the end). Every
# other partition line is copied verbatim and the start is unchanged, so the
# filesystem is preserved. --no-reread: the partition is mounted.
sfdisk --dump "$DISK" \
	| grep -v '^last-lba:' \
	| sed "\\#^${PARTDEV} #s/size=[[:space:]]*[0-9][0-9]*,[[:space:]]*//" \
	| sfdisk --no-reread "$DISK"
sync

# Make the kernel see the partition's new size WITHOUT a reboot: partx -u uses
# BLKPG, which resizes a mounted partition in place. Then grow the ext4 online.
partx -u "$DISK" 2>/dev/null || partx -u --nr "${PARTNUM}:${PARTNUM}" "$DISK" 2>/dev/null || true
resize2fs "$PARTDEV"
log "grown: $PARTDEV now $(( $(cat "/sys/class/block/$PARTBASE/size") / 2048 )) MiB"
