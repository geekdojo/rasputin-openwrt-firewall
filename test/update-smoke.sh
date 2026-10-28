#!/usr/bin/env bash
#
# update-smoke.sh — update a PUBLISHED firewall image to this build in QEMU,
# across a kernel change, and prove every slot then boots the kernel its rootfs
# was built with (geekdojo/geekdojo-brain#888).
#
#   usage: test/update-smoke.sh <leg> <new-ab.img> <new.rootfs> <version> [<old-ab.img>]
#
#   leg          which path to run (below)
#   new-ab.img   this build's A/B disk, decompressed
#   new.rootfs   this build's SIGNED .rootfs, with its .sig and .version beside it
#   version      this build's version
#   old-ab.img   the published image the "box" starts from, decompressed
#                (every leg but fresh-rollback)
#
# WHY. dev.176 moved the kernel from 6.12.94 to 6.12.112, and an OTA'd firewall
# booted the new rootfs on the old shared kernel: on the field hardware, no NIC
# driver, no ext4 /overlay, offline. The boot smoke boots a fresh image on its own kernel, so
# nothing tested the update path. This does, on the real published image, the
# real GRUB and grub.cfg, and this build's real signed artifact and agent.
#
# THE LEGS (each a TC-888 case; the release workflow runs each as a job)
#   fresh-rollback   TC-888-17  this build's fresh image: a tried A rolls back
#                               to B, a tried B rolls back to A and keeps
#                               B_TRY=1, both tried boots A and clears both
#                               (the `selected` flag, F-888-01)
#   field-new-b      TC-888-18  2026.10.3 on A; the NEW agent installs into B;
#                    TC-888-19  B boots its own kernel, MATCH, no repair, ext4
#                               /overlay, a lease; then B_OK=0 and A boots the
#                               legacy shared kernel through the fallback branch
#   field-new-a      TC-888-21  2026.10.3 on B; the new agent installs into A;
#                               A boots its own kernel; an unmarked reboot falls
#                               back to B on the legacy kernel
#   old-b            TC-888-22  the OLD agent's install into B, reproduced
#                               host-side (dd + grubenv, no vmlinuz-B, field
#                               grub.cfg): the guard repairs B from inside the
#                               mismatched boot; exactly two boots
#   old-a            TC-888-23  the same into A, under the field grub.cfg that
#                               un-consumes A's try: two boots, no loop
#   chain            TC-888-24  old-agent hop into B (self-repair), new-agent
#                               hops B->A and A->B, then a forced fallback
#   repair-twice     TC-888-33  as old-b with B_REPAIR=1 preset: the guard
#                               marks B bad, and A boots the legacy kernel
#   generic          any other published FROM: the new agent installs into the
#                               inactive slot, which boots its own kernel; the
#                               other slot still boots after B/A_OK=0
#
# MODELLED, NOT RUN
#   - The OLD agent's install (old-b, old-a, repair-twice, chain hop 1): its
#     on-disk effect, from its source: dd of the .rootfs into the target, then
#     ORDER="<T> <other>" <T>_OK=1 <T>_TRY=0. Nothing else.
#   - mark-good: the image is unseeded, so the agent never starts and never
#     marks a slot good. Where a leg needs the slot it runs on to count as
#     good (as the agent would have made it at boot), the harness powers off
#     and sets <slot>_OK=1 <slot>_TRY=0 (and drops <slot>_REPAIR) host-side.
#
# WHAT IT CANNOT PROVE: igc on the i226-V (e1000e here exercises the same
# module-load path), CWWK firmware, power loss during the ESP writes, the NATS
# update saga, or the old agent's own code. Those are the bench walk's
# (TC-888-25, in the geekdojo-brain rasputin-firewall-test skill).
#
# HOW IT WAITS. Every wait is for a fact on the serial console (a kernel
# command line, the console prompt, a command's end marker) and has a deadline
# that names what never appeared; a dead QEMU ends the wait at once. One boot
# is bounded by BOOT_DEADLINE seconds (default 300: TCG on a runner without
# KVM boots in about 120).
#
# Needs: qemu-system-x86_64, OVMF, mtools, sfdisk, jq, grub-editenv,
# unsquashfs, mkfs.ext4. Logs: $WORK/<leg>/console.log (WORK=/tmp/update-smoke).
#
# Guest commands are passed in single quotes on purpose: they expand in the VM.
# shellcheck disable=SC2016
set -euo pipefail

