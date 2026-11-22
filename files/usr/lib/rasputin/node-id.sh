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

# rasputin_cluster_id_check VALUE
#   Print nothing and exit 0 when VALUE is a valid cluster id. Otherwise print
#   the one sentence naming the rule it breaks and exit 1. A cluster id is a
#   DNS label of at most 59 characters that does not start with sso-: every
#   cluster signs in at sso-<cluster id>.local, and that name has to fit in one
#   63-character label and must not be another cluster's sign-in name
#   (geekdojo/geekdojo-brain#996). VALUE is expected already canonical
#   (rasputin_label_canon). rasputin_label_valid is NOT tightened to match: it
#   still checks node ids, which keep 63, and ids accepted before this rule.
rasputin_cluster_id_check() {
	if [ "${#1}" -gt 59 ]; then
		printf '%s\n' "The cluster id '$1' is ${#1} characters, and a cluster id allows at most 59 so that its sign-in name, sso-<cluster id>.local, fits in one DNS label."
		return 1
	fi
	if ! rasputin_label_valid "$1"; then
		printf '%s\n' "The cluster id '$1' is not a DNS label: it may hold only a-z, 0-9 and -, and must not start or end with -."
		return 1
	fi
	case "$1" in
		sso-*)
			printf '%s\n' "The cluster id '$1' starts with sso-, which is reserved for sign-in names: every cluster signs in at sso-<cluster id>.local, so this one would publish another cluster's sign-in name."
			return 1
			;;
	esac
	return 0
}
