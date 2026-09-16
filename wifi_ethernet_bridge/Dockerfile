ARG BUILD_FROM
FROM $BUILD_FROM

# parprouted   - proxy-ARP bridging daemon (does the actual eth0 <-> wlan0 bridging)
# dhcp-helper  - relays DHCP broadcasts from the Ethernet client to the WiFi network
# iproute2     - `ip` command, used to bring interfaces up/down and set promisc mode
# avahi-daemon - optional mDNS reflector, so .local names resolve across the bridge
# jq           - reads the add-on's options.json
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        parprouted \
        dhcp-helper \
        iproute2 \
        avahi-daemon \
        jq \
        procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
