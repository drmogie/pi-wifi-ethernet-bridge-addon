#!/usr/bin/env bash
# WiFi to Ethernet Bridge - Home Assistant add-on
#
# Re-implements https://www.willhaley.com/blog/raspberry-pi-wifi-ethernet-bridge/
# inside a Supervisor add-on: proxy ARP (parprouted) + DHCP relay (dhcp-helper)
# between this device's WiFi interface and its Ethernet interface, so a single
# wired-only device plugged into Ethernet gets network access over WiFi.
#
# This container runs with host_network: true and NET_ADMIN/NET_RAW, so the
# `ip` commands below act directly on the host's real network interfaces.

set -u

OPTIONS_FILE="/data/options.json"

log() {
  echo "[wifi-ethernet-bridge] $*"
}

# Prefer iptables-nft when it's available. Home Assistant OS's host runs an
# nftables-backed firewall; a reference add-on that reliably passes traffic
# in this same situation (eximius313/ha-wifi-gateway-addon) explicitly uses
# iptables-nft rather than plain iptables, which can otherwise talk to a
# different, disconnected rule set inside the container.
if command -v iptables-nft > /dev/null 2>&1; then
  IPTABLES_BIN="iptables-nft"
elif command -v iptables > /dev/null 2>&1; then
  IPTABLES_BIN="iptables"
else
  IPTABLES_BIN=""
fi

if [ ! -f "$OPTIONS_FILE" ]; then
  log "ERROR: $OPTIONS_FILE not found. This add-on must be run under Home Assistant Supervisor."
  exit 1
fi

WLAN_IF=$(jq -r '.wlan_interface // "wlan0"' "$OPTIONS_FILE")
ETH_IF=$(jq -r '.eth_interface // "eth0"' "$OPTIONS_FILE")
ENABLE_AVAHI=$(jq -r '.enable_avahi_reflector // false' "$OPTIONS_FILE")
DEBUG_MODE=$(jq -r '.debug_mode // "basic"' "$OPTIONS_FILE")
case "$DEBUG_MODE" in
  off|basic|verbose|packet_capture) ;;
  *) log "WARNING: unrecognized debug_mode '$DEBUG_MODE', falling back to 'basic'"; DEBUG_MODE="basic" ;;
esac
log "Debug mode: $DEBUG_MODE"

WLAN_IP=""
STOP=0
trap 'STOP=1' SIGTERM SIGINT

cleanup() {
  log "Stopping bridge..."
  pkill -x dhcp-helper 2>/dev/null || true
  pkill -x parprouted 2>/dev/null || true
  if [ "$ENABLE_AVAHI" = "true" ]; then
    pkill -x avahi-daemon 2>/dev/null || true
    pkill -x dbus-daemon 2>/dev/null || true
  fi
  if [ -n "$IPTABLES_BIN" ]; then
    "$IPTABLES_BIN" -D FORWARD -i "$ETH_IF" -o "$WLAN_IF" -j ACCEPT 2>/dev/null || true
    "$IPTABLES_BIN" -D FORWARD -i "$WLAN_IF" -o "$ETH_IF" -j ACCEPT 2>/dev/null || true
  fi
  ip link set "$WLAN_IF" promisc off 2>/dev/null || true
  ip link set "$ETH_IF" promisc off 2>/dev/null || true
  if [ -n "$WLAN_IP" ]; then
    ip addr del "${WLAN_IP}/32" dev "$ETH_IF" 2>/dev/null || true
  fi
  ip link set dev "$ETH_IF" down 2>/dev/null || true
}

# Periodic diagnostic snapshot, logged every DIAG_INTERVAL_LOOPS iterations of
# the main watch loop (each iteration sleeps 5s). Purely informational - never
# affects the bridge itself - but this is the only way to see whether traffic
# is actually reaching each side without SSH access to the device. How much
# detail is logged, and how often, depends on the "debug_mode" option:
#   off             - no periodic snapshots at all (only startup/error logs)
#   basic (default) - interface state, ARP entries on $ETH_IF, FORWARD chain
#                      counters, every ~30s
#   verbose         - the same as basic, every ~10s, plus the routing table,
#                      ARP entries on $WLAN_IF too, and RX/TX interface stats
#   packet_capture  - everything in verbose, plus a short real packet capture
#                      (ARP + DHCP traffic) on $ETH_IF each cycle
case "$DEBUG_MODE" in
  verbose|packet_capture) DIAG_INTERVAL_LOOPS=2 ;;   # ~10s
  *)                      DIAG_INTERVAL_LOOPS=6 ;;   # ~30s
esac

