#!/usr/bin/env bash
#
# update-smoke.sh — update and downgrade firewall images in QEMU, across
# kernel layouts, and prove each boot runs the kernel its rootfs was built for
# (geekdojo/geekdojo-brain#893).
#
#   usage: test/update-smoke.sh <leg> <new-ab.img> <new.rootfs> [<from-ab.img>]
#
#   leg          which path to run (below)
#   new-ab.img   this build's A/B disk, decompressed
#   new.rootfs   this build's .rootfs, the OTA artifact
#   from-ab.img  the published image the "box" starts from, decompressed:
#                2026.10.3 for the field legs, the newest release for generic
#
# THE LEGS (each a TC-893 case; the release workflow runs each as a job)
#   fresh         TC-893-18  this build's image: slot A boots its own kernel
#                            (BOOT_IMAGE=(hdN,gpt3)/boot/vmlinuz) with MATCH;
#                            with A_TRY=1 left by GRUB, slot B boots its own
#   field-up-b    TC-893-19  2026.10.3 image, an old agent's install of this
#                            build into B: boot 1 is the shared 6.12.94 kernel,
#                            MISMATCH, outcome=repaired, reboot; boot 2 is B's
#                            own kernel with MATCH. Exactly two boots. The ESP
#                            then holds this build's EFI and grub.cfg and the
#                            unchanged shared kernel, and B_REPAIR=1
#   field-up-a    TC-893-20  the same into slot A, under the old grub.cfg that
#                            un-consumes A's try: two boots, no loop
#   down          TC-893-21  field-up-b, then 2026.10.3 back into A (the shared
#                            kernel, no guard line), then this build back into
#                            B (its own kernel, MATCH, no repair). The ESP ends
#                            byte-identical to field-up-b's end
#   repair-twice  TC-893-22  field-up-b's start with B_REPAIR=1 preset: the
#                            repair marks B bad, and A boots 2026.10.3 on the
#                            shared kernel. The ESP's EFI and grub.cfg unchanged
#   mixed-pair    TC-893-23  a 2026.10.3 ESP with only this build's grub.cfg,
#                            then with only this build's EFI: both slots boot
#                            the shared kernel in each case, no hang at the menu
#   generic       TC-893-24  the FROM image, this build into the inactive slot,
#                            then FROM back into the other slot. When FROM is on
#                            this layout (its rootfs carries /boot/kernel-id),
#                            each boot is that slot's own kernel with MATCH, one
#                            boot per hop, and the ESP is unchanged apart from
#                            grubenv. When FROM is older, the up hop is the
#                            field repair (two boots) and the down hop boots
#                            the shared kernel.
#
# MODELLED, NOT RUN. An install by either agent, old or new, is modelled on the
# host: dd of the .rootfs into the slot, then ORDER="<T> <other>" <T>_OK=1
# <T>_TRY=0. Since #893 the new agent writes nothing to the ESP but grubenv,
# and its deactivate step leaves the same end state, so this is faithful for
# both. mark-good (which an unseeded image never runs) is modelled as
# <slot>_OK=1 <slot>_TRY=0 and dropping <slot>_REPAIR.
#
# NON-INTERACTIVE. Nothing is ever typed into the guest. Every check is a fact
# on the serial console (the kernel's "Linux version" and "Command line"
# lines, the guard's verdict, the agent's outcome line, the console prompt,
# and the LAN bridge reaching forwarding) or on the disk, read on the host once
# QEMU is stopped. The bridge line is the "boot has settled" fact: network
# starts at S20, after the guard (S11) has run, so a boot that shows it with
# no guard line ran no guard. (procd's "- init complete -" does not reach the
# console on this image, measured on 2026.10.3.)
# Every wait has a deadline (BOOT_DEADLINE seconds, default 600) that names
# what never appeared, and a dead QEMU ends it at once.
#
# WHAT IT CANNOT PROVE: CWWK firmware and igc, power loss during the ESP
# writes, the NATS update saga, or the old agent's own code. Those are the
# bench walk's (geekdojo-brain rasputin-firewall-test skill).
#
# Needs: qemu-system-x86_64, OVMF, mtools, sfdisk, jq, grub-editenv,
# unsquashfs. Logs: $WORK/<leg>/console.log (WORK=/tmp/update-smoke).
set -euo pipefail

