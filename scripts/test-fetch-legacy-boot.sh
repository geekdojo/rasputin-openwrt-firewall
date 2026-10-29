#!/bin/sh
#
# test-fetch-legacy-boot.sh — fail-closed tests for scripts/fetch-legacy-boot.sh
# (geekdojo/geekdojo-brain#893, TC-893-13).
#
# What this script stages becomes the shared kernel on every fresh image's ESP
# and the modules a field box loads, as root, into its running kernel. So
# every way it could take bytes it should not is a case here, against a
# throwaway CA and a fixture release — a real GPT disk with a FAT ESP and a
# squashfs rootfs-0, gzipped and signed — built in a scratch directory:
#
#   good        exits 0; stages the kernel, the five modules and kernel-id
#   img-sig     -ab.img.gz.sig is signed by a key the CA never issued
#   manifest    manifest.json.sig is signed by a key the CA never issued
#   img-sha     the -ab.img.gz differs from the signed manifest's sha256
#   kernel-pin  the ESP kernel differs from the kernel pin
#   ko-sha      a module differs from its pin
#   missing     a release file is missing
#   no-ca       an empty root CA
#   no-sigtime  a signature with no signingTime
#   expired     signed while the leaf was valid, run after it expired: exits 0,
#               because it verifies at the signing time
#
# Each refusal must exit 1, name the offending file, and stage nothing. The
# pins are fixtures too (RASPUTIN_LEGACY_PINS, RASPUTIN_LEGACY_KERNEL_PIN); the
# real pins are checked on the real download by the build job.
#
# Needs openssl, jq, mksquashfs, unsquashfs, sfdisk and mtools. A missing tool
# is a failure, not a skip (TEST-REAL).
#
# Usage: sh scripts/test-fetch-legacy-boot.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/scripts/fetch-legacy-boot.sh"

for t in openssl jq mksquashfs unsquashfs sfdisk mformat mcopy mmd gzip sha256sum bash; do
	command -v "$t" >/dev/null 2>&1 || { echo "test-fetch-legacy-boot: $t is not installed" >&2; exit 1; }
done

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
export MTOOLS_SKIP_CHECK=1

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2" >&2; }

IMG=rasputin-fw-n100-2026.10.3-ab.img.gz
MODS="fat.ko vfat.ko nls_cp437.ko nls_iso8859-1.ko nls_utf8.ko"
LEGACY_ID=$(cat "$ROOT/image/legacy-kernel-id")

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

# A short-lived leaf from the same root, through `openssl ca`, which sets an
# exact end date (the "expired" case).
mkdir -p ca.db
: > ca.db/index.txt
echo 01 > ca.db/serial
cat > ca.cnf <<EOF
[ca]
default_ca = fx
[fx]
database = $W/ca.db/index.txt
new_certs_dir = $W/ca.db
serial = $W/ca.db/serial
certificate = $W/ca.pem
private_key = $W/ca.key
default_md = sha256
policy = any
unique_subject = no
copy_extensions = none
[any]
commonName = supplied
EOF
q openssl req -newkey rsa:2048 -nodes -keyout short.key -out short.csr -subj "/CN=fixture short-lived leaf"

sign() { # sign <file> <cert> <key>
	q openssl cms -sign -binary -in "$1" -signer "$2" -inkey "$3" -outform DER -out "$1.sig"
}

# bzimage <file> <banner> — a synthetic x86 setup header (see test-kernel-id.sh).
bzimage() {
	dd if=/dev/zero of="$1" bs=1024 count=32 2>/dev/null
	printf 'HdrS' | dd of="$1" bs=1 seek=514 conv=notrunc 2>/dev/null
	printf '\310\060' | dd of="$1" bs=1 seek=526 conv=notrunc 2>/dev/null
	printf '%s\000' "$2" | dd of="$1" bs=1 seek=13000 conv=notrunc 2>/dev/null
}

