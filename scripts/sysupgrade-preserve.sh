#!/usr/bin/env bash
#
# sysupgrade-preserve.sh — orchestrator-side wrapper around `sysupgrade -F`
# that survives the partition-layout-change "Full image will be written"
# path, which bypasses /lib/upgrade/keep.d/* entirely and wipes
# /etc/rasputin/ (seed.env, node-id, trust/root-ca.pem) + /etc/dropbear/
# (SSH host keys).
#
# Background:
#   OpenWrt's sysupgrade has two execution paths. The normal path
#   preserves /lib/upgrade/keep.d/* across the flash. But when the new
#   image's partition table differs from the disk's (e.g. we bumped
#   CONFIG_TARGET_ROOTFS_PARTSIZE from 104→512 MB), sysupgrade falls back
#   to a full whole-disk dd. The keep.d backup tarball goes to /tmp,
#   which is tmpfs/RAM; the reboot wipes it. Everything in /etc/ is
#   gone on the other side. Caught on the CWWK 2026-06-08 IDS bring-up.
#
#   The fundamental issue is that on x86 sysupgrade with a partition-
#   layout change, NOTHING on the firewall's disk survives the write,
#   so preserve-on-the-firewall is impossible. The orchestrator
#   (this script, when run from a developer's Mac, or eventually the
#   controlplane's `firewall.sysupgrade` job) is the only place
#   capable of holding the state across the wipe.
#
# What this script does:
#   1. SSH to firewall, tar /etc/rasputin/ + /etc/dropbear/ to a local
#      file. Abort if the tar fails — better to refuse to flash than to
#      lose state silently.
#   2. SCP the new image to /tmp/fw.img.gz on the firewall.
#   3. Run `sysupgrade -F` over SSH. The SSH session drops at "Closing
#      all shell sessions"; the `Command failed: ubus call system
#      sysupgrade ... (Connection failed)` line is normal — ubus dies
#      as procd switches root.
#   4. Poll for the firewall to come back (ping then SSH).
#   5. If SSH host keys reset (always after a partition-layout-change
#      sysupgrade), re-accept temporarily into a side known_hosts file
#      so the restore SCP can proceed.
#   6. SCP the preserved tarball back, untar into /, restart dropbear
#      (which reloads the OLD host keys) + rasputin-agent (which reloads
#      the OLD seed).
#   7. Clean up the temp known_hosts. The operator's existing
#      known_hosts entry (created before flash) now matches again — no
#      lingering MITM warning.
#
# Limits:
#   - This is a workaround. The long-term fix is a first-boot pairing
#     protocol (mDNS / NATS-multicast / similar): on a fresh empty seed,
#     the firewall advertises itself, the controlplane responds with
#     state. That removes the need for orchestrator-side preservation
#     entirely. Tracked in the wiki backlog at
#     projects/rasputin/backlog/design/os-images/firewall-image.md.
#   - Failures mid-flow can leave the firewall in a halfway state.
#     The script bails early if preserve fails. After-flash restore
#     failures leave the firewall with empty /etc/rasputin/ — recoverable
#     by re-running this script's restore-only path (TODO) or manually
#     re-seeding.
#
# Usage:
#   sysupgrade-preserve.sh <ssh-target> <local-image-path>
#
# Example:
#   sysupgrade-preserve.sh root@192.168.1.1 \
#       /tmp/rasputin-fw-n100-2026.07.1-dev.3-combined-efi.img.gz

set -euo pipefail

if [ $# -ne 2 ]; then
	echo "usage: $0 <ssh-target> <local-image-path>" >&2
	echo "example: $0 root@192.168.1.1 /tmp/rasputin-fw-n100-2026.07.1-dev.3-combined-efi.img.gz" >&2
	exit 64
fi

SSH_TARGET="$1"
IMG_PATH="$2"
KNOWN_HOSTS_MAIN="${KNOWN_HOSTS_MAIN:-/tmp/rasputin_known_hosts}"
KNOWN_HOSTS_TEMP="$(mktemp -t rasputin_known_hosts_temp.XXXXXX)"
PRESERVE_DIR="${PRESERVE_DIR:-/tmp/rasputin-preserve}"
PRESERVE_TAR="${PRESERVE_DIR}/$(date +%Y%m%d-%H%M%S)-$(echo "$SSH_TARGET" | tr '/@:' '___').tar.gz"

# Extract host:port for ping/nc polling. SSH_TARGET is `user@host[:port]`.
SSH_HOST_PORT="${SSH_TARGET#*@}"
SSH_HOST="${SSH_HOST_PORT%:*}"
case "$SSH_HOST_PORT" in
	*:*) SSH_PORT="${SSH_HOST_PORT##*:}";;
	*)   SSH_PORT="22";;
esac

SSH_OPTS=(-o BatchMode=yes -o UserKnownHostsFile="$KNOWN_HOSTS_MAIN" -o StrictHostKeyChecking=accept-new)
SCP_OPTS=(-O -o BatchMode=yes -o UserKnownHostsFile="$KNOWN_HOSTS_MAIN")

trap 'rm -f "$KNOWN_HOSTS_TEMP"' EXIT

log() { printf "==> %s\n" "$*"; }
die() { printf "::error:: %s\n" "$*" >&2; exit 1; }

# --- Pre-flight ---

[ -r "$IMG_PATH" ] || die "image not readable: $IMG_PATH"
mkdir -p "$PRESERVE_DIR"

log "preflight: confirming SSH reaches $SSH_TARGET"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'true' \
	|| die "SSH preflight failed — confirm the firewall is up and reachable"