USAGE="usage: $0 <leg> <new-ab.img> <new.rootfs> [<from-ab.img>]"
LEG="${1:?$USAGE}"
NEW_IMG="${2:?$USAGE}"
NEW_ROOTFS="${3:?$USAGE}"
FROM_IMG="${4:-}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${WORK:-/tmp/update-smoke}/$LEG"
BOOT_DEADLINE="${BOOT_DEADLINE:-600}"
export MTOOLS_SKIP_CHECK=1

LOG="$WORK/console.log"   # every session, appended at the end of each
SLOG=""                   # the current QEMU session's console
SESSION=0

say() { printf 'update-smoke[%s]: %s\n' "$LEG" "$*"; }
die() {
	printf 'update-smoke[%s]: FAIL %s\n' "$LEG" "$*" >&2
	if [ -n "$SLOG" ] && [ -f "$SLOG" ]; then
		echo "----- last 60 console lines of session $SESSION -----" >&2
		tail -n 60 "$SLOG" | tr -d '\r' >&2
	fi
	exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK"
: > "$LOG"

for f in "$NEW_IMG" "$NEW_ROOTFS"; do [ -s "$f" ] || die "missing input $f"; done
sha256_of() { sha256sum "$1" | awk '{print $1}'; }

# --- partitions and the ESP, host-side ---------------------------------------------
# part <disk> <name> → "<byte offset> <byte size>" of a GPT partition, by name.
part() {
	sfdisk -J "$1" | jq -r --arg n "$2" \
		'.partitiontable | (.sectorsize // 512) as $s | .partitions[] | select(.name == $n) | "\(.start * $s) \(.size * $s)"'
}
esp_of() { local off; read -r off _ < <(part "$1" esp); [ -n "$off" ] || die "no esp partition in $1"; echo "$1@@$off"; }

# --- what this build is ---------------------------------------------------------
# To a file, then head: head on a pipe would stop reading and, under pipefail,
# fail on unsquashfs's broken pipe.
unsquashfs -cat "$NEW_ROOTFS" boot/kernel-id > "$WORK/new-kernel-id" 2>/dev/null \
	|| die "this build's .rootfs has no /boot/kernel-id"
NEW_ID="$(head -n 1 "$WORK/new-kernel-id")"
LEGACY_ID="$(head -n 1 "$REPO_ROOT/image/legacy-kernel-id")"
LEGACY_KSHA="$(awk '$2 == "vmlinuz" {print $1}' "$REPO_ROOT/image/legacy-kernel.sha256")"
mcopy -n -i "$(esp_of "$NEW_IMG")" ::/EFI/BOOT/bootx64.efi "$WORK/new-efi" || die "this build's ESP has no bootx64.efi"
mcopy -n -i "$(esp_of "$NEW_IMG")" ::/boot/grub/grub.cfg "$WORK/new-cfg" || die "this build's ESP has no grub.cfg"
say "this build: kernel '$NEW_ID'; shared kernel '$LEGACY_ID'"

DISK="$WORK/disk.img"
ESP=""
use_disk() { cp --sparse=always "$1" "$DISK"; ESP="$(esp_of "$DISK")"; }

genv_pull() { mcopy -n -i "$ESP" ::/boot/grub/grubenv "$WORK/grubenv"; }
genv_push() { mcopy -o -i "$ESP" "$WORK/grubenv" ::/boot/grub/grubenv; }
genv_set() { genv_pull; grub-editenv "$WORK/grubenv" set "$@"; genv_push; say "grubenv set $*"; }
genv_unset() { genv_pull; grub-editenv "$WORK/grubenv" unset "$@"; genv_push; say "grubenv unset $*"; }
genv_get() { genv_pull; grub-editenv "$WORK/grubenv" list | sed -n "s/^$1=//p"; }
genv_show() { genv_pull; say "grubenv: $(grub-editenv "$WORK/grubenv" list | tr '\n' ' ')"; }
expect_genv() { # expect_genv KEY VALUE ("" = absent)
	local got
	got="$(genv_get "$1")"
	[ "$got" = "$2" ] || die "grubenv $1='$got', want '$2'"
}

# slot_rootfs <disk> <slot> <out> — copy a slot's squashfs out (its bytes_used,
# not the whole partition), the way a .rootfs carries it.
slot_rootfs() {
	local off used label=rootfs-0
	[ "$2" = B ] && label=rootfs-1
	read -r off _ < <(part "$1" "$label")
	[ -n "$off" ] || die "no $label partition in $1"
	used=$(od -An -t u8 -j $((off + 40)) -N 8 "$1" | tr -d ' ')
	[ -n "$used" ] && [ "$used" -gt 0 ] || die "no squashfs in $label of $1"
	dd if="$1" of="$3" bs=1M skip="$off" count="$used" iflag=skip_bytes,count_bytes status=none
}

# install <slot> <rootfs> — either agent's install, host-side (see the header).
install() {
	local slot=$1 other=A label=rootfs-1 off size
	[ "$slot" = A ] && { other=B; label=rootfs-0; }
	read -r off size < <(part "$DISK" "$label")
	[ -n "$off" ] || die "no $label partition"
	[ "$(stat -c%s "$2")" -le "$size" ] || die "$2 does not fit $label"
	dd if="$2" of="$DISK" bs=1M seek="$off" oflag=seek_bytes conv=notrunc status=none
	genv_set "ORDER=$slot $other" "${slot}_OK=1" "${slot}_TRY=0"
	say "installed $(basename "$2") into slot $slot (dd + grubenv)"
}
mark_good() { genv_set "${1}_OK=1" "${1}_TRY=0"; genv_unset "${1}_REPAIR"; }

# esp_state — the sha256 of the ESP's boot files and its boot/ listing, one
# line each, for comparing the ESP across a leg.
esp_state() {
	local f
	for f in EFI/BOOT/bootx64.efi boot/grub/grub.cfg boot/vmlinuz; do
		mcopy -n -i "$ESP" "::/$f" "$WORK/esp-f" 2>/dev/null || { echo "$f absent"; continue; }
		echo "$f $(sha256_of "$WORK/esp-f")"
	done
	echo "boot/: $(mdir -b -i "$ESP" ::/boot | sed 's|.*/boot/||' | sort | tr '\n' ' ')"
}
expect_esp() { # expect_esp <want-state-file> <what>
	esp_state > "$WORK/esp-now"
	diff -u "$1" "$WORK/esp-now" >&2 || die "the ESP changed: $2"
}
# The ESP a 2026.10.3 box has after its one-time repair: this build's EFI and
# grub.cfg, the unchanged shared kernel, and no per-slot kernel.
expect_esp_repaired() {
	{
		echo "EFI/BOOT/bootx64.efi $(sha256_of "$WORK/new-efi")"
		echo "boot/grub/grub.cfg $(sha256_of "$WORK/new-cfg")"
		echo "boot/vmlinuz $LEGACY_KSHA"
	} > "$WORK/esp-want"
	esp_state > "$WORK/esp-now"
	head -n 3 "$WORK/esp-now" | diff -u "$WORK/esp-want" - >&2 || die "the ESP is not this build's EFI and grub.cfg with the shared 2026.10.3 kernel"
	if tail -n 1 "$WORK/esp-now" | grep -qE ' vmlinuz-[AB] '; then die "the ESP has a per-slot kernel: $(tail -n 1 "$WORK/esp-now")"; fi
	say "ESP: this build's EFI and grub.cfg, the shared 2026.10.3 kernel, no vmlinuz-[AB]"
}

# --- the VM -----------------------------------------------------------------------
OVMF_CODE=""; OVMF_VARS=""
for f in /usr/share/OVMF/OVMF_CODE*.fd; do case "$f" in *secboot*|*snakeoil*) ;; *) [ -f "$f" ] && [ -z "$OVMF_CODE" ] && OVMF_CODE=$f ;; esac; done
for f in /usr/share/OVMF/OVMF_VARS*.fd; do case "$f" in *secboot*|*ms*|*snakeoil*) ;; *) [ -f "$f" ] && [ -z "$OVMF_VARS" ] && OVMF_VARS=$f ;; esac; done
[ -n "$OVMF_CODE" ] && [ -n "$OVMF_VARS" ] || die "no OVMF firmware under /usr/share/OVMF"
if [ -w /dev/kvm ]; then ACCEL=(-accel kvm -cpu host); else ACCEL=(-cpu max); fi

