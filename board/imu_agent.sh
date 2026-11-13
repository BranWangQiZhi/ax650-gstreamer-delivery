#!/bin/sh
# ============================================================================
# imu_agent.sh - 板端 ICM-45686 IMU 采集 / 上报 / 本地 HTTP 服务
# ----------------------------------------------------------------------------
# 部署路径: /usr/local/bin/imu_agent.sh（chmod 755）
# 依赖: POSIX sh + awk + sed + (wget 或 nc)；HTTP 服务需要 python3 或 busybox httpd
#
# 用法:
#   imu_agent.sh start [push|serve|both]   启动（默认 both）
#   imu_agent.sh stop                     停止
#   imu_agent.sh status                   查看状态与最新帧
#   imu_agent.sh once                     前台采一帧并打印 JSON（调试用）
#   imu_agent.sh sample                    前台持续采帧打印（调试用）
#
# 环境变量（均可覆盖，开机脚本里写死即可）:
#   SRS_HOST=121.196.101.253   服务器 IP（与 flex_srs.sh 共用）
#   IMU_HUB_PORT=8090          服务器 imu_hub.py 端口
#   IMU_TOKEN=                 上报鉴权 token（与服务器 --token 一致）
#   IMU_HTTP_PORT=8099         板端直连 HTTP 端口
#   IMU_MODE=both              push=只上报 / serve=只本地服务 / both=两者
#   IMU_BIN=/opt/bin/sample_icm45686
#   IMU_REG=/sys/bus/spi/devices/spi0.0/imu_reg
#   IMU_PERIOD=1               每次 --duration 秒数
#   IMU_MAX_LINES=40           每帧最多带多少行（降采样，控制带宽）
#   IMU_FILTER=                可选 grep -E 过滤表达式，例 '[0-9]+\.[0-9]+'
#
# 数据链路:
#   push  -> POST http://$SRS_HOST:$IMU_HUB_PORT/api/imu  -> imu_hub.py
#            -> 原子写 players/imu_latest.json -> 播放页同源 fetch（公网可看）
#   serve -> http://<板IP>:$IMU_HTTP_PORT/cgi-bin/imu     -> 播放页 JSONP（局域网可看）
# ============================================================================

SRS_HOST=${SRS_HOST:-121.196.101.253}
HUB_PORT=${IMU_HUB_PORT:-8090}
TOKEN=${IMU_TOKEN:-}
HTTP_PORT=${IMU_HTTP_PORT:-8099}
BIN=${IMU_BIN:-/opt/bin/sample_icm45686}
REG=${IMU_REG:-/sys/bus/spi/devices/spi0.0/imu_reg}
PERIOD=${IMU_PERIOD:-1}
MAX_LINES=${IMU_MAX_LINES:-40}
MODE=${IMU_MODE:-both}
FILTER=${IMU_FILTER:-}

DIR=${IMU_DIR:-/tmp/imu_web}
LOG=${IMU_LOG:-/tmp/imu_agent.log}
JSON="$DIR/imu.json"
RAW="$DIR/raw.txt"
CONF="$DIR/conf.txt"
PIDFILE="$DIR/agent.pid"
HTTPPID="$DIR/httpd.pid"
HUB_URL="http://${SRS_HOST}:${HUB_PORT}/api/imu"
[ -n "$TOKEN" ] && HUB_URL="${HUB_URL}?token=${TOKEN}"

say() { echo "imu_agent: $*"; echo "$(date '+%F %T') imu_agent: $*" >>"$LOG" 2>/dev/null; }

