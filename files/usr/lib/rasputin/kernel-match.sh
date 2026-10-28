#!/bin/sh
#
# kernel-match.sh — once per boot, check that the running kernel is the one
# this rootfs was built with, and repair this slot's boot when it is not
# (geekdojo/geekdojo-brain#888). Run by /etc/init.d/rasputin-kernel-match.
#
# WHY
#   A kernel and its rootfs are one build: /lib/modules in the rootfs only
#   loads into the kernel it was built with. Until #888 the ESP carried ONE
#   kernel shared by both slots, and an OTA replaced only the rootfs. dev.176
#   moved the kernel from 6.12.94 to 6.12.112, so an OTA'd firewall booted the
#   new rootfs on the old kernel. On the field hardware that meant no NIC
#   driver and no ext4 /overlay, so the box was offline. (Which of those an
#   old kernel lacks depends on what it has built in: under QEMU's virtio disk
#   the 6.12.94 kernel mounts the ext4 /overlay itself.)
#
#   Each slot now has its own kernel on the ESP (vmlinuz-A, vmlinuz-B), and the
#   rootfs carries its kernel at /boot/vmlinuz with its identity at
#   /boot/kernel-id. A new agent copies the kernel before it switches slots. An
#   OLD agent (every box in the field before #888) does not, so the first boot
#   of a slot it installed runs the old shared kernel. This guard is what gets
#   that box to the fixed layout in the same OTA: it asks the agent in THIS
#   rootfs to write the slot's own kernel (`rasputin-agent repair-slot-boot`),
#   then reboots into it.
#
# VERDICTS (one line each to the kernel log, which reaches the serial console)
#   MATCH running=<id>                              user.notice; nothing else
#   FAIL <why>                                      user.err; no repair, no reboot
#   MISMATCH running=<id> built-for=<id>            user.err; then the repair
# After the repair returns, one user.notice line records what the boot looked
# like: whether vfat is now in /proc/filesystems (the agent loads it from
# /boot/legacy-kmods when the old kernel lacks it) and what /overlay is. That
# is what tells a person reading a console log why a repair failed. The update
# smoke logs it too, with no shell. The repair must work whether or not the old
# kernel mounted the persistent /overlay: it did not on the field hardware, and
# it does under QEMU.
#
# THE REPAIR, AND WHEN TO REBOOT
#   repair-slot-boot exits 0 when it wrote the slot's kernel and re-armed the
#   slot's trial (Repaired), or when it could not finish and marked this slot
#   bad (Fallback). Either way the next boot is the right one: reboot.
#
#   Any other exit (3 = the ESP could not be reached, 1, 2, or no agent at all)
#   means nothing on the ESP changed. Whether a reboot helps then depends on
#   the slot. GRUB consumes a try when it boots slot B, under the old and the
#   new grub.cfg alike, so rebooting from B falls back to A. On slot A the
#   grub.cfg a field box still has un-consumes A's try every boot, so a reboot
#   would land on A again, mismatched, forever. On A the box stays up and says
#   that nothing can roll it back: an offline box beats a reboot loop, and a
#   person can still reach the console.
#
# WHERE THE LOG GOES
#   /dev/kmsg, as rasputin-trust-clean does and for the same reason: this runs
#   at S11, before logd (S12), so `logger` lines would be lost. A line written
#   with a <priority> prefix lands in the ring buffer at that level; logd
#   imports it into logread when it starts.
#
# TEST SEAMS (scripts/test-kernel-match.sh), each defaulting to the real thing:
#   RASPUTIN_KM_ID_FILE  the build's kernel id       (/boot/kernel-id)
#   RASPUTIN_KM_CMDLINE  the kernel command line     (/proc/cmdline)
#   RASPUTIN_KM_KMSG     the kernel log              (/dev/kmsg)
#   RASPUTIN_KM_UNAME    uname                       (uname)
#   RASPUTIN_KM_AGENT    the agent binary            (/usr/bin/rasputin-agent)
#   RASPUTIN_KM_SYNC     sync                        (sync)
#   RASPUTIN_KM_REBOOT   reboot, called with -f      (reboot)
#   RASPUTIN_KM_FILESYSTEMS  /proc/filesystems, RASPUTIN_KM_MOUNTS  /proc/mounts
#                        (read only for the repair-context line)
#
# /boot here is the rootfs's own directory: OpenWrt's 79_move_config would
# mount the ESP over it, but only when the root= argument names the disk by
# PARTUUID or device, and this image roots by PARTLABEL (F-888-05).
set -u

