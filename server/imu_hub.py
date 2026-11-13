#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""IMU 数据中转服务（AX650 / ICM-45686 -> 浏览器播放页）

零第三方依赖，Python 3.6+ 即可运行。做三件事：
  1. POST /api/imu            接收板端上报的数据信封（JSON 或纯文本原始输出）
  2. 原子写 players/imu_latest.json，供 flv_live.html 同源 fetch（无跨域）
  3. GET /api/imu、/api/imu/history、/api/imu/stream（SSE）供其它客户端读取

标准部署：
  python3 imu_hub.py --port 8090 \
      --html /usr/local/srs/srs-server-6.0-r3/trunk/objs/nginx/html/players \
      --token <SECRET>

信封格式见 server/imu_panel.js 顶部注释。
"""
import argparse
import json
import os
import sys
import threading
import time
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DEFAULT_HTML = ("/usr/local/srs/srs-server-6.0-r3/trunk/"
                "objs/nginx/html/players")
MAX_BODY = 256 * 1024
MAX_LINES = 200

_lock = threading.Lock()
_state = {
    "latest": {},
    "history": deque(maxlen=300),
    "seq": 0,
    "frames": 0,
    "bytes": 0,
    "started": time.time(),
    "last_at": 0.0,
    "last_peer": "",
    "errors": 0,
}
_cfg = {"html": DEFAULT_HTML, "token": "", "file": ""}


def _atomic_write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def _normalize(obj, peer):
    """把板端上报内容规整成统一信封。"""
    if isinstance(obj, str):
        obj = {"lines": obj.splitlines()}
    if not isinstance(obj, dict):
        raise ValueError("body must be a JSON object or plain text")
    lines = obj.get("lines")
    if lines is None:
        raw = obj.get("raw") or obj.get("line") or ""
        lines = raw.splitlines() if isinstance(raw, str) else []
    if isinstance(lines, str):
        lines = lines.splitlines()
    lines = [str(x) for x in lines if x is not None][-MAX_LINES:]
    env = {
        "src": str(obj.get("src") or "icm45686"),
        "ts": float(obj.get("ts") or time.time()),
        "seq": int(obj.get("seq") or 0),
        "lines": lines,
        "conf": str(obj.get("conf") or ""),
        "caps": str(obj.get("caps") or ""),
        "irq": obj.get("irq"),
        "raw": str(obj.get("raw") or ""),
        "peer": peer,
    }
    return env


def accept(obj, peer):
    env = _normalize(obj, peer)
    with _lock:
        _state["frames"] += 1
        _state["seq"] += 1
        _state["last_at"] = time.time()
        _state["last_peer"] = peer
        if not env["seq"]:
            env["seq"] = _state["seq"]
        env["hub_seq"] = _state["seq"]
        env["hub_ts"] = time.time()
        _state["latest"] = env
        _state["history"].append(env)
        payload = json.dumps(env, ensure_ascii=False, separators=(",", ":"))
    if _cfg["file"]:
        try:
            _atomic_write(_cfg["file"], payload)
        except OSError as e:
            sys.stderr.write("imu_hub: write %s failed: %s\n" % (_cfg["file"], e))
    return env


class Handler(BaseHTTPRequestHandler):
    server_version = "imu-hub/1.0"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        if os.environ.get("IMU_HUB_VERBOSE"):
            sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Imu-Token")
        self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Cache-Control", "no-store")

    def _json(self, code, obj, head_only=False):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._cors()
        self.end_headers()
        if not head_only:
            self.wfile.write(body)

    def _ok_token(self, q):
        if not _cfg["token"]:
            return True
        given = self.headers.get("X-Imu-Token") or ""
        if not given:
            given = (q.get("token") or [""])[0]
        return given == _cfg["token"]

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self._cors()
        self.end_headers()

    def do_POST(self):
        parsed = urlparse(self.path)
        q = parse_qs(parsed.query)
        if parsed.path.rstrip("/") != "/api/imu":
            return self._json(404, {"ok": False, "error": "no such endpoint"})
        if not self._ok_token(q):
            return self._json(401, {"ok": False, "error": "bad token"})
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            return self._json(413, {"ok": False, "error": "bad content-length"})
        raw = self.rfile.read(length)
        try:
            try:
                obj = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                obj = raw.decode("utf-8", "replace")
            env = accept(obj, self.client_address[0])
            with _lock:
                _state["bytes"] += length
            return self._json(200, {"ok": True, "seq": env["hub_seq"],
                                    "lines": len(env["lines"])})
        except Exception as e:  # noqa: BLE001 - 上报服务不能因脏数据退出
            with _lock:
                _state["errors"] += 1
            return self._json(400, {"ok": False, "error": str(e)})

    def do_GET(self):
        parsed = urlparse(self.path)
        q = parse_qs(parsed.query)
        p = parsed.path.rstrip("/")
        if p in ("/", "/health"):
            with _lock:
                s = dict(_state)
                history_len = len(s.pop("history"))
            return self._json(200, {
                "ok": True, "service": "imu-hub",
                "uptime_s": round(time.time() - s["started"], 1),
                "frames": s["frames"], "errors": s["errors"],
                "history": history_len,
                "last_age_s": round(time.time() - s["last_at"], 2) if s["last_at"] else None,
                "last_peer": s["last_peer"],
                "file": _cfg["file"], "token_required": bool(_cfg["token"]),
            })
        if p == "/api/imu":
            with _lock:
                env = _state["latest"]
            return self._json(200, env if env else {"src": "icm45686", "lines": [],
                                                    "ts": time.time(), "seq": 0,
                                                    "empty": True})
        if p == "/api/imu/history":
            n = max(1, min(300, int((q.get("n") or ["60"])[0])))
            with _lock:
                items = list(_state["history"])[-n:]
            return self._json(200, {"ok": True, "items": items})
        if p == "/api/imu/stream":
            return self._sse()
        return self._json(404, {"ok": False, "error": "no such endpoint"})

    def _sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Connection", "close")
        self._cors()
        self.end_headers()
        last = -1
        try:
            self.wfile.write(b": imu-hub connected\n\n")
            self.wfile.flush()
            while True:
                with _lock:
                    seq, env = _state["seq"], _state["latest"]
                if seq != last and env:
                    last = seq
                    data = json.dumps(env, ensure_ascii=False, separators=(",", ":"))
                    self.wfile.write(("data: %s\n\n" % data).encode("utf-8"))
                    self.wfile.flush()
                else:
                    self.wfile.write(b": ping\n\n")
                    self.wfile.flush()
                time.sleep(0.2)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass


def main():
    ap = argparse.ArgumentParser(description="AX650 IMU -> browser relay")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--html", default=DEFAULT_HTML,
                    help="SRS players 目录，imu_latest.json 写到这里供页面同源读取")
    ap.add_argument("--token", default=os.environ.get("IMU_HUB_TOKEN", ""),
                    help="板端上报鉴权（不设则不校验，仅建议内网调试时使用）")
    ap.add_argument("--no-file", action="store_true", help="不写静态 JSON 文件")
    args = ap.parse_args()

    _cfg["html"] = args.html
    _cfg["token"] = args.token
    if not args.no_file:
        if not os.path.isdir(args.html):
            sys.stderr.write("imu_hub: WARN html dir not found: %s (静态 JSON 不写)\n" % args.html)
        else:
            _cfg["file"] = os.path.join(args.html, "imu_latest.json")
            _atomic_write(_cfg["file"], json.dumps({
                "src": "icm45686", "ts": time.time(), "seq": 0, "lines": [],
                "conf": "", "empty": True, "hint": "等待板端 imu_agent.sh 上报",
            }, ensure_ascii=False))
    if not args.token:
        sys.stderr.write("imu_hub: WARN 未设置 --token，任何人可 POST /api/imu\n")

    srv = ThreadingHTTPServer((args.host, args.port), Handler)
    srv.daemon_threads = True
    print("imu_hub listening %s:%d  file=%s  token=%s" %
          (args.host, args.port, _cfg["file"] or "(disabled)", "yes" if args.token else "no"),
          flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
