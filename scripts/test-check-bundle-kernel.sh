#!/bin/sh
#
# test-check-bundle-kernel.sh — fixture tests for scripts/check-bundle-kernel.sh
# (geekdojo/geekdojo-brain#888, TC-888-14 and the ESP layout half of TC-888-16).
#
# The check is the build's only defence against publishing another dev.176: a
# rootfs that will boot under a kernel it was not built for. Its pass on a real
# build is in the build job's log; here each way the release can be wrong is
# built as a fixture — a real squashfs and a real GPT disk with a FAT ESP —
# and the check must fail on it, naming the cause:
#
#   pass            a consistent release passes
#   no-kernel-id    /boot/kernel-id missing
#   esp-a, esp-b    the ESP's vmlinuz-A or vmlinuz-B differs from the rootfs's kernel
#   shared-vmlinuz  the ESP still has a shared boot/vmlinuz
#   wrong-id        /boot/kernel-id differs from kernel-id.sh on the kernel
#   two-trees       /lib/modules holds two trees
#   grub-rootfs     the rootfs's /boot/grub.cfg differs from image/grub.cfg
#   grub-esp        the ESP's grub.cfg differs from image/grub.cfg
#   ko-sha          a legacy module's sha256 differs from its pin
#   legacy-id       the legacy kernel-id is not image/legacy-kernel-id
#
# The fixture kernel is a synthetic bzImage setup header; the legacy modules
# are fixture bytes with fixture pins (RASPUTIN_LEGACY_PINS), since the real
# 2026.10.3 modules cannot be checked in.
#
# Needs mksquashfs, unsquashfs, sfdisk and mtools. A missing tool is a
# failure, not a skip (TEST-REAL): CI installs them before this runs.
#
# Usage: sh scripts/test-check-bundle-kernel.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/scripts/check-bundle-kernel.sh"

for t in mksquashfs unsquashfs sfdisk mformat mcopy mmd mdir sha256sum bash; do
	command -v "$t" >/dev/null 2>&1 || { echo "test-check-bundle-kernel: $t is not installed" >&2; exit 1; }
done

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export MTOOLS_SKIP_CHECK=1

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2" >&2; }

MODS="fat.ko vfat.ko nls_cp437.ko nls_iso8859-1.ko nls_utf8.ko"
REL=6.12.112
ID="$REL #0 SMP Sun Oct 25 10:00:00 2026"

# bzimage <file> <banner> — a synthetic x86 setup header (see test-kernel-id.sh).
bzimage() {
	dd if=/dev/zero of="$1" bs=1024 count=32 2>/dev/null
	printf 'HdrS' | dd of="$1" bs=1 seek=514 conv=notrunc 2>/dev/null
	# kernel_version = 13000 - 512 = 12488 = 0x30C8, little-endian
	printf '\310\060' | dd of="$1" bs=1 seek=526 conv=notrunc 2>/dev/null
	printf '%s\000' "$2" | dd of="$1" bs=1 seek=13000 conv=notrunc 2>/dev/null
}

# stage <dir> — the trees of a consistent release.
stage() {
	d=$1
	rm -rf "$d"
	mkdir -p "$d/tree/boot/legacy-kmods/6.12.94" "$d/tree/lib/modules/$REL" "$d/esp/boot/grub"
	bzimage "$d/tree/boot/vmlinuz" "$REL (builder@buildhost) #0 SMP Sun Oct 25 10:00:00 2026"
	printf '%s\n' "$ID" > "$d/tree/boot/kernel-id"
	cp "$ROOT/image/grub.cfg" "$d/tree/boot/grub.cfg"
	cp "$ROOT/image/legacy-kernel-id" "$d/tree/boot/legacy-kmods/kernel-id"
	for m in $MODS; do printf 'fixture %s\n' "$m" > "$d/tree/boot/legacy-kmods/6.12.94/$m"; done
	( cd "$d/tree/boot/legacy-kmods/6.12.94" && for m in $MODS; do sha256sum "$m"; done ) > "$d/pins"
	echo fixture > "$d/tree/lib/modules/$REL/modules.builtin"
	cp "$d/tree/boot/vmlinuz" "$d/esp/boot/vmlinuz-A"
	cp "$d/tree/boot/vmlinuz" "$d/esp/boot/vmlinuz-B"
	cp "$ROOT/image/grub.cfg" "$d/esp/boot/grub/grub.cfg"
}

