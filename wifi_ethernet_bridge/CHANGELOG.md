# Changelog

## 2026.09.18.4

- Reconsidered the `ip_forward: Read-only file system` failure: Home
  Assistant OS's host almost certainly already has IPv4 forwarding
  enabled (Docker itself depends on it for its own networking), so the
  failed write was likely harmless the whole time - `run.sh` now checks
  the actual current value first and only logs a real error if it's
  genuinely not already 1, instead of always treating the write as
  required.
- Added the actual likely fix for "not passing through end0": Docker
  manages its own rules and default policy on the host's `FORWARD`
  chain, and does not automatically allow traffic between two
  non-Docker interfaces like `wlan0`/`end0` even with IPv4 forwarding
  enabled - packets can be silently dropped there regardless of
  parprouted/dhcp-helper working correctly. `run.sh` now explicitly
  inserts `iptables` ACCEPT rules for both directions between the two
  configured interfaces (removed again on stop), and the `iptables`
  package was added to the Dockerfile.

## 2026.09.18.3

- Still fixing `ip_forward: Read-only file system` — `full_access: true`
  alone wasn't enough. Supervisor applies an AppArmor confinement profile
  to add-on containers separately from Docker's privileged mode, and that
  profile can still block writes to `/proc/sys` even under `full_access`.
  Added `apparmor: false` to fully disable it for this add-on.
- **Important:** security-related option changes like `full_access`,
  `apparmor`, `privileged`, and `host_network` often don't take effect on
  a normal update or restart — Supervisor can keep reusing the
  container's original security profile. After updating to this version,
  fully **uninstall** the add-on and **reinstall** it fresh rather than
  just restarting it, so Supervisor rebuilds the container with the
  current security settings.

## 2026.09.18.2

- Fixed `avahi-daemon failed to start` when the mDNS reflector option is
  enabled. avahi-daemon requires a running D-Bus system bus just to start
  at all, which this minimal container image didn't have. `run.sh` now
  starts a private `dbus-daemon --system` instance inside the container
  (added the `dbus` package) purely for avahi's own use, before starting
  avahi-daemon; it's stopped alongside avahi-daemon on shutdown. No
  changes needed on the Home Assistant side.
- Corrected `config.yaml`'s `version` string, which was accidentally left
  at `2026.09.17.1` in the previous release despite that release actually
  being tagged `2026.09.18.1`.

## 2026.09.18.1

- Fixed the bridge not actually passing traffic between WiFi and Ethernet
  ("Device not passing through end0"). The log showed
  `/proc/sys/net/ipv4/ip_forward: Read-only file system` — Docker mounts
  `/proc/sys` read-only inside add-on containers regardless of the
  `NET_ADMIN`/`NET_RAW` capabilities already granted, so kernel IP
  forwarding was never actually enabled even though parprouted still
  answered ARP requests and the log claimed the bridge was "up". Added
  `full_access: true` to `config.yaml` so Supervisor runs the container in
  Docker's privileged mode, which lifts the read-only restriction on
  `/proc/sys` and lets `run.sh` actually turn on `ip_forward`.

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