# ---------------------------------------------------------------- 采集一帧
collect_frame() {
  : >"$RAW"
  if [ -x "$BIN" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout $((PERIOD + 3)) "$BIN" --duration "$PERIOD" --dump 2>/dev/null | tail -n "$MAX_LINES" >"$RAW"
    else
      "$BIN" --duration "$PERIOD" --dump 2>/dev/null | tail -n "$MAX_LINES" >"$RAW"
    fi
  fi
  # 兜底：sysfs 单帧原始寄存器值
  if [ ! -s "$RAW" ] && [ -r "$REG" ]; then head -n 1 "$REG" >"$RAW" 2>/dev/null; fi
  # 可选行过滤（拿到驱动真实输出后按需启用，例 IMU_FILTER='ts_us|ax='）
  if [ -n "$FILTER" ] && [ -s "$RAW" ]; then
    grep -E "$FILTER" "$RAW" >"$RAW.f" 2>/dev/null && mv "$RAW.f" "$RAW" || rm -f "$RAW.f"
  fi
  if [ ! -s "$RAW" ]; then
    echo "no data: $BIN --duration $PERIOD --dump / $REG" >"$RAW"
  fi
  # --conf 变化很慢，每 10 帧刷一次即可
  if [ ! -s "$CONF" ] || [ $((SEQ % 10)) -eq 0 ]; then
    if [ -x "$BIN" ]; then "$BIN" --conf >"$CONF" 2>/dev/null; fi
  fi
}

# ------------------------------------------------------- 组装统一 JSON 信封
build_json() {
  TS=$(date +%s 2>/dev/null)
  [ -z "$TS" ] && TS=$(awk 'BEGIN{print systime()}')
  IRQ=$(awk '/icm45686/ {n=0; for(i=2;i<=NF;i++) if($i ~ /^[0-9]+$/) n+=$i; print n; exit}' /proc/interrupts 2>/dev/null)
  [ -z "$IRQ" ] && IRQ=0
  awk -v ts="$TS" -v seq="$SEQ" -v irq="$IRQ" -v conf_file="$CONF" '
    function esc(s) {
      gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s)
      gsub(/\r/, "", s); gsub(/\t/, " ", s); gsub(/\n/, "\\n", s)
      return s
    }
    BEGIN {
      conf = ""
      while ((getline l < conf_file) > 0) conf = conf l "\n"
      close(conf_file)
      printf "{\"src\":\"icm45686\",\"ts\":%s,\"seq\":%s,\"irq\":%s,\"conf\":\"%s\",\"lines\":[", ts, seq, irq, esc(conf)
    }
    { if (NR > 1) printf ","; printf "\"%s\"", esc($0) }
    END { printf "]}\n" }
  ' "$RAW" >"$JSON.tmp" && mv "$JSON.tmp" "$JSON"
}

# ------------------------------------------------------------- 上报到服务器
post_frame() {
  [ -s "$JSON" ] || return 1
  HAS_POSTFILE=0
  wget --help 2>&1 | grep -q -- '--post-file' && HAS_POSTFILE=1
  if [ "$HAS_POSTFILE" = 1 ]; then
    if wget -q -O /dev/null -T 3 --post-file="$JSON" "$HUB_URL" 2>/dev/null; then
      echo "ok $(date +%s)" >"$DIR/last_post"
      return 0
    fi
  fi
  # nc 兜底：手搓 HTTP POST（busybox wget 不带 --post-file 时）
  if command -v nc >/dev/null 2>&1; then
    LEN=$(wc -c <"$JSON")
    REQ=$(printf '%s' "$HUB_URL" | sed 's|^http://[^/]*||')
    {
      printf 'POST %s HTTP/1.1\r\nHost: %s:%s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n' \
        "$REQ" "$SRS_HOST" "$HUB_PORT" "$LEN"
      cat "$JSON"
    } | nc -w 3 "$SRS_HOST" "$HUB_PORT" >/dev/null 2>&1 && {
      echo "ok(nc) $(date +%s)" >"$DIR/last_post"
      return 0
    }
  fi
  echo "fail $(date +%s)" >"$DIR/last_post"
  return 1
}

# ------------------------------------------------------- 本地 HTTP（直连模式）
make_httpd_files() {
  mkdir -p "$DIR/cgi-bin"
  # 1) CGI：支持 JSON 与 JSONP（页面 board 模式用 JSONP 规避跨域/预检）
  cat >"$DIR/cgi-bin/imu" <<'CGIEOF'
#!/bin/sh
JSON="__JSON__"
CB=$(printf '%s' "${QUERY_STRING:-}" | sed -n 's/.*[?&]cb=\([A-Za-z0-9_]*\).*/\1/p')
if [ -n "$CB" ]; then
  printf 'Content-Type: application/javascript\r\n'
else
  printf 'Content-Type: application/json\r\n'
fi
printf 'Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Private-Network: true\r\n\r\n'
[ -n "$CB" ] && printf '%s(' "$CB"
if [ -f "$JSON" ]; then cat "$JSON"
else printf '{"src":"icm45686","ts":0,"seq":0,"lines":[],"empty":true}'; fi
[ -n "$CB" ] && printf ');\n'
CGIEOF
  sed "s|__JSON__|$JSON|g" "$DIR/cgi-bin/imu" >"$DIR/cgi-bin/imu.tmp" && \
    mv "$DIR/cgi-bin/imu.tmp" "$DIR/cgi-bin/imu"
  chmod 755 "$DIR/cgi-bin/imu"
  # 2) python3 版 HTTP 服务（优先，自带 CORS/PNA/JSONP）
  cat >"$DIR/imu_httpd.py" <<'PYEOF'
import http.server, os, sys, urllib.parse
JSON_PATH = sys.argv[1]
PORT = int(sys.argv[2])

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _send(self, body, ctype, code=200):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
    def do_GET(self):
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        cb = (q.get("cb") or [""])[0]
        try:
            with open(JSON_PATH, "rb") as f:
                data = f.read().strip()
        except OSError:
            data = b'{"src":"icm45686","lines":[],"empty":true}'
        if cb and cb.replace("_", "").isalnum():
            self._send(cb.encode() + b"(" + data + b");\n", "application/javascript")
        else:
            self._send(data + b"\n", "application/json")
    def do_OPTIONS(self):
        self._send(b"", "text/plain", 204)
    def log_message(self, *a):
        pass

http.server.ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
PYEOF
  chmod 755 "$DIR/imu_httpd.py"
}

