#!/bin/sh
#
# test-kernel-match.sh — behaviour tests for files/usr/lib/rasputin/kernel-match.sh
# (geekdojo/geekdojo-brain#888, TC-888-12).
#
# WHY
#   The guard decides, on a box that has just booted the wrong kernel, whether
#   to reboot. Reboot when it should not and a slot-A box loops forever; fail
#   to reboot when it should and a slot-B box sits offline instead of falling
#   back. Neither is visible to a syntax check, so every row of the decision
#   is pinned here: the verdict line and its kmsg priority, how many times the
#   repair verb ran, and whether sync + reboot -f ran.
#
#   uname, the id file, the command line, the agent and the reboot/sync
#   commands are all stand-ins, injected through the guard's RASPUTIN_KM_*
#   seams. The stubs record each call in a scratch directory.
#
# SHELLS
#   The guard runs under busybox ash on the box. Every case runs under each
#   shell in TEST_SHELLS (default: whichever of sh, dash, bash and busybox are
#   installed). REQUIRE_BUSYBOX=1 (CI sets it) makes a missing busybox a
#   failure, so the target shell cannot silently drop out.
#
# Usage: sh scripts/test-kernel-match.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/files/usr/lib/rasputin/kernel-match.sh"
[ -f "$SUT" ] || { echo "missing: $SUT" >&2; exit 2; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi
case " $TEST_SHELLS " in
	*" busybox_sh "*) ;;
	*)
		if [ "${REQUIRE_BUSYBOX:-0}" = "1" ]; then
			echo "kernel-match: REQUIRE_BUSYBOX=1 but busybox is not installed — the target shell was not tested" >&2
			exit 1
		fi ;;
esac

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2" >&2; }

BUILD_ID="6.12.112 #0 SMP Sun Oct 25 10:00:00 2026"
LEGACY_ID="6.12.94 #0 SMP Mon Jun 29 12:59:20 2026"

# Stubs, written once. Each appends a line to its call log.
mkdir -p "$W/bin"
cat > "$W/bin/uname" <<'EOF'
#!/bin/sh
case "$1" in
	-r) printf '%s\n' "${STUB_RELEASE}" ;;
	-v) printf '%s\n' "${STUB_VERSION}" ;;
esac
EOF
cat > "$W/bin/agent" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_LOG/agent"
echo 'level=INFO msg="slot boot repaired" outcome=repaired' >&2
exit "${STUB_AGENT_RC:-0}"
EOF
cat > "$W/bin/sync" <<'EOF'
#!/bin/sh
echo sync >> "$STUB_LOG/order"
EOF
cat > "$W/bin/reboot" <<'EOF'
#!/bin/sh
echo "reboot $*" >> "$STUB_LOG/order"
echo "$*" >> "$STUB_LOG/reboot"
EOF
chmod +x "$W/bin/"*

# run_case <shell> <name> <running-id> <id-file-mode> <slot> <agent-mode> <agent-rc>
#   id-file-mode: build | empty | missing | unreadable
#   agent-mode:   present | missing
run_case() {
	_sh=$1 _name=$2 _running=$3 _idmode=$4 _slot=$5 _agent=$6 _rc=$7
	d="$W/case"
	rm -rf "$d"; mkdir -p "$d/log"
	case "$_idmode" in
		build)      printf '%s\n' "$BUILD_ID" > "$d/kernel-id" ;;
		empty)      : > "$d/kernel-id" ;;
		missing)    ;;
		unreadable) printf '%s\n' "$BUILD_ID" > "$d/kernel-id"; chmod 000 "$d/kernel-id" ;;
	esac
	case "$_slot" in
		A) echo "root=PARTLABEL=rootfs-0 rootfstype=squashfs rootwait ro rasputin.slot=A console=ttyS0,115200" > "$d/cmdline" ;;
		B) echo "root=PARTLABEL=rootfs-1 rootfstype=squashfs rootwait ro rasputin.slot=B console=ttyS0,115200" > "$d/cmdline" ;;
	esac
	: > "$d/kmsg"
	printf 'nodev\ttmpfs\n\tvfat\n' > "$d/filesystems"
	printf 'tmpfs /overlay tmpfs rw 0 0\n' > "$d/mounts"
	agent="$W/bin/agent"
	[ "$_agent" = missing ] && agent="$d/no-such-agent"
	if [ "$_sh" = busybox_sh ]; then set -- busybox sh; else set -- "$_sh"; fi
	STUB_RELEASE="${_running%% *}" STUB_VERSION="${_running#* }" \
	STUB_LOG="$d/log" STUB_AGENT_RC="$_rc" \
	RASPUTIN_KM_ID_FILE="$d/kernel-id" RASPUTIN_KM_CMDLINE="$d/cmdline" \
	RASPUTIN_KM_KMSG="$d/kmsg" RASPUTIN_KM_UNAME="$W/bin/uname" \
	RASPUTIN_KM_AGENT="$agent" RASPUTIN_KM_SYNC="$W/bin/sync" \
	RASPUTIN_KM_REBOOT="$W/bin/reboot" \
	RASPUTIN_KM_FILESYSTEMS="$d/filesystems" RASPUTIN_KM_MOUNTS="$d/mounts" \
		"$@" "$SUT" > "$d/stdout" 2>&1
	chmod 600 "$d/kernel-id" 2>/dev/null
}

