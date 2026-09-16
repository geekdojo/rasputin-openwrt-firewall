#!/usr/bin/env bash
#
# rasputin-snort-rules-check.sh — prove the Snort rules baked into a built
# firewall image actually parse under the Snort that image ships.
#
# WHY (geekdojo/geekdojo-brain#208)
#   The SHA pin proves we got the bytes we meant to get; it proves nothing about
#   whether Snort accepts them. The image's Snort version floats with the OpenWrt
#   feed (packages.txt names an unversioned `snort3`), so the only honest check
#   runs the image's OWN snort-mgr against the image's OWN rules, on the image
#   just built. The failure it exists for already happened once: ET Open rules
#   that Snort 3 rejected with `FATAL: see prior 212249 errors`, found on
#   hardware. A human reviewing a re-pin never caught unparseable rules; this does.
#
# WHAT IT DOES
#   1. Takes the rootfs out of the image — by default the GPT partition named
#      rootfs-0 of the A/B disk (`*-ab.img.gz`); ROOTFS_PARTITION selects
#      another name, or a 1-based index in partition-table order (the canary's
#      single-rootfs combined-efi image uses 2).
#   2. unsquashfs, then mounts proc, /dev and a tmpfs on /tmp (/var links there)
#      so the image's userland runs under chroot.
#   3. Applies the image's own Snort UCI settings: every `set snort.*` line of
#      /etc/uci-defaults/99-rasputin as shipped in the image, exactly as first
#      boot would apply them.
#   4. Runs `snort-mgr -v check` in the chroot.
#
#   It FAILS (exit 1) when snort-mgr exits non-zero, AND ALSO when snort-mgr
#   exits 0 without proving anything. Three ways it does that, all verified on
#   the 2026.09.3 image:
#     - without -v, `snort-mgr check` generates a config WITHOUT rules
#       (_SNORT_WITHOUT_RULES=1), so it passes on any ruleset. Always -v here.
#     - with snort.snort.manual=1 (the package default) `check` returns 0
#       before running Snort at all. manual must read 0 after step 3.
#     - an empty or missing rules file validates clean: Snort still loads its
#       219 built-in rules. So the rules directory must hold active rules, and
#       "total rules loaded" must be at least that many.
#   A bare `snort -c snort.lua -R … -T` is NOT a substitute: it fails on
#   variables that only snort-mgr's generated config defines.
#
# KEEP IN STEP WITH THE MIRROR
#   geekdojo/rasputin-snort3-rules-mirror runs an equivalent check before it
#   publishes a new upstream tarball, inside the latest stable firewall image.
#   The two MUST stay behaviourally identical — same UCI settings, same
#   `snort-mgr -v check`, same pass/fail criteria above — or the mirror can
#   accept rules this build then rejects (or the reverse). Change both together.
#
# NEEDS: Linux on x86_64 (the image's binaries run natively), root (mount,
#   chroot), and sfdisk (fdisk), unsquashfs (squashfs-tools), gunzip.
#
# EXIT: 0 rules parse; 1 rules check failed; 2 could not run the check.
#
# Usage:
#   sudo ./scripts/rasputin-snort-rules-check.sh <image.img[.gz]> [--rules <file.rules>]
#     --rules  replace the image's rules with this file before checking (the
#              functional test uses it to prove a broken rule fails).
#   sudo ROOTFS_PARTITION=2 ./scripts/rasputin-snort-rules-check.sh openwrt-…-combined-efi.img.gz
#
# Functional test: scripts/test-snort-rules-check.sh

set -euo pipefail

die2() { echo "::error::rules check could not run: $*" >&2; exit 2; }

IMAGE=""
RULES_OVERRIDE=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--rules) [ "$#" -ge 2 ] || die2 "--rules needs a file"; RULES_OVERRIDE="$2"; shift 2 ;;
		-*) die2 "unknown option $1" ;;
		*) [ -z "$IMAGE" ] || die2 "more than one image given"; IMAGE="$1"; shift ;;
	esac
