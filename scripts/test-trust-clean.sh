#!/bin/sh
#
# test-trust-clean.sh — behaviour tests for files/etc/init.d/rasputin-trust-clean.
#
# WHY (geekdojo/geekdojo-brain#531)
#   The script deletes a file that decides which images this box will install.
#   Both ways it can be wrong are invisible at boot: leave the overlay copy in
#   place and the anchor is still whatever the box was carrying, so #531 did
#   nothing; delete it when the image ships no anchor of its own and the box is
#   left unable to verify anything at all. Neither shows up in a syntax check,
#   and neither is noticed until an update is refused or — worse — accepted.
#
#   White-box, like test-mgmt-harden.sh: the init script is sourced (its
#   rc.common shebang is a comment when sourced), and the overlay, rom and
#   merged roots, the kernel log device and drop_caches are pointed at scratch
#   paths through the env knobs the script reads. These are plain directories,
#   so they test the DECISIONS; what a mounted overlay serves afterwards, and
#   what lands in the real kernel log, is test-trust-clean-overlay.sh's job.
#
#   The log is asserted in the kmsg stand-in, not in `logger`: the script runs
#   at S10, before logd (S12), so a `logger` line is lost (bench, dev.130).
#
# SHELLS
#   The script runs under busybox ash on the box. The whole suite is re-executed
#   under each shell in TEST_SHELLS (default: whichever of sh, dash, bash and
#   `busybox sh` are installed), so a construct one shell reads differently fails
#   here rather than on hardware. REQUIRE_BUSYBOX=1 (CI sets it) turns a missing
#   busybox into a failure, so the target shell cannot silently drop out.
#
# Usage: sh scripts/test-trust-clean.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SUT="$ROOT/files/etc/init.d/rasputin-trust-clean"
[ -f "$SUT" ] || { echo "missing: $SUT" >&2; exit 2; }

# --- outer pass: fan the suite out across shells ------------------------------
if [ -z "${TRUST_CLEAN_INNER:-}" ]; then
	if [ -z "${TEST_SHELLS:-}" ]; then
		TEST_SHELLS=""
		for s in sh dash bash; do
			command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
		done
		command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
	fi
	[ -n "$TEST_SHELLS" ] || { echo "trust-clean: no shell found to test under" >&2; exit 1; }

	outer_fail=0
	for shell in $TEST_SHELLS; do
		printf '=== shell: %s ===\n' "$shell"
		if [ "$shell" = busybox_sh ]; then
			TRUST_CLEAN_INNER=1 busybox sh "$0" || outer_fail=$((outer_fail + 1))
		else
			TRUST_CLEAN_INNER=1 "$shell" "$0" || outer_fail=$((outer_fail + 1))
		fi
	done

	case " $TEST_SHELLS " in
		*" busybox_sh "*) ;;
		*)
			if [ "${REQUIRE_BUSYBOX:-0}" = "1" ]; then
				echo "trust-clean: REQUIRE_BUSYBOX=1 but busybox is not installed — the target shell was not tested" >&2
				exit 1
			fi ;;
	esac

	if [ "$outer_fail" -ne 0 ]; then
		printf 'trust-clean: FAILED under %d shell(s)\n' "$outer_fail" >&2
		exit 1
	fi
	printf 'trust-clean: passed under:%s\n' "$TEST_SHELLS"
	exit 0
fi
# --- inner pass: the cases themselves -----------------------------------------

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no() { fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "$2" >&2; }

SCRATCH=$(mktemp -d 2>/dev/null || mktemp -d -t trustclean)
trap 'rm -rf "$SCRATCH"' EXIT

TRUST_REL=etc/rasputin/trust/root-ca.pem

# The script logs to the kernel ring buffer (/dev/kmsg); point that at a file.
# logger is stubbed separately: at S10 there is no logd, so a line that only
# reached logger is a line nobody will ever read, and must not count.
LOGFILE="$SCRATCH/kmsg"
LOGGER_FILE="$SCRATCH/logger"
logger() { printf '%s\n' "$*" >> "$LOGGER_FILE"; }

