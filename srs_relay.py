# -*- coding: utf-8 -*-
"""SRS 用户态转发器：绕过坏掉的 Windows ICS NAT。

板上访问 192.168.137.1（PC）：
  - TCP 1985 (WHIP HTTP)  -> 121.40.107.62:1985
  - UDP 8000 (ICE/STUN/RTP) -> 121.40.107.62:8000
板上 WHIP URL 需带 eip=192.168.137.1，让 SRS 在 answer 里通告 PC 作为 candidate。
"""
import asyncio
import socket
import threading

SRS = ("121.40.107.62", 1985)
SRS_UDP = ("121.40.107.62", 8000)

async def pipe(r: asyncio.StreamReader, w: asyncio.StreamWriter):
    try:
        while True:
            data = await r.read(65536)
            if not data:
                break
            w.write(data)
            await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass

async def handle_tcp(r: asyncio.StreamReader, w: asyncio.StreamWriter):
    try:
        ur, uw = await asyncio.open_connection(*SRS)
        await asyncio.gather(pipe(r, uw), pipe(ur, w))
    except Exception:
        try:
            w.close()
        except Exception:
            pass

def udp_relay():
    """UDP 8000 双向转发：按客户端地址维护后端 socket。"""
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind(("0.0.0.0", 8000))
    conns = {}  # client_addr -> socket to SRS
    lock = threading.Lock()

    def reader(client_addr, s):
        while True:
            try:
                data, _ = s.recvfrom(65535)
            except OSError:
                break
            srv.sendto(data, client_addr)

    while True:
        data, addr = srv.recvfrom(65535)
        with lock:
            s = conns.get(addr)
            if s is None:
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.bind(("0.0.0.0", 0))  # 独立源端口
                s.sendto(data, SRS_UDP)
                conns[addr] = s
                t = threading.Thread(target=reader, args=(addr, s), daemon=True)
                t.start()
            else:
                s.sendto(data, SRS_UDP)

async def main():
    t = threading.Thread(target=udp_relay, daemon=True)
    t.start()
    server = await asyncio.start_server(handle_tcp, "0.0.0.0", 1985)
    print("relay up: tcp 1985 -> 121.40.107.62:1985, udp 8000 -> 121.40.107.62:8000")
    async with server:
        await server.serve_forever()

if __name__ == "__main__":
    asyncio.run(main())
