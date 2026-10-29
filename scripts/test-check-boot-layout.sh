#!/bin/sh
#
# test-check-boot-layout.sh — fixture tests for scripts/check-boot-layout.sh
# (geekdojo/geekdojo-brain#893, TC-893-14).
#
# The check is the build's only defence against publishing a release that
# boots the wrong kernel, or none. Its pass on a real build is in the build
# job's log; here each way a release can be wrong is built as a fixture — a
# real xz squashfs and a real GPT disk with a FAT ESP — and the check must
# fail on it with exit 1, naming the cause. A consistent release must pass.
#
# The grub-fstest case is real too: the same payload in an lz4 squashfs, which
# unsquashfs reads and GRUB's squash4 does not, so GRUB's reader genuinely
# misses. The fixture kernel is a synthetic bzImage setup header; the legacy
# kernel and modules are fixture bytes with fixture pins
# (RASPUTIN_LEGACY_PINS, RASPUTIN_LEGACY_KERNEL_PIN), since the real 2026.10.3
# files cannot be checked in.
#
# Needs mksquashfs, unsquashfs, sfdisk, jq, mtools and grub-fstest. A missing
# tool is a failure, not a skip (TEST-REAL): CI installs them before this runs.
#
# Usage: sh scripts/test-check-boot-layout.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/scripts/check-boot-layout.sh"

for t in mksquashfs unsquashfs sfdisk jq mformat mcopy mmd mdir grub-fstest sha256sum bash; do
	command -v "$t" >/dev/null 2>&1 || { echo "test-check-boot-layout: $t is not installed" >&2; exit 1; }
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

# stage <dir> — the trees of a consistent release: the rootfs, the ESP, the
# pins, and the GPT layout (names of partitions 1..4).
stage() {
	d=$1
	rm -rf "$d"
	mkdir -p "$d/tree/boot/legacy-kmods/6.12.94" "$d/tree/lib/modules/$REL" \
		"$d/esp/boot/grub" "$d/esp/EFI/BOOT"
	bzimage "$d/tree/boot/vmlinuz" "$REL (builder@buildhost) #0 SMP Sun Oct 25 10:00:00 2026"
	printf '%s\n' "$ID" > "$d/tree/boot/kernel-id"
	printf 'fixture grub efi\n' > "$d/tree/boot/bootx64.efi"
	cp "$ROOT/image/grub.cfg" "$d/tree/boot/grub.cfg"
	cp "$ROOT/image/legacy-kernel-id" "$d/tree/boot/legacy-kmods/kernel-id"
	for m in $MODS; do printf 'fixture %s\n' "$m" > "$d/tree/boot/legacy-kmods/6.12.94/$m"; done
	( cd "$d/tree/boot/legacy-kmods/6.12.94" && for m in $MODS; do sha256sum "$m"; done ) > "$d/pins"
	echo fixture > "$d/tree/lib/modules/$REL/modules.builtin"
	echo fixture > "$d/tree/etc-placeholder"
	cp "$d/tree/boot/bootx64.efi" "$d/esp/EFI/BOOT/bootx64.efi"
	cp "$ROOT/image/grub.cfg" "$d/esp/boot/grub/grub.cfg"
	printf 'fixture legacy kernel\n' > "$d/esp/boot/vmlinuz"
	( cd "$d/esp/boot" && sha256sum vmlinuz ) > "$d/kpin"
	printf 'esp\nseed\nrootfs-0\nrootfs-1\n' > "$d/names"
	COMP="-comp xz -Xbcj x86"
}

# pack <dir> — the rootfs squashfs and a GPT disk whose partitions carry the
# names in names, the first a FAT holding esp/.
pack() {
	d=$1
	# shellcheck disable=SC2086 # COMP is one option per word
	mksquashfs "$d/tree" "$d/rootfs" $COMP -all-root -no-xattrs -noappend -no-progress >/dev/null || return 1
	rm -f "$d/disk.img"
	truncate -s 40M "$d/disk.img"
	{
		echo 'label: gpt'
		n=0
		while read -r name; do
			n=$((n + 1))
			if [ "$n" -eq 1 ]; then
				echo "start=2048, size=40960, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=\"$name\""
			else
				echo "size=4096, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=\"$name\""
			fi
		done < "$d/names"
	} | sfdisk -q "$d/disk.img" || return 1
	img="$d/disk.img@@$((2048 * 512))"
	mformat -i "$img" -T 40960 -h 2 -s 32 :: || return 1
	mcopy -s -i "$img" "$d/esp/boot" "$d/esp/EFI" :: || return 1
}