# fixture <case> <overlay-content|-> <rom-content|-> — builds a scratch set of
# roots and points the script at them. `-` means "this file does not exist".
# The "merged" root stands in for the mounted overlay and, by default, serves
# the image's copy — what a correct eviction produces.
fixture() {
	_case=$1; _ov=$2; _rom=$3
	CASE_DIR="$SCRATCH/$_case"
	OV_ROOT="$CASE_DIR/overlay/upper"
	ROM_ROOT="$CASE_DIR/rom"
	MERGED_ROOT="$CASE_DIR/merged"
	DROP="$CASE_DIR/drop_caches"
	mkdir -p "$OV_ROOT" "$ROM_ROOT" "$MERGED_ROOT/$(dirname "$TRUST_REL")"
	if [ "$_ov" != "-" ]; then
		mkdir -p "$OV_ROOT/$(dirname "$TRUST_REL")"
		printf '%s\n' "$_ov" > "$OV_ROOT/$TRUST_REL"
	fi
	if [ "$_rom" != "-" ]; then
		mkdir -p "$ROM_ROOT/$(dirname "$TRUST_REL")"
		printf '%s\n' "$_rom" > "$ROM_ROOT/$TRUST_REL"
		cp "$ROM_ROOT/$TRUST_REL" "$MERGED_ROOT/$TRUST_REL"
	fi
	: > "$LOGFILE"
	: > "$LOGGER_FILE"
}

# run — source the script with the fixture's roots and call start(), in a
# subshell so each case gets clean state. stdout is discarded; the kmsg file is
# the record.
run() {
	(
		RASPUTIN_TRUST_OVERLAY_ROOT="$OV_ROOT"
		RASPUTIN_TRUST_ROM_ROOT="$ROM_ROOT"
		RASPUTIN_TRUST_MERGED_ROOT="$MERGED_ROOT"
		RASPUTIN_TRUST_KMSG="$LOGFILE"
		RASPUTIN_TRUST_DROP_CACHES="$DROP"
		export RASPUTIN_TRUST_OVERLAY_ROOT RASPUTIN_TRUST_ROM_ROOT \
			RASPUTIN_TRUST_MERGED_ROOT RASPUTIN_TRUST_KMSG RASPUTIN_TRUST_DROP_CACHES
		# shellcheck disable=SC1090
		. "$SUT"
		start
	) >/dev/null 2>&1
}

echo "1. an overlay copy identical to the image's is removed"
fixture identical "IMAGE-ANCHOR" "IMAGE-ANCHOR"
run
if [ ! -e "$OV_ROOT/$TRUST_REL" ]; then ok "overlay copy gone"; else no "overlay copy gone" "still present"; fi
[ -s "$ROM_ROOT/$TRUST_REL" ] && ok "image copy untouched" || no "image copy untouched" "/rom was modified"
[ ! -s "$LOGFILE" ] && ok "nothing logged — the anchor in force did not change" || no "silent for an identical copy" "$(cat "$LOGFILE")"

echo "2. an overlay copy that DIFFERS is removed, loudly"
fixture differs "OPERATOR-ANCHOR" "IMAGE-ANCHOR"
run
if [ ! -e "$OV_ROOT/$TRUST_REL" ]; then ok "overlay copy gone"; else no "overlay copy gone" "still present"; fi
grep -q "WARNING" "$LOGFILE" && ok "warned that a differing anchor was dropped" || no "warned" "$(cat "$LOGFILE")"
grep -q "DIFFERS" "$LOGFILE" && ok "the log says what was different" || no "log says DIFFERS" "$(cat "$LOGFILE")"
grep -q '^<4>rasputin-trust-clean: WARNING' "$LOGFILE" \
	&& ok "written to the kernel log at warning priority, tagged" \
	|| no "kernel-log line <4>rasputin-trust-clean: WARNING" "$(cat "$LOGFILE")"
[ ! -s "$LOGGER_FILE" ] && ok "not (only) handed to logger, which has no logd at S10" \
	|| no "no logger at S10" "$(cat "$LOGGER_FILE")"

echo "3. the image's own anchor is what remains in force"
fixture inforce "OPERATOR-ANCHOR" "IMAGE-ANCHOR"
run
if [ "$(cat "$ROM_ROOT/$TRUST_REL")" = "IMAGE-ANCHOR" ]; then
	ok "the image's bytes are the surviving anchor"
else
	no "image anchor survives" "$(cat "$ROM_ROOT/$TRUST_REL")"
fi
[ "$(cat "$DROP" 2>/dev/null)" = 2 ] && ok "the dentry cache is dropped so the mount re-resolves" \
	|| no "drop_caches written with 2" "got: $(cat "$DROP" 2>/dev/null || echo nothing)"
grep -q "ERROR" "$LOGFILE" && no "no ERROR when the merged view is the image's" "$(cat "$LOGFILE")" \
	|| ok "no ERROR when the merged view is the image's"

