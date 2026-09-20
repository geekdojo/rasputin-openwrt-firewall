#!/usr/bin/env bash
#
# agent-pin.sh — read the vendored rasputin-agent pin, and verify a downloaded
# tarball against it.
#
# WHY THIS EXISTS (geekdojo/geekdojo-brain#533)
#   The firewall image bakes a pre-built rasputin-agent binary pulled from a
#   rasputin-control-plane release. Until this script the build took whatever
#   bytes the download produced: the pin named a VERSION, and a version names a
#   release asset, not a payload. A release asset can be replaced after
#   publication, so "the pin didn't change" did not mean "the binary didn't
#   change" — and the binary in question is the one that verifies every signed
#   image this box will ever install.
#
#   rasputin-os has never had that gap: its Buildroot package carries
#   rasputin-agent.hash and Buildroot refuses a source whose sha256 does not
#   match (os/package/rasputin-agent/rasputin-agent.hash). This gives the
#   firewall the same property. The hash comes from the release's own published
#   `.hash` asset, which is exactly what the OS pin is refreshed from.
#
# WHY THE HASH LIVES IN agent-version.txt
#   AGENTS.md records that this repo has been bitten by the same configuration
#   living in two places and drifting. A separate hash file would be a second
#   place: bump the version, forget the hash, and the build either fails
#   confusingly or — worse, if the check were lenient — passes on a stale pin.
#   Keeping both lines in one file makes a bump a single edit, and every read
#   refuses a hash line whose filename does not name the pinned version, so the
#   two cannot disagree even in principle.
#
# USAGE
#   scripts/agent-pin.sh version               # bare CalVer, no leading v
#   scripts/agent-pin.sh sha256                # pinned sha256 of the amd64 tarball
#   scripts/agent-pin.sh tarball               # expected tarball filename
#   scripts/agent-pin.sh verify <tarball-path> # fail closed unless sha256 matches
#
# Used by .github/workflows/release.yml and .github/workflows/canary.yml, which
# must resolve the pin identically, and exercised by scripts/test-agent-pin.sh.

set -uo pipefail

PIN_FILE="${AGENT_PIN_FILE:-}"
if [ -z "$PIN_FILE" ]; then
	PIN_FILE="$(cd "$(dirname "$0")/.." && pwd)/agent-version.txt"
fi

# The firewall is amd64-only (CWWK x86-p5-n100 reference hardware), so exactly
# one tarball is ever vendored. An arch column would be dead weight that still
# had to be kept correct.
GOARCH=amd64

die() { printf 'agent-pin: %s\n' "$*" >&2; exit 1; }

[ -r "$PIN_FILE" ] || die "cannot read pin file: $PIN_FILE"

# Payload lines: everything that is not a comment or blank. Line 1 is the
# version, line 2 is the hash. Anything after line 2 is a malformed pin and is
# refused rather than ignored — a third line is far more likely to be a
# half-finished edit than intent.
#
# NOTE: every parse below runs in THIS shell, not in a command substitution.
# `die` exits, and an exit inside `$(...)` would only end the subshell and hand
# the caller an empty string — a pin check that fails open is worse than none.
PAYLOAD="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$PIN_FILE")"
PAYLOAD_LINES="$(printf '%s\n' "$PAYLOAD" | grep -c . || true)"

VERSION="$(printf '%s\n' "$PAYLOAD" | sed -n '1p' | tr -d '[:space:]')"
[ -n "$VERSION" ] || die "$PIN_FILE has no version line"
# Bare CalVer, no leading v: YYYY.MM.MICRO with an optional -dev.N.
printf '%s' "$VERSION" | grep -Eq '^[0-9]{4}\.[0-9]{2}\.[0-9]+(-dev\.[0-9]+)?$' \
	|| die "version line '$VERSION' is not a bare CalVer (YYYY.MM.MICRO[-dev.N], no leading v)"

TARBALL="rasputin-agent-${VERSION}-linux-${GOARCH}.tar.gz"

resolve_sha256() {
	[ "$PAYLOAD_LINES" -ge 2 ] || die "$PIN_FILE has no sha256 line. Take it from the release's published .hash asset:
    gh release download v${VERSION} --repo geekdojo/rasputin-control-plane \\
      --pattern '${TARBALL}.hash' --dir . --clobber"
	[ "$PAYLOAD_LINES" -le 2 ] || die "$PIN_FILE has $PAYLOAD_LINES payload lines; expected exactly 2 (version, then sha256)"

	local line algo sum name
	line="$(printf '%s\n' "$PAYLOAD" | sed -n '2p')"
	# Buildroot's hash-file format, the same shape
	# os/package/rasputin-agent/rasputin-agent.hash carries, so the line can be
	# pasted straight from the release's .hash asset.
	algo="$(printf '%s\n' "$line" | awk '{print $1}')"
	sum="$(printf '%s\n' "$line"  | awk '{print $2}')"
	name="$(printf '%s\n' "$line" | awk '{print $3}')"

	[ "$algo" = "sha256" ] || die "hash line must start with 'sha256', got '$algo'"
	printf '%s' "$sum" | grep -Eq '^[0-9a-f]{64}$' \
		|| die "hash line's digest is not 64 lowercase hex characters: '$sum'"

	# The drift guard. The filename carries the version, so a version bump that
	# forgets the hash cannot pass: the two lines disagree and the build stops
	# here rather than baking a binary nobody pinned.
	[ "$name" = "$TARBALL" ] || die "pin is inconsistent: the version line implies '$TARBALL' but the hash line names '$name'. Bump both lines together — the sha256 comes from that release's published .hash asset."

	SHA256="$sum"
}

verify() {
	local file="$1" got
	[ -f "$file" ] || die "no such file: $file"
	resolve_sha256
	if command -v sha256sum >/dev/null 2>&1; then
		got="$(sha256sum "$file" | awk '{print $1}')"
	elif command -v shasum >/dev/null 2>&1; then
		got="$(shasum -a 256 "$file" | awk '{print $1}')"
	else
		die "neither sha256sum nor shasum is available — cannot verify the pin, refusing to continue"
	fi
	[ "$got" = "$SHA256" ] || die "sha256 MISMATCH for $(basename "$file")
    pinned     $SHA256
    downloaded $got
  The published asset does not match the pin. Do NOT bake this binary: either the
  release asset was replaced after it was pinned, or the pin is wrong."
	printf 'agent-pin: %s sha256 %s OK\n' "$(basename "$file")" "$got"
}

case "${1:-}" in
	version) printf '%s\n' "$VERSION" ;;
	tarball) printf '%s\n' "$TARBALL" ;;
	sha256)  resolve_sha256; printf '%s\n' "$SHA256" ;;
	verify)
		[ $# -eq 2 ] || die "usage: $0 verify <tarball-path>"
		verify "$2"
		;;
	*)
		printf 'usage: %s version|sha256|tarball|verify <tarball-path>\n' "$0" >&2
		exit 64
		;;
esac
