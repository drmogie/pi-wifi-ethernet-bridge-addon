# Changelog

## 2026.09.17.1

- Fixed `s6-overlay-suexec: fatal: can only run as pid 1` on start.
  The `.2` fix switched `build_from` to Home Assistant's own Debian base
  images, which already bundle S6-Overlay as their own init system (PID 1).
  Supervisor was still also wrapping the container in its own default init,
  so S6-Overlay ended up one level below PID 1 and refused to run. Added
  `init: false` to `config.yaml` to tell Supervisor this base image already
  provides its own init, matching Home Assistant's own example add-ons that
  build from these images.

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
