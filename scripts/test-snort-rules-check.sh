#!/usr/bin/env bash
#
# test-snort-rules-check.sh — functional test for scripts/rasputin-snort-rules-check.sh.
#
# WHY A FUNCTIONAL TEST
#   The rules check is a gate on every image build, and a gate that cannot fail
#   is worse than none. Three of snort-mgr's paths exit 0 without checking any
#   rules (see the script's header), so a syntax check or a mock proves nothing.
#   This runs the REAL check against a REAL released image and proves both
#   directions: the image's own rules pass, and a broken rule, an empty ruleset
#   and a missing partition each fail with the right exit code.
#
# THE IMAGE
#   Pass a firewall A/B disk image (`rasputin-fw-n100-<version>-ab.img.gz`, from
#   https://github.com/geekdojo/rasputin-openwrt-firewall/releases) as the first
#   argument. With no argument the latest STABLE release's image is downloaded
#   with `gh release download` (about 60 MB) into a temporary directory.
#
# WHERE IT RUNS
#   The check needs Linux on x86_64 and root. This script arranges that itself:
#     - Linux, root           runs directly
#     - Linux, not root       re-runs itself under sudo
#     - anything else (a Mac) re-runs itself in a privileged ubuntu:24.04 Docker
#                             container (linux/amd64), installing squashfs-tools
#                             and fdisk there. Needs Docker running.
#
# Usage:
#   ./scripts/test-snort-rules-check.sh [path/to/rasputin-fw-n100-<version>-ab.img.gz]

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/scripts/rasputin-snort-rules-check.sh"

IMAGE="${1:-}"
DL_DIR=""
if [ -z "$IMAGE" ]; then
	command -v gh >/dev/null 2>&1 || { echo "no image given and gh is not installed (https://cli.github.com)" >&2; exit 2; }
	DL_DIR="$(mktemp -d -t rasputin-rules-check-img.XXXXXX)"
	trap 'rm -rf "$DL_DIR"' EXIT
	tag="$(gh release list --repo geekdojo/rasputin-openwrt-firewall --exclude-pre-releases --limit 1 --json tagName --jq '.[0].tagName')" \
		|| { echo "could not list releases" >&2; exit 2; }
	[ -n "$tag" ] || { echo "no stable release found" >&2; exit 2; }
	echo "downloading the $tag A/B image"
	gh release download "$tag" --repo geekdojo/rasputin-openwrt-firewall \
		--pattern "rasputin-fw-n100-${tag}-ab.img.gz" --dir "$DL_DIR" \
		|| { echo "download failed" >&2; exit 2; }
	IMAGE="$DL_DIR/rasputin-fw-n100-${tag}-ab.img.gz"
fi
[ -f "$IMAGE" ] || { echo "image not found: $IMAGE" >&2; exit 2; }
IMAGE="$(cd "$(dirname "$IMAGE")" && pwd)/$(basename "$IMAGE")"

if [ "$(uname -s)" != Linux ]; then
	command -v docker >/dev/null 2>&1 || { echo "not Linux and docker is not installed" >&2; exit 2; }
	echo "not Linux: re-running inside a privileged linux/amd64 ubuntu:24.04 container"
	docker run --rm --privileged --platform linux/amd64 \
		-v "$ROOT":/src:ro -v "$(dirname "$IMAGE")":/img:ro \
		ubuntu:24.04 bash -c '
			set -e
			export DEBIAN_FRONTEND=noninteractive
			apt-get update -qq -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 >/dev/null
			apt-get install -y -qq --no-install-recommends -o DPkg::Lock::Timeout=120 \
				squashfs-tools fdisk gzip util-linux >/dev/null
			exec /src/scripts/test-snort-rules-check.sh "/img/$1"
		' _ "$(basename "$IMAGE")"
	exit $?
fi
if [ "$(id -u)" != 0 ]; then
	echo "not root: re-running under sudo"
	sudo "$0" "$IMAGE"
	exit $?
fi

