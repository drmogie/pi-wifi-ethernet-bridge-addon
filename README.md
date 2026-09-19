# Pi WiFi ↔ Ethernet Bridge — Home Assistant Add-on Repository

A Home Assistant add-on that shares a device's WiFi connection out its
Ethernet port, so a wired-only device plugged in gets network access. Based
on [this blog post's Raspberry Pi setup](https://www.willhaley.com/blog/raspberry-pi-wifi-ethernet-bridge/),
rebuilt to run as a Supervisor add-on (`parprouted` proxy ARP in a
host-networked container) instead of installed directly on the OS.

This repository has **two** add-ons — install the standard one first:

- **WiFi to Ethernet Bridge** (`wifi_ethernet_bridge`) — the standard add-on.
  Uses `parprouted` (proxy ARP) + `dhcp-helper` (a DHCP relay agent).
- **WiFi to Ethernet Bridge (Broadcast Relay)** (`wifi_ethernet_bridge_broadcast`) —
  a variant for DHCP servers that silently drop the standard add-on's
  relayed DHCP requests (confirmed with Technitium DNS Server — see its
  DOCS.md for the full explanation). Uses `parprouted` + a raw UDP broadcast
  relay instead of a relay agent. Only switch to this one if the standard
  add-on's `packet_capture` debug mode shows a correctly-relayed request
  getting no reply.

## Add this repository to Home Assistant

1. **Settings → Add-ons → Add-on Store**
2. **⋮** (top right) → **Repositories**
3. Add `https://github.com/drmogie/pi-wifi-ethernet-bridge-addon`
4. Install **WiFi to Ethernet Bridge** from the store (or the Broadcast
   Relay variant, if that's the one you need — see above)

Full setup instructions, required prerequisites, and troubleshooting for
each add-on are in its own `DOCS.md` — that file is also shown as the
add-on's **Documentation** tab inside Home Assistant once installed.

## Repository layout

```
repository.yaml                        # add-on store repository metadata
wifi_ethernet_bridge/                  # standard add-on
  config.yaml                           # add-on manifest (name, version, options schema)
  build.yaml                            # per-arch base image
  Dockerfile                            # installs parprouted, dhcp-helper, iproute2, avahi
  run.sh                                # brings up the bridge, supervises the daemons
  DOCS.md                               # shown as the add-on's Documentation tab
  CHANGELOG.md
wifi_ethernet_bridge_broadcast/        # broadcast-relay variant
  config.yaml
  build.yaml
  Dockerfile                            # also builds udp-broadcast-relay-redux from source
  run.sh
  DOCS.md
  CHANGELOG.md
```

You don't need CI/CD or a container registry for personal use — Supervisor
builds the Docker image locally on your Home Assistant device the first time
you install either add-on.
