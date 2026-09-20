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
#   And for the node id (geekdojo/geekdojo-brain#423):
#     - a seed with a NATS URL or join token but no RASPUTIN_NODE_ID (absent,
#       blank, or a bare CR; with a token or without) fails apply-seed, leaves
#       /etc/config/rasputin exactly as it was, and mints no id;
#     - a seed with its id applies it, through to the agent's environment;
#     - a box not seeded yet (no seed, a blank one, an SSH-key-only one) is a
#       no-op: nothing written, no id minted, the agent not started;
#     - the agent never starts from a UCI config with no node id.
#   And for the join token's own file (geekdojo/geekdojo-brain#537):
#     - the token reaches /etc/rasputin/join.token at mode 600 and NOT
#       /etc/config/rasputin, which carries only its path;
#     - the agent is handed RASPUTIN_CP_JOIN_TOKEN_FILE and the token value is
#       nowhere in its environment;
#     - a box seeded before this — the token still in UCI — is migrated by the
#       agent's own init script on its next start, once, with no commit loop;
#     - sysupgrade's file list keeps the token file.
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
# The join token's own 0600 file: the path as the box sees it, and as this
# harness sees it from outside the chroot (geekdojo/geekdojo-brain#537).
JOIN_TOKEN_FILE=/etc/rasputin/join.token
TOKEN_FILE="$ROOT$JOIN_TOKEN_FILE"

# in_chroot CMD... — bounded: nothing here should take more than seconds, and
# a wait with no deadline is a bug.
in_chroot() { timeout 60 chroot "$ROOT" "$@"; }

# apply NAME — run apply-seed, keeping its stderr in $WORK/NAME.err; sets $APPLY_RC.
#
# RASPUTIN_APPLY_SEED_AGENT points apply-seed at the agent it checks the seed
# through. It is set to a path that does not exist by default: the image this
# harness unpacks is a published one, whose agent predates `seed check`, so the
# ordinary cases take the documented fallback exactly as a fielded box does.
# agent_stub() puts a real one there for the cases that are about the check.
APPLY_SEED_AGENT=/usr/lib/rasputin/no-such-agent
apply() {
	APPLY_RC=0
	in_chroot /usr/bin/env "RASPUTIN_APPLY_SEED_AGENT=$APPLY_SEED_AGENT" \
		/usr/lib/rasputin/apply-seed > "$WORK/$1.out" 2> "$WORK/$1.err" || APPLY_RC=$?
}

