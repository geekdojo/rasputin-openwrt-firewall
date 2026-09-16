#!/bin/sh
#
# node-id.sh — node-id helpers, SOURCED (not executed) by apply-seed.
#
# A node id is always the first label of an FQDN: it becomes the NATS username
# the agent presents to the bus, and the control plane only accepts an RFC 1123
# DNS label — 1-63 characters of a-z, 0-9 and '-', not starting or ending with
# '-', lowercase only. This is the same rule rasputin-provision's
# normalizeDNSLabel applies when it assigns an id, so every id this box accepts
# has to satisfy it or the node cannot join.
#
# The id is always SUPPLIED (RASPUTIN_NODE_ID in the seed); this box never
# makes one up (geekdojo/geekdojo-brain#423). The join token is bound to the id
# the control plane assigned, so it is only lowercased and trimmed
# (rasputin_label_canon, as rasputin-provision does) and then CHECKED with
# rasputin_label_valid. Rewriting it any further would produce an id the token
# does not match — a node that can never join, with no hint why.
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
