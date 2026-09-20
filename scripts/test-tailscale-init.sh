#!/bin/sh
#
# test-tailscale-init.sh — behaviour tests for
# files/etc/init.d/rasputin-tailscale.
#
# WHY
#   The init script does two things at boot that nothing else can see:
#     - it strips the Mesh CA blocks an older agent appended to the box's
#       global trust bundle, and REFUSES to rewrite that bundle if the result
#       does not account for exactly the blocks it removed. The bundle is what
#       every TLS client on the box trusts; a botched rewrite would break all
#       of them at once, so the refusal is the half worth pinning;
#     - it disables the stock tailscale service, so the next boot does not
#       start a second, env-less daemon on the same state file and port.
#   Neither is visible to a syntax or mode check, and both run once, at boot,
#   on hardware. (geekdojo/geekdojo-brain#542)
#
#   White-box, like test-mgmt-harden.sh: the init script is sourced (its
#   `#!/bin/sh /etc/rc.common` line is a comment when sourced) and its
#   functions are driven directly, with the paths it reads pointed at scratch
#   files through the env overrides the script documents.
#
# Usage: sh scripts/test-tailscale-init.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/files/etc/init.d/rasputin-tailscale"
[ -f "$SUT" ] || { echo "missing: $SUT" >&2; exit 2; }

pass=0
fail=0
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3" >&2; }

SCRATCH=$(mktemp -d 2>/dev/null || mktemp -d -t tsinit)
trap 'rm -rf "$SCRATCH"' EXIT

logger() { :; }

# A stub stock init whose every invocation is recorded, and whose `enabled`
# answer is whatever $SCRATCH/stock-enabled says.
STOCK="$SCRATCH/stock-tailscale"
STOCK_LOG="$SCRATCH/stock.log"
cat > "$STOCK" <<'STUB'
#!/bin/sh
printf '%s\n' "$1" >> "$STOCK_LOG"
case "$1" in
	enabled) [ -f "$STOCK_STATE" ] && exit 0; exit 1 ;;
	disable) rm -f "$STOCK_STATE"; exit 0 ;;
	stop) exit 0 ;;
esac
exit 0
STUB
chmod 755 "$STOCK"
STOCK_STATE="$SCRATCH/stock-enabled"
export STOCK_LOG STOCK_STATE

# Point the script at the scratch copies before sourcing it: the paths are
# resolved at source time, which is exactly how they are resolved on the box.
RASPUTIN_CA_BUNDLE_FILE="$SCRATCH/ca-certificates.crt"
RASPUTIN_STOCK_TAILSCALE_INIT="$STOCK"
RASPUTIN_MESH_CA_BUNDLE="$SCRATCH/mesh/tailscaled-ca.pem"
export RASPUTIN_CA_BUNDLE_FILE RASPUTIN_STOCK_TAILSCALE_INIT RASPUTIN_MESH_CA_BUNDLE

# shellcheck source=/dev/null
. "$SUT"

BUNDLE="$RASPUTIN_CA_BUNDLE_FILE"
MARKER='# rasputin-mesh-ca (managed by rasputin-agent)'

# Three PEM-shaped blocks. Content is irrelevant to the script — it counts
# BEGIN lines and cuts on the marker and the END line — so these stay short.
pem() { printf -- '-----BEGIN CERTIFICATE-----\n%s\n-----END CERTIFICATE-----\n' "$1"; }

write_public_bundle() {
	{ pem publicroot1; pem publicroot2; } > "$BUNDLE"
}
append_mesh_block() {
	{ printf '\n%s\n' "$MARKER"; pem "$1"; } >> "$BUNDLE"
}
begins() { grep -c '^-----BEGIN CERTIFICATE-----$' "$BUNDLE" 2>/dev/null || true; }
# Content comparison rather than a checksum: busybox has no cksum, and a
# missing tool would have made every "left untouched" assertion compare an
# empty string with an empty string and pass without testing anything (caught
# running this suite on the box, bench 2026-09-19).

echo "== strip the appended Mesh CA"

# One appended block: removed, the public roots survive, exit 0 (changed).
write_public_bundle; append_mesh_block meshca1
strip_mesh_ca_from_bundle; rc=$?
[ "$rc" = 0 ] && ok || no "appended: returns changed(0)" "0" "$rc"
[ "$(begins)" = 2 ] && ok || no "appended: public roots survive" "2" "$(begins)"
grep -q 'publicroot1' "$BUNDLE" && grep -q 'publicroot2' "$BUNDLE" && ok || no "appended: both public roots by name" "both present" "$(cat "$BUNDLE")"
grep -q 'meshca1' "$BUNDLE" && no "appended: mesh CA removed" "absent" "still present" || ok
grep -q "$MARKER" "$BUNDLE" && no "appended: marker removed" "absent" "still present" || ok

# Idempotent: a second pass has nothing to do and says so.
strip_mesh_ca_from_bundle; rc=$?
[ "$rc" = 1 ] && ok || no "second pass: returns unchanged(1)" "1" "$rc"
[ "$(begins)" = 2 ] && ok || no "second pass: bundle untouched" "2" "$(begins)"

# A bundle that never had the append is left exactly as it was, byte for byte.
write_public_bundle
before_content=$(cat "$BUNDLE")
strip_mesh_ca_from_bundle; rc=$?
[ "$rc" = 1 ] && ok || no "never appended: returns unchanged(1)" "1" "$rc"
[ "$(cat "$BUNDLE")" = "$before_content" ] && ok || no "never appended: byte-identical" "unchanged" "rewritten"

