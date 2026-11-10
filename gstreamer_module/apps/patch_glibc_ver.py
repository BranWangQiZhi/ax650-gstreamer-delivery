#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
patch_glibc_ver.py - 让「用 glibc 2.33 工具链编出的库」能在 glibc 2.30 的板子上跑

背景:
  AX650 SDK 工具链 sysroot 是 glibc 2.33, 板子 rootfs 是 glibc 2.30。
  glibc 2.33 头文件把 stat()/lstat()/fstat() 重定向到了 stat64/lstat64/fstat64,
  并给 pthread_sigmask 也升了版本号, 于是我们编出的 .so 里有:
      stat64/lstat64/fstat64 -> GLIBC_2.33
      pthread_sigmask        -> GLIBC_2.32
  而板子的 2.30 在 aarch64 上压根没导出 stat64, 运行时直接报
  "version `GLIBC_2.33' not found" 或 "undefined symbol: stat64"。

做法 (三步, 都只改 ELF 元数据, 不动代码):
  1. .dynstr 里把 "GLIBC_2.33"/"GLIBC_2.32" 等长替换成 "GLIBC_2.17"
  2. .gnu.version_r 里同步重算 vna_hash (否则 glibc 校验仍失败)
  3. 把这 4 个符号在 .gnu.version (versym) 中的索引改成 1 (=*global*, 无版本约束),
     运行时由 libglibc230_compat.so 提供实现 (LD_PRELOAD)

用法:
  python3 patch_glibc_ver.py <文件或目录> ...
"""
import os
import struct
import sys

DOWNGRADE_MAP = {b"GLIBC_2.33": b"GLIBC_2.17", b"GLIBC_2.32": b"GLIBC_2.17"}

# 板子 glibc 2.30 缺失 / 版本不匹配的符号, 统一去掉版本约束
UNVERSION_SYMS = {b"stat64", b"lstat64", b"fstat64", b"pthread_sigmask",
                  b"__xstat64", b"__lxstat64", b"__fxstat64"}

SHT_DYNSYM = 11
SHT_STRTAB = 3
SHT_GNU_VERNEED = 0x6FFFFFFE
SHT_GNU_VERSYM = 0x6FFFFFFF


def elf_hash(name: bytes) -> int:
    h = 0
    for c in name:
        h = ((h << 4) + c) & 0xFFFFFFFF
        g = h & 0xF0000000
        if g:
            h ^= g >> 24
        h &= ~g & 0xFFFFFFFF
    return h


def parse_sections(data):
    if data[:4] != b"\x7fELF" or data[4] != 2:  # ELF64 only
        return None
    e_shoff = struct.unpack_from("<Q", data, 0x28)[0]
    e_shentsize = struct.unpack_from("<H", data, 0x3A)[0]
    e_shnum = struct.unpack_from("<H", data, 0x3C)[0]
    if e_shoff == 0 or e_shnum == 0:
        return None
    secs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        (sh_name, sh_type, _flags, _addr, sh_offset, sh_size,
         sh_link, _info, _align, sh_entsize) = struct.unpack_from("<IIQQQQIIQQ", data, off)
        secs.append(dict(name=sh_name, type=sh_type, off=sh_offset, size=sh_size,
                         link=sh_link, entsize=sh_entsize))
    return secs


def patch_elf(path):
    with open(path, "rb") as f:
        data = bytearray(f.read())
    if data[:4] != b"\x7fELF":
        return 0

    secs = parse_sections(data)
    if not secs:
        return 0
    changed = 0

    def soff(i):
        return secs[i]["off"]

    def ssize(i):
        return secs[i]["size"]

    def read_cstr(base, off):
        end = data.index(b"\0", base + off)
        return bytes(data[base + off:end])

    # --- 1) 等长替换版本字符串 ---
    for sec in secs:
        if sec["type"] == SHT_STRTAB:
            blob = bytes(data[sec["off"]:sec["off"] + sec["size"]])
            new = blob
            for old, repl in DOWNGRADE_MAP.items():
                if old in new:
                    changed += new.count(old)
                    new = new.replace(old, repl)
            if new != blob:
                data[sec["off"]:sec["off"] + sec["size"]] = new

    # --- 2) 重算 .gnu.version_r 的 vna_hash ---
    for sec in secs:
        if sec["type"] != SHT_GNU_VERNEED:
            continue
        base = soff(sec["link"])
        pos, end = sec["off"], sec["off"] + sec["size"]
        while pos < end:
            _ver, _cnt, _file, vn_aux, vn_next = struct.unpack_from("<HHIII", data, pos)
            apos = pos + vn_aux
            while True:
                vna_hash, _flags, _other, vna_name, vna_next = struct.unpack_from("<IHHII", data, apos)
                want = elf_hash(read_cstr(base, vna_name))
                if want != vna_hash:
                    struct.pack_into("<I", data, apos, want)
                    changed += 1
                if vna_next == 0:
                    break
                apos += vna_next
            if vn_next == 0:
                break
            pos += vn_next

    # --- 3) 目标符号 versym 置 1 (无版本约束) ---
    versym_sec = next((s for s in secs if s["type"] == SHT_GNU_VERSYM), None)
    dynsym_sec = next((s for s in secs if s["type"] == SHT_DYNSYM), None)
    if versym_sec and dynsym_sec:
        strbase = soff(dynsym_sec["link"])
        n = dynsym_sec["size"] // 24
        for i in range(n):
            off = dynsym_sec["off"] + i * 24
            st_name = struct.unpack_from("<I", data, off)[0]
            if st_name == 0:
                continue
            name = read_cstr(strbase, st_name)
            if name in UNVERSION_SYMS:
                vpos = versym_sec["off"] + i * 2
                cur = struct.unpack_from("<H", data, vpos)[0]
                if cur != 1:
                    struct.pack_into("<H", data, vpos, 1)
                    changed += 1

    if changed:
        with open(path, "wb") as f:
            f.write(data)
    return changed


def walk(target):
    total = 0
    if os.path.isfile(target):
        n = patch_elf(target)
        if n:
            print("patched %d: %s" % (n, target))
        return n
    for root, _dirs, files in os.walk(target):
        for name in files:
            if "glibc230_compat" in name:
                continue  # 兼容层自身的版本节点不能改
            if ".so" in name or name == "whip_push":
                p = os.path.join(root, name)
                if os.path.islink(p):
                    continue
                n = patch_elf(p)
                if n:
                    print("patched %d: %s" % (n, p))
                    total += n
    return total


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    print("total: %d" % sum(walk(t) for t in sys.argv[1:]))
