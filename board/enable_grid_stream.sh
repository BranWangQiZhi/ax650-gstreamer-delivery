#!/bin/sh
# ============================================================================
# enable_grid_stream.sh - turn the 5-in-1 stitched stream axstream5 on/off
# ============================================================================
# Deployed as: /usr/local/bin/enable_grid_stream.sh   (chmod 755)
#
# Usage:
#   enable_grid_stream.sh enable    set enable=1 in ini and restart flex_vision (default)
#   enable_grid_stream.sh disable   set enable=0 and restart (rollback)
#   enable_grid_stream.sh status    read-only health check, changes nothing
#
# Environment variables:
#   INI=/path/to/xxx.ini  config path (default /opt/etc/cfg_og05b10_5cam_2lan.ini)
#   NO_RESTART=1          edit ini only; effective after next boot or manual flex_start.sh
#   NO_RESTORE=1          do not restore the previously active liveN WHIP streams
#
# Background: in SDK front_ppl each of the N cameras occupies VENC[0..N-1]
#             -> axstream0..N-1; the grid canvas takes one extra VENC[N]
#             -> axstreamN, which is axstream5 for 5 cameras.
#             Only "enable" is parsed from this section; encoder settings come
#             from [Encode] and are shared by all VENC channels.
#
# Side effect: restarting flex_vision interrupts the running WHIP streams for
#              ~20-40s. The script backs up the ini, stops the streams, restarts
#              and verifies 8554 / axstream5, then brings liveN back as before.
# ============================================================================

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin:/soc/scripts
export PATH

# Non-interactive SSH does not source /etc/profile; restore the GStreamer
# runtime env so flex_start.sh / flex_srs.sh children inherit LD_* / GST_*.
[ -f /etc/profile.d/gstreamer.sh ] && . /etc/profile.d/gstreamer.sh

INI=${INI:-/opt/etc/cfg_og05b10_5cam_2lan.ini}
FV_LOG=/tmp/flex_vision.log
ACTION=${1:-enable}

say()  { echo "[grid] $*"; }
fail() { echo "[grid] ERROR: $*" >&2; exit 1; }

[ -f "$INI" ] || fail "找不到 ini: $INI"