LEG="${1:?usage: $0 <leg> <new-ab.img> <new.rootfs> <version> [<old-ab.img>]}"
NEW_IMG="${2:?new-ab.img}"
NEW_ROOTFS="${3:?new.rootfs}"
VERSION="${4:?version}"
OLD_IMG="${5:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/tmp/update-smoke}/$LEG"
BOOT_DEADLINE="${BOOT_DEADLINE:-300}"
CMD_DEADLINE="${CMD_DEADLINE:-180}"
BUNDLE_ID=fw-update-smoke

LOG="$WORK/console.log"
export MTOOLS_SKIP_CHECK=1
# Console searches go through a snapshot file, never `... | grep -q` (F-888-24).
CON_SNAP="$WORK/console.snap"
# shellcheck source=test/console.sh
. "$REPO_ROOT/test/console.sh"

say() { printf 'update-smoke[%s]: %s\n' "$LEG" "$*"; }
die() {
	printf 'update-smoke[%s]: FAIL %s\n' "$LEG" "$*" >&2
	if [ -f "$LOG" ]; then
		echo "----- last 60 console lines -----" >&2
		tail -n 60 "$LOG" | tr -d '\r' >&2
	fi
	exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"
: > "$LOG"

# --- what this build is ---------------------------------------------------------
for f in "$NEW_IMG" "$NEW_ROOTFS" "$NEW_ROOTFS.sig" "$NEW_ROOTFS.version"; do
	[ -s "$f" ] || die "missing input $f"
done
# To a file, then head: head on a pipe would stop reading and, under pipefail,
# fail on unsquashfs's broken pipe (F-888-24).
unsquashfs -cat "$NEW_ROOTFS" boot/kernel-id > "$WORK/new-kernel-id" 2>/dev/null \
	|| die "this build's .rootfs has no /boot/kernel-id"
NEW_ID="$(head -n 1 "$WORK/new-kernel-id")"
unsquashfs -cat "$NEW_ROOTFS" boot/vmlinuz > "$WORK/new-vmlinuz" 2>/dev/null \
	|| die "this build's .rootfs has no /boot/vmlinuz"
NEW_KSHA="$(sha256sum "$WORK/new-vmlinuz" | awk '{print $1}')"
LEGACY_ID="$(head -n 1 "$REPO_ROOT/image/legacy-kernel-id")"
say "this build: $VERSION, kernel '$NEW_ID' (sha256 $NEW_KSHA)"

# --- the disk, host-side --------------------------------------------------------
DISK="$WORK/disk.img"

# part <name> → "<byte offset> <byte size>" of a GPT partition, by name.
part() {
	sfdisk -J "$DISK" | jq -r --arg n "$1" \
		'.partitiontable | .sectorsize as $s | .partitions[] | select(.name == $n) | "\(.start * ($s // 512)) \(.size * ($s // 512))"'
}
esp() { read -r off _ < <(part esp); [ -n "$off" ] || die "no esp partition"; echo "$DISK@@$off"; }

genv_pull() { mcopy -n -i "$(esp)" ::/boot/grub/grubenv "$WORK/grubenv"; }
genv_push() { mcopy -o -i "$(esp)" "$WORK/grubenv" ::/boot/grub/grubenv; }
# genv_set KEY=VALUE... ; genv_unset KEY... ; genv_get KEY
genv_set() { genv_pull; grub-editenv "$WORK/grubenv" set "$@"; genv_push; say "grubenv set $*"; }
genv_unset() { genv_pull; grub-editenv "$WORK/grubenv" unset "$@"; genv_push; say "grubenv unset $*"; }
genv_get() { genv_pull; grub-editenv "$WORK/grubenv" list | sed -n "s/^$1=//p"; }
genv_show() { genv_pull; say "grubenv: $(grub-editenv "$WORK/grubenv" list | tr '\n' ' ')"; }
expect_genv() { # expect_genv KEY VALUE ("" = absent)
	got="$(genv_get "$1")"
	[ "$got" = "$2" ] || die "grubenv $1='$got', want '$2'"
}

# The old agent's install, from its source: dd the .rootfs into the slot, then
# ORDER="<T> <other>" <T>_OK=1 <T>_TRY=0.
old_agent_install() {
	slot=$1; other=A; label=rootfs-1
	[ "$slot" = A ] && { other=B; label=rootfs-0; }
	read -r poff psize < <(part "$label")
	[ -n "$poff" ] || die "no $label partition"
	[ "$(stat -c%s "$NEW_ROOTFS")" -le "$psize" ] || die "the .rootfs does not fit $label"
	dd if="$NEW_ROOTFS" of="$DISK" bs=1M seek="$poff" oflag=seek_bytes conv=notrunc status=none
	genv_set "ORDER=$slot $other" "${slot}_OK=1" "${slot}_TRY=0"
	say "old-agent install into $slot reproduced host-side"
}

# The agent's mark-good, which an unseeded box never runs.
mark_good() {
	genv_set "${1}_OK=1" "${1}_TRY=0"
	genv_unset "${1}_REPAIR"
}

esp_has() { mdir -i "$(esp)" "::/boot/$1" >/dev/null 2>&1; }
expect_esp_kernel() { # expect_esp_kernel vmlinuz-X
	esp_has "$1" || die "the ESP has no boot/$1"
	mcopy -n -i "$(esp)" "::/boot/$1" "$WORK/esp-k"
	[ "$(sha256sum "$WORK/esp-k" | awk '{print $1}')" = "$NEW_KSHA" ] || die "the ESP's boot/$1 is not this build's kernel"
}
expect_esp_grubcfg() {
	mcopy -n -i "$(esp)" ::/boot/grub/grub.cfg "$WORK/esp-cfg"
	cmp -s "$WORK/esp-cfg" "$REPO_ROOT/image/grub.cfg" || die "the ESP's grub.cfg is not this build's"
}
esp_listing() { say "ESP boot/: $(mdir -b -i "$(esp)" ::/boot | sed 's|.*/boot/||' | tr '\n' ' ')"; }

# The transfer disk: an ext4 holding the new agent and the bundle store the
# agent's install-rootfs reads (<state>/bundles/<id>.rootfs, .sig, .version).
make_transfer() {
	st="$WORK/xfer/state/bundles"
	mkdir -p "$st"
	cp "$NEW_ROOTFS" "$st/$BUNDLE_ID.rootfs"
	cp "$NEW_ROOTFS.sig" "$st/$BUNDLE_ID.rootfs.sig"
	cp "$NEW_ROOTFS.version" "$st/$BUNDLE_ID.rootfs.version"
	unsquashfs -cat "$NEW_ROOTFS" usr/bin/rasputin-agent > "$WORK/xfer/rasputin-agent" \
		|| die "this build's .rootfs has no /usr/bin/rasputin-agent"
	chmod 755 "$WORK/xfer/rasputin-agent"
	sz=$(( $(du -sm "$WORK/xfer" | cut -f1) + 64 ))
	truncate -s "${sz}M" "$WORK/xfer.img"
	mkfs.ext4 -q -F -L smokexfer -d "$WORK/xfer" "$WORK/xfer.img"
	rm -rf "$WORK/xfer"
}

# --- the VM -----------------------------------------------------------------------
# The non-secure-boot OVMF (Ubuntu names it with a _4M suffix).
OVMF_CODE=""; OVMF_VARS=""
for f in /usr/share/OVMF/OVMF_CODE*.fd; do case "$f" in *secboot*) ;; *) [ -f "$f" ] && [ -z "$OVMF_CODE" ] && OVMF_CODE=$f ;; esac; done
for f in /usr/share/OVMF/OVMF_VARS*.fd; do case "$f" in *secboot*|*ms*) ;; *) [ -f "$f" ] && [ -z "$OVMF_VARS" ] && OVMF_VARS=$f ;; esac; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || die "no OVMF firmware under /usr/share/OVMF"
cp "$OVMF_VARS" "$WORK/vars.fd"
if [ -w /dev/kvm ]; then ACCEL=(-accel kvm -cpu host); else ACCEL=(-cpu max); fi

