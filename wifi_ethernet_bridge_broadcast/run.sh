#!/usr/bin/env bash
# WiFi to Ethernet Bridge (Broadcast Relay) - Home Assistant add-on
#
# Variant of the standard WiFi to Ethernet Bridge add-on that swaps the DHCP
# relay agent (dhcp-helper) for a raw UDP broadcast relay (parprouted still
# does proxy ARP the same way in both variants). Use this one instead if your
# DHCP server never replies to a relayed request (a packet with a non-zero
# Gateway-IP/relay-agent field) - some DHCP servers, confirmed with Technitium
# DNS Server, silently drop such a request when the relay agent's own address
# is on the same subnet as the DHCP scope, which is exactly the situation this
# bridge creates (the wired client is deliberately kept on the SAME subnet as
# the WiFi side via proxy ARP, not a genuinely different one). This variant
# sidesteps that entirely: instead of rewriting the client's DHCP broadcast
# into a relay-agent packet, it just retransmits the ORIGINAL broadcast
# unmodified onto the other interface, so the DHCP server sees it exactly
# like an ordinary directly-attached client's broadcast - no relay-agent
# semantics involved at all.
#
# NOTE: DHCP servers are allowed (per RFC 2131) to unicast their reply
# straight to the client's hardware address instead of broadcasting it, when
# the client's DHCPDISCOVER didn't set the "broadcast" flag. A pure broadcast
# relay (this add-on) only ever retransmits genuinely broadcast traffic - if
# your DHCP server chooses to unicast its OFFER/ACK, this variant won't catch
# it either, and that would show up in a "packet_capture" snapshot as the
# request going out fine on $WLAN_IF but still no reply captured there. If
# you hit that, it points to a different fix (a relay agent that unicasts
# BOOTREPLY packets back based on chaddr rather than a broadcast relay) -
# see DOCS.md.
#
# This container runs with host_network: true and NET_ADMIN/NET_RAW, so the
# `ip` commands below act directly on the host's real network interfaces.

set -u

OPTIONS_FILE="/data/options.json"