start_httpd() {
  make_httpd_files
  if command -v python3 >/dev/null 2>&1; then
    python3 "$DIR/imu_httpd.py" "$JSON" "$HTTP_PORT" >>"$LOG" 2>&1 &
    echo $! >"$HTTPPID"
    say "HTTP 服务(python3) 0.0.0.0:$HTTP_PORT"
  elif command -v busybox >/dev/null 2>&1 && busybox --list 2>/dev/null | grep -qx httpd; then
    cp "$JSON" "$DIR/imu.json" 2>/dev/null
    busybox httpd -f -p "$HTTP_PORT" -h "$DIR" >>"$LOG" 2>&1 &
    echo $! >"$HTTPPID"
    say "HTTP 服务(busybox httpd/CGI) 0.0.0.0:$HTTP_PORT"
  else
    say "WARN: 板端无 python3 / busybox httpd，本地直连不可用，仅上报模式"
  fi
}

# ------------------------------------------------------------------ 主循环
agent_loop() {
  SEQ=0
  mkdir -p "$DIR"
  say "采集开始 mode=$MODE bin=$BIN period=${PERIOD}s hub=$HUB_URL"
  while true; do
    collect_frame
    build_json
    if [ "$MODE" = "push" ] || [ "$MODE" = "both" ]; then post_frame; fi
    SEQ=$((SEQ + 1))
  done
}

kill_pidfile() {
  [ -f "$1" ] || return 0
  P=$(cat "$1" 2>/dev/null)
  [ -n "$P" ] && kill "$P" 2>/dev/null
  rm -f "$1"
}

case "${1:-status}" in
start)
  MODE=${2:-$MODE}
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    say "already running pid=$(cat "$PIDFILE")"; exit 0
  fi
  mkdir -p "$DIR"
  if [ "$MODE" = "serve" ] || [ "$MODE" = "both" ]; then start_httpd; fi
  agent_loop >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  say "started pid=$(cat "$PIDFILE") mode=$MODE (log: $LOG)"
  ;;
stop)
  kill_pidfile "$PIDFILE"
  kill_pidfile "$HTTPPID"
  # 收掉可能残留的采样子进程
  pkill -f "$BIN --duration" 2>/dev/null
  say "stopped"
  ;;
status)
  echo "--- imu_agent status ---"
  echo "mode=$MODE  hub=$HUB_URL  http_port=$HTTP_PORT  bin=$BIN"
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
    echo "agent : RUNNING pid=$(cat "$PIDFILE")"
  else echo "agent : STOPPED"; fi
  if [ -f "$HTTPPID" ] && kill -0 "$(cat "$HTTPPID" 2>/dev/null)" 2>/dev/null; then
    echo "httpd : RUNNING pid=$(cat "$HTTPPID")"
  else echo "httpd : STOPPED"; fi
  [ -f "$DIR/last_post" ] && echo "last_post: $(cat "$DIR/last_post")"
  [ -f "$JSON" ] && { echo "latest  : $(head -c 260 "$JSON")"; }
  [ -f "$LOG" ] && { echo "--- log tail ---"; tail -n 8 "$LOG"; }
  ;;
once)
  SEQ=1; mkdir -p "$DIR"; collect_frame; build_json; cat "$JSON"
  ;;
sample)
  SEQ=0; mkdir -p "$DIR"
  while true; do collect_frame; build_json; echo "--- frame $SEQ ---"; cat "$JSON"; SEQ=$((SEQ + 1)); done
  ;;
*)
  echo "Usage: $0 {start [push|serve|both]|stop|status|once|sample}"
  exit 2
  ;;
esac
exit 0
