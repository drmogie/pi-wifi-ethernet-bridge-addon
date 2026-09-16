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

if [ ! -f "$OPTIONS_FILE" ]; then
  log "ERROR: $OPTIONS_FILE not found. This add-on must be run under Home Assistant Supervisor."
  exit 1
fi

WLAN_IF=$(jq -r '.wlan_interface // "wlan0"' "$OPTIONS_FILE")
ETH_IF=$(jq -r '.eth_interface // "eth0"' "$OPTIONS_FILE")
ENABLE_AVAHI=$(jq -r '.enable_avahi_reflector // false' "$OPTIONS_FILE")

WLAN_IP=""
STOP=0
trap 'STOP=1' SIGTERM SIGINT

cleanup() {
  log "Stopping bridge..."
  pkill -x dhcp-helper 2>/dev/null || true
  pkill -x parprouted 2>/dev/null || true
  if [ "$ENABLE_AVAHI" = "true" ]; then
    pkill -x avahi-daemon 2>/dev/null || true
  fi
  ip link set "$WLAN_IF" promisc off 2>/dev/null || true
  if [ -n "$WLAN_IP" ]; then
    ip addr del "${WLAN_IP}/32" dev "$ETH_IF" 2>/dev/null || true
  fi
  ip link set dev "$ETH_IF" down 2>/dev/null || true
}

log "Enabling IPv4 forwarding"
if ! echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null; then
  log "WARNING: could not enable ip_forward. Confirm 'host_network' and NET_ADMIN are set for this add-on."
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
ip link set "$WLAN_IF" promisc on

if [ "$ENABLE_AVAHI" = "true" ]; then
  log "Enabling mDNS (avahi) reflector between $WLAN_IF and $ETH_IF"
  if grep -q '^\[reflector\]' /etc/avahi/avahi-daemon.conf 2>/dev/null; then
    sed -i 's/^#*enable-reflector=.*/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf
  else
    printf '\n[reflector]\nenable-reflector=yes\n' >> /etc/avahi/avahi-daemon.conf
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

while [ "$STOP" = "0" ]; do
  if ! kill -0 "$DHCP_PID" 2>/dev/null; then
    log "ERROR: dhcp-helper exited unexpectedly."
    break
  fi
  if ! pgrep -x parprouted > /dev/null; then
    log "ERROR: parprouted exited unexpectedly."
    break
  fi
  sleep 5
done

cleanup
log "Bridge stopped."
exit 0
