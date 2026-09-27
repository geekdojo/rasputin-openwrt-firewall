#!/bin/sh
#
# test-trust-clean-overlay.sh — functional test of files/etc/init.d/rasputin-trust-clean
# against a REAL, mounted overlayfs and the REAL kernel log.
#
# WHY (geekdojo/geekdojo-brain#531, bench 2026-09-27 on dev.130)
#   test-trust-clean.sh drives the script against plain directories, and every
#   case in it passed while the script failed on hardware in two ways that plain
#   directories cannot show:
#
#   1. The stale anchor kept being served for the rest of the boot. OpenWrt's
#      S00sysfixtime walks every file under /etc through the MOUNTED overlay
#      (`find /etc -type f` plus a stat of each), so by S10 the kernel holds an
#      overlay dentry for /etc/rasputin/trust/root-ca.pem that points at the
#      upper-layer inode. Unlinking that file in /overlay/upper — beneath the
#      mount, which the kernel documents as undefined behaviour — does not touch
#      the cached dentry: every open of /etc/rasputin/trust/root-ca.pem kept
#      returning the stale bytes (of a deleted inode) until the dentry was
#      evicted, and the trust/ directory listed as empty.
#   2. Nothing was logged. The script ran at S10 and wrote with `logger`, but
#      logd starts at S12, so there was no /dev/log to receive the lines.
#
#   So this test mounts an overlay, warms the dentry cache exactly as
#   sysfixtime does, runs the script, and then reads the anchor back THROUGH THE
#   MOUNT in the same "boot" (same mount, no remount, no cache drop by the test).
#   Log lines are asserted in the kernel ring buffer (`dmesg`), which is where
#   the script now writes and what logd imports once it starts.
#
# REQUIREMENTS
#   Linux, root (mount, /dev/kmsg, dmesg, drop_caches) and overlayfs. Off Linux
#   or without root it SKIPS — unless REQUIRE_OVERLAY=1 (CI sets it), which turns
#   a skip into a failure, so the runner that can run it cannot silently not.
#
# SHELLS
#   Runs the script under each of sh and `busybox sh` (the box's shell) that is
#   installed; REQUIRE_BUSYBOX=1 makes a missing busybox a failure.
#
# Usage: sudo sh scripts/test-trust-clean-overlay.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/files/etc/init.d/rasputin-trust-clean"
[ -f "$SUT" ] || { echo "missing: $SUT" >&2; exit 2; }

skip() {
	if [ "${REQUIRE_OVERLAY:-0}" = "1" ]; then
		echo "trust-clean-overlay: REQUIRE_OVERLAY=1 but $1 — the functional test did not run" >&2
		exit 1
	fi
	echo "trust-clean-overlay: SKIP — $1"
	exit 0
}

[ "$(uname -s)" = Linux ] || skip "not Linux (no overlayfs)"
[ "$(id -u)" = 0 ] || skip "not root (needs mount, /dev/kmsg and dmesg)"
[ -w /dev/kmsg ] || skip "/dev/kmsg is not writable"
[ -w /proc/sys/vm/drop_caches ] || skip "/proc/sys/vm/drop_caches is not writable"
dmesg >/dev/null 2>&1 || skip "dmesg cannot read the kernel log"

SHELLS="sh"
if command -v busybox >/dev/null 2>&1; then
	SHELLS="$SHELLS busybox_sh"
elif [ "${REQUIRE_BUSYBOX:-0}" = "1" ]; then
	echo "trust-clean-overlay: REQUIRE_BUSYBOX=1 but busybox is not installed" >&2
	exit 1
fi

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2" >&2; }

