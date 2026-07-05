#!/bin/sh
#
# dhcp-detect.sh — no-op udhcpc handler used ONLY by rasputin-dhcp-auto to
# detect whether another DHCP server is present on the LAN.
#
# udhcpc invokes this with an event as $1 (deconfig, bound, renew, …). We
# intentionally do NOTHING for every event: the probe cares only about udhcpc's
# EXIT STATUS (0 = it got an offer, i.e. a server is out there), never the
# offered lease — so br-lan's configured address must be left untouched.
exit 0
