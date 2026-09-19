ARG BUILD_FROM
FROM $BUILD_FROM

# parprouted     - proxy-ARP bridging daemon (does the actual eth0 <-> wlan0 bridging)
# l2_broadcast_relay.py (this repo, run via python3) - retransmits the
#                  client's raw DHCP broadcast (ports 67 and 68) between the
#                  two interfaces unmodified, with no relay-agent/Gateway-IP
#                  rewriting. Used instead of dhcp-helper because some DHCP
#                  servers (confirmed with Technitium DNS Server) silently
#                  drop a relayed request when the relay agent's own address
#                  is on the same subnet as the DHCP scope - see the standard
#                  add-on's DOCS.md/CHANGELOG for the full diagnosis.
#                  2026-09-19: this used to be udp-broadcast-relay-redux (built
#                  from source below), but that tool receives by binding a
#                  normal UDP socket to 0.0.0.0:<port> - which conflicts with
#                  the HOST's own DHCP client (already bound to port 68 for
#                  its own lease on wlan0) on every device this add-on is
#                  actually meant to run on. Replaced with a small stdlib-only
#                  Python script that captures raw Ethernet frames via
#                  AF_PACKET instead (same technique tcpdump uses), which
#                  never touches UDP port ownership at all. See that script's
#                  own header comment for the full writeup.
# iproute2       - `ip` command, used to bring interfaces up/down and set promisc mode
# iptables       - needed to explicitly allow FORWARD traffic between the two
#                  interfaces, since Docker manages its own FORWARD chain
#                  rules/policy on the host and doesn't automatically allow
#                  traffic between two non-Docker interfaces
# avahi-daemon   - optional mDNS reflector, so .local names resolve across the bridge
# dbus           - avahi-daemon needs a running D-Bus system bus to start at all;
#                  run.sh starts a private one inside the container for this
# jq             - reads the add-on's options.json
# python3        - runs l2_broadcast_relay.py (stdlib only, no pip packages needed)
# tcpdump        - used only when the "debug_mode" option is set to "packet_capture",
#                  to show real packets (or their absence) arriving on each interface
#                  directly in the add-on's log, with no SSH/device access needed
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        parprouted \
        iproute2 \
        iptables \
        avahi-daemon \
        dbus \
        jq \
        procps \
        python3 \
        tcpdump \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY l2_broadcast_relay.py /usr/sbin/l2_broadcast_relay.py
RUN chmod a+x /usr/sbin/l2_broadcast_relay.py

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