SCRATCH=$(mktemp -d)
MOUNTS=""
cleanup() {
	exec 3<&- 2>/dev/null
	for m in $MOUNTS; do umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null; done
	rm -rf "$SCRATCH"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

TRUST_REL=etc/rasputin/trust/root-ca.pem
TRUST_DIR=etc/rasputin/trust

# A real certificate for each side, so the fingerprint the script logs is the
# real code path and not the no-openssl fallback.
mkcert() {
	openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=$1" \
		-keyout "$SCRATCH/$1.key" -out "$SCRATCH/$1.pem" >/dev/null 2>&1 \
		|| { echo "openssl could not make a test certificate" >&2; exit 2; }
}
mkcert image-anchor
mkcert stale-anchor

# The kernel log lines this script has written so far. Counted, not matched on
# content, so a line from an earlier case cannot satisfy a later one.
klog_count() { dmesg 2>/dev/null | grep -c "rasputin-trust-clean: $1" ; }

# fixture <name> — a fresh /rom (lower), /overlay/upper and mounted merged root.
fixture() {
	C="$SCRATCH/$1"
	LOWER="$C/rom"; UPPER="$C/overlay/upper"; WORK="$C/overlay/work"; MERGED="$C/merged"
	mkdir -p "$LOWER/$TRUST_DIR" "$UPPER" "$WORK" "$MERGED"
	cp "$SCRATCH/image-anchor.pem" "$LOWER/$TRUST_REL"
	echo "tracked-dir marker" > "$LOWER/$TRUST_DIR/README.md"
	mount -t overlay overlay -o "lowerdir=$LOWER,upperdir=$UPPER,workdir=$WORK" "$MERGED" \
		|| { echo "overlay mount failed" >&2; exit 1; }
	MOUNTS="$MERGED $MOUNTS"
}

# plant <pem> — write a copy into the overlay THROUGH the mount (how an
# operator or an old keep.d restore put it there), then drop caches so the next
# boot starts cold, as a reboot would.
plant() {
	cp "$1" "$MERGED/$TRUST_REL"
	echo 2 > /proc/sys/vm/drop_caches
}

# boot_walk — what OpenWrt's S00sysfixtime does before S10: find every file
# under /etc through the mount and stat it. This is what leaves the overlay
# dentries cached when the script runs.
boot_walk() {
	for f in $(find "$MERGED/etc" -type f); do [ "$f" -ot "$MERGED/etc" ]; done
}

# run <shell> — the init script's start(), as S10 would run it.
run() {
	_shell=$1
	[ "$_shell" = busybox_sh ] && _shell="busybox sh"
	RASPUTIN_TRUST_OVERLAY_ROOT="$UPPER" RASPUTIN_TRUST_ROM_ROOT="$LOWER" \
	RASPUTIN_TRUST_MERGED_ROOT="$MERGED" \
		$_shell -c '. "$1"; start' sh "$SUT" >/dev/null 2>&1
}

# served_is_image — the anchor the running system reads, through the mount, is
# the image's, and it is the image's FILE (a live inode, not a deleted upper one
# still pinned by a stale dentry).
served_is_image() {
	if cmp -s "$MERGED/$TRUST_REL" "$LOWER/$TRUST_REL"; then
		ok "$1: the image's anchor is served, same boot"
	else
		no "$1: the image's anchor is served, same boot" "read $(openssl x509 -in "$MERGED/$TRUST_REL" -noout -subject 2>/dev/null || echo unreadable)"
	fi
	links=$(stat -c %h "$MERGED/$TRUST_REL" 2>/dev/null || echo "?")
	if [ "$links" != 0 ]; then
		ok "$1: served from a live file (link count $links)"
	else
		no "$1: served from a live file" "link count 0 — a deleted overlay inode, pinned by a stale dentry"
	fi
	if ls "$MERGED/$TRUST_DIR" 2>/dev/null | grep -qx root-ca.pem \
		&& ls "$MERGED/$TRUST_DIR" 2>/dev/null | grep -qx README.md; then
		ok "$1: trust/ lists the image's files"
	else
		no "$1: trust/ lists the image's files" "listing: $(ls "$MERGED/$TRUST_DIR" 2>&1 | tr '\n' ' ')"
	fi
}

for SH in $SHELLS; do
	printf '=== shell: %s ===\n' "$SH"

	echo "1. a stale overlay copy is removed and the image's is served, same boot"
	fixture "$SH-stale"
	plant "$SCRATCH/stale-anchor.pem"
	boot_walk
	# Precondition: the test really is reproducing the bench — the running
	# system is serving the stale copy before the script runs.
	cmp -s "$MERGED/$TRUST_REL" "$SCRATCH/stale-anchor.pem" \
		|| no "precondition" "the stale copy is not what the mount serves"
	w0=$(klog_count WARNING); e0=$(klog_count ERROR)
	run "$SH"
	[ ! -e "$UPPER/$TRUST_REL" ] && ok "overlay copy removed" || no "overlay copy removed" "still in $UPPER"
	served_is_image "stale"
	[ "$(klog_count WARNING)" -eq $((w0 + 1)) ] \
		&& ok "one WARNING line in the kernel log (survives until logd imports it)" \
		|| no "WARNING in the kernel log" "count $w0 -> $(klog_count WARNING)"
	[ "$(klog_count ERROR)" -eq "$e0" ] && ok "no ERROR" || no "no ERROR" "$(dmesg | grep 'rasputin-trust-clean: ERROR' | tail -2)"
	cmp -s "$LOWER/$TRUST_REL" "$SCRATCH/image-anchor.pem" && ok "/rom untouched" || no "/rom untouched" "modified"

	echo "2. an identical overlay copy: removed, nothing logged, the anchor read is unchanged"
	fixture "$SH-identical"
	plant "$SCRATCH/image-anchor.pem"
	boot_walk
	n0=$(dmesg | grep -c 'rasputin-trust-clean')
	run "$SH"
	[ ! -e "$UPPER/$TRUST_REL" ] && ok "overlay copy removed" || no "overlay copy removed" "still in $UPPER"
	served_is_image "identical"
	[ "$(dmesg | grep -c 'rasputin-trust-clean')" -eq "$n0" ] && ok "nothing logged" \
		|| no "nothing logged" "$(dmesg | grep 'rasputin-trust-clean' | tail -2)"

	echo "3. nothing on the overlay: nothing changed, nothing logged"
	fixture "$SH-clean"
	boot_walk
	n0=$(dmesg | grep -c 'rasputin-trust-clean')
	run "$SH"
	[ -z "$(ls -A "$UPPER")" ] && ok "overlay untouched" || no "overlay untouched" "$(find "$UPPER")"
	served_is_image "clean"
	[ "$(dmesg | grep -c 'rasputin-trust-clean')" -eq "$n0" ] && ok "nothing logged" \
		|| no "nothing logged" "$(dmesg | grep 'rasputin-trust-clean' | tail -2)"

	echo "4. an opaque trust/ in the overlay (rm -rf'd and recreated through the mount)"
	fixture "$SH-opaque"
	rm -rf "${MERGED:?}/$TRUST_DIR"
	mkdir "$MERGED/$TRUST_DIR"
	plant "$SCRATCH/stale-anchor.pem"
	boot_walk
	e0=$(klog_count ERROR)
	run "$SH"
	served_is_image "opaque"
	[ "$(klog_count ERROR)" -eq "$e0" ] && ok "no ERROR" || no "no ERROR" "$(dmesg | grep 'rasputin-trust-clean: ERROR' | tail -2)"

	echo "5. the stale anchor is held open while the script runs (its dentry cannot be evicted)"
	fixture "$SH-pinned"
	plant "$SCRATCH/stale-anchor.pem"
	boot_walk
	exec 3< "$MERGED/$TRUST_REL"
	f0=$(klog_count "WARNING: /$TRUST_REL was still served")
	run "$SH"
	[ "$(klog_count "WARNING: /$TRUST_REL was still served")" -eq $((f0 + 1)) ] \
		&& ok "pinned: the write-through fallback is logged" || no "pinned: fallback logged" "no line in dmesg"
	# The pinned dentry is still what a path lookup resolves to, so this is the
	# case only the script's write-through fallback can satisfy.
	if cmp -s "$MERGED/$TRUST_REL" "$LOWER/$TRUST_REL"; then
		ok "pinned: the image's anchor is served, same boot"
	else
		no "pinned: the image's anchor is served, same boot" "still the stale bytes"
	fi
	exec 3<&-
done

echo ""
if [ "$fail" -ne 0 ]; then
	printf 'FAILED — %d of %d checks\n' "$fail" "$((pass + fail))" >&2
	exit 1
fi
printf 'OK — %d checks passed\n' "$pass"
