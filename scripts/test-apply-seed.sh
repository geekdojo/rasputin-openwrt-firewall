#!/usr/bin/env bash
#
# test-apply-seed.sh — functional test of the seed → UCI → agent environment
# path, run inside a real firewall image.
#
# WHY A FUNCTIONAL TEST
#   apply-seed turns /etc/rasputin/seed.env into /etc/config/rasputin, and
#   init.d/rasputin-agent turns that into the agent's environment. Every link
#   in that chain is something a syntax check cannot see: busybox ash sourcing
#   the seed, the real `uci` accepting (or silently aborting) the batch,
#   config_get reading it back, procd_append_param handing it on. A mistake in
#   any of them builds, signs and boots cleanly — the box just never gets the
#   value. So this runs the SHIPPED userland against this checkout's files.
#
#   It was written for the bus pin (geekdojo/geekdojo-brain#448, contract:
#   docs/bus-tls-contract.md in rasputin-control-plane), and proves:
#     - a pin in the seed reaches UCI and the agent's RASPUTIN_BUS_PIN, a pin
#       computed from a real P-256 key with the contract's own openssl recipe;
#     - a seed saved on Windows (CR on the line) still applies the pin;
#     - a malformed pin fails apply-seed and leaves /etc/config/rasputin
#       exactly as it was, on a provisioned box and on a fresh one;
#     - RASPUTIN_BUS_KEY is never applied: not in UCI, not in the agent's
#       environment, and blanked in seed.env with every other line intact;
#     - a seed with no pin writes none, and does not remove a pin already held;
#       a different valid pin replaces it;
#     - sysupgrade's own file list keeps both a seeded pin (seed.env) and a
#       delivered one (agent-state/bus/pin).
#
# HOW
#   1. rootfs-0 of a firewall A/B image is unsquashed (the latest STABLE
#      release by default, downloaded with `gh`, ~60 MB; or pass one).
#   2. This checkout's files/ is copied over it — exactly what ImageBuilder
#      layers onto the package set — so the code under test is this branch's
#      and everything it calls (busybox, uci, /lib/functions.sh) is the image's.
#   3. apply-seed runs under chroot. The agent's environment is read by
#      sourcing the image's init.d/rasputin-agent with the four procd_*
#      functions stubbed to print what they are given, then calling its
#      start_service. That stub is the only thing here that is not shipped
#      code; procd itself cannot run in a chroot.
#
#   The image's /etc/rc.d link for rasputin-agent is removed, so apply-seed's
#   final `rasputin-agent restart` is skipped: there is no procd or ubus in a
#   chroot to restart anything. That step is outside what this test proves.
#
# WHERE IT RUNS
#   Linux x86_64 as root runs directly; Linux as non-root re-runs under sudo;
#   anything else (a Mac) re-runs in a privileged linux/amd64 ubuntu:24.04
#   container. Needs unsquashfs (squashfs-tools), sfdisk (fdisk), openssl.
#
# Usage:
#   ./scripts/test-apply-seed.sh [path/to/rasputin-fw-n100-<version>-ab.img.gz]

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"

IMAGE="${1:-}"
DL_DIR=""
if [ -z "$IMAGE" ]; then
	command -v gh >/dev/null 2>&1 || { echo "no image given and gh is not installed (https://cli.github.com)" >&2; exit 2; }
	DL_DIR="$(mktemp -d -t rasputin-apply-seed-img.XXXXXX)"
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
		-v "$SRC":/src:ro -v "$(dirname "$IMAGE")":/img:ro \
		ubuntu:24.04 bash -c '
			set -e
			export DEBIAN_FRONTEND=noninteractive
			apt-get update -qq -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 >/dev/null
			apt-get install -y -qq --no-install-recommends -o DPkg::Lock::Timeout=120 \
				squashfs-tools fdisk gzip util-linux openssl coreutils >/dev/null
			exec /src/scripts/test-apply-seed.sh "/img/$1"
		' _ "$(basename "$IMAGE")"
	exit $?