fail=0
pass=0
ok()  { printf '  ✓ %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  ✗ %s\n' "$*" >&2; fail=$((fail + 1)); }

WORK="$(mktemp -d -t rasputin-rules-check-test.XXXXXX)"
cleanup() { rm -rf "$WORK"; [ -z "$DL_DIR" ] || rm -rf "$DL_DIR"; }
trap cleanup EXIT

# run NAME EXPECTED_EXIT [env/args...] — run the check, keep its output, compare exit.
run() {
	local name="$1" want="$2" got=0
	shift 2
	echo "== $name"
	"$@" > "$WORK/$name.log" 2>&1 || got=$?
	sed 's/^/    | /' "$WORK/$name.log" | grep -E 'rules check:|::error::|ERROR:|FATAL:|successfully validated' || true
	if [ "$got" -eq "$want" ]; then
		ok "$name: exit $got"
	else
		bad "$name: exit $got, want $want"
	fi
}

# expect_log NAME REGEX DESCRIPTION
expect_log() {
	if grep -Eq "$2" "$WORK/$1.log"; then ok "$1: $3"; else bad "$1: $3 (no match for /$2/)"; fi
}

# 1. The image as released, straight from the .gz, rootfs-0 by name: must pass.
run baked-rules 0 "$CHECK" "$IMAGE"
expect_log baked-rules 'rules check: OK — [0-9]+ rules loaded \([1-9][0-9]* from' "reports rules actually loaded"

# Decompress once for the remaining cases, and pull the baked rules out to derive
# the broken ruleset from the real one.
gunzip -c "$IMAGE" > "$WORK/image.img" 2>/dev/null
rc=$?
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then echo "gunzip failed ($rc)" >&2; exit 2; fi
start="$(sfdisk -d "$WORK/image.img" | grep -F 'name="rootfs-0"' | sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
index="$(sfdisk -d "$WORK/image.img" | grep -E '^[^ ]+[[:space:]]*:[[:space:]]*start=' | grep -nF 'name="rootfs-0"' | cut -d: -f1)"
unsquashfs -no-progress -o "$((start * 512))" -d "$WORK/rootfs" "$WORK/image.img" \
	etc/snort/rules/snort3-community.rules >/dev/null \
	|| { echo "could not extract the baked rules" >&2; exit 2; }
cp "$WORK/rootfs/etc/snort/rules/snort3-community.rules" "$WORK/good.rules"
rm -rf "$WORK/rootfs"

# 2. Same rootfs selected by partition INDEX (the path the canary's combined-efi
#    image takes) — must pass too.
run by-index 0 env ROOTFS_PARTITION="$index" "$CHECK" "$WORK/image.img"

# 3. The real rules plus one rule using a keyword Snort does not have: must fail.
{ cat "$WORK/good.rules"; echo 'alert tcp any any -> any any ( msg:"rasputin functional test: invented keyword"; rasputin_no_such_keyword; sid:9990001; rev:1; )'; } > "$WORK/broken.rules"
run broken-rule 1 "$CHECK" "$WORK/image.img" --rules "$WORK/broken.rules"
expect_log broken-rule 'unknown rule keyword: rasputin_no_such_keyword' "Snort names the invented keyword"

# 4. An empty ruleset: snort-mgr itself exits 0 on this (built-in rules only), so
#    the check must fail it.
: > "$WORK/empty.rules"
run empty-rules 1 "$CHECK" "$WORK/image.img" --rules "$WORK/empty.rules"
expect_log empty-rules 'no active rules' "explains the empty ruleset"

# 5. A partition that does not exist: could-not-run, not a rules verdict.
run no-partition 2 env ROOTFS_PARTITION=no-such-partition "$CHECK" "$WORK/image.img"

echo
if [ "$fail" -eq 0 ]; then
	echo "snort rules check: $pass check(s) passed"
	exit 0
fi
echo "snort rules check: $fail check(s) FAILED, $pass passed" >&2
exit 1