# pack <dir> — the rootfs squashfs and a GPT disk whose "esp" partition is a
# FAT holding esp/.
pack() {
	d=$1
	mksquashfs "$d/tree" "$d/rootfs" -all-root -no-xattrs -noappend -no-progress >/dev/null || return 1
	truncate -s 24M "$d/disk.img"
	printf 'label: gpt\nstart=2048, size=40960, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"\n' \
		| sfdisk -q "$d/disk.img" || return 1
	img="$d/disk.img@@$((2048 * 512))"
	mformat -i "$img" -T 40960 -h 2 -s 32 :: || return 1
	mcopy -s -i "$img" "$d/esp/boot" :: || return 1
}

# check <name> <dir> [fragment] — no fragment: must pass; else must fail naming it.
check() {
	_n=$1 _d=$2 _frag=${3:-}
	pack "$_d" || { no "$_n" "fixture could not be built"; return; }
	RASPUTIN_LEGACY_PINS="$_d/pins" bash "$SUT" "$_d/disk.img" "$_d/rootfs" > "$_d/out.txt" 2>&1
	rc=$?
	if [ -z "$_frag" ]; then
		if [ "$rc" -eq 0 ]; then ok "$_n"; else no "$_n" "exit $rc: $(cat "$_d/out.txt")"; fi
		return
	fi
	if [ "$rc" -eq 0 ]; then no "$_n" "passed, want a failure naming '$_frag'"; return; fi
	if grep -qF -- "$_frag" "$_d/out.txt"; then ok "$_n"; else no "$_n" "exit $rc but no '$_frag' in: $(cat "$_d/out.txt")"; fi
}

D="$W/case"

stage "$D"
check "a consistent release passes" "$D"

stage "$D"; rm "$D/tree/boot/kernel-id"
check "missing /boot/kernel-id fails" "$D" "the rootfs has no /boot/kernel-id"

stage "$D"; printf 'x' >> "$D/esp/boot/vmlinuz-A"
check "ESP vmlinuz-A differing from the rootfs kernel fails" "$D" "boot/vmlinuz-A differs"

stage "$D"; printf 'x' >> "$D/esp/boot/vmlinuz-B"
check "ESP vmlinuz-B differing from the rootfs kernel fails" "$D" "boot/vmlinuz-B differs"

stage "$D"; cp "$D/esp/boot/vmlinuz-A" "$D/esp/boot/vmlinuz"
check "an ESP that still has a shared vmlinuz fails" "$D" "still has a shared boot/vmlinuz"

stage "$D"; printf '%s\n' "$REL #0 SMP Sat Oct 24 10:00:00 2026" > "$D/tree/boot/kernel-id"
check "a kernel-id that does not match kernel-id.sh fails" "$D" "/boot/kernel-id says"

stage "$D"; mkdir -p "$D/tree/lib/modules/6.12.94"; echo x > "$D/tree/lib/modules/6.12.94/modules.builtin"
check "two /lib/modules trees fail" "$D" "/lib/modules holds 2 trees"

stage "$D"; echo '# drift' >> "$D/tree/boot/grub.cfg"
check "an embedded grub.cfg differing from image/grub.cfg fails" "$D" "rootfs's /boot/grub.cfg differs"

stage "$D"; echo '# drift' >> "$D/esp/boot/grub/grub.cfg"
check "an ESP grub.cfg differing from image/grub.cfg fails" "$D" "ESP's boot/grub/grub.cfg differs"

stage "$D"; echo tampered >> "$D/tree/boot/legacy-kmods/6.12.94/vfat.ko"
check "a legacy .ko whose sha differs from the pin fails" "$D" "6.12.94/vfat.ko has sha256"

stage "$D"; printf '%s\n' '6.12.94 #1 SMP Tue Jun 30 00:00:00 2026' > "$D/tree/boot/legacy-kmods/kernel-id"
check "a legacy kernel-id other than the pinned 2026.10.3 id fails" "$D" "legacy-kmods/kernel-id says"

printf '\ncheck-bundle-kernel: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