# agent_stub BODY — install a fake `rasputin-agent` in the chroot whose
# `seed check` behaves as BODY says. The real one is a Go binary from another
# repo; what apply-seed depends on is the contract — exit 0 with a normalized
# seed on stdout, 1 with the reason on stderr and nothing on stdout, 2 for a
# build that has never heard of the subcommand — and that is what this drives.
agent_stub() {
	APPLY_SEED_AGENT=/usr/lib/rasputin/agent-stub
	{
		printf '#!/bin/sh\n'
		printf 'if [ "$1" != seed ] || [ "$2" != check ]; then\n'
		printf '  echo "rasputin-agent: unknown command \\"$1\\"" >&2\n'
		printf '  exit 2\n'
		printf 'fi\n'
		printf 'shift 2\n'
		printf '%s\n' "$1"
	} > "$ROOT$APPLY_SEED_AGENT"
	chmod +x "$ROOT$APPLY_SEED_AGENT"
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
reset() { rm -f "$UCI" "$SEED" "$SEED".tmp.* "$TOKEN_FILE" "$TOKEN_FILE".tmp.*; }

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
# Populate every path the keep list is asserted about below. sysupgrade -l only
# prints files that EXIST, so an assertion about a path that was never created
# passes for the wrong reason — including the one that matters most, that the
# trust anchor is absent from the backup.
mkdir -p "$ROOT/etc/rasputin/trust" "$ROOT/etc/rasputin/mesh"
printf 'not-a-real-ca\n' > "$ROOT/etc/rasputin/trust/root-ca.pem"
printf 'not-a-real-ca\n' > "$ROOT/etc/rasputin/mesh/tailscaled-ca.pem"
[ -s "$ROOT/etc/rasputin/join.token" ] || printf 'tok\n' > "$ROOT/etc/rasputin/join.token"
if in_chroot /sbin/sysupgrade -l > "$WORK/keep.txt" 2> "$WORK/keep.err"; then
	grep -qx /etc/rasputin/seed.env "$WORK/keep.txt" && ok "seed.env (seeded pin) is in the sysupgrade backup" \
		|| { bad "seed.env missing from sysupgrade -l"; sed 's/^/      /' "$WORK/keep.txt" >&2; }
	grep -qx /etc/rasputin/agent-state/bus/pin "$WORK/keep.txt" && ok "agent-state/bus/pin (delivered pin) is in the sysupgrade backup" \
		|| bad "agent-state/bus/pin missing from sysupgrade -l"

	# geekdojo/geekdojo-brain#531: the trust anchor must NOT be carried across.
	# It decides which images this box installs, and preserving it made the
	# anchor a property of the overlay rather than of the image — so a reflash
	# could not replace it. Asserted against the REAL sysupgrade -l, not against
	# the keep.d text, because the two are only the same until someone adds a
	# broader path back.
	if grep -q '^/etc/rasputin/trust/' "$WORK/keep.txt"; then
		bad "the trust anchor is in the sysupgrade backup — a reflash would carry a stale root forward:"
		grep '^/etc/rasputin/trust/' "$WORK/keep.txt" | sed 's/^/      /' >&2
	else
		ok "trust/ is NOT in the sysupgrade backup (the image's anchor wins on the other side)"
	fi

	# The narrowing that made that possible must not have taken the rest with
	# it: /etc/rasputin/ is no longer listed wholesale, so each surviving path
	# is named, and a dropped one would silently unconfigure the box.
	for keptpath in /etc/rasputin/join.token /etc/rasputin/mesh; do
		if grep -q "^${keptpath}" "$WORK/keep.txt"; then
			ok "$keptpath is still in the sysupgrade backup"
		else
			bad "$keptpath missing from sysupgrade -l — narrowing the keep list dropped it"
		fi
	done
else
	bad "sysupgrade -l failed in the chroot:"; sed 's/^/      /' "$WORK/keep.err" >&2
fi

echo "7. a seed without a node id is refused and changes nothing"
# The node id always comes from the seed: the token is bound to it, and the box
# never makes one up (geekdojo/geekdojo-brain#423). A seed that names a NATS URL
# or a join token but no id fails — with a token or without one. A blank value
# and a bare CR (a seed saved on Windows) count as no id.
NODE_ID_FILE="$ROOT/etc/rasputin/node-id"
for idcase in absent blank cr tokenless; do
	no_id_seed() {
		case "$idcase" in
			absent)    base_seed | grep -v '^RASPUTIN_NODE_ID=' ;;
			blank)     base_seed | sed 's#^RASPUTIN_NODE_ID=.*#RASPUTIN_NODE_ID=#' ;;
			cr)        base_seed | sed 's#^RASPUTIN_NODE_ID=.*#RASPUTIN_NODE_ID=\r#' ;;
			tokenless) base_seed | grep -v -e '^RASPUTIN_NODE_ID=' -e '^RASPUTIN_CP_JOIN_TOKEN=' ;;
		esac
		printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"
	}
	label="no node id ($idcase)"
	# on a provisioned box: the working config must survive untouched
	reset; rm -f "$NODE_ID_FILE"
	{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"; } > "$SEED"
	apply provisioned
	cp "$UCI" "$WORK/uci-before"
	no_id_seed | sed 's#^RASPUTIN_NATS_URL=.*#RASPUTIN_NATS_URL=nats://changed.local:4222#' > "$SEED"
	apply no-id
	if [ "$APPLY_RC" -eq 1 ]; then ok "$label: apply-seed exits 1"; else bad "$label: apply-seed exit $APPLY_RC, want 1"; fi
	if grep -q "ERROR: .* has no RASPUTIN_NODE_ID" "$WORK/no-id.err"; then
		ok "$label: says why on stderr"
	else
		bad "$label: no error naming the missing RASPUTIN_NODE_ID"; sed 's/^/      /' "$WORK/no-id.err" >&2
	fi
	if cmp -s "$WORK/uci-before" "$UCI"; then
		ok "$label: /etc/config/rasputin unchanged (old id, old URL)"
	else
		bad "$label: /etc/config/rasputin changed"; diff "$WORK/uci-before" "$UCI" | sed 's/^/      /' >&2
	fi
	# on a fresh box: nothing provisioned, and no id minted
	reset; rm -f "$NODE_ID_FILE"
	no_id_seed > "$SEED"
	apply fresh-no-id
	if [ "$APPLY_RC" -eq 1 ] && [ ! -e "$UCI" ]; then
		ok "$label: fresh box stays unprovisioned (no /etc/config/rasputin)"
	else
		bad "$label: fresh box: exit $APPLY_RC, nats_url '$(uci_get rasputin.main.nats_url)', node_id '$(uci_get rasputin.main.node_id)'"
	fi
	if [ ! -e "$NODE_ID_FILE" ]; then
		ok "$label: no id minted at /etc/rasputin/node-id"
	else
		bad "$label: minted /etc/rasputin/node-id: $(cat "$NODE_ID_FILE")"
	fi
done

echo "8. a seed with its node id: applied as before, token or not"
for tokcase in token tokenless; do
	reset; rm -f "$NODE_ID_FILE"
	case "$tokcase" in
		token)     base_seed > "$SEED"; want_token=deadbeefdeadbeefdeadbeefdeadbeef ;;
		tokenless) base_seed | grep -v '^RASPUTIN_CP_JOIN_TOKEN=' > "$SEED"; want_token= ;;
	esac
	apply with-id
	agent_env > "$WORK/with-id.env" 2>&1
	if [ "$APPLY_RC" -eq 0 ]; then
		ok "$tokcase: apply-seed exits 0"
	else
		bad "$tokcase: apply-seed exit $APPLY_RC"; sed 's/^/      /' "$WORK/with-id.err" >&2
	fi
	if [ "$(uci_get rasputin.main.node_id)" = fw-test-1 ] && [ "$(uci_get rasputin.main.join_token_file)" = "$JOIN_TOKEN_FILE" ]; then
		ok "$tokcase: UCI carries the seed's node id and the join-token file path"
	else
		bad "$tokcase: UCI node_id '$(uci_get rasputin.main.node_id)', join_token_file '$(uci_get rasputin.main.join_token_file)'"
	fi
	if [ "$(cat "$TOKEN_FILE" 2>/dev/null || true)" = "$want_token" ]; then
		ok "$tokcase: the token file holds the seed's token (empty seed -> no file)"
	else
		bad "$tokcase: $JOIN_TOKEN_FILE = '$(cat "$TOKEN_FILE" 2>/dev/null || true)', want '$want_token'"
	fi
	if grep -qx "RASPUTIN_NODE_ID=fw-test-1" "$WORK/with-id.env" && grep -qx "#instance-closed" "$WORK/with-id.env"; then
		ok "$tokcase: the agent starts with RASPUTIN_NODE_ID=fw-test-1"
	else
		bad "$tokcase: agent environment has no RASPUTIN_NODE_ID=fw-test-1 instance:"; sed 's/^/      /' "$WORK/with-id.env" >&2
	fi
	if [ ! -e "$NODE_ID_FILE" ]; then ok "$tokcase: no id minted at /etc/rasputin/node-id"; else bad "$tokcase: minted /etc/rasputin/node-id"; fi
