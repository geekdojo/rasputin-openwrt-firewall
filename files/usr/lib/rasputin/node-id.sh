#!/bin/sh
#
# node-id.sh — node-id helpers, SOURCED (not executed) by apply-seed.
#
# A node id is always the first label of an FQDN: it becomes the NATS username
# the agent presents to the bus, and the control plane only accepts an RFC 1123
# DNS label — 1-63 characters of a-z, 0-9 and '-', not starting or ending with
# '-', lowercase only. This is the same rule rasputin-provision's
# normalizeDNSLabel applies when it assigns an id, so every id this box produces
# has to satisfy it or the node cannot join.
#
# Two kinds of id, two behaviours:
#   - DERIVED here (DMI serial, else a persistent UUID) ONLY for a seed with no
#     join token: rasputin_label_normalize bends the raw string into a valid
#     label, deterministically, so the same box always derives the same id. A
#     seed WITH a token must supply the id — apply-seed refuses it otherwise,
#     because the token is bound to one id (geekdojo/geekdojo-brain#423).
#   - SUPPLIED by an operator (RASPUTIN_NODE_ID in the seed): the join token is
#     bound to the id they chose, so it is only lowercased and trimmed
#     (rasputin_label_canon, as rasputin-provision does) and then CHECKED with
#     rasputin_label_valid. Rewriting it any further would produce an id the
#     token does not match — a node that can never join, with no hint why.
#
# Executable only because validate-files.sh requires +x for everything in this
# directory; running it directly defines the functions and does nothing else.
# busybox ash compatible: no bashisms, no `local` (helper variables carry an
# _rl_ prefix instead). Tested by scripts/test-node-id.sh.

# rasputin_label_valid VALUE
#   Exit 0 when VALUE is already a valid node id, 1 otherwise. The set is
#   spelled out rather than written as a-z: range expressions in shell patterns
#   can follow the locale's collation order, which is not ASCII everywhere.
rasputin_label_valid() {
	case "$1" in
		"" | -* | *- | *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
	esac
	[ "${#1}" -le 63 ]
}

# rasputin_label_canon VALUE
#   Print VALUE with leading/trailing whitespace (including a CR from a seed
#   saved on Windows) removed and ASCII letters lowercased. Nothing else changes:
#   the result still has to pass rasputin_label_valid.
rasputin_label_canon() {
	_rl_ws=$(printf ' \t\n\r\v\f')
	_rl_v=$1
	_rl_v=${_rl_v#"${_rl_v%%[!$_rl_ws]*}"}
	_rl_v=${_rl_v%"${_rl_v##*[!$_rl_ws]}"}
	printf '%s' "$_rl_v" | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
}

# rasputin_label_normalize VALUE
#   Print a valid node id derived from VALUE, or nothing when VALUE holds no
#   usable character: lowercase, map every character outside a-z 0-9 - to '-'
#   (each byte of a multi-byte character counts as one), collapse runs of '-',
#   trim '-' from both ends, cut to 63 characters, trim a trailing '-' again.
#   An empty result means "fall through to the next id source".
rasputin_label_normalize() {
	_rl_v=$(printf '%s' "$1" \
		| LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz' \
		| LC_ALL=C tr '\n' ' ' \
		| LC_ALL=C sed 's/[^abcdefghijklmnopqrstuvwxyz0123456789-]/-/g; s/--*/-/g; s/^-//; s/-$//')
	_rl_v=$(printf '%s\n' "$_rl_v" | LC_ALL=C cut -c1-63)
	printf '%s' "${_rl_v%-}"
}

# rasputin_dmi_node_id [DMI_DIR]
#   Print a node id derived from the first usable DMI serial under DMI_DIR
#   (default /sys/class/dmi/id), or nothing. Sources in priority order:
#   board_serial, product_serial, chassis_serial.
#
#   Many cheap N100 boards (the CWWK x86-p5-n100 reference Node N among them)
#   leave these at AMI placeholder strings like "Default string", which would
#   give every such box the same id — useless for identity — so placeholders
#   are skipped, as is any serial that normalizes to nothing.
rasputin_dmi_node_id() {
	_rl_dir=${1:-/sys/class/dmi/id}
	for _rl_src in board_serial product_serial chassis_serial; do
		[ -f "$_rl_dir/$_rl_src" ] || continue
		# Trim surrounding whitespace and collapse internal runs (sometimes seen
		# in vendor strings) so the placeholder match below is reliable. An
		# unreadable file is skipped, never fatal to a `set -e` caller.
		_rl_raw=$(awk '{$1=$1; print}' "$_rl_dir/$_rl_src" 2>/dev/null) || _rl_raw=""
		case "$_rl_raw" in
			"" | \
			"Default string" | \
			"To Be Filled By O.E.M." | \
			"To be filled by O.E.M." | \
			"System Serial Number" | \
			"Not Specified" | \
			"Not Applicable" | \
			"None" | \
			"O.E.M." | \
			"OEM" | \
			"0123456789")
				continue ;;
		esac
		_rl_id=$(rasputin_label_normalize "$_rl_raw")
		if [ -n "$_rl_id" ]; then
			printf '%s' "$_rl_id"
			return 0
		fi
	done
	return 0
}