QPID=""
CATPID=""
stop_vm() {
	[ -n "$QPID" ] && kill "$QPID" 2>/dev/null || true
	[ -n "$QPID" ] && wait "$QPID" 2>/dev/null || true
	[ -n "$CATPID" ] && kill "$CATPID" 2>/dev/null || true
	# Braces: a bare `exec 7>&- 2>/dev/null` would ALSO send this shell's own
	# stderr to /dev/null for good, and every later failure would be silent.
	{ exec 7>&-; } 2>/dev/null || true
	QPID=""; CATPID=""
}
trap stop_vm EXIT

# start_vm [transfer] — boot the disk; the console goes to $LOG.
start_vm() {
	extra=()
	[ "${1:-}" = transfer ] && extra=(-drive "file=$WORK/xfer.img,format=raw,if=virtio")
	rm -f "$WORK/con.in" "$WORK/con.out"
	mkfifo "$WORK/con.in" "$WORK/con.out"
	qemu-system-x86_64 -machine q35 -m 1024 -smp 2 "${ACCEL[@]}" \
		-display none -monitor none \
		-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$WORK/vars.fd" \
		-drive "file=$DISK,format=raw,if=virtio" "${extra[@]}" \
		-netdev user,id=lan,restrict=on -device e1000e,netdev=lan \
		-netdev user,id=wan -device e1000e,netdev=wan \
		-chardev "pipe,id=con,path=$WORK/con" -serial chardev:con \
		> "$WORK/qemu.log" 2>&1 &
	QPID=$!
	cat "$WORK/con.out" >> "$LOG" &
	CATPID=$!
	# Read-write, so the open cannot block on a QEMU that died before opening it.
	exec 7<> "$WORK/con.in"
}
alive() { [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; }
send() { printf '%s\r' "$1" >&7; }

# wait_for <ERE> <deadline-s> <what> [from-line] — a console fact, bounded.
wait_for() {
	re=$1 deadline=$2 what=$3 from=${4:-1}
	end=$(( $(date +%s) + deadline ))
	while :; do
		con_has "$LOG" "$from" "$re" && return 0
		alive || die "QEMU exited before $what"
		[ "$(date +%s)" -lt "$end" ] || die "$what did not appear within ${deadline}s"
		sleep 1
	done
}
lines() { wc -l < "$LOG" | tr -d ' '; }
boots() { tr -d '\r' < "$LOG" | grep -c 'Kernel command line:' || true; }

# boot_n <n> <slot> — wait for the n-th kernel boot of this leg and check its slot.
BOOT_FROM=1
boot_n() {
	n=$1 slot=$2
	end=$(( $(date +%s) + BOOT_DEADLINE ))
	while [ "$(boots)" -lt "$n" ]; do
		alive || die "QEMU exited before boot $n"
		[ "$(date +%s)" -lt "$end" ] || die "boot $n did not start within ${BOOT_DEADLINE}s"
		sleep 1
	done
	BOOT_FROM=$(tr -d '\r' < "$LOG" | grep -n 'Kernel command line:' | sed -n "${n}p" | cut -d: -f1)
	got=$(con_first "$LOG" "$BOOT_FROM" 'Kernel command line:' | sed -n 's/.*rasputin\.slot=\([AB]\).*/\1/p')
	[ "$got" = "$slot" ] || die "boot $n came up on slot '$got', want $slot"
	say "boot $n: slot $slot"
}

# shell — the console root shell of the current boot (the image is unseeded,
# so ttylogin is unset and Enter gives root).
shell() {
	wait_for 'Please press Enter to activate this console' "$BOOT_DEADLINE" "the console prompt" "$BOOT_FROM"
	from=$(lines)
	send ""
	wait_for 'root@[^ ]+:' 60 "a root shell" "$from"
	run quiet 'dmesg -n 1' >/dev/null
}

# run <tag> <command> — run in the guest; prints its output; returns its status.
# Usually called inside $(...), so the marker is made unique by the console's
# current length, not by a counter that would only advance in the subshell.
run() {
	from=$(lines)
	t="$1-$from"
	send "echo @@B:$t@@; $2; echo @@E:$t:\$?@@"
	wait_for "^@@E:$t:[0-9]+@@" "$CMD_DEADLINE" "the end of '$2'" "$from"
	# Output only, with terminal colour codes stripped (the image's ip colours).
	out=$(tail -n +"$from" "$LOG" | tr -d '\r' | sed -n "/^@@B:$t@@\$/,/^@@E:$t:/p" | sed 's/\x1b\[[0-9;]*m//g')
	printf '%s\n' "$out" | sed '1d;$d'
	rc=$(printf '%s\n' "$out" | sed -n "s/^@@E:$t:\([0-9]*\)@@\$/\1/p")
	return "${rc:-1}"
}

# poweroff — sync and power off from the shell, and wait for QEMU to exit.
poweroff_vm() {
	send 'sync; poweroff -f'
	end=$(( $(date +%s) + 120 ))
	while alive; do
		[ "$(date +%s)" -lt "$end" ] || die "the VM did not power off within 120s"
		sleep 1
	done
	stop_vm
}

# --- assertions inside a boot ---------------------------------------------------
expect_kernel() { # expect_kernel <id>
	got=$(run uname 'echo "$(uname -r) $(uname -v)"') || die "uname failed"
	[ "$got" = "$1" ] || die "running kernel '$got', want '$1'"
	say "running kernel '$got'"
}
expect_match() {
	# procd opens the console before rc reaches S11, so the verdict can still
	# be on its way: wait (bounded, in the guest) for the guard's line.
	run km 'n=0; until dmesg | grep -q rasputin-kernel-match: || [ $n -ge 150 ]; do n=$((n+1)); sleep 1; done; dmesg | grep rasputin-kernel-match' > "$WORK/km.txt" || true
	grep -qF "MATCH running=$NEW_ID" "$WORK/km.txt" || die "no kernel-match MATCH in this boot: $(cat "$WORK/km.txt")"
	if grep -qE 'MISMATCH|repair' "$WORK/km.txt"; then die "this boot ran a repair: $(cat "$WORK/km.txt")"; fi
	say "kernel-match: MATCH, no repair"
}
expect_overlay_ext4() {
	got=$(run ovl 'awk '"'"'$2=="/overlay"{print $3}'"'"' /proc/mounts | tail -1') || true
	[ "$got" = ext4 ] || die "/overlay is '$got', want the ext4 rootfs_data"
	run ovlbl 'block info | grep -F "LABEL=\"rootfs_data\"" | grep -q "MOUNT=\"/overlay\""' >/dev/null \
		|| die "/overlay is not the rootfs_data partition"
	say "/overlay is the ext4 rootfs_data"
}
expect_lease() {
	# The fact is an IPv4 address on eth1 (WAN, DHCP from QEMU's user net),
	# polled in the guest and bounded.
	got=$(run lease 'n=0; until ip -4 -o addr show dev eth1 | grep -q inet || [ $n -ge 120 ]; do n=$((n+1)); sleep 1; done; ip -4 -o addr show dev eth1') || true
	case "$got" in *"inet 10.0.2."*) ;; *) die "eth1 holds no DHCP lease: '$got'" ;; esac
	drv=$(run drv 'basename "$(readlink /sys/class/net/eth1/device/driver)"') || true
	[ "$drv" = e1000e ] || die "eth1 is bound to '$drv', want e1000e"
	say "eth1 (e1000e) leased $(printf '%s' "$got" | sed -n 's/.*inet \([0-9.]*\).*/\1/p')"
}
expect_version() {
	got=$(run ver 'cat /etc/rasputin/image-version') || true
	[ "$got" = "$1" ] || die "image-version '$got', want '$1'"
}
# The new agent's install-rootfs, from the transfer disk's bundle store, then
# a power-off. The target is checked host-side: the agent's activate leaves
# ORDER="<target> <other>" and <target>_OK=1.
new_agent_install() { # new_agent_install <agent-path> <target>
	run mnt 'mkdir -p /tmp/x && mount -t ext4 /dev/vdb /tmp/x' >/dev/null || die "could not mount the transfer disk"
	out=$(run inst "$1 install-rootfs --state-dir /tmp/x/state $BUNDLE_ID 2>&1") \
		|| die "install-rootfs failed: $out"
	say "install-rootfs: $(printf '%s' "$out" | tr '\n' ' ')"
	run umnt 'umount /tmp/x' >/dev/null || true
	poweroff_vm
	other=A; [ "$2" = A ] && other=B
	expect_genv ORDER "$2 $other"
	expect_genv "${2}_OK" 1
}
# A boot that must be this build, on its own kernel, healthy.
expect_healthy_new() {
	expect_kernel "$NEW_ID"
	expect_match
	expect_version "$VERSION"
	expect_overlay_ext4
	expect_lease
}
# Boot 1 of an old-agent leg: the guard's MISMATCH, its repair context, and the
# agent's outcome, all on the console with no shell. What /overlay is in this
# boot is logged, not asserted (F-888-25): on the field hardware the old kernel
# could not mount the ext4 /overlay, but under QEMU's virtio disk 6.12.94 does,
# and the repair must work either way. Boot 2 and the host-side ESP and grubenv
# checks are what prove the repair.
expect_repair_boot() { # expect_repair_boot <outcome>
	wait_for "rasputin-kernel-match: MISMATCH running=$LEGACY_ID built-for=$NEW_ID" "$BOOT_DEADLINE" "the MISMATCH verdict" "$BOOT_FROM"
	wait_for "outcome=$1" "$BOOT_DEADLINE" "the repair's outcome=$1 record" "$BOOT_FROM"
	wait_for 'repair context: vfat=present' "$BOOT_DEADLINE" "the repair context" "$BOOT_FROM"
	ctx=$(con_first "$LOG" "$BOOT_FROM" 'repair context:')
	say "boot 1: MISMATCH, outcome=$1; ${ctx#*repair context: }"
}
expect_boots() { # expect_boots <n>
	[ "$(boots)" = "$1" ] || die "$(boots) kernel boots, want exactly $1"
}

