# Pi WiFi ↔ Ethernet Bridge — Home Assistant Add-on Repository

A Home Assistant add-on that shares a device's WiFi connection out its
Ethernet port, so a wired-only device plugged in gets network access. Based
on [this blog post's Raspberry Pi setup](https://www.willhaley.com/blog/raspberry-pi-wifi-ethernet-bridge/),
rebuilt to run as a Supervisor add-on (`parprouted` + `dhcp-helper` in a
host-networked container) instead of installed directly on the OS.

## Add this repository to Home Assistant

1. **Settings → Add-ons → Add-on Store**
2. **⋮** (top right) → **Repositories**
3. Add `https://github.com/drmogie/pi-wifi-ethernet-bridge-addon`
4. Install **WiFi to Ethernet Bridge** from the store

Full setup instructions, required prerequisites, and troubleshooting are in
[`wifi_ethernet_bridge/DOCS.md`](wifi_ethernet_bridge/DOCS.md) — that file is
also shown as the add-on's **Documentation** tab inside Home Assistant once
installed.

## Repository layout

```
repository.yaml              # add-on store repository metadata
wifi_ethernet_bridge/
  config.yaml                 # add-on manifest (name, version, options schema)
  build.yaml                  # per-arch base image
  Dockerfile                  # installs parprouted, dhcp-helper, iproute2, avahi
  run.sh                      # brings up the bridge, supervises the daemons
  DOCS.md                     # shown as the add-on's Documentation tab
  CHANGELOG.md
```

You don't need CI/CD or a container registry for personal use — Supervisor
builds the Docker image locally on your Home Assistant device the first time
you install it.