QPID=""
stop_vm() {
	if [ -n "$QPID" ]; then
		kill "$QPID" 2>/dev/null || true
		wait "$QPID" 2>/dev/null || true
		QPID=""
	fi
	if [ -n "$SLOG" ] && [ -f "$SLOG" ]; then
		{ echo "===== session $SESSION ====="; tr -d '\r' < "$SLOG"; } >> "$LOG"
	fi
}
trap stop_vm EXIT

# start_vm — boot the disk in a new QEMU session; its console goes to $SLOG.
# A guest reboot stays in the session (a warm reset re-reads the ESP).
start_vm() {
	SESSION=$((SESSION + 1))
	SLOG="$WORK/session-$SESSION.log"
	: > "$SLOG"
	cp "$OVMF_VARS" "$WORK/vars.fd"
	qemu-system-x86_64 -machine q35 -m 1024 -smp 2 "${ACCEL[@]}" \
		-display none -monitor none \
		-drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
		-drive "if=pflash,format=raw,file=$WORK/vars.fd" \
		-drive "file=$DISK,format=raw,if=virtio" \
		-netdev user,id=lan,restrict=on -device e1000e,netdev=lan \
		-netdev user,id=wan -device e1000e,netdev=wan \
		-chardev "file,id=con,path=$SLOG" -serial chardev:con \
		> "$WORK/qemu-$SESSION.log" 2>&1 &
	QPID=$!
	say "session $SESSION: QEMU started"
}
alive() { [ -n "$QPID" ] && kill -0 "$QPID" 2>/dev/null; }

