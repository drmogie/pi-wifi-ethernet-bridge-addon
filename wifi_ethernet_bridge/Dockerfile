ARG BUILD_FROM
FROM $BUILD_FROM

# parprouted   - proxy-ARP bridging daemon (does the actual eth0 <-> wlan0 bridging)
# dhcp-helper  - relays DHCP broadcasts from the Ethernet client to the WiFi network
# iproute2     - `ip` command, used to bring interfaces up/down and set promisc mode
# iptables     - needed to explicitly allow FORWARD traffic between the two
#                interfaces, since Docker manages its own FORWARD chain
#                rules/policy on the host and doesn't automatically allow
#                traffic between two non-Docker interfaces
# avahi-daemon - optional mDNS reflector, so .local names resolve across the bridge
# dbus         - avahi-daemon needs a running D-Bus system bus to start at all;
#                run.sh starts a private one inside the container for this
# jq           - reads the add-on's options.json
# tcpdump      - used only when the "debug_mode" option is set to "packet_capture",
#                to show real packets (or their absence) arriving on each interface
#                directly in the add-on's log, with no SSH/device access needed
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        parprouted \
        dhcp-helper \
        iproute2 \
        iptables \
        avahi-daemon \
        dbus \
        jq \
        procps \
        tcpdump \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
