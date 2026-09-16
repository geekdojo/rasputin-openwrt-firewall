#!/bin/sh
#
# bus-pin.sh — bus-pin helpers, SOURCED (not executed) by apply-seed.
#
# The cluster bus is TLS, and a node trusts the controlplane's end of it by a
# PIN: RASPUTIN_BUS_PIN, the SHA-256 of the bus key's public half
# (geekdojo/geekdojo-brain#448; the seed contract is docs/bus-tls-contract.md
# in rasputin-control-plane). The exact form is
#
#   sha256/<standard, padded base64 of the 32-byte digest>   (51 characters)
#
# e.g. sha256/47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=
#
# The agent accepts ONLY that form: it trims surrounding whitespace and refuses
# everything else (hex, URL-safe base64, a missing '=', SHA256/, curl's
# sha256//). rasputin_bus_pin_valid applies the same rule as the agent's
# proto.ParseBusPin, including its STRICT base64 decode: 32 bytes encode to 43
# characters plus one '=', and the 43rd character carries two unused low bits
# that must be zero. A pin that passes here is one the agent will accept.
#
# Executable only because validate-files.sh requires +x for everything in this
# directory; running it directly defines the functions and does nothing else.
# busybox ash compatible: no bashisms, no `local` (helper variables carry a
# _bp_ prefix instead). Tested by scripts/test-bus-pin.sh.

# rasputin_seed_trim VALUE
#   Print VALUE with leading and trailing whitespace removed, including the CR
#   a seed saved on Windows leaves on every value. Nothing else changes.
rasputin_seed_trim() {
	_bp_ws=$(printf ' \t\n\r\v\f')
	_bp_v=$1
	_bp_v=${_bp_v#"${_bp_v%%[!$_bp_ws]*}"}
	_bp_v=${_bp_v%"${_bp_v##*[!$_bp_ws]}"}
	printf '%s' "$_bp_v"
}

# rasputin_bus_pin_valid VALUE
#   Exit 0 when VALUE is exactly a canonical bus pin, 1 otherwise. VALUE is
#   not trimmed here; trim it first with rasputin_seed_trim. The alphabet is
#   spelled out rather than written as ranges: range expressions in shell
#   patterns can follow the locale's collation order, which is not ASCII
#   everywhere.
rasputin_bus_pin_valid() {
	case "$1" in
		sha256/*) ;;
		*) return 1 ;;
	esac
	_bp_b64=${1#sha256/}
	# 44 characters. ${#} of a non-ASCII string counts bytes in some shells and
	# characters in others, so this is only exact for ASCII; the alphabet check
	# below is what refuses anything else.
	[ "${#_bp_b64}" -eq 44 ] || return 1
	# The first 43 are base64 characters with no '=' among them...
	case "${_bp_b64%=}" in
		*[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/]*) return 1 ;;
	esac
	# ...the 44th is the one '=' of padding, and the 43rd is one of the 16
	# characters whose value has its two low bits clear (index 0, 4, 8, ...),
	# as a strict decoder requires.
	case "$_bp_b64" in
		*[AEIMQUYcgkosw048]=) return 0 ;;
	esac
	return 1
}
