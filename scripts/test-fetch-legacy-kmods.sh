#!/bin/sh
#
# test-fetch-legacy-kmods.sh — fail-closed tests for scripts/fetch-legacy-kmods.sh
# (geekdojo/geekdojo-brain#888, TC-888-32).
#
# The modules this script stages are loaded into the running kernel of a field
# box, as root, from inside a boot that has no other way to reach its ESP. So
# every way it could take bytes it should not is a case here, against a
# throwaway CA and a fixture release built in a scratch directory:
#
#   good        exits 0; stages the five modules with their pinned sha256 and
#               the pinned legacy kernel id (image/legacy-kernel-id, F-888-08)
#   rootfs-sha  the .rootfs differs from the signed manifest's rootfsSha256
#   manifest    manifest.json.sig is signed by a key the CA never issued
#   rootfs-sig  .rootfs.sig is signed by a key the CA never issued
#   ko-sha      a module's sha256 differs from its pin
#   no-ca       an empty root CA (a build with RASPUTIN_ROOT_CA_PEM unset)
#
# Each refusal must exit non-zero AND name the offending file. A fixture
# cannot carry the real 2026.10.3 modules, so the pins are a fixture too
# (RASPUTIN_LEGACY_PINS); the real pins are checked on the real download by
# the build job, and by scripts/check-bundle-kernel.sh on the built rootfs.
#
# Needs openssl, jq, mksquashfs and unsquashfs. A missing tool is a failure,
# not a skip (TEST-REAL): CI installs squashfs-tools before this runs.
#
# Usage: sh scripts/test-fetch-legacy-kmods.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/scripts/fetch-legacy-kmods.sh"

for t in openssl jq mksquashfs unsquashfs sha256sum; do
	command -v "$t" >/dev/null 2>&1 || { echo "test-fetch-legacy-kmods: $t is not installed" >&2; exit 1; }
done

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2" >&2; }

ROOTFS=rasputin-fw-n100-2026.10.3.rootfs
MODS="fat.ko vfat.ko nls_cp437.ko nls_iso8859-1.ko nls_utf8.ko"

# --- a throwaway PKI: a root, a leaf it issued, and a stranger -----------------
cd "$W" || exit 1
cat > ext.cnf <<'EOF'
[leaf]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = emailProtection, codeSigning
EOF
q() { "$@" >/dev/null 2>&1 || { echo "fixture step failed: $*" >&2; exit 1; }; }
q openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 \
	-subj "/CN=fixture root" -addext "basicConstraints=critical,CA:TRUE" \
	-addext "keyUsage=critical,keyCertSign,cRLSign"
q openssl req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj "/CN=fixture leaf"
q openssl x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out leaf.pem -days 2 \
	-extfile ext.cnf -extensions leaf
q openssl req -x509 -newkey rsa:2048 -nodes -keyout stranger.key -out stranger.pem -days 2 -subj "/CN=stranger"

sign() { # sign <file> <cert> <key>
	q openssl cms -sign -binary -in "$1" -signer "$2" -inkey "$3" -outform DER -out "$1.sig"
}

# --- the fixture release -------------------------------------------------------
# build_release <dir> — a squashfs with five fixture modules, its pins, a
# manifest naming its sha, everything signed by the leaf.
build_release() {
	d=$1
	mkdir -p "$d/tree/lib/modules/6.12.94"
	for m in $MODS; do printf 'fixture module %s\n' "$m" > "$d/tree/lib/modules/6.12.94/$m"; done
	q mksquashfs "$d/tree" "$d/$ROOTFS" -all-root -no-xattrs -noappend
	# shellcheck disable=SC2086 # one argument per module name
	( cd "$d/tree/lib/modules/6.12.94" && sha256sum $MODS ) > "$d/pins"
	sha=$(sha256sum "$d/$ROOTFS" | awk '{print $1}')
	jq -n --arg r "$ROOTFS" --arg s "$sha" \
		'{version:"2026.10.3", artifacts:[{sku:"fw-n100", rootfs:$r, rootfsSha256:$s}]}' > "$d/manifest.json"
	sign "$d/manifest.json" "$W/leaf.pem" "$W/leaf.key"
	sign "$d/$ROOTFS" "$W/leaf.pem" "$W/leaf.key"
}

# run <dir> [ca] — the SUT against that release; output in $d/out.txt
run() {
	d=$1; ca=${2:-$W/ca.pem}
	rm -rf "$d/staged"
	RASPUTIN_LEGACY_SRC="$d" RASPUTIN_LEGACY_PINS="$d/pins" \
		bash "$SUT" "$ca" "$d/staged" > "$d/out.txt" 2>&1
}

# refused <name> <dir> <fragment> [ca]
refused() {
	run "$2" "${4:-}"
	rc=$?
	if [ "$rc" -eq 0 ]; then no "$1" "exited 0; output: $(cat "$2/out.txt")"; return; fi
	if ! grep -qF -- "$3" "$2/out.txt"; then no "$1" "exit $rc but the output does not name '$3': $(cat "$2/out.txt")"; return; fi
	if [ -e "$2/staged" ]; then no "$1" "refused, but staged output anyway"; return; fi
	ok "$1"
}

# good
build_release "$W/good"
if run "$W/good"; then
	bad=""
	( cd "$W/good/staged/6.12.94" && sha256sum -c --quiet "$W/good/pins" ) >/dev/null 2>&1 || bad="module shas"
	[ "$(find "$W/good/staged/6.12.94" -type f | wc -l | tr -d ' ')" = 5 ] || bad="$bad module count"
	[ "$(cat "$W/good/staged/kernel-id")" = '6.12.94 #0 SMP Mon Jun 29 12:59:20 2026' ] || bad="$bad kernel-id"
	if [ -z "$bad" ]; then ok "good release: five pinned modules and the pinned legacy kernel id"; else no "good release" "wrong:$bad"; fi
else
	no "good release" "exited non-zero: $(cat "$W/good/out.txt")"
fi

# rootfs sha differs from the signed manifest
build_release "$W/rootfs-sha"
printf 'tampered' >> "$W/rootfs-sha/$ROOTFS"
sign "$W/rootfs-sha/$ROOTFS" "$W/leaf.pem" "$W/leaf.key"
refused "a .rootfs whose sha differs from the manifest is refused" "$W/rootfs-sha" "$ROOTFS has sha256"

# manifest signed by a stranger
build_release "$W/manifest"
sign "$W/manifest/manifest.json" "$W/stranger.pem" "$W/stranger.key"
refused "a manifest.json.sig that fails cms -verify is refused" "$W/manifest" "manifest.json.sig does not verify"

# rootfs signed by a stranger
build_release "$W/rootfs-sig"
sign "$W/rootfs-sig/$ROOTFS" "$W/stranger.pem" "$W/stranger.key"
refused "a .rootfs.sig that fails cms -verify is refused" "$W/rootfs-sig" "$ROOTFS.sig does not verify"

# a module that differs from its pin
build_release "$W/ko-sha"
sed 's/^[0-9a-f]\{64\}  vfat.ko$/0000000000000000000000000000000000000000000000000000000000000000  vfat.ko/' \
	"$W/ko-sha/pins" > "$W/ko-sha/pins.new" && mv "$W/ko-sha/pins.new" "$W/ko-sha/pins"
refused "a .ko whose sha differs from the pin is refused" "$W/ko-sha" "vfat.ko has sha256"

# no root CA
: > "$W/empty.pem"
refused "an empty root CA is refused" "$W/good" "is missing or empty" "$W/empty.pem"

printf '\nfetch-legacy-kmods: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