# The console of boot n of this session, CRs stripped, to a file: searches
# read the file, never a pipe into grep -q (a closed pipe under pipefail).
SEG="$WORK/seg.txt"
seg() {
	tr -d '\r' < "$SLOG" | awk -v n="$1" '/Linux version / {b++} b == n' > "$SEG"
}
boots() { tr -d '\r' < "$SLOG" | grep -c 'Linux version ' || true; }

# wait_fact <n> <ERE> <what> — wait for a console line of boot n, bounded.
wait_fact() {
	local end=$(( $(date +%s) + BOOT_DEADLINE ))
	while :; do
		seg "$1"
		grep -qE -- "$2" "$SEG" && return 0
		alive || { seg "$1"; grep -qE -- "$2" "$SEG" && return 0; die "QEMU exited before $3 (boot $1)"; }
		[ "$(date +%s)" -lt "$end" ] || die "$3 did not appear within ${BOOT_DEADLINE}s (boot $1)"
		sleep 2
	done
}
wait_boot() { # wait_boot <n> — boot n has begun.
	local end=$(( $(date +%s) + BOOT_DEADLINE ))
	while [ "$(boots)" -lt "$1" ]; do
		alive || die "QEMU exited before boot $1 began"
		[ "$(date +%s)" -lt "$end" ] || die "boot $1 did not begin within ${BOOT_DEADLINE}s"
		sleep 2
	done
}

