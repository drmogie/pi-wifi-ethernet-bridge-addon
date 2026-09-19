# WiFi to Ethernet Bridge (Broadcast Relay)

Turns this device's spare Ethernet port into a bridge that shares its own
WiFi connection with **one** wired-only device plugged in — no switch, no
router config, no static IPs. This is a variant of the standard
**WiFi to Ethernet Bridge** add-on in this same repository, for one specific
situation described below.

## Is this the add-on you want?

Install the standard **WiFi to Ethernet Bridge** add-on first. Only switch
to this one if, with `debug_mode: packet_capture` on the standard add-on,
you see the wired client's DHCP request being relayed *correctly* (a proper
non-zero Gateway-IP field, `hops 1`, correctly addressed — optionally
straight to your DHCP server's address via its `dhcp_server_ip` option) but
your DHCP server still never replies.

That symptom means your DHCP server is silently dropping *relayed* requests
specifically — confirmed, in one real case, against Technitium DNS Server:
its DHCP server only accepts a relayed request for a scope whose interface
binding is "Any," which a scope for a subnet the server is itself directly
attached to never is. Since this bridge deliberately keeps the wired client
on the *same* subnet as the WiFi side (that's what the proxy ARP is for),
any DHCP server with similar relay-agent handling will hit the same wall.

This add-on works around it by not using DHCP relay-agent semantics at all.

## Before you install

Same prerequisites as the standard add-on:

1. This device must already be connected to your WiFi network under
   **Settings → System → Network**. The add-on shares that existing
   connection — it does not set up WiFi itself.
2. Go to **Settings → System → Network**, select the Ethernet interface
   (usually `eth0`), and set it to **Disabled**. If Home Assistant's own
   network manager is also trying to get a DHCP lease on that port, it will
   fight with the bridge. This is the one manual step you have to do — the
   add-on can't do it for you.
3. Only tested with a Raspberry Pi 4 running Home Assistant OS. It should
   work on any HAOS/Supervised device with a WiFi and an Ethernet interface.
4. Don't run this add-on and the standard **WiFi to Ethernet Bridge** add-on
   at the same time — they both try to manage the same interfaces.

## Installing

1. In Home Assistant, go to **Settings → Add-ons → Add-on Store**.
2. Click the **⋮** menu (top right) → **Repositories**, and add the URL of
   this repository (the same one as the standard add-on — both live here).
3. Find **WiFi to Ethernet Bridge (Broadcast Relay)** in the store and click
   **Install**. The first install builds the Docker image on your device,
   which takes a bit longer than the standard add-on since it compiles
   `udp-broadcast-relay-redux` from source.
4. Open the add-on's **Configuration** tab if your interface names aren't
   the defaults (see below), then go to **Info** and click **Start**.
5. Plug the wired-only device into this device's Ethernet port. It should
   pick up an IP address from your WiFi network's router within a few
   seconds.

## Configuration

```yaml
wlan_interface: wlan0
eth_interface: eth0
enable_avahi_reflector: false
debug_mode: basic
```

Same meaning as the standard add-on for all four options — see its DOCS.md
for the full description of each. There's no `dhcp_server_ip` option here;
it doesn't apply to a broadcast relay, since nothing is unicast to a
specific server address.

## How it works

- `parprouted` answers ARP requests on each interface on behalf of the other
  ("proxy ARP"), exactly as in the standard add-on.
- Instead of `dhcp-helper` (a DHCP relay agent), this add-on runs
  `udp-broadcast-relay-redux` — a small, single-purpose daemon that just
  retransmits UDP broadcast packets it sees on one interface out onto the
  other, unmodified. Two instances run: one for port 67 (the client's
  request, Ethernet → WiFi) and one for port 68 (the DHCP server's reply,
  if it broadcasts it, WiFi → Ethernet). Neither instance rewrites the
  packet in any way — no Gateway-IP/relay-agent field gets added, so the
  DHCP server sees a plain, ordinary broadcast, indistinguishable from any
  other directly-attached client on the network.
- IPv4 forwarding is turned on so traffic actually passes between the two
  interfaces once the client has an address.

This add-on requests `host_network: true` and the `NET_ADMIN` / `NET_RAW`
capabilities, for the same reason as the standard add-on: it needs direct
control of your device's real `wlan0`/`eth0` interfaces.

## Limitations

- Everything in the standard add-on's Limitations section applies here too
  (one wired client, WiFi-capped throughput, same-subnet requirement).
- **A DHCP server that unicasts its OFFER/ACK won't be caught by this
  add-on.** RFC 2131 allows a DHCP server to send its reply straight to the
  client's hardware address (skipping broadcast) when the client's
  DHCPDISCOVER didn't set the "broadcast" flag — a pure broadcast relay like
  this one only ever retransmits genuinely broadcast traffic, so it can't
  help with that case. Check a `packet_capture` snapshot: if the client's
  request goes out fine on the WiFi interface but you still never see a
  reply captured there either, this is likely what's happening, and neither
  add-on in this repository currently has a fix for it — that would need a
  proper relay agent that also handles unicast BOOTREPLY delivery based on
  the request's `chaddr` field.

## Troubleshooting

Check the add-on's **Log** tab first — every line is prefixed
`[wifi-ethernet-bridge-broadcast]`.

- **"never got an IPv4 address"**, **"parprouted failed to start"**, wired
  client gets no IP at all: same causes and same fixes as the standard
  add-on — see its DOCS.md Troubleshooting section.
- **"udp-broadcast-relay-redux failed to start"**: same underlying cause as
  a parprouted start failure — usually missing `NET_ADMIN`/`NET_RAW`, or
  `eth_interface`/`wlan_interface` not matching real interface names.
- Client gets an IP relayed correctly (per a `packet_capture` snapshot on
  the standard add-on) but still nothing here either: see the Limitations
  section above about unicast replies.
