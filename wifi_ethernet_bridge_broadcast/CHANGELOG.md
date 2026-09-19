# Changelog

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