# expect_boot <n> <slot> <own|shared> <kernel-id> — boot n came from that slot,
# on the slot's own kernel (BOOT_IMAGE=(hdN,gpt3|4)/boot/vmlinuz) or the
# shared one (BOOT_IMAGE=/boot/vmlinuz), and is that kernel.
expect_boot() {
	local n=$1 slot=$2 kind=$3 id=$4 line img gpt=gpt3 ver
	[ "$slot" = B ] && gpt=gpt4
	wait_boot "$n"
	wait_fact "$n" ' Command line: ' "the kernel command line"
	line=$(grep -m 1 ' Command line: ' "$SEG")
	img=$(printf '%s\n' "$line" | sed -n 's/.* BOOT_IMAGE=\([^ ]*\).*/\1/p')
	case " $line " in *" rasputin.slot=$slot "*) ;; *) die "boot $n is not slot $slot: $line" ;; esac
	if [ "$kind" = own ]; then
		printf '%s\n' "$img" | grep -qE "^\(hd[0-9]+,$gpt\)/boot/vmlinuz$" \
			|| die "boot $n has BOOT_IMAGE=$img, want slot $slot's own (hdN,$gpt)/boot/vmlinuz"
	else
		[ "$img" = /boot/vmlinuz ] || die "boot $n has BOOT_IMAGE=$img, want the shared /boot/vmlinuz"
	fi
	# "Linux version <release> (<builder>) (<toolchain>) <version>"
	line=$(grep -m 1 'Linux version ' "$SEG" | sed 's/.*Linux version //; s/[[:space:]]*$//')
	ver="#${id#* #}"
	case "$line" in
		"${id%% *} "*"$ver") ;;
		*) die "boot $n is kernel '$line', want '$id'" ;;
	esac
	say "boot $n: slot $slot, BOOT_IMAGE=$img, kernel '$id'"
}
PROMPT='Please press Enter to activate this console'
SETTLED='br-lan: port [0-9]+\(eth[0-9]+\) entered forwarding state'
# settle <n> — the console prompt, then the LAN bridge forwarding.
settle() {
	wait_fact "$1" "$PROMPT" "the console prompt"
	wait_fact "$1" "$SETTLED" "the LAN bridge reaching forwarding"
}
# expect_match <n> — the guard's MATCH, no repair, and the boot settled.
expect_match() {
	wait_fact "$1" "rasputin-kernel-match: MATCH running=$NEW_ID|rasputin-kernel-match: (MISMATCH|FAIL)" "the kernel-match verdict"
	grep -qF "rasputin-kernel-match: MATCH running=$NEW_ID" "$SEG" \
		|| die "boot $1: $(grep -m 1 'rasputin-kernel-match:' "$SEG")"
	settle "$1"
	say "boot $1: MATCH, settled"
}
# expect_match_of <n> <id> — as expect_match, for a FROM kernel on this layout.
expect_match_of() {
	wait_fact "$1" "rasputin-kernel-match: (MATCH|MISMATCH|FAIL)" "the kernel-match verdict"
	grep -qF "rasputin-kernel-match: MATCH running=$2" "$SEG" \
		|| die "boot $1: $(grep -m 1 'rasputin-kernel-match:' "$SEG")"
	settle "$1"
	say "boot $1: MATCH, settled"
}
# expect_no_guard <n> — a release with no guard settled and printed no verdict.
expect_no_guard() {
	settle "$1"
	if grep -q 'rasputin-kernel-match:' "$SEG"; then die "boot $1 ran the guard: $(grep -m 1 'rasputin-kernel-match:' "$SEG")"; fi
	say "boot $1: settled, no guard line"
}
# expect_repair <n> <outcome> — the guard's MISMATCH and the agent's outcome,
# then the guard's reboot (boot n+1 begins).
expect_repair() {
	wait_fact "$1" "rasputin-kernel-match: MISMATCH running=$LEGACY_ID built-for=$NEW_ID|rasputin-kernel-match: (MATCH|FAIL)" "the kernel-match verdict"
	grep -qF "rasputin-kernel-match: MISMATCH running=$LEGACY_ID built-for=$NEW_ID" "$SEG" \
		|| die "boot $1: $(grep -m 1 'rasputin-kernel-match:' "$SEG")"
	wait_fact "$1" "rasputin-kernel-match: (agent: .*outcome=|repair-slot-boot exited|no agent at)" "the repair's outcome"
	grep -q "rasputin-kernel-match: agent: .*outcome=$2" "$SEG" \
		|| die "boot $1: want the agent's outcome=$2, got: $(grep -E 'rasputin-kernel-match: (agent:|repair-slot-boot|no agent)' "$SEG" | head -5 | tr '\n' ' ')"
	wait_boot $(( $1 + 1 ))
	say "boot $1: MISMATCH, outcome=$2, rebooted"
}
# end_session <boots> — exactly that many boots, then stop QEMU.
end_session() {
	[ "$(boots)" = "$1" ] || die "$(boots) kernel boots in session $SESSION, want exactly $1"
	stop_vm
	SLOG=""
}

# --- the legs ---------------------------------------------------------------------
need_from() { [ -s "$FROM_IMG" ] || die "leg $LEG needs <from-ab.img>"; }

leg_fresh() {
	use_disk "$NEW_IMG"
	start_vm
	expect_boot 1 A own "$NEW_ID"; expect_match 1
	end_session 1
	expect_genv A_TRY 1
	say "GRUB left A_TRY=1; restarting"
	start_vm
	expect_boot 1 B own "$NEW_ID"; expect_match 1
	end_session 1
}

# field_up <slot> — the 2026.10.3 image; an old agent installs this build.
field_up() {
	local slot=$1
	need_from; use_disk "$FROM_IMG"
	esp_state > "$WORK/esp-field"
	if [ "$slot" = A ]; then genv_set "ORDER=B A" B_OK=1 B_TRY=0 A_OK=1 A_TRY=0; fi
	install "$slot" "$NEW_ROOTFS"
	start_vm
	expect_boot 1 "$slot" shared "$LEGACY_ID"; expect_repair 1 repaired
	expect_boot 2 "$slot" own "$NEW_ID"; expect_match 2
	end_session 2
	expect_esp_repaired
	expect_genv "${slot}_REPAIR" 1
	expect_genv "${slot}_OK" 1
	if [ "$slot" = B ]; then expect_genv A_OK 1; else expect_genv B_OK 1; fi
}

