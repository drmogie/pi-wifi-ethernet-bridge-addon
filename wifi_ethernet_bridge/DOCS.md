# WiFi to Ethernet Bridge

Turns this device's spare Ethernet port into a bridge that shares its own
WiFi connection with **one** wired-only device plugged in — no switch, no
router config, no static IPs. This is a Home Assistant add-on version of
[this blog post's Raspberry Pi setup](https://www.willhaley.com/blog/raspberry-pi-wifi-ethernet-bridge/),
using the same two tools (`parprouted` for proxy ARP, `dhcp-helper` for DHCP
relay), running inside a container instead of installed on the host OS.

## Before you install

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

## Installing

1. In Home Assistant, go to **Settings → Add-ons → Add-on Store**.
2. Click the **⋮** menu (top right) → **Repositories**, and add the URL of
   this repository.
3. Find **WiFi to Ethernet Bridge** in the store and click **Install**.
   The first install builds the Docker image on your device, which can take
   a few minutes on a Pi.
4. Open the add-on's **Configuration** tab if your interface names aren't
   the defaults (see below), then go to **Info** and click **Start**.
5. Plug the wired-only device into this device's Ethernet port. It should
   pick up an IP address from your WiFi network's router within a few
   seconds.

## Configuration

The add-on's Configuration tab gives you a form for these options — you
don't need to edit YAML by hand:

```yaml
wlan_interface: wlan0
eth_interface: eth0
enable_avahi_reflector: false
debug_mode: basic
```

- **wlan_interface**: the WiFi interface name. `wlan0` on virtually all Pi
  setups; change it only if `ip a` on your device shows something different.
- **eth_interface**: the Ethernet interface name to bridge. `eth0` on a Pi 4.
- **enable_avahi_reflector**: when `true`, mDNS (`.local` name / Bonjour)
  traffic is reflected between the two interfaces, so devices on either side
  can discover each other by name (matches the optional `avahi-daemon.conf`
  step in the original blog post). Leave `false` if you don't need this.
- **debug_mode**: how much diagnostic detail is written to the Log tab, with
  no SSH needed:
  - `off` — just startup/error messages.
  - `basic` (default) — a snapshot every ~30s of interface state, ARP
    entries seen on the Ethernet interface, and forwarding-rule counters.
  - `verbose` — the same, every ~10s, plus the routing table, ARP entries on
    the WiFi interface too, and RX/TX statistics for both interfaces.
  - `packet_capture` — everything in `verbose`, plus a real DHCP-only
    packet capture run on **both** the Ethernet and WiFi interfaces at the
    same time each cycle, so you can see the full relay round trip: a
    client's DHCP request arriving on Ethernet, `dhcp-helper` relaying it
    onto WiFi, and the router's reply coming back. The most detail
    available; use this if `verbose` still isn't enough to tell what's
    happening.

## How it works

- `parprouted` answers ARP requests on each interface on behalf of the other
  ("proxy ARP"), which is what makes wired clients appear to be directly on
  the WiFi subnet without needing their own routed subnet.
- `dhcp-helper` relays DHCP broadcast requests from the Ethernet side over to
  the WiFi side, so the wired client gets a real lease from your normal
  router — not from this device.
- IPv4 forwarding is turned on so traffic actually passes between the two
  interfaces.

This add-on requests `host_network: true` and the `NET_ADMIN` / `NET_RAW`
capabilities, because it needs to directly control your device's real
`wlan0`/`eth0` interfaces — a normal, unprivileged add-on container can't do
that.

## Limitations

- Designed for **one** wired client. Proxy ARP can technically support more,
  but it wasn't tested that way here — same as the original blog post.
- Throughput is capped by your WiFi link (the original writeup measured
  roughly 60 Mbps).
- If the wired client and this device's own WiFi IP ever end up on different
  subnets, this won't work — it depends on both being on the same network.

## Troubleshooting

Check the add-on's **Log** tab first — every step logs a line prefixed
`[wifi-ethernet-bridge]`.

- **"never got an IPv4 address"**: WiFi isn't connected yet, or you set the
  wrong `wlan_interface` name.
- **"parprouted failed to start"**: usually means the add-on doesn't have
  `NET_ADMIN`/`NET_RAW`, or `eth_interface`/`wlan_interface` don't match real
  interface names on this device.
- Wired client gets no IP: double check `eth_interface` is set to
  **Disabled** in Home Assistant's own Network settings (step 2 above) — if
  Home Assistant is also managing that port, the two will conflict.