diag_snapshot() {
  log "--- diagnostic snapshot ($DEBUG_MODE) ---"
  log "$ETH_IF: $(ip -4 -br addr show "$ETH_IF" 2>/dev/null) (promisc: $(ip link show "$ETH_IF" 2>/dev/null | grep -o PROMISC || echo off))"
  log "$WLAN_IF: $(ip -4 -br addr show "$WLAN_IF" 2>/dev/null) (promisc: $(ip link show "$WLAN_IF" 2>/dev/null | grep -o PROMISC || echo off))"
  ETH_NEIGH=$(ip neigh show dev "$ETH_IF" 2>/dev/null)
  if [ -n "$ETH_NEIGH" ]; then
    log "ARP/neighbor entries on $ETH_IF (a plugged-in client should show up here once it sends any traffic):"
    echo "$ETH_NEIGH" | while IFS= read -r line; do log "  $line"; done
  else
    log "No ARP/neighbor entries on $ETH_IF yet - nothing has been heard from a device plugged into it."
  fi
  if [ -n "$IPTABLES_BIN" ]; then
    log "FORWARD chain packet/byte counters ($ETH_IF -> $WLAN_IF, $WLAN_IF -> $ETH_IF):"
    "$IPTABLES_BIN" -L FORWARD -v -n 2>/dev/null | grep -E "$ETH_IF|$WLAN_IF" | while IFS= read -r line; do log "  $line"; done
  fi

  if [ "$DEBUG_MODE" = "verbose" ] || [ "$DEBUG_MODE" = "packet_capture" ]; then
    log "RX/TX stats for $ETH_IF:"
    ip -s link show "$ETH_IF" 2>/dev/null | tail -n +2 | while IFS= read -r line; do log "  $line"; done
    log "RX/TX stats for $WLAN_IF:"
    ip -s link show "$WLAN_IF" 2>/dev/null | tail -n +2 | while IFS= read -r line; do log "  $line"; done
    WLAN_NEIGH=$(ip neigh show dev "$WLAN_IF" 2>/dev/null)
    if [ -n "$WLAN_NEIGH" ]; then
      log "ARP/neighbor entries on $WLAN_IF:"
      echo "$WLAN_NEIGH" | while IFS= read -r line; do log "  $line"; done
    fi
    log "Routing table:"
    ip route show 2>/dev/null | while IFS= read -r line; do log "  $line"; done
  fi

  if [ "$DEBUG_MODE" = "packet_capture" ]; then
    if command -v tcpdump > /dev/null 2>&1; then
      log "Capturing up to 15 ARP/DHCP packets on $ETH_IF for 8s (nothing shown below means nothing arrived):"
      timeout 8 tcpdump -i "$ETH_IF" -nn -c 15 'arp or (udp and (port 67 or port 68))' 2>&1 | \
        grep -v '^tcpdump: verbose output suppressed\|^listening on\|packets captured\|packets received by filter\|packets dropped by kernel' | \
        while IFS= read -r line; do log "  $line"; done
    else
      log "WARNING: tcpdump not available; cannot do a packet capture"
    fi
  fi

  log "--- end diagnostic snapshot ---"
}

CURRENT_IP_FORWARD=$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo "unknown")
if [ "$CURRENT_IP_FORWARD" = "1" ]; then
  log "IPv4 forwarding is enabled (ip_forward=1)"
else
  # config.yaml now sets this declaratively via `sysctls: net.ipv4.ip_forward: 1`,
  # which Supervisor applies to the container at creation time (before this
  # script ever runs), so this should never actually be needed. Still attempt
  # it and log clearly if the sysctls option didn't take effect for some reason.
  log "ip_forward is '$CURRENT_IP_FORWARD', expected 1 - attempting to set it directly"
  if echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null; then
    log "IPv4 forwarding enabled"
  else
    log "ERROR: could not set ip_forward (Read-only file system) and it is not already 1."
    log "This add-on sets 'sysctls: net.ipv4.ip_forward: 1' in config.yaml, which Supervisor"
    log "should apply automatically - if you still see this, fully uninstall and reinstall"
    log "the add-on so Supervisor recreates the container with the current config."
  fi
fi

