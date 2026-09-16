# Changelog

## 2026.09.16.3

- Added friendly display names/descriptions for the Configuration tab's
  options (WiFi Interface, Ethernet Interface, Enable mDNS Reflector)
  via `translations/en.yaml`, so the form no longer shows the raw
  underscored option keys. The underlying option keys themselves are
  unchanged.

## 2026.09.16.2

- Fixed `build.yaml`'s `build_from` values (`debian:bookworm-slim`) failing
  Supervisor's image-reference validation (missing a registry/namespace
  segment), which silently fell back to Supervisor's default Alpine-based
  build image and made the Docker build fail on `apt-get install` (exit
  code 1). Now points at Home Assistant's own Debian-based build images
  (`ghcr.io/home-assistant/<arch>-base-debian:bookworm`) so `apt-get` works
  as the Dockerfile expects.

## 2026.09.16.1

- Initial release. Proxy-ARP + DHCP-relay bridge between a WiFi and an
  Ethernet interface, based on
  https://www.willhaley.com/blog/raspberry-pi-wifi-ethernet-bridge/
- Configurable `wlan_interface` / `eth_interface`.
- Optional Avahi (mDNS) reflector toggle.
