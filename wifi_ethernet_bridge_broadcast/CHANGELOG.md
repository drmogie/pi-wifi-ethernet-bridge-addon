# Changelog

## 2026.09.19.03

Replaced `udp-broadcast-relay-redux` entirely after finding a real,
structural bug: it receives by binding a plain UDP socket to
`0.0.0.0:<port>`, and on port 68 that always collides with the HOST's own
DHCP client - which this exact device needs anyway, since `wlan0` gets
its own address via DHCP. That client was already bound to port 68 before
this add-on ever started, and (very likely) never set `SO_REUSEPORT`
itself, so nothing else can ever bind that port alongside it, on any
device this add-on is meant to run on. The port-68 instance failing to
start every time is what tripped this add-on's own health check and shut
the whole bridge down (see `2026.09.19.02` above).

Fixed by swapping in a small new script, `l2_broadcast_relay.py`
(Python 3, standard library only), which captures raw Ethernet frames via
`AF_PACKET` - the same technique `tcpdump` uses - instead of binding a UDP
port at all, so there is nothing for the host's DHCP client to conflict
with. It filters for the target UDP destination port itself and
retransmits the untouched IP/UDP/DHCP payload as a fresh Ethernet-broadcast
frame on the other interface.

Possible side benefit, not yet confirmed: because both interfaces are
already in promiscuous mode, this also picks up a DHCP reply sent as a
genuine *unicast* frame straight to the client's MAC address - something a
plain broadcast-only relay can never see. That was a separately-documented
open risk (a DHCP server is allowed, per RFC 2131, to unicast its reply
when the client's DHCPDISCOVER left the "broadcast" flag unset) - this
rewrite may resolve it as a side effect, but that still needs a real
retest to know for sure.

## 2026.09.19.02

Fixed a real bug found on first install (Mogie): both `udp-broadcast-relay-redux`
instances failed to start immediately, the add-on's own health check caught
that and shut the whole bridge down (logged as
"udp-broadcast-relay-redux failed to start... Stopping bridge..."), and the
shutdown path's `ip link set dev $ETH_IF down` step then took the Ethernet
port itself administratively down - which, on this hardware, killed the link
light on BOTH ends of the cable (the Pi's own port and the far-end device),
making it look like a wiring/hardware problem rather than a software one.

Root cause: `run.sh` invoked the relay binary with `-id <n>` (single dash),
but `udp-broadcast-relay-redux` parses its arguments with plain `strcmp()`
against exact strings - it only recognizes `--id` (double dash). `-id` never
matched, so the binary printed its usage message and exited immediately,
every single time, on both the port-67 and port-68 instances. Fixed by
correcting all four invocations (initial start plus the per-process watchdog
restart) to `--id`.

## 2026.09.19.01

Initial release of this add-on.

This is a variant of the standard **WiFi to Ethernet Bridge** add-on for one
specific situation: your DHCP server never replies to the standard add-on's
relayed DHCP request, even though a `packet_capture` snapshot shows the
request being relayed correctly (proper non-zero Gateway-IP field, correct
`hops`, correctly addressed).

Root cause found this session, confirmed directly against Technitium DNS
Server's own source code: its DHCP server only matches a relayed request
(non-zero Gateway-IP) to a scope whose `InterfaceAddress` is `Any` - but a
scope for a subnet Technitium is itself directly attached to (which is
exactly this bridge's situation, since the wired client is deliberately kept
on the *same* subnet as the WiFi side via proxy ARP) always gets a specific
`InterfaceAddress`, never `Any`. So the relayed request is silently dropped
inside Technitium with no log entry at all, regardless of broadcast vs.
unicast relay - confirmed against Technitium's live DHCP log during testing
(zero trace of the client's MAC address anywhere, even while it was actively
leasing IPs to other devices on the same scope).

This add-on works around that by using a raw UDP broadcast relay
(`udp-broadcast-relay-redux`, built from source - not packaged for Debian)
instead of a DHCP relay agent (`dhcp-helper`). It retransmits the client's
original DHCP broadcast unmodified between the two interfaces - no
relay-agent/Gateway-IP rewriting at all - so the DHCP server sees it exactly
like an ordinary directly-attached client's broadcast, the same as every
other device already being served successfully on that network.

Known open question: if your DHCP server chooses to *unicast* its
OFFER/ACK straight to the client's hardware address (allowed by RFC 2131
when the client's DHCPDISCOVER doesn't set the "broadcast" flag) rather than
broadcasting it, a pure broadcast relay won't catch that reply either. If
this add-on's `packet_capture` mode shows the request going out fine on the
WiFi interface but still no reply captured there, that's the next thing to
diagnose - see DOCS.md.