log "Waiting for $WLAN_IF to get an IPv4 address (Home Assistant's own WiFi connection)..."
for _ in $(seq 1 60); do
  [ "$STOP" = "1" ] && exit 0
  WLAN_IP=$(ip -4 -br addr show "$WLAN_IF" 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
  [ -n "$WLAN_IP" ] && break
  sleep 2
done

if [ -z "$WLAN_IP" ]; then
  log "ERROR: $WLAN_IF never got an IPv4 address."
  log "Connect this device to WiFi first under Settings > System > Network, then restart this add-on."
  exit 1
fi
log "$WLAN_IF has IP $WLAN_IP"

log "NOTE: make sure $ETH_IF is set to 'Disabled' under Settings > System > Network,"
log "so Home Assistant's own network manager doesn't also try to configure it."

ip addr add "${WLAN_IP}/32" dev "$ETH_IF" 2>/dev/null
ip link set dev "$ETH_IF" up
# Promiscuous mode on BOTH interfaces, matching the original blog post recipe
# this add-on is based on. Earlier releases only set this on $WLAN_IF -
# without it on $ETH_IF too, parprouted may not reliably see ARP/DHCP frames
# from a device plugged into Ethernet, depending on the NIC driver.
ip link set "$WLAN_IF" promisc on
ip link set "$ETH_IF" promisc on
log "Interface state after setup:"
log "  $ETH_IF: $(ip -4 -br addr show "$ETH_IF" 2>/dev/null) (promisc: $(ip link show "$ETH_IF" 2>/dev/null | grep -o PROMISC || echo off))"
log "  $WLAN_IF: $(ip -4 -br addr show "$WLAN_IF" 2>/dev/null) (promisc: $(ip link show "$WLAN_IF" 2>/dev/null | grep -o PROMISC || echo off))"

# Docker manages its own rules AND default policy on the host's FORWARD
# chain, and does not automatically allow traffic between two non-Docker
# interfaces like these - even with ip_forward enabled, packets can be
# silently dropped here. Interface-specific ACCEPT rules alone weren't
# enough to fix this in practice; a working reference add-on with the same
# problem (eximius313/ha-wifi-gateway-addon) fixes it by setting the
# chain's default POLICY to ACCEPT, so that's done here too, on top of the
# explicit interface rules.
if [ -n "$IPTABLES_BIN" ]; then
  log "Using $IPTABLES_BIN to allow forwarding between $ETH_IF and $WLAN_IF"
  "$IPTABLES_BIN" -P FORWARD ACCEPT
  "$IPTABLES_BIN" -C FORWARD -i "$ETH_IF" -o "$WLAN_IF" -j ACCEPT 2>/dev/null || \
    "$IPTABLES_BIN" -I FORWARD 1 -i "$ETH_IF" -o "$WLAN_IF" -j ACCEPT
  "$IPTABLES_BIN" -C FORWARD -i "$WLAN_IF" -o "$ETH_IF" -j ACCEPT 2>/dev/null || \
    "$IPTABLES_BIN" -I FORWARD 1 -i "$WLAN_IF" -o "$ETH_IF" -j ACCEPT
else
  log "WARNING: no iptables binary available; cannot confirm the host's FORWARD chain allows this traffic"
fi

if [ "$ENABLE_AVAHI" = "true" ]; then
  log "Enabling mDNS (avahi) reflector between $WLAN_IF and $ETH_IF"
  if grep -q '^\[reflector\]' /etc/avahi/avahi-daemon.conf 2>/dev/null; then
    sed -i 's/^#*enable-reflector=.*/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf
  else
    printf '\n[reflector]\nenable-reflector=yes\n' >> /etc/avahi/avahi-daemon.conf
  fi
  # avahi-daemon requires a D-Bus system bus to even start, which this minimal
  # container image doesn't have running by default. Start a private one just
  # for avahi's own use - it doesn't need to see the host's real D-Bus.
  mkdir -p /var/run/dbus
  if ! pgrep -x dbus-daemon > /dev/null; then
    dbus-daemon --system --fork || log "WARNING: dbus-daemon failed to start; avahi reflector needs it"
  fi
  avahi-daemon --daemonize --no-drop-root || log "WARNING: avahi-daemon failed to start"
fi

log "Starting dhcp-helper (relays DHCP requests: $ETH_IF -> $WLAN_IF)"
/usr/sbin/dhcp-helper -n -i "$ETH_IF" -b "$WLAN_IF" &
DHCP_PID=$!

log "Starting parprouted (proxy ARP: $ETH_IF <-> $WLAN_IF)"
# parprouted always forks itself into the background, so we start it and then
# confirm separately that it actually stayed up.
/usr/sbin/parprouted "$ETH_IF" "$WLAN_IF"
sleep 1
if ! pgrep -x parprouted > /dev/null; then
  log "ERROR: parprouted failed to start. Check that $ETH_IF and $WLAN_IF exist and this add-on has NET_ADMIN/NET_RAW."
  cleanup
  exit 1
fi

log "Bridge is up: WiFi ($WLAN_IF, $WLAN_IP) <-> Ethernet ($ETH_IF)"

LOOP_COUNT=0
while [ "$STOP" = "0" ]; do
  if ! kill -0 "$DHCP_PID" 2>/dev/null; then
    log "ERROR: dhcp-helper exited unexpectedly."
    break
  fi
  if ! pgrep -x parprouted > /dev/null; then
    log "ERROR: parprouted exited unexpectedly."
    break
  fi
  LOOP_COUNT=$((LOOP_COUNT + 1))
  if [ "$DEBUG_MODE" != "off" ] && [ "$((LOOP_COUNT % DIAG_INTERVAL_LOOPS))" = "0" ]; then
    diag_snapshot
  fi
  sleep 5
done

cleanup
log "Bridge stopped."
exit 0