done
[ -n "$IMAGE" ] || die2 "usage: $0 <image.img[.gz]> [--rules <file.rules>]"
[ -f "$IMAGE" ] || die2 "image not found: $IMAGE"
[ -z "$RULES_OVERRIDE" ] || [ -f "$RULES_OVERRIDE" ] || die2 "rules file not found: $RULES_OVERRIDE"
PARTITION="${ROOTFS_PARTITION:-rootfs-0}"

[ "$(uname -s)" = Linux ] || die2 "needs Linux (got $(uname -s))"
[ "$(uname -m)" = x86_64 ] || die2 "needs an x86_64 host to run the image's binaries (got $(uname -m))"
[ "$(id -u)" = 0 ] || die2 "needs root for mount + chroot (run it with sudo)"
for tool in sfdisk unsquashfs gunzip chroot mount umount mountpoint; do
	command -v "$tool" >/dev/null 2>&1 || die2 "missing tool: $tool"
done

WORK="$(mktemp -d -t rasputin-rules-check.XXXXXX)"
ROOT="$WORK/rootfs"
MOUNTS=()

cleanup() {
	local rc=$? m busy=0 i
	for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
		m="${MOUNTS[$i]}"
		umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
	done
	# Never rm -rf across a live bind mount of /dev. If anything is still
	# mounted, leave the directory and say so rather than risk the host.
	for m in "${MOUNTS[@]}"; do
		if mountpoint -q "$m"; then
			echo "::warning::still mounted, leaving $WORK in place: $m" >&2
			busy=1
		fi
	done
	[ "$busy" = 1 ] || rm -rf "$WORK"
	exit "$rc"
}
trap cleanup EXIT

# --- 1. image -> rootfs squashfs ---------------------------------------------
img="$IMAGE"
case "$IMAGE" in
	*.gz)
		img="$WORK/image.img"
		# OpenWrt images carry trailing NUL padding, so gunzip exits 2 ("trailing
		# garbage ignored") after decompressing correctly — tolerated here, as in
		# release.yml. Anything else is a real failure.
		rc=0
		gunzip -c "$IMAGE" > "$img" || rc=$?
		if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
			die2 "gunzip exited $rc on $IMAGE"
		fi
		;;
esac

table="$(sfdisk -d "$img" 2>/dev/null)" || die2 "sfdisk cannot read a partition table from $IMAGE"
parts="$(printf '%s\n' "$table" | grep -E '^[^ ]+[[:space:]]*:[[:space:]]*start=' || true)"
if printf '%s' "$PARTITION" | grep -Eq '^[0-9]+$'; then
	line="$(printf '%s\n' "$parts" | sed -n "${PARTITION}p")"
else
	line="$(printf '%s\n' "$parts" | grep -F "name=\"$PARTITION\"" || true)"
	[ "$(printf '%s\n' "$line" | grep -c .)" -le 1 ] || die2 "more than one partition named $PARTITION"
fi
[ -n "$line" ] || { printf '%s\n' "$table" >&2; die2 "no partition '$PARTITION' in $IMAGE"; }
start="$(printf '%s\n' "$line" | sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
[ -n "$start" ] || die2 "could not parse the start of partition '$PARTITION'"
offset=$((start * 512))
magic="$(dd if="$img" iflag=skip_bytes skip="$offset" bs=4 count=1 status=none)"
[ "$magic" = "hsqs" ] || die2 "partition '$PARTITION' (sector $start) is not squashfs"
echo "rules check: $IMAGE partition '$PARTITION' at sector $start"

unsquashfs -no-progress -o "$offset" -d "$ROOT" "$img" >/dev/null \
	|| die2 "unsquashfs failed on partition '$PARTITION'"
rm -f "$WORK/image.img"

[ -x "$ROOT/usr/bin/snort-mgr" ] || die2 "image has no /usr/bin/snort-mgr — is snort3 still in packages.txt?"
[ -f "$ROOT/etc/uci-defaults/99-rasputin" ] || die2 "image has no /etc/uci-defaults/99-rasputin"