count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# expect <name> <kmsg-fixed-string> <agent-calls> <reboots>
expect() {
	_n=$1 _line=$2 _agent=$3 _reboots=$4
	d="$W/case"
	if ! grep -qF -- "$_line" "$d/kmsg"; then
		no "$_n" "kmsg lacks '$_line'; kmsg was: $(cat "$d/kmsg")"; return
	fi
	a=$(count "$d/log/agent"); r=$(count "$d/log/reboot")
	if [ "$a" != "$_agent" ]; then no "$_n" "repair ran $a time(s), want $_agent"; return; fi
	if [ "$r" != "$_reboots" ]; then no "$_n" "reboot ran $r time(s), want $_reboots"; return; fi
	if [ "$_agent" = 1 ] && [ "$(cat "$d/log/agent")" != "repair-slot-boot" ]; then
		no "$_n" "agent called with '$(cat "$d/log/agent")', want 'repair-slot-boot'"; return
	fi
	if [ "$_reboots" = 1 ]; then
		if [ "$(cat "$d/log/order")" != "$(printf 'sync\nreboot -f')" ]; then
			no "$_n" "want sync then reboot -f, got: $(tr '\n' ';' < "$d/log/order")"; return
		fi
	fi
	ok "$_n"
}

for shell in $TEST_SHELLS; do
	printf '=== shell: %s ===\n' "$shell"

	run_case "$shell" match "$BUILD_ID" build A present 0
	expect "MATCH: user.notice verdict, no repair, no reboot" "<13>rasputin-kernel-match: MATCH running=$BUILD_ID" 0 0

	for m in missing empty unreadable; do
		# root reads a mode-000 file anyway; that row only means something unprivileged.
		if [ "$m" = unreadable ] && [ "$(id -u)" = 0 ]; then continue; fi
		run_case "$shell" "fail-$m" "$BUILD_ID" "$m" B present 0
		expect "FAIL ($m id): user.err, no repair, no reboot" "<11>rasputin-kernel-match: FAIL" 0 0
	done

	run_case "$shell" mismatch "$LEGACY_ID" build B present 0
	expect "MISMATCH logs both ids at user.err and runs the repair once" \
		"<11>rasputin-kernel-match: MISMATCH running=$LEGACY_ID built-for=$BUILD_ID" 1 1
	if grep -qF "agent: level=INFO" "$W/case/kmsg"; then
		ok "MISMATCH relays the agent's own log lines to kmsg"
	else
		no "MISMATCH relays the agent's own log lines to kmsg" "kmsg: $(cat "$W/case/kmsg")"
	fi
	if grep -qF "<13>rasputin-kernel-match: repair context: vfat=present in /proc/filesystems, /overlay=tmpfs from tmpfs" "$W/case/kmsg"; then
		ok "MISMATCH logs the repair context (vfat, /overlay)"
	else
		no "MISMATCH logs the repair context (vfat, /overlay)" "kmsg: $(cat "$W/case/kmsg")"
	fi

	for s in A B; do
		run_case "$shell" "rc0-$s" "$LEGACY_ID" build "$s" present 0
		expect "repair exit 0 on $s: sync then reboot -f" \
			"<11>rasputin-kernel-match: repair-slot-boot finished on slot $s (outcome in the agent line above); rebooting: GRUB boots slot $s on its own kernel if it was repaired, the other slot if it was marked bad" 1 1
		# F-888-26: exit 0 is Fallback as well as Repaired, so the line must not
		# promise this slot's own kernel.
		if grep -qF "rebooting into its own kernel" "$W/case/kmsg"; then
			no "repair exit 0 on $s: the reboot line holds for Fallback too" "kmsg: $(cat "$W/case/kmsg")"
		else
			ok "repair exit 0 on $s: the reboot line holds for Fallback too"
		fi
	done

	run_case "$shell" rc3-B "$LEGACY_ID" build B present 3
	expect "repair exit 3 on B: reboot (GRUB falls back to A)" "exited 3 on slot B" 1 1

	run_case "$shell" rc3-A "$LEGACY_ID" build A present 3
	expect "repair exit 3 on A: no reboot, says nothing can roll it back" \
		"<11>rasputin-kernel-match: repair-slot-boot exited 3 on slot A, so the ESP is unchanged. Not rebooting: nothing can roll slot A back" 1 0

	for rc in 1 2; do
		run_case "$shell" "rc$rc-A" "$LEGACY_ID" build A present "$rc"
		expect "repair exit $rc on A: no reboot" "exited $rc on slot A" 1 0
		run_case "$shell" "rc$rc-B" "$LEGACY_ID" build B present "$rc"
		expect "repair exit $rc on B: reboot" "exited $rc on slot B" 1 1
	done

	run_case "$shell" noagent-A "$LEGACY_ID" build A missing 0
	expect "no agent binary on A: no reboot" "nothing can roll slot A back" 0 0
	run_case "$shell" noagent-B "$LEGACY_ID" build B missing 0
	expect "no agent binary on B: reboot" "exited 127 on slot B" 0 1
done

printf '\nkernel-match: %d passed, %d failed (shells:%s)\n' "$pass" "$fail" "$TEST_SHELLS"
[ "$fail" -eq 0 ]
