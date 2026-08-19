#!/usr/bin/env bash
#
# validate-files.sh — static checks over everything this repo ships into the image.
#
# WHY THIS EXISTS
#   The scripts under files/ ARE the hardening: 96-rasputin-dropbear-harden makes SSH
#   key-only, 97-rasputin-disable-ipv6 strips the v6 config, rasputin-ipv4-only re-asserts
#   it after netifd. Both ways they can be broken fail SILENTLY at boot on hardware — the
#   box comes up, serves traffic, and is quietly less hardened than the design claims.
#   uci-defaults make it worse: they self-delete on exit 0 and only run on a fresh
#   overlay, so a script that dies midway gets no second chance.
#
#   ImageBuilder packages files/ verbatim and executes nothing, so a broken script builds,
#   signs and publishes cleanly. Nothing downstream notices.
#
# WHAT IT CHECKS, AND WHY EACH ONE EARNED ITS PLACE
#   1. Syntax   — `bash -n`. Was already in release.yml's validate job; lifted here so
#                 both the release path and PRs run the identical checks from one file
#                 (this repo has been bitten by the same config living in two workflows
#                 and drifting — see the agent-version.txt note in AGENTS.md).
#   2. MODE     — every file in an executable directory must actually be executable.
#                 NEW, and the reason this script exists. On 2026-08-16
#                 files/etc/init.d/rasputin-ipv4-only merged at 100644. On a fresh flash
#                 `/etc/init.d/rasputin-ipv4-only enable` fails with "Permission denied",
#                 no rc.d symlink is created, and the fix it shipped never runs — leaving
#                 IPv6 live on the WAN, the exact condition it was written to close.
#                 `bash -n` cannot see a mode. (geekdojo/geekdojo-brain#147)
#   3. Structure — required paths still present, so a rename cannot silently drop a file
#                 the build or the boot path depends on.
#
# USAGE
#   ./scripts/validate-files.sh          # from the repo root; exits non-zero on any failure
#
# Run by .github/workflows/ci.yml on every pull request, and by release.yml's validate
# job before any build. Also worth running by hand before pushing.

set -uo pipefail

fail=0
note() { printf '  %s\n' "$*"; }
bad()  { printf '  ✗ %s\n' "$*" >&2; fail=$((fail + 1)); }

cd "$(dirname "$0")/.." || exit 2

# Directories whose contents are executed (or enabled) rather than read. A file landing
# here without +x is a silent-at-boot defect, so the mode is part of the contract.
EXEC_DIRS="
files/etc/init.d
files/etc/uci-defaults
files/usr/lib/rasputin
files/etc/hotplug.d/iface
"

# Everything that is a shell script, executable or not.
SYNTAX_GLOBS="
scripts/*.sh
files/etc/init.d/*
files/etc/uci-defaults/*
files/usr/lib/rasputin/*
files/etc/hotplug.d/iface/*
"

REQUIRED="
README.md
packages.txt
agent-version.txt
scripts/init-imagebuilder.sh
scripts/fetch-snort-rules.sh
scripts/assemble-ab-image.sh
scripts/validate-files.sh
image/grub.cfg
image/genimage.cfg
files/etc/init.d/rasputin-agent
files/etc/init.d/rasputin-ipv4-only
files/etc/uci-defaults/99-rasputin
files/etc/uci-defaults/98-rasputin-seed
files/usr/lib/rasputin/apply-seed
files/usr/lib/rasputin/seed-fat-device
files/usr/lib/rasputin/scrub-seed-token
files/etc/sysctl.d/99-rasputin-no-ipv6.conf
files/etc/snort/rasputin-extra.lua
files/etc/rasputin/seed.env.template
files/etc/rasputin/trust/README.md
"

echo "1. Shell syntax"
checked=0
for glob in $SYNTAX_GLOBS; do
	for f in $glob; do
		[ -f "$f" ] || continue
		checked=$((checked + 1))
		if ! bash -n "$f" 2>/dev/null; then
			bad "syntax error: $f"
			bash -n "$f" 2>&1 | sed 's/^/      /' >&2
		fi
	done
done
note "checked $checked file(s)"

echo "2. Executable modes"
#    An init script or uci-default without +x cannot run, and nothing else in the
#    pipeline will tell you. See the header for the incident this encodes.
mode_checked=0
for d in $EXEC_DIRS; do
	[ -d "$d" ] || continue
	for f in "$d"/*; do
		[ -f "$f" ] || continue
		mode_checked=$((mode_checked + 1))
		if [ ! -x "$f" ]; then
			bad "not executable: $f — a file in $d must be +x or it silently never runs"
		fi
	done
done
note "checked $mode_checked file(s)"

echo "3. Required paths"
for f in $REQUIRED; do
	[ -e "$f" ] || bad "missing: $f"
done
note "checked $(echo "$REQUIRED" | grep -c .) path(s)"

echo ""
if [ "$fail" -ne 0 ]; then
	echo "FAILED — $fail problem(s). These ship into the image and fail silently at boot." >&2
	exit 1
fi
echo "OK — files/ is syntactically valid, correctly moded, and structurally complete."