# --- the legs ---------------------------------------------------------------------
need_old() { [ -s "$OLD_IMG" ] || die "leg $LEG needs <old-ab.img>"; cp --sparse=always "$OLD_IMG" "$DISK"; }

leg_fresh_rollback() {
	cp --sparse=always "$NEW_IMG" "$DISK"
	genv_set "ORDER=A B" A_OK=1 A_TRY=1 B_OK=1 B_TRY=0
	start_vm; boot_n 1 B; shell; poweroff_vm
	say "a tried A rolled back to B"
	genv_set "ORDER=B A" B_OK=1 B_TRY=1 A_OK=1 A_TRY=0
	: > "$LOG"; start_vm; boot_n 1 A; shell; poweroff_vm
	expect_genv B_TRY 1
	say "a tried B rolled back to A, B_TRY=1 kept"
	genv_set "ORDER=A B" A_OK=1 A_TRY=1 B_OK=1 B_TRY=1
	: > "$LOG"; start_vm; boot_n 1 A; shell; poweroff_vm
	expect_genv A_TRY 0
	expect_genv B_TRY 0
	say "both tried: booted A, both tries cleared"
}

leg_field_new_b() {
	need_old; make_transfer
	start_vm transfer; boot_n 1 A; shell
	new_agent_install /tmp/x/rasputin-agent B
	mark_good A
	start_vm transfer; boot_n 2 B; shell
	expect_healthy_new
	poweroff_vm
	expect_esp_kernel vmlinuz-B; expect_esp_grubcfg; esp_listing
	# TC-888-19: the fallback slot boots its own (legacy, shared) kernel.
	genv_set B_OK=0
	start_vm; boot_n 3 A; shell
	expect_kernel "$LEGACY_ID"
	expect_lease
	poweroff_vm
}