echo "4. an image with NO anchor keeps the overlay copy (fail safe, not fail empty)"
fixture noanchor "OPERATOR-ANCHOR" "-"
run
if [ -e "$OV_ROOT/$TRUST_REL" ]; then
	ok "overlay copy kept — the box can still verify something"
else
	no "overlay copy kept" "removed, leaving the box with no trust anchor at all"
fi
grep -q "WARNING" "$LOGFILE" && ok "warned that the image ships no anchor" || no "warned" "$(cat "$LOGFILE")"

echo "5. an empty (zero-byte) image anchor counts as no anchor"
fixture emptyanchor "OPERATOR-ANCHOR" ""
: > "$ROM_ROOT/$TRUST_REL"
run
[ -e "$OV_ROOT/$TRUST_REL" ] && ok "overlay copy kept" || no "overlay copy kept" "removed on an empty /rom anchor"

echo "6. nothing on the overlay: a no-op, and silent"
fixture clean "-" "IMAGE-ANCHOR"
run
[ -s "$ROM_ROOT/$TRUST_REL" ] && ok "image copy untouched" || no "image copy untouched" "/rom was modified"
[ ! -s "$LOGFILE" ] && ok "logs nothing on a steady-state boot" || no "silent" "$(cat "$LOGFILE")"
[ ! -e "$DROP" ] && ok "does not touch the caches when there was nothing to remove" || no "no drop_caches" "written"

echo "7. idempotent: a second boot changes nothing and says nothing"
fixture twice "IMAGE-ANCHOR" "IMAGE-ANCHOR"
run
: > "$LOGFILE"
run
[ ! -s "$LOGFILE" ] && ok "second run is silent" || no "second run silent" "$(cat "$LOGFILE")"
[ -s "$ROM_ROOT/$TRUST_REL" ] && ok "image copy still intact" || no "image copy intact" "/rom was modified"

echo "8. not an overlay layout (no /rom): no-op, never an error"
fixture noroot "-" "-"
rmdir "$ROM_ROOT"
run
[ ! -s "$LOGFILE" ] && ok "silent when there is no /rom to compare against" || no "silent" "$(cat "$LOGFILE")"

echo "9. the mount still serves the stale copy after eviction: the image's bytes are written through it"
fixture stillstale "OPERATOR-ANCHOR" "IMAGE-ANCHOR"
printf '%s\n' "OPERATOR-ANCHOR" > "$MERGED_ROOT/$TRUST_REL"
run
if [ "$(cat "$MERGED_ROOT/$TRUST_REL")" = "IMAGE-ANCHOR" ]; then
	ok "the running view now reads the image's anchor"
else
	no "running view reads the image's anchor" "$(cat "$MERGED_ROOT/$TRUST_REL")"
fi
grep -q "still served" "$LOGFILE" && ok "the fallback is logged" || no "fallback logged" "$(cat "$LOGFILE")"
[ "$(cat "$ROM_ROOT/$TRUST_REL")" = "IMAGE-ANCHOR" ] && ok "/rom untouched" || no "/rom untouched" "modified"

echo "10. no kernel log device (a manual run off-box): falls back to logger"
fixture nokmsg "OPERATOR-ANCHOR" "IMAGE-ANCHOR"
(
	RASPUTIN_TRUST_OVERLAY_ROOT="$OV_ROOT" RASPUTIN_TRUST_ROM_ROOT="$ROM_ROOT"
	RASPUTIN_TRUST_MERGED_ROOT="$MERGED_ROOT" RASPUTIN_TRUST_DROP_CACHES="$DROP"
	RASPUTIN_TRUST_KMSG="$CASE_DIR/no-such-dir/kmsg"
	export RASPUTIN_TRUST_OVERLAY_ROOT RASPUTIN_TRUST_ROM_ROOT RASPUTIN_TRUST_MERGED_ROOT \
		RASPUTIN_TRUST_DROP_CACHES RASPUTIN_TRUST_KMSG
	# shellcheck disable=SC1090
	. "$SUT"
	start
) >/dev/null 2>&1
grep -q "WARNING" "$LOGGER_FILE" && ok "the warning still goes somewhere" || no "logger fallback" "$(cat "$LOGGER_FILE")"

echo ""
if [ "$fail" -ne 0 ]; then
	printf 'FAILED — %d of %d checks\n' "$fail" "$((pass + fail))" >&2
	exit 1
fi
printf 'OK — %d checks passed\n' "$pass"
