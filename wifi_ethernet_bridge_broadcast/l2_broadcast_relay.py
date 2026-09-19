#!/usr/bin/env python3
"""Minimal L2 broadcast relay for a single UDP port.

Why this exists (2026-09-19): the tool this add-on used to use here,
udp-broadcast-relay-redux, receives by binding an ordinary UDP socket to
0.0.0.0:<port>. On a host-networked Home Assistant add-on running on a
device whose own uplink interface (wlan0) gets its address via DHCP, the
HOST's own DHCP client is already bound to port 68 for its own lease
renewal - and since that client almost certainly did not set
SO_REUSEPORT itself, nothing else can ever bind port 68 alongside it, no
matter what socket options this add-on's own process sets (Linux only
allows two sockets to share one exact address:port when BOTH opt in).
That made the port-68 (server-reply) instance fail to start on every run,
which in turn tripped this add-on's own health check and tore the whole
bridge down.

This script sidesteps the problem entirely: it captures raw Ethernet
frames via AF_PACKET (the same technique tcpdump/tshark use), which does
not register any ownership of a UDP port at all, filters for the target
port itself, and retransmits the untouched IP/UDP/DHCP payload as a fresh
Ethernet-broadcast frame on the other interface. IP/UDP checksums are
never touched (only the Ethernet header is replaced), so they stay valid.

Side benefit: because both interfaces are already put into promiscuous
mode by run.sh, this also picks up a DHCP reply that a server sent as a
*unicast* frame straight to the client's real MAC address (something a
plain broadcast-only relay tool can never see, since that traffic isn't
addressed to this host at all outside of promiscuous mode) - this was a
separately-documented open risk (RFC 2131 allows a server to do this when
the client's DHCPDISCOVER left its "broadcast" flag unset) that this
rewrite may incidentally also resolve, though that still needs a real
retest to confirm.
"""
import argparse
import socket
import struct
import sys

ETH_P_IP = 0x0800
BROADCAST_MAC = b"\xff\xff\xff\xff\xff\xff"


def log(port, msg):
    print(f"[l2-relay:{port}] {msg}", flush=True)


def get_mac(ifname):
    with open(f"/sys/class/net/{ifname}/address") as f:
        return bytes.fromhex(f.read().strip().replace(":", ""))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True, help="UDP destination port to relay (67 or 68)")
    ap.add_argument("--recv-if", required=True, help="Interface to capture matching frames on")
    ap.add_argument("--send-if", required=True, help="Interface to retransmit matching frames on")
    args = ap.parse_args()

    try:
        send_mac = get_mac(args.send_if)
    except OSError as e:
        log(args.port, f"ERROR: could not read MAC address for {args.send_if}: {e}")
        sys.exit(1)

    try:
        rx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_IP))
        rx.bind((args.recv_if, 0))
        tx = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_IP))
        tx.bind((args.send_if, 0))
    except OSError as e:
        log(args.port, f"ERROR: could not open a raw socket on {args.recv_if}/{args.send_if}: {e}")
        sys.exit(1)

    log(args.port, f"relaying UDP/{args.port} frames {args.recv_if} -> {args.send_if}")

    while True:
        try:
            frame = rx.recv(65535)
        except OSError as e:
            log(args.port, f"ERROR: recv failed: {e}")
            sys.exit(1)

        if len(frame) < 14 + 20 + 8:
            continue
        if struct.unpack("!H", frame[12:14])[0] != ETH_P_IP:
            continue

        ip_hdr = frame[14:34]
        ihl = (ip_hdr[0] & 0x0F) * 4
        proto = ip_hdr[9]
        if proto != 17:  # UDP
            continue

        udp_off = 14 + ihl
        if len(frame) < udp_off + 8:
            continue
        _src_port, dst_port = struct.unpack("!HH", frame[udp_off:udp_off + 4])
        if dst_port != args.port:
            continue

        # Keep the original IP/UDP/DHCP payload byte-for-byte; only the
        # Ethernet header is replaced (broadcast destination, sender's own
        # source MAC on the outgoing interface).
        payload = frame[14:]
        new_frame = BROADCAST_MAC + send_mac + struct.pack("!H", ETH_P_IP) + payload
        try:
            tx.send(new_frame)
        except OSError as e:
            log(args.port, f"send error (dropping this frame): {e}")


if __name__ == "__main__":
    main()
