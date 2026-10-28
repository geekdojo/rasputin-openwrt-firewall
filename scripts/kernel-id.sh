#!/bin/sh
#
# kernel-id.sh — print the identity of an x86 kernel image, in the exact form
# a running kernel reports it: "$(uname -r) $(uname -v)", one line.
#
#   usage: scripts/kernel-id.sh <bzImage>
#
# The identity is the release (UTS_RELEASE, "6.12.94") plus the build version
# (UTS_VERSION, "#0 SMP Mon Jun 29 12:59:20 2026"). The release alone is not
# enough: two builds of one release can differ in config, and the build version
# carries the build timestamp, so it tells them apart.
#
# Ported from the x86 branch of rasputin-os scripts/kernel-id.sh
# (geekdojo/geekdojo-brain#807); the firewall has no arm64 kernel.
#
# Callers (geekdojo/geekdojo-brain#888):
#   - scripts/assemble-ab-image.sh writes the build kernel's id into the
#     rootfs as /boot/kernel-id, which the kernel-match guard compares with
#     uname on every boot.
#   - scripts/check-bundle-kernel.sh checks that file against the kernel the
#     rootfs carries.
#   - test/update-smoke.sh compares the kernel a VM booted with the build's id.
#
# Format: an x86 bzImage has "HdrS" at 0x202. The setup header's
# kernel_version field (u16 at 0x20E) points, +0x200, at the NUL-terminated
# string "R (user@host) V". V starts at the first " #" (UTS_VERSION always
# begins "#<n>").
#
# Exit: 0 with the id on stdout; 1 when the file is not a bzImage or carries
# no readable identity.
set -eu

f="${1:?usage: kernel-id.sh <bzImage>}"
[ -f "$f" ] || { echo "kernel-id: no such file: $f" >&2; exit 1; }

if [ "$(dd if="$f" bs=1 skip=514 count=4 2>/dev/null | tr -d '\000')" != "HdrS" ]; then
	echo "kernel-id: $f is not an x86 bzImage (no HdrS setup header at 0x202)" >&2
	exit 1
fi

# kernel_version: two bytes, little-endian, read into named fields.
read -r lo hi extra <<FIELD
$(od -An -t u1 -j 526 -N 2 "$f")
FIELD
case "${lo:-x}${hi:-x}${extra:-}" in
	*[!0-9]*) echo "kernel-id: $f: unreadable kernel_version field" >&2; exit 1 ;;
esac
off=$(( lo + hi * 256 + 512 ))
# sed, not head: head exits after one line, and a tr still writing then gets
# EPIPE, which a shell that ignores SIGPIPE (GitHub Actions runners do) turns
# into "tr: write error: Broken pipe" on stderr.
text="$(dd if="$f" bs=1 skip="$off" count=512 2>/dev/null | tr '\000' '\n' | sed -n 1p)"
release="${text%% *}"

case "$text" in
	*" #"*) ;;
	*) echo "kernel-id: $f: no kernel identity found (read '$text')" >&2; exit 1 ;;
esac
version="#${text#* #}"
[ -n "$release" ] || { echo "kernel-id: $f: empty kernel release" >&2; exit 1; }
printf '%s %s\n' "$release" "$version"
