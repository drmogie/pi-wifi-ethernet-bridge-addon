ARG BUILD_FROM

# --- Stage 1: build udp-broadcast-relay-redux from source -------------------
# Not packaged for Debian, so it's compiled here and only the resulting
# binary is copied into the final image (build-essential/git never ship).
# Upstream: https://github.com/udp-redux/udp-broadcast-relay-redux - it's a
# single main.c with no external dependencies beyond libc, built with a
# one-line Makefile (`gcc -g main.c -o udp-broadcast-relay-redux`).
FROM $BUILD_FROM AS builder
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/udp-redux/udp-broadcast-relay-redux.git /src && \
    cd /src && make

# --- Stage 2: runtime image ---------------------------------------------
FROM $BUILD_FROM

# parprouted   - proxy-ARP bridging daemon (does the actual eth0 <-> wlan0 bridging)
# udp-broadcast-relay-redux (built above) - retransmits the client's raw DHCP
#                broadcast (ports 67 and 68) between the two interfaces
#                unmodified, with no relay-agent/Gateway-IP rewriting. Used
#                instead of dhcp-helper because some DHCP servers (confirmed
#                with Technitium DNS Server) silently drop a relayed request
#                when the relay agent's own address is on the same subnet as
#                the DHCP scope - see the standard add-on's DOCS.md/CHANGELOG
#                for the full diagnosis. This makes the wired client's
#                broadcast look, to the DHCP server, exactly like an ordinary
#                directly-attached client's broadcast.
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
        iproute2 \
        iptables \
        avahi-daemon \
        dbus \
        jq \
        procps \
        tcpdump \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=builder /src/udp-broadcast-relay-redux /usr/sbin/udp-broadcast-relay-redux
RUN chmod a+x /usr/sbin/udp-broadcast-relay-redux

COPY run.sh /run.sh
RUN chmod a+x /run.sh

CMD [ "/run.sh" ]