ID_FILE=${RASPUTIN_KM_ID_FILE:-/boot/kernel-id}
CMDLINE=${RASPUTIN_KM_CMDLINE:-/proc/cmdline}
KMSG=${RASPUTIN_KM_KMSG:-/dev/kmsg}
UNAME=${RASPUTIN_KM_UNAME:-uname}
AGENT=${RASPUTIN_KM_AGENT:-/usr/bin/rasputin-agent}
SYNC=${RASPUTIN_KM_SYNC:-sync}
REBOOT=${RASPUTIN_KM_REBOOT:-reboot}
FILESYSTEMS=${RASPUTIN_KM_FILESYSTEMS:-/proc/filesystems}
MOUNTS=${RASPUTIN_KM_MOUNTS:-/proc/mounts}

TAG=rasputin-kernel-match

# log <priority> <message>: 13 = user.notice, 11 = user.err (facility user = 1).
# Stdout too, so a manual run shows it. A kmsg that cannot be written must not
# change what the guard decides.
log() {
	_prio=$1; shift
	echo "$TAG: $*"
	printf '<%s>%s: %s\n' "$_prio" "$TAG" "$*" >> "$KMSG" 2>/dev/null \
		|| echo "$TAG: could not write to $KMSG" >&2
}

# The slot this boot came from, from the kernel command line GRUB wrote.
running_slot() {
	case " $(cat "$CMDLINE" 2>/dev/null) " in
		*" rasputin.slot=A "*|*"PARTLABEL=rootfs-0 "*) echo A ;;
		*" rasputin.slot=B "*|*"PARTLABEL=rootfs-1 "*) echo B ;;
		*) echo unknown ;;
	esac
}

reboot_now() {
	log 11 "$1"
	"$SYNC"
	"$REBOOT" -f
}

running="$("$UNAME" -r) $("$UNAME" -v)"

if [ ! -r "$ID_FILE" ]; then
	log 11 "FAIL no readable kernel id at $ID_FILE, so nothing says which kernel this rootfs was built for (running=$running)"
	exit 1
fi
built_for="$(head -n 1 "$ID_FILE" 2>/dev/null)"
if [ -z "$built_for" ]; then
	log 11 "FAIL the kernel id at $ID_FILE is empty (running=$running)"
	exit 1
fi

if [ "$running" = "$built_for" ]; then
	log 13 "MATCH running=$running"
	exit 0
fi

log 11 "MISMATCH running=$running built-for=$built_for"

slot=$(running_slot)
if [ -x "$AGENT" ]; then
	# The agent logs to stderr; relay it, so its outcome record reaches the
	# console with the verdict. Command substitution keeps the exit status.
	out=$("$AGENT" repair-slot-boot 2>&1)
	rc=$?
	printf '%s\n' "$out" | while IFS= read -r line; do
		[ -n "$line" ] && log 13 "agent: $line"
	done
else
	log 11 "no agent at $AGENT to repair slot $slot"
	rc=127
fi

vfat=absent
grep -qw vfat "$FILESYSTEMS" 2>/dev/null && vfat=present
overlay=$(awk '$2 == "/overlay" {m = $3 " from " $1} END {print m}' "$MOUNTS" 2>/dev/null)
log 13 "repair context: vfat=$vfat in /proc/filesystems, /overlay=${overlay:-unmounted}"

if [ "$rc" -eq 0 ]; then
	# Exit 0 is Repaired or Fallback, and the guard cannot tell which (the
	# agent's outcome= line above says): the message must hold for both.
	reboot_now "repair-slot-boot finished on slot $slot (outcome in the agent line above); rebooting: GRUB boots slot $slot on its own kernel if it was repaired, the other slot if it was marked bad"
	exit 0
fi

if [ "$slot" = B ]; then
	reboot_now "repair-slot-boot exited $rc on slot B, so the ESP is unchanged; rebooting, and GRUB falls back to slot A"
	exit 1
fi

log 11 "repair-slot-boot exited $rc on slot $slot, so the ESP is unchanged. Not rebooting: nothing can roll slot $slot back, and a reboot would boot it mismatched again. This box needs a person at the console."
exit 1
