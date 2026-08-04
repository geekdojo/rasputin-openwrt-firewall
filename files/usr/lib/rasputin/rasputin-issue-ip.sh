#!/bin/sh
# rasputin-issue-ip — surface the firewall's live IPv4s on the console.
#
# The WAN address is DHCP'd, so on a headless bring-up it's otherwise unknowable
# without hunting the upstream router's lease table or attaching a console and
# running `ip addr` (this bit every CWWK bring-up). Parity with the OS nodes'
# rasputin-issue-ip, adapted to OpenWrt: it rewrites /etc/banner (shown at the
# serial/VGA login prompt) with the current WAN + LAN IPv4, and echoes a line
# into the boot/console scroll where a busy boot can't bury it like it buries an
# idle login banner. Driven by the hotplug.d/iface trigger (WAN/LAN up/renew/
# down): the LAN ifup at boot paints it the first time, DHCP renewals keep it
# fresh. Safe to run anytime; idempotent.
BANNER=/etc/banner

wan_ip=""
lan_ip=""
# OpenWrt's network helpers read the addresses straight from netifd's ubus state
# — busybox `ip` has no `route get`, so we don't mirror the OS default-route
# trick. Fall back to parsing `ip addr` per device if the lib is ever absent.
if [ -r /lib/functions/network.sh ]; then
	. /lib/functions/network.sh
	network_flush_cache
	network_get_ipaddr wan_ip wan
	network_get_ipaddr lan_ip lan
fi
[ -n "$wan_ip" ] || wan_ip=$(ip -4 addr show dev eth1 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
[ -n "$lan_ip" ] || lan_ip=$(ip -4 addr show dev br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)

# ASCII only — a dumb serial terminal may not render box-drawing glyphs.
new=$(cat <<EOF
  Rasputin Firewall
  ---------------------------------
  WAN: ${wan_ip:-(acquiring address...)}
  LAN: ${lan_ip:-(acquiring address...)}
EOF
)

# The WAN fires a hotplug event on every DHCP renewal and /etc/banner lives on
# the flash-backed overlay, so only rewrite when the addresses actually changed.
if [ "$(cat "$BANNER" 2>/dev/null)" != "$new" ]; then
	printf '%s\n\n' "$new" > "$BANNER" 2>/dev/null || true
	# Also drop it into the console scroll (serial OR VGA), where a chatty boot
	# can't bury it. Best-effort — never fail on a non-writable /dev/console.
	printf '\n**** Rasputin Firewall  |  WAN: %s  LAN: %s ****\n\n' \
		"${wan_ip:-(no address)}" "${lan_ip:-(no address)}" > /dev/console 2>/dev/null || true
fi
