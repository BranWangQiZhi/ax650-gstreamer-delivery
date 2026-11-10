import socket, struct, os, sys, time

SERVER = ("121.40.107.62", 8000)

def stun_binding():
    # STUN Binding Request: type=0x0001, len=0, magic cookie 0x2112A442, txid
    txid = os.urandom(12)
    pkt = struct.pack(">HHI", 0x0001, 0, 0x2112A442) + txid
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(3)
    s.sendto(pkt, SERVER)
    try:
        data, addr = s.recvfrom(2048)
        print("REPLY from", addr, "len=", len(data), "txid_match=", data[8:20] == txid)
        # parse XOR-MAPPED-ADDRESS (0x0020) or MAPPED-ADDRESS (0x0001)
        i = 20
        while i + 4 <= len(data):
            atype, alen = struct.unpack(">HH", data[i:i+4])
            val = data[i+4:i+4+alen]
            if atype == 0x0020 and len(val) >= 8:
                fam = val[1]
                port = struct.unpack(">H", val[2:4])[0] ^ 0x2112
                ip = bytes(b ^ k for b, k in zip(val[4:8], b"\x21\x12\xa4\x42"))
                print("MAPPED(XOR) %d.%d.%d.%d:%d" % (ip[0], ip[1], ip[2], ip[3], port))
            i += 4 + alen + ((4 - alen % 4) % 4)
        return True
    except socket.timeout:
        print("TIMEOUT: no STUN reply from", SERVER)
        return False
    finally:
        s.close()

ok = stun_binding()
sys.exit(0 if ok else 1)
