#!/usr/bin/env python3
# UDP echo listener on multiple ports to find which ports pass the path
import socket, select, sys, time

PORTS = [8000, 8001, 8081, 3478, 443, 19302, 50000]
socks = {}
for p in PORTS:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        s.bind(("0.0.0.0", p))
        s.setblocking(False)
        socks[s] = p
    except Exception as e:
        print("bind fail", p, e)

print("listening on", sorted(socks.values()), flush=True)
end = time.time() + 60
while time.time() < end:
    r, _, _ = select.select(list(socks.keys()), [], [], 1.0)
    for s in r:
        try:
            data, addr = s.recvfrom(2048)
            s.sendto(b"ECHO:" + data, addr)
            print("recv on %d from %s:%d len=%d" % (socks[s], addr[0], addr[1], len(data)), flush=True)
        except Exception as e:
            print("err", e, flush=True)
print("done", flush=True)
