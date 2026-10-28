#!/bin/sh
#
# test-kernel-id.sh — tests for scripts/kernel-id.sh (geekdojo/geekdojo-brain#888,
# TC-888-13).
#
# kernel-id.sh decides what the kernel-match guard compares uname with. If it
# reads the wrong bytes, every boot is a MISMATCH (a repair and a reboot on
# every box) or every mismatch is a MATCH (the dev.176 outage, silently). So
# the parse is pinned against fixtures built here byte by byte:
#
#   - a synthetic bzImage setup header with a typical banner;
#   - the 2026.10.3 field kernel's own header layout: its kernel_version
#     pointer (0x3860, so the string sits at 14944) and the exact string at
#     that offset, read from the published 2026.10.3 ESP's /boot/vmlinuz.
#     Its id must equal image/legacy-kernel-id, which is what `uname -r` and
#     `uname -v` print on that kernel (F-888-08);
#   - files that are not bzImages, or carry no identity, which must exit 1
#     with a message.
#
# Usage: sh scripts/test-kernel-id.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/scripts/kernel-id.sh"
LEGACY_ID_FILE="$ROOT/image/legacy-kernel-id"

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2" >&2; }

# put <file> <offset> <printf-format> [args] — write bytes at an offset, in place.
put() {
	_f=$1 _o=$2; shift 2
	# shellcheck disable=SC2059 # the format is the point
	printf "$@" | dd of="$_f" bs=1 seek="$_o" conv=notrunc 2>/dev/null
}

# bzimage <file> <string-offset> <banner> — a 32 KiB file with an x86 setup
# header: "HdrS" at 0x202, kernel_version (u16 LE at 0x20E) = offset - 0x200,
# and the NUL-terminated banner at the offset.
bzimage() {
	_f=$1 _off=$2 _banner=$3
	dd if=/dev/zero of="$_f" bs=1024 count=32 2>/dev/null
	put "$_f" 514 'HdrS'
	_kv=$((_off - 512))
	put "$_f" 526 "\\$(printf '%03o' $((_kv % 256)))\\$(printf '%03o' $((_kv / 256)))"
	put "$_f" "$_off" '%s\000' "$_banner"
}

# expect_id <name> <file> <want>
expect_id() {
	got=$(sh "$SUT" "$2" 2>&1); rc=$?
	if [ "$rc" -eq 0 ] && [ "$got" = "$3" ]; then ok "$1"; else no "$1" "rc=$rc got '$got', want '$3'"; fi
}

# expect_refusal <name> <file> <message-fragment>
expect_refusal() {
	got=$(sh "$SUT" "$2" 2>&1 >/dev/null); rc=$?
	if [ "$rc" -ne 1 ]; then no "$1" "exit $rc, want 1"; return; fi
	case "$got" in *"$3"*) ok "$1" ;; *) no "$1" "message '$got' lacks '$3'" ;; esac
}

bzimage "$W/synthetic" 13000 '6.12.112 (builder@buildhost) #1 SMP PREEMPT Sat Oct  3 01:02:03 UTC 2026'
expect_id "synthetic bzImage: release plus the version from ' #', spacing kept" "$W/synthetic" \
	'6.12.112 #1 SMP PREEMPT Sat Oct  3 01:02:03 UTC 2026'

bzimage "$W/field-2026.10.3" 14944 '6.12.94 (builder@buildhost) #0 SMP Mon Jun 29 12:59:20 2026'
legacy=$(cat "$LEGACY_ID_FILE")
expect_id "2026.10.3 field kernel header gives the pinned legacy id" "$W/field-2026.10.3" "$legacy"
if [ "$legacy" = '6.12.94 #0 SMP Mon Jun 29 12:59:20 2026' ]; then
	ok "image/legacy-kernel-id is the measured 2026.10.3 uname -r + uname -v"
else
	no "image/legacy-kernel-id is the measured 2026.10.3 uname -r + uname -v" "it reads '$legacy'"
fi

head -c 4096 /dev/zero > "$W/zeros"
expect_refusal "a file with no HdrS header is refused" "$W/zeros" "not an x86 bzImage"

bzimage "$W/no-version" 13000 '6.12.112 (builder@buildhost)'
expect_refusal "a header string with no ' #' version is refused" "$W/no-version" "no kernel identity"

expect_refusal "a missing file is refused" "$W/absent" "no such file"

printf '\nkernel-id: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