leg_down() {
	need_from
	slot_rootfs "$FROM_IMG" A "$WORK/field.rootfs"
	field_up B
	esp_state > "$WORK/esp-up"
	mark_good B
	install A "$WORK/field.rootfs"
	start_vm
	expect_boot 1 A shared "$LEGACY_ID"; expect_no_guard 1
	end_session 1
	mark_good A
	install B "$NEW_ROOTFS"
	start_vm
	expect_boot 1 B own "$NEW_ID"; expect_match 1
	end_session 1
	expect_esp "$WORK/esp-up" "after the downgrade and the update back"
	say "ESP byte-identical to field-up-b's end"
}

leg_repair_twice() {
	need_from; use_disk "$FROM_IMG"
	esp_state > "$WORK/esp-field"
	install B "$NEW_ROOTFS"
	genv_set B_REPAIR=1
	start_vm
	expect_boot 1 B shared "$LEGACY_ID"; expect_repair 1 fallback
	expect_boot 2 A shared "$LEGACY_ID"; expect_no_guard 2
	end_session 2
	expect_genv B_OK 0
	expect_genv B_REPAIR ""
	expect_esp "$WORK/esp-field" "the fallback must not write the EFI or grub.cfg"
}

# mixed_case <what> — boot slot A, then slot B, on the shared kernel.
mixed_case() {
	start_vm
	expect_boot 1 A shared "$LEGACY_ID"; expect_no_guard 1
	end_session 1
	genv_set "ORDER=B A" B_OK=1 B_TRY=0 A_OK=1 A_TRY=0
	start_vm
	expect_boot 1 B shared "$LEGACY_ID"; expect_no_guard 1
	end_session 1
	say "$1: both slots booted the shared kernel"
}
leg_mixed_pair() {
	need_from
	use_disk "$FROM_IMG"
	mcopy -o -i "$ESP" "$WORK/new-cfg" ::/boot/grub/grub.cfg
	say "case 1: 2026.10.3 EFI, this build's grub.cfg"
	mixed_case "old EFI + new grub.cfg"
	use_disk "$FROM_IMG"
	mcopy -o -i "$ESP" "$WORK/new-efi" ::/EFI/BOOT/bootx64.efi
	say "case 2: this build's EFI, 2026.10.3 grub.cfg"
	mixed_case "new EFI + old grub.cfg"
}

leg_generic() {
	need_from
	use_disk "$FROM_IMG"
	slot_rootfs "$FROM_IMG" A "$WORK/from.rootfs"
	local from_id=""
	if unsquashfs -cat "$WORK/from.rootfs" boot/kernel-id > "$WORK/from-kernel-id" 2>/dev/null; then
		from_id="$(head -n 1 "$WORK/from-kernel-id")"
	fi
	esp_state > "$WORK/esp-from"
	install B "$NEW_ROOTFS"
	start_vm
	if [ -n "$from_id" ]; then
		say "FROM is on this layout (kernel '$from_id'): new to new, no repair"
		expect_boot 1 B own "$NEW_ID"; expect_match 1
		end_session 1
		expect_esp "$WORK/esp-from" "an update between two releases on this layout writes only grubenv"
	else
		say "FROM predates this layout: the up hop is the field repair"
		expect_boot 1 B shared "$LEGACY_ID"; expect_repair 1 repaired
		expect_boot 2 B own "$NEW_ID"; expect_match 2
		end_session 2
		expect_esp_repaired
	fi
	esp_state > "$WORK/esp-up"
	mark_good B
	install A "$WORK/from.rootfs"
	start_vm
	if [ -n "$from_id" ]; then
		expect_boot 1 A own "$from_id"; expect_match_of 1 "$from_id"
	else
		expect_boot 1 A shared "$LEGACY_ID"; expect_no_guard 1
	fi
	end_session 1
	expect_esp "$WORK/esp-up" "the downgrade writes only grubenv"
}

case "$LEG" in
	fresh)        leg_fresh ;;
	field-up-b)   field_up B ;;
	field-up-a)   field_up A ;;
	down)         leg_down ;;
	repair-twice) leg_repair_twice ;;
	mixed-pair)   leg_mixed_pair ;;
	generic)      leg_generic ;;
	*) die "unknown leg '$LEG'" ;;
esac
genv_show
say "PASS"