leg_field_new_a() {
	need_old; make_transfer
	genv_set "ORDER=B A" B_OK=1 B_TRY=0 A_OK=1
	start_vm transfer; boot_n 1 B; shell
	expect_kernel "$LEGACY_ID"
	new_agent_install /tmp/x/rasputin-agent A
	mark_good B
	start_vm; boot_n 2 A; shell
	expect_healthy_new
	# An unmarked reboot: A's try stays consumed, so GRUB falls back to B.
	send 'reboot'
	boot_n 3 B; shell
	expect_kernel "$LEGACY_ID"
	expect_lease
	poweroff_vm
	expect_genv A_TRY 1
	expect_esp_kernel vmlinuz-A; esp_listing
}

# old-agent install into <slot>, then the guard's two boots.
old_agent_hop() { # old_agent_hop <slot> <boot-base>
	old_agent_install "$1"
	start_vm
	boot_n $(( $2 + 1 )) "$1"
	expect_repair_boot repaired
	boot_n $(( $2 + 2 )) "$1"
	shell
	expect_healthy_new
	expect_boots $(( $2 + 2 ))
	poweroff_vm
	# Still two boots after the power-off: the guard never asked for a third.
	expect_boots $(( $2 + 2 ))
	expect_esp_kernel "vmlinuz-$1"; expect_esp_grubcfg
	expect_genv "${1}_OK" 1
	expect_genv "${1}_REPAIR" 1
}