# --- the fixture release -------------------------------------------------------
# build_release <dir> — a GPT disk: p1 "esp" (FAT, /boot/vmlinuz with the
# legacy id), p2 "seed", p3 "rootfs-0" (squashfs with the five modules);
# gzipped, its pins, a manifest naming its sha, everything signed by the leaf.
build_release() {
	d=$1
	mkdir -p "$d/tree/lib/modules/6.12.94" "$d/espdir/boot"
	for m in $MODS; do printf 'fixture module %s\n' "$m" > "$d/tree/lib/modules/6.12.94/$m"; done
	bzimage "$d/espdir/boot/vmlinuz" "6.12.94 (builder@buildhost) #0 SMP Mon Jun 29 12:59:20 2026"
	q mksquashfs "$d/tree" "$d/rootfs.sq" -comp xz -all-root -no-xattrs -noappend
	truncate -s 24M "$d/disk.img"
	printf 'label: gpt\nstart=2048, size=20480, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="esp"\nsize=2048, name="seed"\nsize=16384, name="rootfs-0"\n' \
		| q sfdisk "$d/disk.img"
	q mformat -i "$d/disk.img@@$((2048 * 512))" -T 20480 -h 2 -s 32 ::
	q mcopy -s -i "$d/disk.img@@$((2048 * 512))" "$d/espdir/boot" ::
	rstart=$(sfdisk -J "$d/disk.img" | jq '.partitiontable.partitions[] | select(.name == "rootfs-0") | .start')
	q dd if="$d/rootfs.sq" of="$d/disk.img" bs=512 seek="$rstart" conv=notrunc
	gzip -c "$d/disk.img" > "$d/$IMG"
	rm -f "$d/disk.img" "$d/rootfs.sq"
	# shellcheck disable=SC2086 # one argument per module name
	( cd "$d/tree/lib/modules/6.12.94" && sha256sum $MODS ) > "$d/pins"
	( cd "$d/espdir/boot" && sha256sum vmlinuz ) > "$d/kpin"
	sha=$(sha256sum "$d/$IMG" | awk '{print $1}')
	jq -n --arg i "$IMG" --arg s "$sha" \
		'{version:"2026.10.3", artifacts:[{sku:"fw-n100", image:$i, sha256:$s}]}' > "$d/manifest.json"
	sign "$d/manifest.json" "$W/leaf.pem" "$W/leaf.key"
	sign "$d/$IMG" "$W/leaf.pem" "$W/leaf.key"
}

# run <dir> [ca] — the SUT against that release; output in $d/out.txt
run() {
	d=$1; ca=${2:-$W/ca.pem}
	rm -rf "$d/staged"
	RASPUTIN_LEGACY_SRC="$d" RASPUTIN_LEGACY_PINS="$d/pins" RASPUTIN_LEGACY_KERNEL_PIN="$d/kpin" \
		bash "$SUT" "$ca" "$d/staged" > "$d/out.txt" 2>&1
}

# refused <name> <dir> <fragment> [ca] — exit 1, the fragment named, nothing staged.
refused() {
	run "$2" "${4:-}"
	rc=$?
	if [ "$rc" -ne 1 ]; then no "$1" "exit $rc, want 1; output: $(cat "$2/out.txt")"; return; fi
	if ! grep -qF -- "$3" "$2/out.txt"; then no "$1" "exit 1 but the output does not name '$3': $(cat "$2/out.txt")"; return; fi
	if [ -e "$2/staged" ]; then no "$1" "refused, but staged output anyway"; return; fi
	ok "$1"
}

# TC-893-13: good fixtures write the kernel, the five modules and kernel-id.
build_release "$W/good"
if run "$W/good"; then
	bad=""
	( cd "$W/good/staged/6.12.94" && sha256sum -c --quiet "$W/good/pins" ) >/dev/null 2>&1 || bad="module shas"
	[ "$(find "$W/good/staged/6.12.94" -type f | wc -l | tr -d ' ')" = 5 ] || bad="$bad module count"
	[ "$(sha256sum "$W/good/staged/vmlinuz" | awk '{print $1}')" = "$(awk '{print $1}' "$W/good/kpin")" ] || bad="$bad kernel sha"
	[ "$(cat "$W/good/staged/kernel-id")" = "$LEGACY_ID" ] || bad="$bad kernel-id"
	if [ -z "$bad" ]; then ok "good release: the pinned kernel, five pinned modules and the legacy kernel id"; else no "good release" "wrong:$bad"; fi