log "preflight: checking /etc/rasputin/ + /etc/dropbear/ exist"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" '[ -d /etc/rasputin ] && [ -d /etc/dropbear ]' \
	|| die "/etc/rasputin/ or /etc/dropbear/ missing on firewall — refusing to flash"

# --- Step 1: capture state ---

log "preserving /etc/rasputin/ + /etc/dropbear/ → $PRESERVE_TAR"
ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
	'tar czf - /etc/rasputin /etc/dropbear 2>/dev/null' \
	> "$PRESERVE_TAR" \
	|| die "preserve tar failed — refusing to proceed (no flash happened, firewall is intact)"

PRESERVE_SIZE=$(stat -f%z "$PRESERVE_TAR" 2>/dev/null || stat -c%s "$PRESERVE_TAR")
[ "$PRESERVE_SIZE" -gt 100 ] || die "preserve tarball suspiciously small ($PRESERVE_SIZE bytes) — refusing to proceed"
log "preserved $PRESERVE_SIZE bytes"

# --- Step 2: push the new image ---

log "scp'ing image to firewall:/tmp/fw.img.gz (busybox dropbear needs scp -O)"
scp "${SCP_OPTS[@]}" "$IMG_PATH" "$SSH_TARGET:/tmp/fw.img.gz"

# --- Step 3: run sysupgrade ---

# The SSH session drops on "Closing all shell sessions" — the final
# ubus error is a normal side-effect of procd dying mid-flash. Swallow
# the non-zero exit with `|| true` so set -e doesn't kill the script
# before we get to the wait + restore steps.
#
# (Earlier versions used `... | cat` thinking that would swallow the
# exit, but with `set -o pipefail` enabled at the top, the pipeline
# still returned the ssh's non-zero code → set -e killed the script
# right after dispatching sysupgrade. Caught on the dev.6 flash
# 2026-06-09 — the firewall came back fine via keep.d, but the
# script's restore step never ran. Documented here as the canonical
# "don't reach for `| cat` on a failure-expected command under
# pipefail" reminder.)
log "running sysupgrade -F on firewall (SSH session will drop — that's normal)"
ssh "${SSH_OPTS[@]}" -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
	"$SSH_TARGET" 'sysupgrade -F /tmp/fw.img.gz 2>&1' || true
log "sysupgrade dispatched; firewall is rebooting"

# --- Step 4: wait for re-up ---

log "waiting for $SSH_HOST to come back online..."
for _ in $(seq 1 60); do
	if ping -c 1 -W 1000 "$SSH_HOST" >/dev/null 2>&1; then break; fi
	sleep 2
done
ping -c 1 -W 1000 "$SSH_HOST" >/dev/null 2>&1 \
	|| die "firewall did not respond to ping within 120s — flash may have bricked the image"
log "ping OK"

for _ in $(seq 1 60); do
	if nc -zv -G 2 "$SSH_HOST" "$SSH_PORT" >/dev/null 2>&1; then break; fi
	sleep 2
done
nc -zv -G 2 "$SSH_HOST" "$SSH_PORT" >/dev/null 2>&1 \
	|| die "SSH port did not open within 120s of ping responding"
log "ssh ready"

# --- Step 5: prepare to talk to the post-flash firewall ---
# SSH host keys reset after a partition-layout-change sysupgrade. The
# main known_hosts now mismatches. Use a temp known_hosts that
# accepts-new for the restore SCP, then throw it away at the end.

log "accepting new SSH host key into $KNOWN_HOSTS_TEMP (temporary)"
ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
	-o UserKnownHostsFile="$KNOWN_HOSTS_TEMP" "$SSH_TARGET" 'true' \
	|| die "post-flash SSH failed"

# --- Step 6: push preserve tarball back, untar, restart services ---

log "pushing preserve tarball back to firewall"
scp -O -o BatchMode=yes -o UserKnownHostsFile="$KNOWN_HOSTS_TEMP" \
	"$PRESERVE_TAR" "$SSH_TARGET:/tmp/rasputin-restore.tar.gz"

log "restoring /etc/rasputin/ + /etc/dropbear/ + restarting dropbear & rasputin-agent"
ssh -o BatchMode=yes -o UserKnownHostsFile="$KNOWN_HOSTS_TEMP" "$SSH_TARGET" '
	set -eu
	tar xzf /tmp/rasputin-restore.tar.gz -C /
	rm -f /tmp/rasputin-restore.tar.gz
	# Restart dropbear to load the OLD host keys — operator''s main
	# known_hosts will match again after this.
	/etc/init.d/dropbear restart
	# Re-apply seed and restart the agent so it picks up the restored
	# controlplane URL + join token.
	/usr/lib/rasputin/apply-seed >/dev/null 2>&1 || true
	/etc/init.d/rasputin-agent restart 2>/dev/null || true
'

# Brief settle period — restarting dropbear races our follow-on SSH.
sleep 3

# --- Step 7: verify the main known_hosts works again ---

log "verifying SSH back to firewall with the ORIGINAL host keys ($KNOWN_HOSTS_MAIN)"
if ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS_MAIN" \
	"$SSH_TARGET" 'cat /etc/rasputin/node-id 2>/dev/null; cat /etc/openwrt_release | head -2' 2>/dev/null; then
	log "host-key restore confirmed — original known_hosts matches"
else
	log "WARNING: main known_hosts mismatch after restore — dropbear may not have reloaded the saved keys"
	log "         workaround: rm $KNOWN_HOSTS_MAIN and re-accept the (new) keys manually"
fi

log "done"
log "preserved tarball kept at $PRESERVE_TAR for ${PRESERVE_DIR} history (delete when no longer needed)"