log() {
  echo "[wifi-ethernet-bridge-broadcast] $*"
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
  pkill -f l2_broadcast_relay.py 2>/dev/null || true
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
#   packet_capture  - everything in verbose, plus a DHCP-only (port 67/68)
#                      packet capture run simultaneously on BOTH $ETH_IF and
#                      $WLAN_IF each cycle, to see the full relay round trip
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
      # DHCP-only (port 67/68), captured on BOTH interfaces at once, run in
      # the background in parallel and joined with `wait`. Filtering to DHCP
      # only and watching both sides at once makes the full relay round trip
      # (client -> $ETH_IF -> broadcast relay -> $WLAN_IF -> router/DHCP
      # server -> back) visible in a single snapshot. Unlike the standard
      # add-on, a correctly-working request here should show NO Gateway-IP
      # field at all - this variant never rewrites the packet, it just
      # retransmits the client's original broadcast as-is.
      CAP_DIR=$(mktemp -d)
      log "Capturing DHCP traffic (port 67/68 only) on $ETH_IF and $WLAN_IF for 10s (nothing shown for an interface means no DHCP traffic arrived there):"
      timeout 10 tcpdump -i "$ETH_IF" -nn -e -vv 'udp and (port 67 or port 68)' > "$CAP_DIR/eth.log" 2>&1 &
      ETH_CAP_PID=$!
      timeout 10 tcpdump -i "$WLAN_IF" -nn -e -vv 'udp and (port 67 or port 68)' > "$CAP_DIR/wlan.log" 2>&1 &
      WLAN_CAP_PID=$!
      wait "$ETH_CAP_PID" "$WLAN_CAP_PID" 2>/dev/null
      log "-- $ETH_IF (client <-> broadcast relay) --"
      grep -v '^tcpdump: verbose output suppressed\|^listening on\|packets captured\|packets received by filter\|packets dropped by kernel' "$CAP_DIR/eth.log" 2>/dev/null | \
        while IFS= read -r line; do log "  $line"; done
      log "-- $WLAN_IF (broadcast relay <-> WiFi router/DHCP server) --"
      grep -v '^tcpdump: verbose output suppressed\|^listening on\|packets captured\|packets received by filter\|packets dropped by kernel' "$CAP_DIR/wlan.log" 2>/dev/null | \
        while IFS= read -r line; do log "  $line"; done
      rm -rf "$CAP_DIR"
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
# Promiscuous mode on BOTH interfaces, matching the standard add-on - without
# it, parprouted (and the broadcast relay) may not reliably see ARP/DHCP
# frames from a device plugged into Ethernet, depending on the NIC driver.
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

start_broadcast_relay() {
  # Two separate directional relays, one per DHCP port: 67 carries the
  # client's request (Ethernet -> WiFi direction) and 68 carries the
  # server's reply when it broadcasts it back (WiFi -> Ethernet direction).
  # These capture raw Ethernet frames via AF_PACKET (see
  # l2_broadcast_relay.py's own header comment for why - in short,
  # binding a normal UDP socket to port 68 conflicts with the host's own
  # DHCP client on this exact kind of device) rather than binding the UDP
  # port itself, so there's nothing here for the host's own DHCP client to
  # conflict with.
  log "Starting L2 broadcast relay, port 67 (client requests: $ETH_IF -> $WLAN_IF)"
  /usr/bin/python3 /usr/sbin/l2_broadcast_relay.py --port 67 --recv-if "$ETH_IF" --send-if "$WLAN_IF" &
  BCAST67_PID=$!
  log "Starting L2 broadcast relay, port 68 (broadcast/unicast replies: $WLAN_IF -> $ETH_IF)"
  /usr/bin/python3 /usr/sbin/l2_broadcast_relay.py --port 68 --recv-if "$WLAN_IF" --send-if "$ETH_IF" &
  BCAST68_PID=$!
}

start_parprouted() {
  log "Starting parprouted (proxy ARP: $ETH_IF <-> $WLAN_IF)"
  # Run with -d (debug/foreground) instead of letting it daemonize itself.
  # A daemonized parprouted double-forks and detaches, so it was never
  # actually OUR child process - we could only notice it was gone via
  # `pgrep`, with no way to see its own error output or its real exit
  # code/signal when it died. Keeping it as a direct background job (&)
  # lets us `wait` on it directly for both.
  /usr/sbin/parprouted -d "$ETH_IF" "$WLAN_IF" &
  PARPROUTED_PID=$!
}

# $1 = process name (for the log line), $2 = exit status as bash reports it
# from `wait` (128+signal if killed by a signal, e.g. 139 = SIGSEGV).
log_exit_reason() {
  local name="$1" status="$2"
  if [ "$status" -gt 128 ] 2>/dev/null; then
    local sig=$((status - 128))
    log "$name exited unexpectedly, killed by signal $sig ($(kill -l "$sig" 2>/dev/null || echo unknown)) - restarting it"
  else
    log "$name exited unexpectedly with exit code $status - restarting it"
  fi
}

start_broadcast_relay
start_parprouted
sleep 1
if ! kill -0 "$PARPROUTED_PID" 2>/dev/null; then
  log "ERROR: parprouted failed to start. Check that $ETH_IF and $WLAN_IF exist and this add-on has NET_ADMIN/NET_RAW."
  cleanup
  exit 1
fi
if ! kill -0 "$BCAST67_PID" 2>/dev/null || ! kill -0 "$BCAST68_PID" 2>/dev/null; then
  log "ERROR: the L2 broadcast relay failed to start. Check that $ETH_IF and $WLAN_IF exist and this add-on has NET_ADMIN/NET_RAW."
  cleanup
  exit 1
fi

log "Bridge is up: WiFi ($WLAN_IF, $WLAN_IP) <-> Ethernet ($ETH_IF)"

# parprouted is old, lightly-maintained software (its own man page says it
# was "designed for and tested only with Linux 2.4.x kernels") and has been
# observed crashing outright (killed by a signal, no error output of its
# own) after a few minutes on a busy WiFi network with many other devices'
# ARP/DHCP traffic. Rather than tearing down and restarting the WHOLE
# add-on (interfaces, iptables rules, promiscuous mode, avahi) every time
# this happens, restart just the crashed process in place - this keeps the
# rest of the bridge state intact and cuts the outage from a full container
# restart cycle down to about a second.
LOOP_COUNT=0
while [ "$STOP" = "0" ]; do
  if ! kill -0 "$BCAST67_PID" 2>/dev/null; then
    wait "$BCAST67_PID"
    log_exit_reason "L2 broadcast relay (port 67)" "$?"
    sleep 1
    log "Restarting L2 broadcast relay, port 67 (client requests: $ETH_IF -> $WLAN_IF)"
    /usr/bin/python3 /usr/sbin/l2_broadcast_relay.py --port 67 --recv-if "$ETH_IF" --send-if "$WLAN_IF" &
    BCAST67_PID=$!
  fi
  if ! kill -0 "$BCAST68_PID" 2>/dev/null; then
    wait "$BCAST68_PID"
    log_exit_reason "L2 broadcast relay (port 68)" "$?"
    sleep 1
    log "Restarting L2 broadcast relay, port 68 (broadcast/unicast replies: $WLAN_IF -> $ETH_IF)"
    /usr/bin/python3 /usr/sbin/l2_broadcast_relay.py --port 68 --recv-if "$WLAN_IF" --send-if "$ETH_IF" &
    BCAST68_PID=$!
  fi
  if ! kill -0 "$PARPROUTED_PID" 2>/dev/null; then
    wait "$PARPROUTED_PID"
    log_exit_reason "parprouted" "$?"
    sleep 1
    start_parprouted
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