# --- 2. rules under test -------------------------------------------------------
RULES_DIR="$ROOT/etc/snort/rules"
if [ -n "$RULES_OVERRIDE" ]; then
	mkdir -p "$RULES_DIR"
	find "$RULES_DIR" -maxdepth 1 -name '*.rules' -type f -delete
	cp "$RULES_OVERRIDE" "$RULES_DIR/snort3-community.rules"
	echo "rules check: rules replaced with $RULES_OVERRIDE"
fi
active_rules=0
if [ -d "$RULES_DIR" ]; then
	active_rules="$(find "$RULES_DIR" -maxdepth 1 -name '*.rules' -type f -exec cat {} + \
		| grep -cE '^[[:space:]]*(alert|block|drop|log|pass|react|reject|rewrite|sdrop)[[:space:]]' || true)"
fi
echo "rules check: $active_rules active rule line(s) in /etc/snort/rules"
if [ "${active_rules:-0}" -eq 0 ]; then
	echo "::error::no active rules in the image's /etc/snort/rules — an empty ruleset validates clean (Snort still loads its built-in rules), so it fails here" >&2
	exit 1
fi

# --- 3. chroot mounts + the image's Snort UCI settings -----------------------
mount -t proc proc "$ROOT/proc" || die2 "mount proc failed"
MOUNTS+=("$ROOT/proc")
mount --bind /dev "$ROOT/dev" || die2 "bind-mount /dev failed"
MOUNTS+=("$ROOT/dev")
mount -t tmpfs -o size=256m tmpfs "$ROOT/tmp" || die2 "mount tmpfs on /tmp failed"
MOUNTS+=("$ROOT/tmp")

uci_lines="$(grep -E '^[[:space:]]*set snort\.' "$ROOT/etc/uci-defaults/99-rasputin" | sed 's/^[[:space:]]*//' || true)"
[ -n "$uci_lines" ] || die2 "no 'set snort.*' lines in the image's 99-rasputin — the Snort UCI block moved or was removed"
echo "rules check: applying the image's Snort UCI settings:"
printf '%s\n' "$uci_lines" | sed 's/^/  /'
printf '%s\ncommit snort\n' "$uci_lines" | chroot "$ROOT" /sbin/uci -q batch \
	|| die2 "uci batch failed in the image chroot"
manual="$(chroot "$ROOT" /sbin/uci -q get snort.snort.manual || true)"
if [ "$manual" != "0" ]; then
	echo "::error::snort.snort.manual is '$manual' after applying 99-rasputin — with manual != 0, 'snort-mgr check' returns 0 without running Snort, so nothing would be checked" >&2
	exit 1
fi

# --- 4. snort-mgr -v check -------------------------------------------------------
LOG="$WORK/snort-mgr-check.log"
t0="$(date +%s)"
rc=0
chroot "$ROOT" /usr/bin/snort-mgr -v check > "$LOG" 2>&1 || rc=$?
t1="$(date +%s)"
loaded="$(sed -n 's/^[[:space:]]*total rules loaded:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$LOG" | tail -n 1)"
echo "rules check: snort-mgr -v check exit $rc, total rules loaded ${loaded:-none}, $((t1 - t0))s"

if [ "$rc" -ne 0 ]; then
	echo "::error::Snort rejected the rules baked into this image (snort-mgr -v check exit $rc)" >&2
	grep -E '^(ERROR|FATAL)' "$LOG" | head -n 40 >&2 || true
	echo "----- last 40 lines of snort-mgr output -----" >&2
	tail -n 40 "$LOG" >&2
	exit 1
fi
if [ -z "$loaded" ] || [ "$loaded" -lt "$active_rules" ]; then
	echo "::error::snort-mgr check exited 0 but loaded ${loaded:-no} rules for $active_rules active rule line(s) — the rules were not actually checked" >&2
	tail -n 40 "$LOG" >&2
	exit 1
fi
grep -E 'successfully validated' "$LOG" || true
echo "rules check: OK — $loaded rules loaded ($active_rules from /etc/snort/rules)"
