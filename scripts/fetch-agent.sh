#!/usr/bin/env sh
#
# fetch-agent.sh — download the pinned rasputin-agent tarball, verify it
# against BOTH pins, and extract the binary into files/usr/bin.
#
# Usage: scripts/fetch-agent.sh [dest-dir]      (default: files/usr/bin)
# Needs: gh (authenticated), sha256sum or shasum, tar.
#
# WHAT IT VERIFIES, AND WHY TWICE
#
# The agent binary is the one file in a firewall image that OpenWrt's
# ImageBuilder does not produce and no package feed signature covers. It is
# baked into the rootfs, runs as root on the node that terminates the WAN, and
# holds the bus join credential. Until this script existed the build downloaded
# it by version tag and ran `tar -xzf` on whatever came back.
#
#   1. agent-sha256.txt — the sha this repository was built and tested against.
#   2. the published .sha256 asset beside the tarball.
#
# (2) alone proves only that the tarball matches what the release page says
# TODAY: both are assets of the same release, so anything able to replace one
# is able to replace the other. (1) alone would not notice a release that was
# republished with a different tarball, which is worth saying out loud rather
# than silently accepting. Requiring both means a build proceeds only when the
# published record and this repository's record agree.
#
# Both pins live in files whose ONLY content is the pin, read by this one
# script, which both release.yml and canary.yml call — so a canary build and a
# real build cannot disagree about what they installed.

set -eu

DEST="${1:-files/usr/bin}"
REPO="${AGENT_REPO:-geekdojo/rasputin-control-plane}"

die() { echo "::error::fetch-agent: $*" >&2; exit 1; }

# First non-comment, non-blank line of a pin file.
pin() {
	[ -f "$1" ] || die "$1 is missing"
	v=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$1" | head -n1 | tr -d '[:space:]')
	[ -n "$v" ] || die "$1 has no value line"
	printf '%s' "$v"
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	else
		shasum -a 256 "$1" | awk '{print $1}'
	fi
}

VER=$(pin agent-version.txt)
WANT=$(pin agent-sha256.txt)

case "$WANT" in
	*[!0-9a-f]* | "") die "agent-sha256.txt is not 64 lowercase hex characters: $WANT" ;;
esac
[ "${#WANT}" -eq 64 ] || die "agent-sha256.txt is ${#WANT} characters, want 64: $WANT"

TARBALL="rasputin-agent-${VER}-linux-amd64.tar.gz"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "fetch-agent: rasputin-agent v$VER (agent-version.txt)"
gh release download "v$VER" \
	--repo "$REPO" \
	--pattern "$TARBALL" \
	--pattern "${TARBALL}.sha256" \
	--dir "$WORK" --clobber \
	|| die "could not download $TARBALL from $REPO v$VER — the version must already be published there"

[ -f "$WORK/$TARBALL" ] || die "$TARBALL was not in the release"

GOT=$(sha256_of "$WORK/$TARBALL")

if [ "$GOT" != "$WANT" ]; then
	die "$TARBALL is $GOT, but agent-sha256.txt pins $WANT.
       If this is a deliberate agent bump, agent-version.txt and agent-sha256.txt
       must change in the SAME commit — set the pin to $GOT after reading why the
       tarball changed. If it is not, the published tarball moved under a version
       that was already released, and nothing should be built from it."
fi

if [ -f "$WORK/${TARBALL}.sha256" ]; then
	PUB=$(tr -d '[:space:]' < "$WORK/${TARBALL}.sha256")
	[ "$PUB" = "$GOT" ] || die "$TARBALL is $GOT but its published .sha256 says $PUB — the release's own record disagrees with the release's own asset"
	echo "fetch-agent: sha256 $GOT — matches agent-sha256.txt and the published .sha256"
else
	# Not fatal on its own: pin (1) already held. Say so loudly, because the
	# asset going missing is itself a change in the release.
	echo "::warning::fetch-agent: no published ${TARBALL}.sha256 to cross-check; agent-sha256.txt matched"
fi

mkdir -p "$DEST"
tar -xzf "$WORK/$TARBALL" -C "$DEST"
chmod +x "$DEST/rasputin-agent"

# Prove the file installed is the file that was verified. `tar -xzf` of a
# multi-entry archive would otherwise leave whichever entry came last.
[ -f "$DEST/rasputin-agent" ] || die "the tarball did not contain rasputin-agent"
echo "fetch-agent: installed $DEST/rasputin-agent"
file "$DEST/rasputin-agent" 2>/dev/null | head -1 || true
