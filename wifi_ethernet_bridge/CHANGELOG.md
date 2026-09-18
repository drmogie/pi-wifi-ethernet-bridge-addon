# Changelog

## 2026.09.18.08

- Major finding from a `.7` packet capture: a genuine external DHCP request
  (a real MAC address, not this add-on's own) was caught arriving on the
  Ethernet interface, proving a client device IS plugged in, powered on,
  and actively trying to get an IP - the "nothing is reaching the port"
  theory from `.6`/`.7`'s flat RX counters and empty ARP tables was wrong,
  or at least incomplete. The packet nearly didn't show up at all, for two
  reasons the `.7` capture didn't account for: `parprouted`'s own constant
  self-generated ARP probing was consuming most of each capture's small
  15-packet budget, and the capture only ever watched the Ethernet side, so
  there was no way to tell whether `dhcp-helper` actually relayed the
  request onward, or whether the WiFi router replied.
- Reworked the `packet_capture` debug mode to fix both: it now filters to
  DHCP traffic only (port 67/68, no more competing with ARP for the
  capture budget) and runs the capture on **both** the Ethernet and WiFi
  interfaces at once, in parallel, for a fixed 10s window each cycle. This
  should make the full relay round trip visible in a single log snapshot -
  a client's request on the Ethernet side, whether `dhcp-helper` relays it
  onto the WiFi side, and whether the router replies - which is what's
  needed to pin down exactly where the DHCP exchange is breaking down.

## 2026.09.18.7

- Added a configurable **Debug Mode** option (`debug_mode`, in the
  Configuration tab), so the amount of diagnostic detail written to the log
  can be adjusted without needing SSH/device access:
  - **Off** - no periodic diagnostics, just startup/error messages.
  - **Basic** (default) - the interface-state/ARP/FORWARD-counter snapshot
    added in `.18.6`, every ~30s.
  - **Verbose** - the same, every ~10s, plus the routing table, ARP entries
    on the WiFi interface too, and RX/TX packet/byte/error statistics for
    both interfaces (useful to see whether the kernel is receiving any
    frames at all on the Ethernet port, even before ARP/forwarding come
    into it).
  - **Packet Capture** - everything in Verbose, plus a short real `tcpdump`
    capture (ARP + DHCP traffic only) on the Ethernet interface each cycle,
    logged directly - the most direct evidence of whether anything is
    actually arriving on that port. Added the `tcpdump` package for this.
- Still investigating the underlying "no network on the plugged-in device"
  issue - `.18.6`'s diagnostics showed zero ARP entries and zero forwarded
  packets over several minutes, which points at something before the
  bridge software even gets involved (nothing reaching the port at all, or
  no device was actually connected during that test) rather than a
  `parprouted`/`dhcp-helper` configuration problem. These new modes are
  meant to pin that down on the next test.

## 2026.09.18.6

- Confirmed `.5`'s `sysctls`/`iptables-nft` fixes actually took effect (a
  fresh device log showed the entire startup sequence complete with zero
  errors - `ip_forward` enabled, FORWARD policy set, `dhcp-helper` and
  `parprouted` both started, "Bridge is up") - but a device plugged into
  Ethernet still got no network access. Also ruled out Home Assistant's own
  NetworkManager fighting for the Ethernet interface (confirmed already
  correctly set to Disabled).
- Found a real, concrete gap against the blog post recipe this add-on is
  based on (willhaley.com's Raspberry Pi WiFi<->Ethernet bridge): that
  recipe sets **both** interfaces to promiscuous mode before starting
  `parprouted`, but this add-on had only ever set it on the WiFi interface,
  never the Ethernet one. Without it on the Ethernet side, `parprouted` may
  not reliably see ARP/DHCP frames from a device plugged in, depending on
  the NIC driver. Fixed to match the recipe exactly (both interfaces,
  cleaned up symmetrically on stop).
- Added on-log diagnostics, since there's no SSH access to inspect this
  live: after setup, logs each interface's address/promiscuous state, and
  every ~30 seconds while running, logs a snapshot of the ARP/neighbor table
  on the Ethernet interface (so we can see whether anything has even been
  heard from a plugged-in device) and the FORWARD chain's packet/byte
  counters (so we can see whether any packets are actually hitting the
  forwarding rules). If the promiscuous-mode fix alone doesn't resolve it,
  this diagnostic output is what we need from the next test to find the
  actual point where packets stop.

## 2026.09.18.5

- Found the actual fix for "not passing through end0" by comparing against a
  working community add-on with the same underlying problem
  (eximius313/ha-wifi-gateway-addon, a WiFi-to-Ethernet gateway rather than a
  bridge, but hitting the same Docker networking obstacles):
  - Replaced the runtime `full_access: true` + `apparmor: false` workaround
    for `ip_forward` with the correct, declarative Supervisor mechanism:
    `sysctls: net.ipv4.ip_forward: 1` in `config.yaml`. Supervisor applies
    this to the container directly, so it no longer depends on Docker
    privileged mode or disabling AppArmor confinement, neither of which
    actually fixed the problem in testing. `full_access` and `apparmor:
    false` have been removed.
  - The `.4` fix only inserted interface-specific `FORWARD` ACCEPT rules,
    which wasn't reliably enough - Docker also sets its own default
    **policy** on the `FORWARD` chain. `run.sh` now also explicitly sets
    `-P FORWARD ACCEPT`, matching the reference add-on's proven fix.
  - `run.sh` now prefers the `iptables-nft` binary over plain `iptables`
    when both are present, matching the reference add-on (Home Assistant
    OS's host firewall is nftables-backed).
  - **Important:** as with any `config.yaml` security-option change, fully
    **uninstall** and **reinstall** the add-on after updating to this
    version rather than just restarting it, so Supervisor recreates the
    container with the new `sysctls` setting applied.

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