# Read-only: fetch enable from [multiGrideDisplay] only (never [sensorN] enable).
read_enable() {
  awk '
    /^[ \t]*\[/ { insec = ($0 ~ /^[ \t]*\[multiGrideDisplay\]/) }
    insec && /^[ \t]*enable[ \t]*=/ {
      v = $0
      sub(/^[ \t]*enable[ \t]*=[ \t]*/, "", v)
      sub(/[ \t;].*$/, "", v)
      print v; exit
    }
  ' "$INI"
}

# Targeted replacement: change only enable in [multiGrideDisplay], keeping
# the trailing comment on that line and the original file permissions.
write_enable() {
  val=$1
  tmp=${INI}.tmp.$$
  awk -v val="$val" '
    /^[ \t]*\[/ { insec = ($0 ~ /^[ \t]*\[multiGrideDisplay\]/) }
    insec && /^[ \t]*enable[ \t]*=/ {
      line = $0
      sub(/^[ \t]*enable[ \t]*=[ \t]*[0-9]+/, "enable = " val, line)
      print line; found = 1; next
    }
    { print }
    END { if (!found) exit 3 }
  ' "$INI" > "$tmp" || { rm -f "$tmp"; return 1; }
  cat "$tmp" > "$INI" || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  return 0
}

flex_pid() {
  ps -o pid,args 2>/dev/null | grep '[f]lex_vision -p' | awk '{print $1; exit}'
}

# RTSP DESCRIBE check: has axstream5 actually registered a media track?
grid_probe() {
  if ! command -v nc >/dev/null 2>&1; then
    echo "  axstream5  : SKIP（板端无 nc，请在 PC 侧验证）"
    return 2
  fi
  resp=$(printf 'DESCRIBE rtsp://127.0.0.1:8554/axstream5 RTSP/1.0\r\nCSeq: 1\r\nAccept: application/sdp\r\n\r\n' \
         | nc -w 2 127.0.0.1 8554 2>/dev/null)
  if [ -z "$resp" ]; then
    echo "  axstream5  : UNKNOWN（RTSP 未响应，稍后重跑 status）"
    return 2
  fi
  if echo "$resp" | grep -q 'm=video'; then
    echo "  axstream5  : OK（SDP 含 m=video，拼接流已注册）"
    return 0
  fi
  echo "  axstream5  : MISSING（SDP 无 m=video：grid 未启用或 flex_vision 未重启）"
  return 1
}

show_status() {
  say "ini          : $INI"
  say "grid enable  : $(read_enable)"
  pid=$(flex_pid)
  if [ -n "$pid" ]; then
    say "flex_vision  : running (pid $pid)"
  else
    say "flex_vision  : STOPPED"
  fi
  if netstat -lnt 2>/dev/null | grep ':8554' >/dev/null; then
    say "RTSP 8554    : listening"
  else
    say "RTSP 8554    : not listening"
  fi
  if [ -f "$FV_LOG" ]; then
    grep -E '\[multiGrideDisplay\]|ivps-merge config' "$FV_LOG" 2>/dev/null \
      | tail -3 | sed 's/^/  log: /'
  fi
  grid_probe
}

# Active liveN streams (whip_push URL contains stream=liveN).
active_streams() {
  ps w 2>/dev/null | grep '[w]hip_push' | grep -o 'stream=live[0-4]' \
    | sed 's/^stream=//' | sort -u
}

restart_flex() {
  say "停止现有推流进程（避免重启后残留僵尸占 UDP 端口）..."
  if command -v flex_srs.sh >/dev/null 2>&1; then
    flex_srs.sh stop >/dev/null 2>&1
  fi

  pid=$(flex_pid)
  if [ -n "$pid" ]; then
    say "停止 flex_vision (pid $pid)..."
    kill "$pid" 2>/dev/null
    i=0
    while [ "$i" -lt 15 ] && kill -0 "$pid" 2>/dev/null; do
      sleep 1
      i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null
      say "flex_vision 未优雅退出，已 kill -9"
    fi
  fi
  # Wait until the 8554 listener is really released; otherwise flex_start.sh
  # may mistake the stale port for a newly started process.
  i=0
  while [ "$i" -lt 10 ] && netstat -lnt 2>/dev/null | grep -q ':8554'; do
    sleep 1
    i=$((i + 1))
  done
  if netstat -lnt 2>/dev/null | grep -q ':8554'; then
    fail "8554 仍被占用，旧 flex_vision 未退干净；请检查进程后重试"
  fi
  # A just-exited process may still show up as a zombie; as long as 8554 is
  # free we proceed instead of failing on a stale ps entry.
  i=0
  while [ "$i" -lt 5 ] && [ -n "$(flex_pid)" ]; do
    sleep 1
    i=$((i + 1))
  done
  [ -n "$(flex_pid)" ] && say "警告：仍有残留进程记录 ($(flex_pid))，但 8554 已释放，继续启动"

  command -v flex_start.sh >/dev/null 2>&1 \
    || fail "找不到 flex_start.sh，请先部署 board/flex_start.sh"
  say "重新启动 flex_vision（PWM 前置 + 等 8554 就绪，最多 30s）..."
  if ! flex_start.sh "$INI"; then
    grep -iE 'ERROR|fail' "$FV_LOG" 2>/dev/null | head -5
    fail "flex_vision 启动失败；ini 备份在 ${INI}.bak_grid_*，可改回后重跑 disable"
  fi
  sleep 2
}

case "$ACTION" in
  status)
    show_status
    exit 0 ;;
  enable|disable)
    if [ "$ACTION" = enable ]; then WANT=1; else WANT=0; fi ;;
  *)
    echo "用法: $0 {enable|disable|status}" >&2
    exit 2 ;;
esac

CUR=$(read_enable)
if [ "$CUR" = "$WANT" ]; then
  say "ini 已是 enable=$WANT，无需修改"
else
  BAK="${INI}.bak_grid_$(date +%Y%m%d_%H%M%S)"
  cp "$INI" "$BAK" || fail "备份 ini 失败"
  say "已备份 ini -> $BAK"
  write_enable "$WANT" \
    || fail "写入 enable=$WANT 失败（ini 中未找到 [multiGrideDisplay] 段的 enable 行）"
  say "ini: enable $CUR -> $(read_enable)"
fi

if [ "${NO_RESTART:-0}" = 1 ]; then
  say "NO_RESTART=1：只改配置。下次开机或手动执行 flex_start.sh 后生效"
  exit 0
fi

say "注意：接下来重启 flex_vision，当前 WHIP 推流会中断约 20~40 秒"
STREAMS=$(active_streams)
[ -n "$STREAMS" ] && say "检测到在推的流: $(echo "$STREAMS" | tr '\n' ' ')（重启后自动恢复）"

restart_flex

say "--- 验证 ---"
show_status

if [ "${NO_RESTORE:-0}" != 1 ] && [ -n "$STREAMS" ]; then
  say "恢复原有推流..."
  for s in $STREAMS; do
    say "  启动 $s"
    setsid flex_srs.sh "$s" >/dev/null 2>&1 </dev/null &
    sleep 3
  done
  say "推流已拉起，可用 flex_srs.sh status 查看"
fi

say "完成。拼接流地址: rtsp://<板IP>:8554/axstream5（3 列 x 2 行，2880x1440@30fps）"
say "PC 侧预览: ffplay -rtsp_transport tcp rtsp://<板IP>:8554/axstream5"