# Two appended blocks (a rotation appended a second CA): both go, roots stay.
write_public_bundle; append_mesh_block meshca1; append_mesh_block meshca2
strip_mesh_ca_from_bundle; rc=$?
[ "$rc" = 0 ] && ok || no "two blocks: returns changed(0)" "0" "$rc"
[ "$(begins)" = 2 ] && ok || no "two blocks: only the public roots are left" "2" "$(begins)"

echo "== refuse to damage the bundle"

# A marker with NO terminating END line makes the cut run to EOF. When public
# roots sit after it, that would silently delete them — one certificate too
# many — and the count check has to refuse the whole rewrite.
write_public_bundle
{ printf '\n%s\n' "$MARKER"; printf -- '-----BEGIN CERTIFICATE-----\ntruncated\n'; } >> "$BUNDLE"
pem publicroot3 >> "$BUNDLE"
before_content=$(cat "$BUNDLE")
strip_mesh_ca_from_bundle; rc=$?
[ "$rc" = 1 ] && ok || no "truncated block before a root: returns refused(1)" "1" "$rc"
[ "$(cat "$BUNDLE")" = "$before_content" ] && ok || no "truncated block before a root: bundle left untouched" "unchanged" "rewritten"
grep -q 'publicroot3' "$BUNDLE" && ok || no "truncated block before a root: the root after it survives" "present" "deleted"
[ -z "$(ls "$SCRATCH"/ca-certificates.crt.rasputin.* 2>/dev/null)" ] && ok || no "truncated block before a root: no temp file left behind" "none" "$(ls "$SCRATCH"/ca-certificates.crt.rasputin.* 2>/dev/null)"

# The same truncation with nothing after it removes exactly the one managed
# block, which is what the count says, so it is allowed through.
write_public_bundle
{ printf '\n%s\n' "$MARKER"; printf -- '-----BEGIN CERTIFICATE-----\ntruncated\n'; } >> "$BUNDLE"
strip_mesh_ca_from_bundle; rc=$?
[ "$rc" = 0 ] && ok || no "truncated block at EOF: returns changed(0)" "0" "$rc"
[ "$(begins)" = 2 ] && ok || no "truncated block at EOF: public roots survive" "2" "$(begins)"

# A bundle that is nothing BUT the managed block: stripping it would leave no
# trust at all, so it is refused rather than emptied.
: > "$BUNDLE"; append_mesh_block meshca1
before_content=$(cat "$BUNDLE")
strip_mesh_ca_from_bundle; rc=$?
[ "$rc" = 1 ] && ok || no "mesh-only bundle: returns refused(1)" "1" "$rc"
[ "$(cat "$BUNDLE")" = "$before_content" ] && ok || no "mesh-only bundle: left untouched" "unchanged" "rewritten"

# No bundle at all (an image without ca-bundle): nothing to do, no error.
rm -f "$BUNDLE"
strip_mesh_ca_from_bundle; rc=$?
[ "$rc" = 1 ] && ok || no "absent bundle: returns unchanged(1)" "1" "$rc"

echo "== disable the stock service"

# Enabled stock service: disabled, stopped, and reported as changed.
: > "$STOCK_LOG"; : > "$STOCK_STATE"
disable_stock_tailscale; rc=$?
[ "$rc" = 0 ] && ok || no "enabled stock: returns changed(0)" "0" "$rc"
[ ! -f "$STOCK_STATE" ] && ok || no "enabled stock: disabled" "disabled" "still enabled"
grep -q '^stop$' "$STOCK_LOG" && ok || no "enabled stock: stopped too" "stop called" "$(cat "$STOCK_LOG")"

# Already disabled: not disabled again (no thrash), still stopped, unchanged.
: > "$STOCK_LOG"
disable_stock_tailscale; rc=$?
[ "$rc" = 1 ] && ok || no "already disabled: returns unchanged(1)" "1" "$rc"
grep -q '^disable$' "$STOCK_LOG" && no "already disabled: no second disable" "not called" "called" || ok
grep -q '^stop$' "$STOCK_LOG" && ok || no "already disabled: still stopped" "stop called" "$(cat "$STOCK_LOG")"

# No stock init on the box at all: nothing to do, no error.
RASPUTIN_STOCK_TAILSCALE_INIT="$SCRATCH/not-here" STOCK_INIT="$SCRATCH/not-here" disable_stock_tailscale
rc=$?
[ "$rc" = 1 ] && ok || no "absent stock init: returns unchanged(1)" "1" "$rc"

echo "== the service definition itself"

# The whole point of the file: tailscaled gets SSL_CERT_FILE, pointed at the
# bundle the agent writes, and reads the same UCI options the stock init read.
grep -q 'procd_set_param env SSL_CERT_FILE="\$MESH_CA_BUNDLE"' "$SUT" && ok \
	|| no "service: passes SSL_CERT_FILE to tailscaled" "present" "absent"
[ "$MESH_CA_BUNDLE" = "$RASPUTIN_MESH_CA_BUNDLE" ] && ok \
	|| no "service: mesh bundle path is overridable" "$RASPUTIN_MESH_CA_BUNDLE" "$MESH_CA_BUNDLE"
for opt in log_stdout log_stderr port state_file fw_mode; do
	grep -q "\"settings\" $opt" "$SUT" && ok || no "service: reads UCI option $opt" "present" "absent"
done
# START must stay after the stock S80 and before the agent's S90: the ordering
# is what makes stopping the stock daemon deterministic within one boot.
start_value=$(sed -n 's/^START=\([0-9]*\)$/\1/p' "$SUT")
[ "$start_value" -gt 80 ] && [ "$start_value" -lt 90 ] && ok \
	|| no "service: START between the stock init (80) and the agent (90)" "81..89" "$start_value"

echo ""
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
