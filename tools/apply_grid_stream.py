#!/usr/bin/env python3
"""PC-side helper: upload and enable the board's 5-in-1 grid stream axstream5.

Usage:
  python tools/apply_grid_stream.py                       # upload script + enable axstream5
  python tools/apply_grid_stream.py --action status      # health check only, no changes
  python tools/apply_grid_stream.py --action disable     # rollback
  BOARD_PASSWORD=xxx python tools/apply_grid_stream.py   # non-interactive (env var, never stored)

The password is read only from BOARD_PASSWORD or an interactive getpass prompt;
it is never written to disk or printed.
Board script: board/enable_grid_stream.sh -> /usr/local/bin/enable_grid_stream.sh
"""

from __future__ import annotations

import argparse
import getpass
import os
import shlex
import socket
import sys
import time
from pathlib import Path

import paramiko

ROOT = Path(__file__).resolve().parents[1]
LOCAL_SCRIPT = ROOT / "board" / "enable_grid_stream.sh"
REMOTE_SCRIPT = "/usr/local/bin/enable_grid_stream.sh"


def connect(host: str, user: str, port: int) -> paramiko.SSHClient:
    # Try key / agent auth first, then fall back to a password prompt.
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        cli.connect(host, port=port, username=user, timeout=6,
                    banner_timeout=6, auth_timeout=6,
                    look_for_keys=True, allow_agent=True)
        print("[pc] SSH: 免密登录成功")
        return cli
    except Exception:
        cli.close()

    pw = os.environ.get("BOARD_PASSWORD") or getpass.getpass(
        "板端 SSH 密码（不回显、不保存）: ")
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(host, port=port, username=user, password=pw, timeout=10,
                banner_timeout=10, auth_timeout=10,
                look_for_keys=False, allow_agent=False)
    print("[pc] SSH: 密码登录成功")
    return cli


def run_stream(cli: paramiko.SSHClient, cmd: str, timeout: int = 240) -> int:
    """Run a board command and stream its output live (restart may take 30s+)."""
    print(f"[pc] 板端执行: {cmd}")
    ch = cli.get_transport().open_session()
    ch.settimeout(timeout)
    ch.set_combine_stderr(True)  # merge stderr, otherwise board-side errors get swallowed
    ch.exec_command(cmd)
    buf = b""
    start = time.time()
    while True:
        if ch.recv_ready():
            buf += ch.recv(4096)
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                print(line.decode("utf-8", "replace"), flush=True)
        if ch.exit_status_ready() and not ch.recv_ready():
            break
        if time.time() - start > timeout:
            print("[pc] ERROR: 板端命令超时", file=sys.stderr)
            ch.close()
            return 124
        time.sleep(0.2)
    if buf:
        print(buf.decode("utf-8", "replace"), flush=True)
    rc = ch.recv_exit_status()
    ch.close()
    print(f"[pc] 板端命令退出码: {rc}")
    return rc


def describe(host: str, path: str, timeout: float = 2.0) -> str:
    """Send a DESCRIBE to the board's RTSP server and return the full response."""
    url = f"rtsp://{host}:8554/{path}"
    req = (f"DESCRIBE {url} RTSP/1.0\r\nCSeq: 1\r\n"
           f"Accept: application/sdp\r\n\r\n").encode()
    try:
        s = socket.create_connection((host, 8554), timeout)
        s.settimeout(timeout)
        s.sendall(req)
        data = b""
        need = None
        while True:
            c = s.recv(4096)
            if not c:
                break
            data += c
            if need is None and b"\r\n\r\n" in data:
                head, _ = data.split(b"\r\n\r\n", 1)
                for line in head.split(b"\r\n"):
                    if line.lower().startswith(b"content-length:"):
                        try:
                            need = data.find(b"\r\n\r\n") + 4 + int(line.split(b":", 1)[1])
                        except ValueError:
                            pass
            if need is not None and len(data) >= need:
                break
        s.close()
        return data.decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        return f"ERROR {e}"


def verify(host: str, wait: int = 20) -> bool:
    print("\n[pc] --- RTSP 通道验证（DESCRIBE）---")
    for p in ["axstream0", "axstream1", "axstream2", "axstream3",
              "axstream4", "axstream5"]:
        resp = describe(host, p)
        status = resp.split("\r\n", 1)[0].strip() if resp else "NO RESPONSE"
        has_video = "m=video" in resp
        print(f"  {p:11s} {status:20s} m=video: {'YES' if has_video else 'NO'}")
    ok = "m=video" in describe(host, "axstream5")
    if not ok and wait > 0:
        deadline = time.time() + wait
        while time.time() < deadline:
            time.sleep(2)
            ok = "m=video" in describe(host, "axstream5")
            if ok:
                break
    if ok:
        print(f"[pc] GRID_STREAM_OK: rtsp://{host}:8554/axstream5 已可拉流")
    else:
        print("[pc] GRID_STREAM_MISSING: axstream5 仍无媒体轨；"
              "检查板端日志 /tmp/flex_vision.log 里的 [multiGrideDisplay] 与 ivps-merge config",
              file=sys.stderr)
    return ok


def main() -> int:
    ap = argparse.ArgumentParser(description="下发并启用板端 axstream5 拼接流")
    ap.add_argument("--host", default="192.168.137.226", help="板端 IP")
    ap.add_argument("--user", default="root")
    ap.add_argument("--port", type=int, default=22)
    ap.add_argument("--action", choices=["enable", "disable", "status"],
                    default="enable")
    ap.add_argument("--ini", help="板端 ini 路径（默认用板端脚本内置值）")
    ap.add_argument("--no-restart", action="store_true", help="只改 ini，不重启 flex_vision")
    ap.add_argument("--no-restore", action="store_true", help="重启后不恢复原推流")
    ap.add_argument("--skip-upload", action="store_true", help="板端已有脚本，跳过上传")
    ap.add_argument("--skip-verify", action="store_true", help="跳过 RTSP DESCRIBE 验证")
    ap.add_argument("--wait", type=int, default=20, help="验证阶段最多等待秒数")
    args = ap.parse_args()

    if not args.skip_upload and not LOCAL_SCRIPT.is_file():
        print(f"[pc] ERROR: 找不到 {LOCAL_SCRIPT}", file=sys.stderr)
        return 2

    try:
        cli = connect(args.host, args.user, args.port)
    except Exception as e:  # noqa: BLE001
        print(f"[pc] ERROR: SSH 连接失败: {e}", file=sys.stderr)
        return 2

    try:
        if not args.skip_upload:
            sftp = cli.open_sftp()
            sftp.put(str(LOCAL_SCRIPT), REMOTE_SCRIPT)
            sftp.chmod(REMOTE_SCRIPT, 0o755)
            sftp.close()
            print(f"[pc] 已下发 {LOCAL_SCRIPT.name} -> {REMOTE_SCRIPT} (755)")

        env = []
        if args.ini:
            env.append("INI=" + shlex.quote(args.ini))
        if args.no_restart:
            env.append("NO_RESTART=1")
        if args.no_restore:
            env.append("NO_RESTORE=1")
        cmd = (" ".join(env) + " " if env else "") + \
              f"{REMOTE_SCRIPT} {args.action}"
        rc = run_stream(cli, cmd)
    finally:
        cli.close()

    if args.skip_verify:
        return 0 if rc == 0 else rc

    ok = verify(args.host, wait=args.wait if args.action == "enable" else 0)
    if args.action == "enable":
        return 0 if ok else 1
    return 0 if rc == 0 else rc


if __name__ == "__main__":
    sys.exit(main())