done

echo "9. not seeded yet: a no-op, and the agent does not start"
# No seed file, a seed with every value blank, and a seed carrying only the
# operator's SSH key (so they can get in and fill it) are all "not seeded yet":
# exit 0, nothing written to /etc/config/rasputin, no id minted, no agent.
for seedcase in nofile blank sshonly; do
	write_unseeded() {
		case "$seedcase" in
			nofile)  rm -f "$SEED" ;;
			blank)   printf 'RASPUTIN_NODE_ROLE=firewall\nRASPUTIN_NODE_ID=\nRASPUTIN_CLUSTER_ID=\nRASPUTIN_NATS_URL=\nRASPUTIN_CP_JOIN_TOKEN=\nRASPUTIN_BUS_PIN=\n' > "$SEED" ;;
			sshonly) printf 'RASPUTIN_NODE_ROLE=firewall\nRASPUTIN_SSH_AUTHORIZED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUnseededSeedTestKeyOnly test@apply-seed"\n' > "$SEED" ;;
		esac
	}
	label="not seeded ($seedcase)"
	reset; rm -f "$NODE_ID_FILE" "$ROOT/etc/dropbear/authorized_keys"
	write_unseeded
	apply unseeded
	if [ "$APPLY_RC" -eq 0 ]; then
		ok "$label: apply-seed exits 0"
	else
		bad "$label: apply-seed exit $APPLY_RC"; sed 's/^/      /' "$WORK/unseeded.err" >&2
	fi
	if [ ! -e "$UCI" ]; then
		ok "$label: nothing written to /etc/config/rasputin"
	else
		bad "$label: /etc/config/rasputin written:"; sed 's/^/      /' "$UCI" >&2
	fi
	if [ ! -e "$NODE_ID_FILE" ]; then ok "$label: no id minted"; else bad "$label: minted /etc/rasputin/node-id"; fi
	agent_env > "$WORK/unseeded.env" 2>&1
	if grep -qx "#instance-closed" "$WORK/unseeded.env"; then bad "$label: the agent started"; else ok "$label: the agent does not start"; fi
	if [ "$seedcase" = sshonly ]; then
		if grep -qF "UnseededSeedTestKeyOnly" "$ROOT/etc/dropbear/authorized_keys" 2>/dev/null; then
			ok "$label: the SSH key is still applied"
		else
			bad "$label: SSH key not applied"
		fi
	fi
	# a provisioned box keeps its working config
	reset
	{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"; } > "$SEED"
	apply provisioned
	cp "$UCI" "$WORK/uci-before"
	write_unseeded
	apply unseeded-provisioned
	if [ "$APPLY_RC" -eq 0 ] && cmp -s "$WORK/uci-before" "$UCI"; then
		ok "$label: provisioned box keeps its config"
	else
		bad "$label: provisioned box: exit $APPLY_RC or config changed"; diff "$WORK/uci-before" "$UCI" | sed 's/^/      /' >&2
	fi
done
rm -f "$ROOT/etc/dropbear/authorized_keys"

echo "9c. the seed is read through the agent, not sourced as a shell script"
# geekdojo/geekdojo-brain#540 (F18). Each of the three exit statuses means
# something different to apply-seed, and each is driven here against the real
# image's busybox and the real uci.

# 0 — checked. What apply-seed uses is the agent's OUTPUT, not the file on
# disk: the stub answers with a different node id than the seed carries, and
# UCI must end up with the stub's.
reset; rm -f "$TOKEN_FILE"
agent_stub "cat <<'CHECKED'
RASPUTIN_NODE_ROLE='firewall'
RASPUTIN_NODE_ID='fw-from-the-agent'
RASPUTIN_CLUSTER_ID='example-cluster'
RASPUTIN_NATS_URL='nats://example-cluster.local:4222'
RASPUTIN_CP_JOIN_TOKEN='tok-checked'
CHECKED"
{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"; } > "$SEED"
apply seedcheck-ok
[ "$APPLY_RC" -eq 0 ] && ok "seed check: apply-seed exits 0" \
	|| { bad "seed check: exit $APPLY_RC"; sed 's/^/      /' "$WORK/seedcheck-ok.err" >&2; }
[ "$(uci_get rasputin.main.node_id)" = fw-from-the-agent ] \
	&& ok "seed check: the normalized copy is what was applied" \
	|| bad "seed check: node_id is '$(uci_get rasputin.main.node_id)', want the agent's"
[ ! -e "$ROOT/tmp/rasputin-seed.checked" ] && ok "seed check: the normalized copy does not outlive the read" \
	|| bad "seed check: /tmp/rasputin-seed.checked was left behind (it holds the join token)"

# 1 — the agent refuses. NOTHING is applied and apply-seed exits 1, the same
# shape a bad node id or a bad pin already takes.
reset; rm -f "$TOKEN_FILE"
agent_stub "echo 'SEED UNUSABLE: RASPUTIN_NODE_ROLE is \"compute\" but this image can only be a \"firewall\"' >&2; exit 1"
{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"; } > "$SEED"
apply seedcheck-refused
[ "$APPLY_RC" -ne 0 ] && ok "seed refused: apply-seed exits non-zero" \
	|| bad "seed refused: apply-seed exited 0"
grep -q 'SEED UNUSABLE' "$WORK/seedcheck-refused.err" && ok "seed refused: relays the agent's reason" \
	|| { bad "seed refused: the reason did not reach stderr"; sed 's/^/      /' "$WORK/seedcheck-refused.err" >&2; }
[ ! -e "$UCI" ] && ok "seed refused: nothing written to /etc/config/rasputin" \
	|| { bad "seed refused: /etc/config/rasputin written:"; sed 's/^/      /' "$UCI" >&2; }

# 2 — an agent that predates the subcommand. MIXED FLEETS: this image pins its
# agent and that pin lags on purpose, so a box WILL exist whose agent has never
# heard of `seed check`. It must still provision, from the seed as before.
reset; rm -f "$TOKEN_FILE"
agent_stub "echo unreachable"
printf '#!/bin/sh\necho "rasputin-agent: unknown command \\"$1\\"" >&2\nexit 2\n' > "$ROOT$APPLY_SEED_AGENT"
chmod +x "$ROOT$APPLY_SEED_AGENT"
{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"; } > "$SEED"
apply seedcheck-old
[ "$APPLY_RC" -eq 0 ] && ok "old agent: apply-seed still provisions" \
	|| { bad "old agent: exit $APPLY_RC"; sed 's/^/      /' "$WORK/seedcheck-old.err" >&2; }
[ "$(uci_get rasputin.main.node_id)" = fw-test-1 ] \
	&& ok "old agent: the seed's own values are applied" \
	|| bad "old agent: node_id is '$(uci_get rasputin.main.node_id)'"

# And with no agent on the box at all — the default every other case here
# runs under, stated once so it is a claim rather than a side effect.
reset; rm -f "$TOKEN_FILE"
APPLY_SEED_AGENT=/usr/lib/rasputin/no-such-agent
{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"; } > "$SEED"
apply seedcheck-none
[ "$APPLY_RC" -eq 0 ] && ok "no agent: apply-seed still provisions" \
	|| { bad "no agent: exit $APPLY_RC"; sed 's/^/      /' "$WORK/seedcheck-none.err" >&2; }
[ "$(uci_get rasputin.main.node_id)" = fw-test-1 ] \
	&& ok "no agent: the seed's own values are applied" \
	|| bad "no agent: node_id is '$(uci_get rasputin.main.node_id)'"

echo "9b. key-only SSH is re-asserted with NO authorized key on the box"
# THE case the old gate skipped (geekdojo/geekdojo-brain#545). apply-seed used
# to re-assert key-only SSH only when /etc/dropbear/authorized_keys was
# non-empty, so a box with no key kept whatever PasswordAuth said — and a box
# with no key is exactly the one where password auth left on is a root login
# prompt on the LAN rather than "no network shell". apply-seed now delegates to
# the one implementation, /etc/init.d/rasputin-mgmt-harden, and this runs it on
# the real image's busybox and the real uci.
reset; rm -f "$ROOT/etc/dropbear/authorized_keys"
# Stock OpenWrt: password auth ON, on a real /etc/config/dropbear.
in_chroot /bin/sh -c 'uci -q set dropbear.@dropbear[0].PasswordAuth=on; \
	uci -q set dropbear.@dropbear[0].RootPasswordAuth=on; uci -q commit dropbear' || true
before_pw="$(uci_get 'dropbear.@dropbear[0].PasswordAuth')"
[ "$before_pw" = on ] && ok "the box starts with password auth on" \
	|| bad "could not set up the stock dropbear config (got '$before_pw')"
{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"; } > "$SEED"
apply dropbear-nokey
[ "$APPLY_RC" -eq 0 ] && ok "apply-seed exits 0 with no authorized key" \
	|| { bad "apply-seed exit $APPLY_RC"; sed 's/^/      /' "$WORK/dropbear-nokey.err" >&2; }
[ ! -s "$ROOT/etc/dropbear/authorized_keys" ] && ok "there is still no authorized key" \
	|| bad "an authorized key appeared from nowhere"
[ "$(uci_get 'dropbear.@dropbear[0].PasswordAuth')" = off ] \
	&& ok "PasswordAuth is off although no key exists" \
	|| bad "PasswordAuth is '$(uci_get 'dropbear.@dropbear[0].PasswordAuth')', want off"
[ "$(uci_get 'dropbear.@dropbear[0].RootPasswordAuth')" = off ] \
	&& ok "RootPasswordAuth is off although no key exists" \
	|| bad "RootPasswordAuth is '$(uci_get 'dropbear.@dropbear[0].RootPasswordAuth')', want off"

# The uci-defaults script takes the same path, so a FRESH overlay is hardened
# before any service starts — and by the same implementation.
in_chroot /bin/sh -c 'uci -q set dropbear.@dropbear[0].PasswordAuth=on; uci -q commit dropbear' || true
in_chroot /bin/sh /etc/uci-defaults/96-rasputin-dropbear-harden >/dev/null 2>&1 || true
[ "$(uci_get 'dropbear.@dropbear[0].PasswordAuth')" = off ] \
	&& ok "the first-boot uci-defaults script hardens through the same path" \
	|| bad "96-rasputin-dropbear-harden left PasswordAuth '$(uci_get 'dropbear.@dropbear[0].PasswordAuth')'"

echo "10. the agent never starts without a node id"
# apply-seed never writes such a config; this is a UCI file edited by hand, or
# one written before that check. The agent must not run under its default id.
reset
cat > "$UCI" <<'EOF'
config rasputin 'main'
	option node_role 'firewall'
	option nats_url 'nats://example-cluster.local:4222'
	option join_token 'deadbeefdeadbeefdeadbeefdeadbeef'
	option cluster_id 'example-cluster'
EOF
agent_env > "$WORK/noid.env" 2>&1
if grep -qx "#instance-closed" "$WORK/noid.env" || grep -q '^RASPUTIN_' "$WORK/noid.env"; then
	bad "the agent started with no node id:"; sed 's/^/      /' "$WORK/noid.env" >&2
else
	ok "nats_url set, node_id blank: no procd instance"
fi

echo "11. the join token: its own 0600 file, never a UCI value or an env value"
# geekdojo/geekdojo-brain#537 (auth methodology §7 4.1). The token used to be
# rasputin.main.join_token in a world-readable config file, handed to the agent
# as RASPUTIN_CP_JOIN_TOKEN in its environment. Now apply-seed writes
# /etc/rasputin/join.token (0600) and UCI carries only the path, which init.d
# passes as RASPUTIN_CP_JOIN_TOKEN_FILE for the agent to re-read on every
# connect. Proved against the image's real uci and its real init script.
TOKEN=deadbeefdeadbeefdeadbeefdeadbeef
reset
{ base_seed; printf 'RASPUTIN_BUS_PIN=%s\n' "$PIN"; } > "$SEED"
apply token-file
[ "$APPLY_RC" -eq 0 ] && ok "apply-seed exits 0" || { bad "apply-seed exit $APPLY_RC"; sed 's/^/      /' "$WORK/token-file.err" >&2; }
[ "$(cat "$TOKEN_FILE" 2>/dev/null)" = "$TOKEN" ] && ok "the token is in $JOIN_TOKEN_FILE" \
	|| bad "$JOIN_TOKEN_FILE = '$(cat "$TOKEN_FILE" 2>/dev/null)'"
[ "$(stat -c %a "$TOKEN_FILE" 2>/dev/null)" = 600 ] && ok "the token file is mode 600" \
	|| bad "the token file is mode $(stat -c %a "$TOKEN_FILE" 2>/dev/null)"
ls "$TOKEN_FILE".tmp.* >/dev/null 2>&1 && bad "a temp file was left beside the token file" || ok "no temp file left beside it"
[ -z "$(uci_get rasputin.main.join_token)" ] && ok "UCI has no join_token option" \
	|| bad "UCI join_token = '$(uci_get rasputin.main.join_token)'"
grep -rqF -- "$TOKEN" "$ROOT/etc/config/" && bad "the token is somewhere in /etc/config" || ok "the token is nowhere in /etc/config"
[ "$(uci_get rasputin.main.join_token_file)" = "$JOIN_TOKEN_FILE" ] && ok "UCI carries the path instead" \
	|| bad "UCI join_token_file = '$(uci_get rasputin.main.join_token_file)'"
agent_env > "$WORK/token-file.env" 2>&1
grep -qx "RASPUTIN_CP_JOIN_TOKEN_FILE=$JOIN_TOKEN_FILE" "$WORK/token-file.env" \
	&& ok "the agent is given RASPUTIN_CP_JOIN_TOKEN_FILE" \
	|| { bad "no RASPUTIN_CP_JOIN_TOKEN_FILE in the agent environment:"; sed 's/^/      /' "$WORK/token-file.env" >&2; }
if grep -q '^RASPUTIN_CP_JOIN_TOKEN=' "$WORK/token-file.env" || grep -qF -- "$TOKEN" "$WORK/token-file.env"; then
	bad "the token value reached the agent's environment:"; sed 's/^/      /' "$WORK/token-file.env" >&2
else
	ok "the token value is not in the agent's environment"
fi
grep -qx "#instance-closed" "$WORK/token-file.env" && ok "start_service reached the procd calls (the checks above mean something)" \
	|| bad "start_service never reached the procd calls"
grep -qx "RASPUTIN_CP_JOIN_TOKEN=$TOKEN" "$SEED" && ok "seed.env still holds the token (it is the source of record)" \
	|| bad "seed.env lost the token"

echo "11b. a seed saved on Windows: CR on the token line"
reset
{ base_seed | grep -v '^RASPUTIN_CP_JOIN_TOKEN='; printf 'RASPUTIN_CP_JOIN_TOKEN=%s\r\n' "$TOKEN"; } > "$SEED"
apply token-crlf
[ "$APPLY_RC" -eq 0 ] && [ "$(cat "$TOKEN_FILE" 2>/dev/null)" = "$TOKEN" ] && ok "trimmed and written" \
	|| bad "exit $APPLY_RC, token file '$(od -c < "$TOKEN_FILE" 2>/dev/null | head -2)'"

echo "11c. a box seeded before the token file: init.d moves it, once"
# An A/B slot update carries the overlay across and does not re-run apply-seed,
# so the agent's own init script has to do the migration. This is the pre-#537
# UCI config, written by hand exactly as the old apply-seed wrote it.
reset
cat > "$UCI" <<EOF
config rasputin 'main'
	option node_role 'firewall'
	option nats_url 'nats://example-cluster.local:4222'
	option join_token '$TOKEN'
	option node_id 'fw-test-1'
	option cluster_id 'example-cluster'
EOF
agent_env > "$WORK/migrate.env" 2>&1
[ "$(cat "$TOKEN_FILE" 2>/dev/null)" = "$TOKEN" ] && ok "the token was moved into $JOIN_TOKEN_FILE" \
	|| bad "$JOIN_TOKEN_FILE = '$(cat "$TOKEN_FILE" 2>/dev/null)'"
[ "$(stat -c %a "$TOKEN_FILE" 2>/dev/null)" = 600 ] && ok "mode 600" || bad "mode $(stat -c %a "$TOKEN_FILE" 2>/dev/null)"
[ -z "$(uci_get rasputin.main.join_token)" ] && ok "the legacy UCI option is gone" \
	|| bad "UCI join_token = '$(uci_get rasputin.main.join_token)'"
[ "$(uci_get rasputin.main.join_token_file)" = "$JOIN_TOKEN_FILE" ] && ok "UCI now carries the path" \
	|| bad "UCI join_token_file = '$(uci_get rasputin.main.join_token_file)'"
grep -qx "RASPUTIN_CP_JOIN_TOKEN_FILE=$JOIN_TOKEN_FILE" "$WORK/migrate.env" \
	&& ok "the agent starts on the file in the same pass" \
	|| { bad "the agent's environment does not name the token file:"; sed 's/^/      /' "$WORK/migrate.env" >&2; }
grep -q '^RASPUTIN_CP_JOIN_TOKEN=' "$WORK/migrate.env" \
	&& bad "the inline token was passed too" || ok "the inline token was not passed"
cp "$UCI" "$WORK/uci-after-migrate"
agent_env > "$WORK/migrate2.env" 2>&1
cmp -s "$WORK/uci-after-migrate" "$UCI" && ok "a second start changes nothing (no commit loop)" \
	|| { bad "a second start rewrote /etc/config/rasputin"; diff "$WORK/uci-after-migrate" "$UCI" | sed 's/^/      /' >&2; }

echo "11d. sysupgrade keeps the token file"
if in_chroot /sbin/sysupgrade -l > "$WORK/keep-token.txt" 2> "$WORK/keep-token.err"; then
	grep -qx "$JOIN_TOKEN_FILE" "$WORK/keep-token.txt" && ok "$JOIN_TOKEN_FILE is in the sysupgrade backup" \
		|| { bad "$JOIN_TOKEN_FILE missing from sysupgrade -l"; sed 's/^/      /' "$WORK/keep-token.txt" >&2; }
else
	bad "sysupgrade -l failed in the chroot:"; sed 's/^/      /' "$WORK/keep-token.err" >&2
fi

echo
if [ "$fail" -eq 0 ]; then
	echo "apply-seed: $pass check(s) passed"
	exit 0
fi
echo "apply-seed: $fail check(s) FAILED, $pass passed" >&2
exit 1