leg_old_b() {
	need_old
	old_agent_hop B 0
	expect_genv ORDER "B A"
	esp_listing
}

leg_old_a() {
	need_old
	# The box ran 2026.10.3 on B (marked good) when the old agent installed into A.
	genv_set "ORDER=B A" B_OK=1 B_TRY=0 A_OK=1
	old_agent_hop A 0
	esp_listing
}

leg_repair_twice() {
	need_old
	old_agent_install B
	genv_set B_REPAIR=1
	start_vm
	boot_n 1 B
	expect_repair_boot fallback
	boot_n 2 A
	shell
	expect_kernel "$LEGACY_ID"
	expect_lease
	expect_boots 2
	poweroff_vm
	expect_boots 2
	expect_genv B_OK 0
	expect_genv B_REPAIR ""
}

leg_chain() {
	need_old; make_transfer
	say "hop 1: the old agent into B"
	old_agent_hop B 0
	mark_good B
	say "hop 2: the new agent, B into A"
	start_vm transfer; boot_n 3 B; shell
	expect_match
	new_agent_install /usr/bin/rasputin-agent A
	mark_good B
	start_vm; boot_n 4 A; shell
	expect_healthy_new
	poweroff_vm; mark_good A
	say "hop 3: the new agent, A into B"
	start_vm transfer; boot_n 5 A; shell
	new_agent_install /usr/bin/rasputin-agent B
	mark_good A
	start_vm; boot_n 6 B; shell
	expect_healthy_new
	poweroff_vm; mark_good B
	say "fallback: B_OK=0"
	genv_set B_OK=0
	start_vm; boot_n 7 A; shell
	expect_healthy_new
	poweroff_vm
	expect_esp_kernel vmlinuz-A; expect_esp_kernel vmlinuz-B; expect_esp_grubcfg
	esp_has vmlinuz || die "the field ESP's shared vmlinuz is gone"
	esp_listing
}

leg_generic() {
	need_old; make_transfer
	start_vm transfer; boot_n 1 A; shell
	new_agent_install /tmp/x/rasputin-agent B
	mark_good A
	start_vm; boot_n 2 B; shell
	expect_healthy_new
	poweroff_vm
	expect_esp_kernel vmlinuz-B; esp_listing
	genv_set B_OK=0
	start_vm; boot_n 3 A; shell
	expect_lease
	poweroff_vm
}

case "$LEG" in
	fresh-rollback) leg_fresh_rollback ;;
	field-new-b)    leg_field_new_b ;;
	field-new-a)    leg_field_new_a ;;
	old-b)          leg_old_b ;;
	old-a)          leg_old_a ;;
	chain)          leg_chain ;;
	repair-twice)   leg_repair_twice ;;
	generic)        leg_generic ;;
	*) die "unknown leg '$LEG'" ;;
esac
genv_show
say "PASS"