else
	no "good release" "exited non-zero: $(cat "$W/good/out.txt")"
fi

# TC-893-13: a bad -ab.img.gz signature.
build_release "$W/img-sig"
sign "$W/img-sig/$IMG" "$W/stranger.pem" "$W/stranger.key"
refused "a bad -ab.img.gz signature is refused" "$W/img-sig" "$IMG.sig does not verify"

# TC-893-13: a bad manifest.json signature.
build_release "$W/manifest"
sign "$W/manifest/manifest.json" "$W/stranger.pem" "$W/stranger.key"
refused "a bad manifest.json signature is refused" "$W/manifest" "manifest.json.sig does not verify"

# TC-893-13: image sha256 differing from the manifest (re-signed, so only the sha is wrong).
build_release "$W/img-sha"
printf 'tampered' >> "$W/img-sha/$IMG"
sign "$W/img-sha/$IMG" "$W/leaf.pem" "$W/leaf.key"
refused "an image whose sha256 differs from the manifest is refused" "$W/img-sha" "$IMG has sha256"

# TC-893-13: ESP kernel sha256 differing from the kernel pin.
build_release "$W/kernel-pin"
printf '%064d  vmlinuz\n' 0 > "$W/kernel-pin/kpin"
refused "an ESP kernel off the kernel pin is refused" "$W/kernel-pin" "the ESP kernel in $IMG has sha256"

# TC-893-13: a module differing from its pin.
build_release "$W/ko-sha"
sed 's/^[0-9a-f]\{64\}  vfat.ko$/0000000000000000000000000000000000000000000000000000000000000000  vfat.ko/' \
	"$W/ko-sha/pins" > "$W/ko-sha/pins.new" && mv "$W/ko-sha/pins.new" "$W/ko-sha/pins"
refused "a module off its pin is refused" "$W/ko-sha" "vfat.ko has sha256"

# TC-893-13: a missing file.
build_release "$W/missing"
rm "$W/missing/$IMG.sig"
refused "a missing release file is refused" "$W/missing" "$IMG.sig is missing"

# No root CA.
: > "$W/empty.pem"
refused "an empty root CA is refused" "$W/good" "is missing or empty" "$W/empty.pem"

# No signingTime: -noattr leaves out every signed attribute.
build_release "$W/no-sigtime"
q openssl cms -sign -noattr -binary -in "$W/no-sigtime/manifest.json" -signer "$W/leaf.pem" \
	-inkey "$W/leaf.key" -outform DER -out "$W/no-sigtime/manifest.json.sig"
refused "a signature with no signingTime is refused" "$W/no-sigtime" "manifest.json.sig carries no signingTime"

# Signed by a short-lived leaf while it was valid, verified after it expired.
# The wait is for the fact itself, the leaf's expiry, with a bound.
build_release "$W/expired"
q openssl ca -batch -config "$W/ca.cnf" -in "$W/short.csr" -out "$W/short.pem" -notext \
	-startdate "$(jq -rn 'now - 3600 | strftime("%Y%m%d%H%M%SZ")')" \
	-enddate "$(jq -rn 'now + 5 | strftime("%Y%m%d%H%M%SZ")')" \
	-extfile "$W/ext.cnf" -extensions leaf
sign "$W/expired/manifest.json" "$W/short.pem" "$W/short.key"
sign "$W/expired/$IMG" "$W/short.pem" "$W/short.key"
n=0
while openssl x509 -checkend 0 -noout -in "$W/short.pem" >/dev/null 2>&1; do
	[ "$n" -lt 30 ] || { echo "test-fetch-legacy-boot: the short-lived leaf never expired" >&2; exit 1; }
	n=$((n + 1)); sleep 1
done
if run "$W/expired" && grep -qF "manifest.json.sig verified (at its signing time" "$W/expired/out.txt"; then
	ok "a release signed before its leaf expired still verifies at its signing time"
else
	no "a release signed before its leaf expired still verifies at its signing time" "$(cat "$W/expired/out.txt")"
fi

printf '\nfetch-legacy-boot: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