fi
if [ "$(id -u)" != 0 ]; then
	echo "not root: re-running under sudo"
	sudo "$0" "$IMAGE"
	exit $?
fi
[ "$(uname -m)" = x86_64 ] || { echo "needs an x86_64 host to run the image's binaries (got $(uname -m))" >&2; exit 2; }
for tool in sfdisk unsquashfs openssl timeout; do
	command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 2; }
done

fail=0
pass=0
ok()  { printf '  ✓ %s\n' "$*"; pass=$((pass + 1)); }
bad() { printf '  ✗ %s\n' "$*" >&2; fail=$((fail + 1)); }

WORK="$(mktemp -d -t rasputin-apply-seed-test.XXXXXX)"
ROOT="$WORK/rootfs"
MOUNTS=()
cleanup() {
	local i busy=0
	for ((i = ${#MOUNTS[@]} - 1; i >= 0; i--)); do
		umount "${MOUNTS[$i]}" 2>/dev/null || umount -l "${MOUNTS[$i]}" 2>/dev/null || true
	done
	# Never rm -rf across a live bind mount of /dev.
	for m in "${MOUNTS[@]}"; do
		if mountpoint -q "$m"; then
			echo "still mounted, leaving $WORK in place: $m" >&2
			busy=1
		fi
	done
	[ "$busy" = 1 ] || rm -rf "$WORK"
	[ -z "$DL_DIR" ] || rm -rf "$DL_DIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------- the image
echo "image: $IMAGE"
img="$WORK/image.img"
rc=0
gunzip -c "$IMAGE" > "$img" || rc=$?
# OpenWrt images carry trailing padding; gunzip exits 2 after a correct
# decompress ("trailing garbage ignored"), as release.yml also tolerates.
if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then echo "gunzip exited $rc" >&2; exit 2; fi
start="$(sfdisk -d "$img" | grep -F 'name="rootfs-0"' | sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
[ -n "$start" ] || { echo "no rootfs-0 partition in $IMAGE" >&2; exit 2; }
unsquashfs -no-progress -o "$((start * 512))" -d "$ROOT" "$img" >/dev/null \
	|| { echo "unsquashfs failed" >&2; exit 2; }
rm -f "$img"

for f in /sbin/uci /lib/functions.sh /bin/sh; do
	[ -e "$ROOT$f" ] || { echo "image has no $f" >&2; exit 2; }
done

# This checkout's files/, over the image's — what ImageBuilder does.
cp -a "$SRC/files/." "$ROOT/"
rm -f "$ROOT"/etc/rc.d/S*rasputin-agent "$ROOT"/etc/rc.d/K*rasputin-agent

mount -t proc proc "$ROOT/proc" && MOUNTS+=("$ROOT/proc") || { echo "mount proc failed" >&2; exit 2; }
mount --bind /dev "$ROOT/dev" && MOUNTS+=("$ROOT/dev") || { echo "bind /dev failed" >&2; exit 2; }
mount -t tmpfs -o size=64m tmpfs "$ROOT/tmp" && MOUNTS+=("$ROOT/tmp") || { echo "mount /tmp failed" >&2; exit 2; }

# ---------------------------------------------------------------- helpers
SEED="$ROOT/etc/rasputin/seed.env"
UCI="$ROOT/etc/config/rasputin"

# in_chroot CMD... — bounded: nothing here should take more than seconds, and
# a wait with no deadline is a bug.
in_chroot() { timeout 60 chroot "$ROOT" "$@"; }

# apply NAME — run apply-seed, keeping its stderr in $WORK/NAME.err; sets $APPLY_RC.
apply() {
	APPLY_RC=0
	in_chroot /usr/lib/rasputin/apply-seed > "$WORK/$1.out" 2> "$WORK/$1.err" || APPLY_RC=$?
}

# agent_env — the environment init.d/rasputin-agent hands procd, one VAR=value
# per line. Only the procd_* calls are stubbed; everything else is the image's.
agent_env() {
	in_chroot /bin/sh -c '
		procd_open_instance() { :; }
		procd_close_instance() { echo "#instance-closed"; }
		procd_set_param() { :; }
		procd_append_param() {
			[ "$1" = env ] || return 0
			shift
			for kv in "$@"; do printf "%s\n" "$kv"; done
		}
		. /etc/init.d/rasputin-agent
		start_service
	'
}

uci_get() { in_chroot /sbin/uci -q get "$1"; }

# reset — a fresh box: no UCI config, no seed.
reset() { rm -f "$UCI" "$SEED" "$SEED".tmp.*; }

base_seed() {
	cat <<'EOF'
RASPUTIN_NODE_ROLE=firewall
RASPUTIN_NODE_ID=fw-test-1
RASPUTIN_CLUSTER_ID=example-cluster
RASPUTIN_NATS_URL=nats://example-cluster.local:4222
RASPUTIN_CP_JOIN_TOKEN=deadbeefdeadbeefdeadbeefdeadbeef
EOF
}

# A real bus key and its pin, made the way the contract says: the key as one
# line of base64 PKCS#8 DER, the pin recomputed from that line with openssl.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -outform DER -out "$WORK/bus.der" 2>/dev/null \
	|| { echo "openssl could not generate a P-256 key" >&2; exit 2; }
BUS_KEY_LINE="$(openssl base64 -A < "$WORK/bus.der")"
PIN="sha256/$(printf '%s' "$BUS_KEY_LINE" | openssl base64 -d -A \
	| openssl pkey -inform der -pubout -outform der | openssl dgst -sha256 -binary | openssl base64 -A)"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -outform DER -out "$WORK/bus2.der" 2>/dev/null
PIN2="sha256/$(openssl pkey -inform der -in "$WORK/bus2.der" -pubout -outform der | openssl dgst -sha256 -binary | openssl base64 -A)"
[ "${#PIN}" -eq 51 ] && [ "${#PIN2}" -eq 51 ] || { echo "reference pins are not 51 characters: $PIN $PIN2" >&2; exit 2; }
echo "reference pin: $PIN"

# ---------------------------------------------------------------- cases
echo "1. pin in the seed -> UCI -> agent environment"
reset
{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"; } > "$SEED"
apply pin
[ "$APPLY_RC" -eq 0 ] && ok "apply-seed exits 0" || { bad "apply-seed exit $APPLY_RC"; sed 's/^/      /' "$WORK/pin.err" >&2; }
[ "$(uci_get rasputin.main.bus_pin)" = "$PIN" ] && ok "UCI rasputin.main.bus_pin is the pin" \
	|| bad "UCI rasputin.main.bus_pin = '$(uci_get rasputin.main.bus_pin)'"
[ "$(uci_get rasputin.main.nats_url)" = "nats://example-cluster.local:4222" ] && ok "the rest of the batch applied with it" \
	|| bad "nats_url = '$(uci_get rasputin.main.nats_url)'"
agent_env > "$WORK/pin.env" 2>&1
if grep -qx "RASPUTIN_BUS_PIN=$PIN" "$WORK/pin.env"; then
	ok "agent environment carries RASPUTIN_BUS_PIN"
else
	bad "agent environment has no RASPUTIN_BUS_PIN=$PIN:"; sed 's/^/      /' "$WORK/pin.env" >&2
fi
# The stub is only proof if start_service really reached procd.
grep -qx "RASPUTIN_NATS_URL=nats://example-cluster.local:4222" "$WORK/pin.env" && grep -qx "#instance-closed" "$WORK/pin.env" \
	&& ok "start_service opened and closed a procd instance (stub reached)" \
	|| bad "start_service never reached the procd calls — the env check above proves nothing"
grep -qx "RASPUTIN_BUS_PIN=$PIN" "$SEED" && ok "seed.env keeps the pin (public, not scrubbed)" || bad "seed.env lost the pin"

echo "2. a seed saved on Windows: CR on the pin line"
reset
{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\r\n' "$PIN"; } > "$SEED"
apply crlf
[ "$APPLY_RC" -eq 0 ] && [ "$(uci_get rasputin.main.bus_pin)" = "$PIN" ] && ok "trimmed and applied" \
	|| bad "exit $APPLY_RC, bus_pin '$(uci_get rasputin.main.bus_pin | od -c | head -2)'"

echo "3. malformed pins are refused and change nothing"
for bad_pin in \
	"sha256//${PIN#sha256/}" \
	"SHA256/${PIN#sha256/}" \
	"${PIN%=}" \
	"sha256/$(openssl pkey -inform der -in "$WORK/bus.der" -pubout -outform der | openssl dgst -sha256 | sed 's/.*= *//')"
do
	# on a provisioned box: the working config must survive untouched
	reset
	{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"; } > "$SEED"
	apply provisioned
	cp "$UCI" "$WORK/uci-before"
	{ base_seed | sed 's#^RASPUTIN_NATS_URL=.*#RASPUTIN_NATS_URL=nats://changed.local:4222#'; printf 'RASPUTIN_BUS_PIN=%s\n' "$bad_pin"; } > "$SEED"
	apply malformed
	label="'$bad_pin'"
	[ "$APPLY_RC" -eq 1 ] && ok "$label: apply-seed exits 1" || bad "$label: apply-seed exit $APPLY_RC, want 1"
	grep -q "RASPUTIN_BUS_PIN.*is not a valid bus pin" "$WORK/malformed.err" && ok "$label: says why on stderr" \
		|| { bad "$label: no error naming RASPUTIN_BUS_PIN"; sed 's/^/      /' "$WORK/malformed.err" >&2; }
	cmp -s "$WORK/uci-before" "$UCI" && ok "$label: /etc/config/rasputin unchanged (old pin, old URL)" \
		|| { bad "$label: /etc/config/rasputin changed"; diff "$WORK/uci-before" "$UCI" | sed 's/^/      /' >&2; }
	# on a fresh box: nothing provisioned at all
	reset
	{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$bad_pin"; } > "$SEED"
	apply fresh-malformed
	if [ "$APPLY_RC" -eq 1 ] && [ -z "$(uci_get rasputin.main.nats_url)" ]; then
		ok "$label: fresh box stays unprovisioned"
	else
		bad "$label: fresh box: exit $APPLY_RC, nats_url '$(uci_get rasputin.main.nats_url)'"
	fi
done

echo "4. RASPUTIN_BUS_KEY on a firewall: never applied, blanked from seed.env"
reset
{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\nRASPUTIN_BUS_KEY=%s\n' "$PIN" "$BUS_KEY_LINE"; } > "$SEED"
chmod 600 "$SEED"
cp "$SEED" "$WORK/key-before"
apply key
[ "$APPLY_RC" -eq 0 ] && ok "apply-seed still provisions (exit 0)" || bad "apply-seed exit $APPLY_RC"
[ "$(uci_get rasputin.main.bus_pin)" = "$PIN" ] && ok "the pin beside it still applied" || bad "pin not applied"
grep -q "WARNING: .*RASPUTIN_BUS_KEY" "$WORK/key.err" && ok "warns on stderr" || bad "no warning naming RASPUTIN_BUS_KEY"
if grep -rqF -- "$BUS_KEY_LINE" "$ROOT/etc/config/"; then
	bad "the bus key is in /etc/config"
else
	ok "the bus key is nowhere in /etc/config"
fi
agent_env > "$WORK/key.env" 2>&1
if grep -qF -- "$BUS_KEY_LINE" "$WORK/key.env" || grep -q '^RASPUTIN_BUS_KEY=' "$WORK/key.env"; then
	bad "the bus key reached the agent's environment"
else
	ok "the bus key is not in the agent's environment"
fi
grep -qx "RASPUTIN_BUS_KEY=" "$SEED" && ! grep -qF -- "$BUS_KEY_LINE" "$SEED" \
	&& ok "seed.env: RASPUTIN_BUS_KEY blanked" || bad "seed.env still holds the key"
if diff <(grep -v '^RASPUTIN_BUS_KEY=' "$WORK/key-before") <(grep -v '^RASPUTIN_BUS_KEY=' "$SEED") >/dev/null \
	&& [ "$(wc -l < "$SEED")" -eq "$(wc -l < "$WORK/key-before")" ]; then
	ok "seed.env: every other line byte-identical, line count unchanged"
else
	bad "seed.env: other lines changed"
fi
[ "$(stat -c %a "$SEED")" = 600 ] && ok "seed.env: still mode 600" || bad "seed.env mode $(stat -c %a "$SEED")"
ls "$SEED".tmp.* >/dev/null 2>&1 && bad "a temp file was left beside seed.env" || ok "no temp file left behind"
apply key-again
[ "$APPLY_RC" -eq 0 ] && ! grep -q "RASPUTIN_BUS_KEY" "$WORK/key-again.err" && ok "re-run: silent, nothing left to blank" \
	|| bad "re-run: exit $APPLY_RC or warned again"

echo "5. no pin in the seed"
reset
base_seed > "$SEED"
apply nopin-fresh
agent_env > "$WORK/nopin.env" 2>&1
if [ "$APPLY_RC" -eq 0 ] && [ -z "$(uci_get rasputin.main.bus_pin)" ] && ! grep -q '^RASPUTIN_BUS_PIN' "$WORK/nopin.env" \
	&& grep -qx "RASPUTIN_NATS_URL=nats://example-cluster.local:4222" "$WORK/nopin.env"; then
	ok "fresh box: no bus_pin option, no RASPUTIN_BUS_PIN in the environment"
else
	bad "fresh box: exit $APPLY_RC, bus_pin '$(uci_get rasputin.main.bus_pin)'"; sed 's/^/      /' "$WORK/nopin.env" >&2
fi
{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"; } > "$SEED"
apply pinned
{ base_seed; printf 'RASPUTIN_BUS_PIN=\n'; } > "$SEED"
apply blank-pin
[ "$APPLY_RC" -eq 0 ] && [ "$(uci_get rasputin.main.bus_pin)" = "$PIN" ] \
	&& ok "pinned box + seed with a blank pin: the pin stays" || bad "pin removed: '$(uci_get rasputin.main.bus_pin)'"
base_seed > "$SEED"
apply no-pin-line
[ "$APPLY_RC" -eq 0 ] && [ "$(uci_get rasputin.main.bus_pin)" = "$PIN" ] \
	&& ok "pinned box + seed with no pin line: the pin stays" || bad "pin removed: '$(uci_get rasputin.main.bus_pin)'"
{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN2"; } > "$SEED"
apply replace
[ "$APPLY_RC" -eq 0 ] && [ "$(uci_get rasputin.main.bus_pin)" = "$PIN2" ] \
	&& ok "a different valid pin replaces it" || bad "not replaced: '$(uci_get rasputin.main.bus_pin)'"

echo "6. sysupgrade keeps the pin"
# sysupgrade -l prints the files its backup would carry, walking keep.d.
mkdir -p "$ROOT/etc/rasputin/agent-state/bus"
printf '%s\n' "$PIN" > "$ROOT/etc/rasputin/agent-state/bus/pin"
if in_chroot /sbin/sysupgrade -l > "$WORK/keep.txt" 2> "$WORK/keep.err"; then
	grep -qx /etc/rasputin/seed.env "$WORK/keep.txt" && ok "seed.env (seeded pin) is in the sysupgrade backup" \
		|| { bad "seed.env missing from sysupgrade -l"; sed 's/^/      /' "$WORK/keep.txt" >&2; }
	grep -qx /etc/rasputin/agent-state/bus/pin "$WORK/keep.txt" && ok "agent-state/bus/pin (delivered pin) is in the sysupgrade backup" \
		|| bad "agent-state/bus/pin missing from sysupgrade -l"
else
	bad "sysupgrade -l failed in the chroot:"; sed 's/^/      /' "$WORK/keep.err" >&2
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "apply-seed: $pass check(s) passed"
	exit 0
fi
echo "apply-seed: $fail check(s) FAILED, $pass passed" >&2
exit 1