# check <name> <dir> [fragment] — no fragment: must pass; else must exit 1 naming it.
check() {
	_n=$1 _d=$2 _frag=${3:-}
	pack "$_d" || { no "$_n" "fixture could not be built"; return; }
	RASPUTIN_LEGACY_PINS="$_d/pins" RASPUTIN_LEGACY_KERNEL_PIN="$_d/kpin" \
		bash "$SUT" "$_d/disk.img" "$_d/rootfs" > "$_d/out.txt" 2>&1
	rc=$?
	if [ -z "$_frag" ]; then
		if [ "$rc" -eq 0 ]; then ok "$_n"; else no "$_n" "exit $rc: $(cat "$_d/out.txt")"; fi
		return
	fi
	if [ "$rc" -ne 1 ]; then no "$_n" "exit $rc, want 1 naming '$_frag': $(cat "$_d/out.txt")"; return; fi
	if grep -qF -- "$_frag" "$_d/out.txt"; then ok "$_n"; else no "$_n" "exit 1 but no '$_frag' in: $(cat "$_d/out.txt")"; fi
}

D="$W/case"

# TC-893-14: a good fixture passes.
stage "$D"
check "a consistent release passes" "$D"

# TC-893-14: an extra payload file.
stage "$D"; echo x > "$D/tree/boot/vmlinuz-A"
check "an extra file in the rootfs's /boot fails" "$D" "+/boot/vmlinuz-A"

# TC-893-14: a missing payload file.
stage "$D"; rm "$D/tree/boot/bootx64.efi"
check "a missing /boot/bootx64.efi fails" "$D" "-/boot/bootx64.efi"

# TC-893-14: vmlinuz-A or vmlinuz-B on the ESP.
stage "$D"; cp "$D/tree/boot/vmlinuz" "$D/esp/boot/vmlinuz-A"
check "a vmlinuz-A on the ESP fails" "$D" "the ESP has a boot/vmlinuz-A"
stage "$D"; cp "$D/tree/boot/vmlinuz" "$D/esp/boot/vmlinuz-B"
check "a vmlinuz-B on the ESP fails" "$D" "the ESP has a boot/vmlinuz-B"

# TC-893-14: a shared kernel off the legacy pin (here: this build's kernel).
stage "$D"; cp "$D/tree/boot/vmlinuz" "$D/esp/boot/vmlinuz"
check "a shared kernel off the legacy pin fails" "$D" "the ESP's shared boot/vmlinuz has sha256"

# TC-893-14: ESP EFI differing from the payload EFI.
stage "$D"; echo drift >> "$D/esp/EFI/BOOT/bootx64.efi"
check "an ESP EFI differing from the payload EFI fails" "$D" "EFI/BOOT/bootx64.efi differs from the rootfs's /boot/bootx64.efi"

# TC-893-14: ESP grub.cfg differing from the payload's.
stage "$D"; echo '# drift' >> "$D/esp/boot/grub/grub.cfg"
check "an ESP grub.cfg differing from the payload fails" "$D" "the ESP's boot/grub/grub.cfg differs from the rootfs's /boot/grub.cfg"

# TC-893-14: the payload grub.cfg (and the ESP's with it) differing from image/grub.cfg.
stage "$D"; echo '# drift' >> "$D/tree/boot/grub.cfg"; cp "$D/tree/boot/grub.cfg" "$D/esp/boot/grub/grub.cfg"
check "a grub.cfg differing from image/grub.cfg fails" "$D" "the rootfs's /boot/grub.cfg differs from image/grub.cfg"

# TC-893-14: GPT partitions 3 and 4 not rootfs-0 and rootfs-1.
stage "$D"; printf 'esp\nseed\nrootfs-1\nrootfs-0\n' > "$D/names"
check "swapped partitions 3 and 4 fail" "$D" "GPT partition 3 is named 'rootfs-1', want 'rootfs-0'"

# TC-893-14: kernel-id disagreeing with the kernel.
stage "$D"; printf '%s\n' "$REL #0 SMP Sat Oct 24 10:00:00 2026" > "$D/tree/boot/kernel-id"
check "a kernel-id that does not match the kernel fails" "$D" "/boot/kernel-id says"

# TC-893-14: two /lib/modules trees.
stage "$D"; mkdir -p "$D/tree/lib/modules/6.12.94"; echo x > "$D/tree/lib/modules/6.12.94/modules.builtin"
check "two /lib/modules trees fail" "$D" "/lib/modules holds 2 trees"

# TC-893-14: a grub-fstest cmp miss — GRUB cannot read an lz4 squashfs.
stage "$D"; COMP="-comp lz4"
check "a rootfs GRUB cannot read back fails the grub-fstest check" "$D" "grub-fstest cannot read /boot/vmlinuz back"

printf '\ncheck-boot-layout: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
