#!/bin/sh
# ============================================================================
# flex_srs.sh - camera channel N: RTSP -> SRS (WHIP for ch0..4, RTMP for ch5)
# ============================================================================
# Usage:
#   flex_srs.sh liveN              # N=0..5: axstreamN -> liveN, one-to-one
#   flex_srs.sh start liveN        # same as above ('start' is a subcommand, not a stream)
#   flex_srs.sh <stream> [channel] # custom stream name / explicit channel 0..5
#   flex_srs.sh stop  [liveN|all] # stop one stream or all (default all)
#   flex_srs.sh status            # show all 6 channels and SRS streams
#   flex_srs.sh test  [stream]    # color-bar self test, no camera / RTSP / RTP bridge
#
# Notes:
#   - The board RTSP server only knows axstream0..axstream5; chN falls back to
#     axstream0, so always use axstreamN. N=5 is the 3x2 multi-grid canvas.
#   - WHIP mode, per stream: UDP port 5200+2*N, own RTP bridge, bridge log,
#     WHIP log and process matching. No shared 5004 port, no global check.
#   - Read OutFps from /proc/ax_proc/venc before starting; refuse a channel
#     that is not producing frames (avoids pushing a black stream).
#   - ch0..4 use WHIP(WebRTC) end to end. ch5 (3x2 grid canvas) defaults to
#     PUSH_MODE=rtmp: ffmpeg feeds SRS directly over RTMP. The WHIP forwarder
#     accepts this low-fps stream into webrtcbin but never sends video RTP to
#     SRS, producing endless fake-connection retries. SRS has rtmp_to_rtc on,
#     so WHEP / HTTP-FLV playback works with the same stream name.
#     Use PUSH_MODE=whip to force the legacy path for debugging.
#   - Kill stale whip_push owners of the UDP port before starting; Ctrl+C only
#     cleans up this run's children, so two udpsrc never fight over one port
#     (the classic "connected but bufs=0" symptom).
# Deployed as: /usr/local/bin/flex_srs.sh
# ============================================================================

# 服务器地址可用环境变量覆盖，换服务器时无需改脚本：
#   SRS_HOST=192.168.1.9 flex_srs.sh live1
SRS_HOST=${SRS_HOST:-121.196.101.253}
SRS_API_PORT=${SRS_API_PORT:-1985}
SRS_RTMP_PORT=${SRS_RTMP_PORT:-1935}
# A bare IPv6 literal must be bracketed inside both HTTP and RTMP URLs,
# e.g. SRS_HOST=240e:... -> http://[240e:...]:1985/... and
# rtmp://[240e:...]:1935/live/... . Host names / IPv4 stay untouched, and
# an already bracketed SRS_HOST=[240e:...] is accepted as-is.
case "$SRS_HOST" in
  \[*\]) : ;;
  *:*)   SRS_HOST="[$SRS_HOST]" ;;
esac
API="http://${SRS_HOST}:${SRS_API_PORT}/api/v1/streams/"
WHIP="http://${SRS_HOST}:${SRS_API_PORT}/rtc/v1/whip/?app=live&stream="

# 运行环境: 优先 source profile.d；再兜底自设(非登录 shell / profile 未生成也能跑)
[ -f /etc/profile.d/gstreamer.sh ] && . /etc/profile.d/gstreamer.sh
export PATH=/usr/local/bin:/usr/bin:/bin:/sbin:/usr/sbin:$PATH
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
[ -f /usr/local/lib/libglibc230_compat.so ] && \
  export LD_PRELOAD=/usr/local/lib/libglibc230_compat.so
export GST_PLUGIN_SYSTEM_PATH=/usr/local/lib/gstreamer-1.0
export GST_PLUGIN_SCANNER=/usr/local/libexec/gstreamer-1.0/gst-plugin-scanner
export GST_REGISTRY=/usr/local/var/gst-registry.bin

# ---------- SRS API: 按流名取指标（BusyBox 无 jq/python，用 grep -oE + awk 配对） ----------
pairs() {
  busybox wget -q -O - "$API" 2>/dev/null |
    grep -oE '"name":"[^"]*"|"recv_bytes":[0-9]*|"publish":\{"active":[a-z]*'
}

get_recv() {  # 当前流的 recv_bytes，取不到返回 0
  V=$(pairs | awk -v want="$STREAM" '
    /^"name":/ { n=$0; sub(/^"name":"/,"",n); sub(/"$/,"",n); hit=(n==want); next }
    hit && /^"recv_bytes":/ { sub(/^"recv_bytes":/,""); print; exit }')
  echo "${V:-0}"
}

publish_state() {  # 当前流是否还有 publish 会话: true / false / 空
  pairs | awk -v want="$STREAM" '
    /^"name":/ { n=$0; sub(/^"name":"/,"",n); sub(/"$/,"",n); hit=(n==want); next }
    hit && /^"publish":/ { sub(/.*active":/,""); print; exit }'
}

wait_release() {  # 旧 whip_push 被杀后 SRS 约需 40s 回收会话
  n=0
  while [ $n -lt 60 ]; do
    if [ "$(publish_state)" != "true" ]; then
      # Extra settle for the low-fps grid stream: SRS keeps the stale RTC
      # transport briefly after publish.active flips to false.
      [ "${SETTLE:-0}" -gt 0 ] && sleep "$SETTLE"
      return 0
    fi
    n=$((n+1))
    # 每 5 秒报一次进度：否则前台看起来像卡死，用户容易 Ctrl+C，反而留下新僵尸
    [ $((n % 5)) -eq 0 ] && echo "  ... 等待 SRS 回收旧会话 ${n}s/60s"
    sleep 1
  done
  return 1
}

chn_fps() {  # $1=通道号，读 VENC OutFps
  sed -n '/VENC STATUS/,/^$/p' /proc/ax_proc/venc 2>/dev/null |
    awk -v n="$1" '$1==n {print $3; exit}'
}

# ---------- 进程定位: 全部按「本流 / 本通道」过滤，绝不误杀其它路 ----------
whip_pids()   { ps w | grep '[w]hip_push'        | grep -v defunct | grep "stream=$1"  | awk '{print $1}'; }
bridge_pids() { ps w | grep '[r]tp_bridge.sh'    | grep -v defunct | grep "axstream$1" | awk '{print $1}'; }
ffmpeg_pids() { ps w | grep '[f]fmpeg -loglevel' | grep -v defunct | grep "axstream$1" | awk '{print $1}'; }

# 占用某 UDP 端口的 whip_push（含异常流名 / Ctrl+C 留下的僵尸）。
# GStreamer udpsrc 默认 reuse=true，两个进程能同时 bind 同一端口并静默抢包，
# 这正是「HTTP 201 + connection established 却 bufs=0 / recv_bytes 不涨」的根因。
port_owners() {
  ps w | grep '[w]hip_push' | grep -v defunct |
    grep "udpsrc port=$1 " | awk '{print $1}'
}

# ffmpeg publisher that pushes one stream straight to SRS over RTMP (ch5).
rtmp_pids() {
  ps w | grep '[f]fmpeg' | grep -v defunct | grep 'rtmp://' |
    grep -E "live/$1([[:space:]]|$)" | awk '{print $1}'
}

cleanup_port() {  # $1=UDP 端口；杀掉全部占用者并等它们真正退出
  PIDS=$(port_owners "$1")
  [ -z "$PIDS" ] && return 0
  echo "CLEANUP_PORT udp=$1 清理僵尸: $(echo $PIDS | tr ' ' ',')"
  for p in $PIDS; do kill "$p" 2>/dev/null; done
  n=0
  while [ $n -lt 10 ] && [ -n "$(port_owners "$1")" ]; do
    sleep 1; n=$((n+1))
  done
  for p in $(port_owners "$1"); do kill -9 "$p" 2>/dev/null; done
  sleep 1
}

wait_whip_gone() {  # $1=流名；kill 是异步的，等进程真正退出再重连
  n=0
  while [ $n -lt 12 ] && [ -n "$(whip_pids "$1")" ]; do
    sleep 1; n=$((n+1))
  done
  for p in $(whip_pids "$1"); do kill -9 "$p" 2>/dev/null; done
}

kill_one() {  # $1=stream name $2=channel number
  for p in $(whip_pids "$1");   do kill "$p" 2>/dev/null; done
  for p in $(bridge_pids "$2"); do kill "$p" 2>/dev/null; done
  for p in $(ffmpeg_pids "$2"); do kill "$p" 2>/dev/null; done
  for p in $(rtmp_pids "$1");   do kill "$p" 2>/dev/null; done
  echo "STOPPED stream=$1 ch=$2"
}

usage() {
  cat <<EOF
Usage: flex_srs.sh [start] liveN | <stream> [channel] | stop [liveN|all] | status | test [stream]
  liveN -> axstreamN -> liveN (N=0..5); 'start' is a subcommand, not a stream name
  ch0..4 use WHIP/WebRTC; ch5 (5-in-1 grid) defaults to RTMP, override PUSH_MODE=whip
EOF
}

# ---------- 参数解析 ----------
CMD=${1:-live1}
case "$CMD" in
  stop)
    TARGET=${2:-all}
    if [ "$TARGET" = "all" ]; then
      for n in 0 1 2 3 4 5; do kill_one "live$n" "$n"; done
      # 兜底: 杀掉所有 whip_push（含异常流名僵尸）、RTP 桥与 ffmpeg。
      # 旧版只按 stream=liveN 过滤，Ctrl+C 留下的 stream=start 会一直占着 UDP 端口。
      for p in $(ps w | grep '[w]hip_push' | grep -v defunct | awk '{print $1}'); do kill "$p" 2>/dev/null; done
      for p in $(ps w | grep '[r]tp_bridge.sh' | grep -v defunct | awk '{print $1}'); do kill "$p" 2>/dev/null; done
      for p in $(ps w | grep '[f]fmpeg -loglevel' | grep -v defunct | awk '{print $1}'); do kill "$p" 2>/dev/null; done
      sleep 2
      echo "CLEANED: 所有推流后台进程"
    else
      S=$TARGET
      C=$(echo "$S" | grep -oE '[0-9]+$' | head -1)
      [ -z "$C" ] && C=1
      kill_one "$S" "$C"
      cleanup_port "$((5200 + C * 2))"
    fi
    exit 0 ;;
  status)
    for n in 0 1 2 3 4 5; do
      W=$(whip_pids "live$n" | tr '\n' ',')
      B=$(bridge_pids "$n"   | tr '\n' ',')
      R=$(rtmp_pids "live$n" | tr '\n' ',')
      F=$(chn_fps "$n")
      echo "live$n <- axstream$n  venc_fps=${F:-?}  whip=[$W] bridge=[$B] rtmp=[$R]"
    done
    echo '--- SRS streams ---'
    busybox wget -q -O - "$API" 2>/dev/null | head -c 1500; echo
    exit 0 ;;
  test|-t|--test)
    TEST=1; shift; STREAM=${1:-test}; CH=1 ;;
  start|run|up)
    # 兼容直觉写法: flex_srs.sh start liveN == flex_srs.sh liveN
    # 旧版把 'start' 当流名、把 live1 当通道号，会推出一个 stream=start 的僵尸流。
    TEST=0; shift; STREAM=${1:-live1}; CH="" ;;
  *)
    TEST=0
    STREAM=$CMD
    CH=""
    [ $# -ge 2 ] && CH=$2
    ;;
esac

# 通道号 = 流名末尾的数字；也允许第二个参数显式指定
if [ "$TEST" != "1" ]; then
  if ! echo "$STREAM" | grep -qE '^[A-Za-z0-9_-]+$'; then
    echo "BAD_STREAM: '$STREAM' 不是合法流名（只允许字母/数字/_/-）"
    echo "  提示: 'start' 是子命令不是流名；写 flex_srs.sh liveN 或 flex_srs.sh start liveN"
    usage
    exit 2
  fi
  case "$CH" in
    ''|[0-5]) ;;
    *) echo "忽略无效通道参数 '$CH'，改用流名末尾数字"; CH="" ;;
  esac
  if [ -z "$CH" ]; then
    CH=$(echo "$STREAM" | grep -oE '[0-9]+$' | head -1)
    [ -z "$CH" ] && CH=1
  fi
  case "$CH" in
    [0-5]) ;;
    *) echo "CHANNEL_OUT_OF_RANGE: '$CH' 不在 0~5，回退到 1"; CH=1 ;;
  esac
fi

# The grid stream is not compatible with the WHIP forwarder (see header).
# Allow an explicit override for debugging / comparison.
if [ -z "${PUSH_MODE:-}" ]; then
  if [ "$TEST" != "1" ] && [ "$CH" = 5 ]; then PUSH_MODE=rtmp; else PUSH_MODE=whip; fi
fi
case "$PUSH_MODE" in
  whip|rtmp) ;;
  *) echo "BAD_PUSH_MODE: '$PUSH_MODE' (whip|rtmp)，回退到 whip"; PUSH_MODE=whip ;;
esac

# The grid canvas (ch5) runs at ~7-13fps / 0.4-0.7Mbps, far below a 2592x1944
# main stream (~2Mbps), so scale its recv_bytes health thresholds down.
# SRS recycles the grid publisher slowly and its VENC emits keyframes sparsely,
# so give cold starts a longer probe window, more tries and a settle delay.
MIN_DELTA=500000
MIN_DELTA_ALIVE=500000
MAX_TRY=8
PROBE_CONNECT=9
PROBE_RECV=6
SETTLE=0
if [ "$CH" = 5 ]; then
  MIN_DELTA=120000
  MIN_DELTA_ALIVE=60000
  MAX_TRY=12
  PROBE_CONNECT=12
  PROBE_RECV=8
  SETTLE=5
fi

SRC="rtsp://127.0.0.1:8554/axstream$CH"
RTP_PORT=$((5200 + CH * 2))
BRIDGE_LOG=/tmp/ffmpeg_bridge_$STREAM.log
WHIP_LOG=/tmp/srs_whip_$STREAM.log
RTMP_LOG=/tmp/rtmp_$STREAM.log
URL="$WHIP$STREAM"
RTMP_URL="rtmp://${SRS_HOST}:${SRS_RTMP_PORT}/live/${STREAM}"

# Ctrl+C / TERM 时只清理「本次拉起」的后台进程，避免误杀已在正常推的流
OWN_PIDS=""
trap 'if [ -n "$OWN_PIDS" ]; then echo "INTERRUPTED: 清理本次拉起的推流进程"; for p in $OWN_PIDS; do kill "$p" 2>/dev/null; done; [ "$TEST" != "1" ] && cleanup_port "$RTP_PORT"; fi; exit 130' INT TERM

# ---------- 环境 / 源检查 ----------
if [ "$TEST" != "1" ]; then
  if ! netstat -lnt 2>/dev/null | grep -q ':8554'; then
    echo "SOURCE_MISSING: 127.0.0.1:8554 无监听 (flex_vision 没起来?)"
    echo "  先执行: /usr/local/bin/flex_start.sh"
    exit 2
  fi
  FPS=$(chn_fps "$CH")
  # The grid VENC OutFps counter is bursty (PTS sync drops whole rounds) and
  # can read 0.00 for an instant. Sample a few times before rejecting.
  if ! awk -v f="$FPS" 'BEGIN{exit !(f+0>0)}'; then
    j=0
    while [ "$j" -lt 3 ]; do
      sleep 1
      F2=$(chn_fps "$CH")
      if awk -v f="$F2" 'BEGIN{exit !(f+0>0)}'; then FPS=$F2; break; fi
      j=$((j + 1))
    done
  fi
  if ! awk -v f="$FPS" 'BEGIN{exit !(f+0>0)}'; then
    echo "SOURCE_NO_FRAMES: axstream$CH 当前没有编码帧 (VENC OutFps=${FPS:-0})"
    echo "  该路传感器未出图，推上去也是黑流。先修摄像头，或换一路有帧的 liveN："
    for n in 0 1 2 3 4 5; do
      F=$(chn_fps "$n")
      awk -v f="$F" -v n="$n" 'BEGIN{if(f+0>0) printf "    live%s (OutFps=%s)\n",n,f}'
    done
    exit 2
  fi
fi

# ---------- RTMP mode (ch5 grid): RTSP -> SRS directly ----------
# The WHIP forwarder silently buffers this stream in webrtcbin and never
# sends video RTP, so feed SRS over RTMP instead. rtmp_to_rtc on keeps
# WHEP / HTTP-FLV playback working with the same stream name.
if [ "$TEST" != "1" ] && [ "$PUSH_MODE" = "rtmp" ]; then
  # Idempotence: leave a healthy publisher untouched.
  if [ -n "$(rtmp_pids "$STREAM")" ]; then
    B1=$(get_recv)
    sleep 8
    B2=$(get_recv)
    DELTA8=$((B2 - B1))
    if [ "$DELTA8" -gt "$MIN_DELTA_ALIVE" ]; then
      echo "ALREADY_PUSHING stream=$STREAM mode=rtmp recv_8s=$DELTA8 bytes (未打断现有流)"
      exit 0
    fi
    echo "RTMP ffmpeg 在跑但本流无码流 (8s 增量=$DELTA8)，重建"
    for p in $(rtmp_pids "$STREAM"); do kill "$p" 2>/dev/null; done
    sleep 2
  fi

  # A leftover RTP bridge for this channel is useless in RTMP mode; stop
  # the parent first so its restart loop cannot respawn ffmpeg.
  for p in $(bridge_pids "$CH"); do kill "$p" 2>/dev/null; done
  sleep 1
  for p in $(ffmpeg_pids "$CH"); do kill "$p" 2>/dev/null; done

  if [ "$(publish_state)" = "true" ]; then
    echo "WAIT_RELEASE: SRS 仍在回收 stream=$STREAM 的旧 publish 会话（最多 60s）..."
    wait_release || echo "WARN: SRS 60s 内未释放会话，仍继续尝试"
  fi

  : > "$RTMP_LOG"
  setsid /usr/local/bin/ffmpeg -loglevel warning -rtsp_transport tcp -i "$SRC" \
    -an -c copy -f flv "$RTMP_URL" >> "$RTMP_LOG" 2>&1 < /dev/null &
  OWN_PIDS="$OWN_PIDS $!"

  BASE=$(get_recv)
  i=0
  while [ "$i" -lt 10 ]; do
    sleep 5
    B=$(get_recv)
    DELTA=$((B - BASE))
    if [ "$DELTA" -gt "$MIN_DELTA" ]; then
      echo "PUSH_OK stream=$STREAM ch=$CH mode=rtmp src=$SRC recv_delta_KB=$((DELTA/1024))"
      exit 0
    fi
    if [ -z "$(rtmp_pids "$STREAM")" ]; then
      echo "RTMP_EXITED: 日志 $RTMP_LOG"
      tail -5 "$RTMP_LOG" 2>/dev/null
      exit 2
    fi
    i=$((i + 1))
  done
  echo "PUSH_FAIL stream=$STREAM mode=rtmp (50s 内无码流)"
  tail -5 "$RTMP_LOG" 2>/dev/null
  exit 1
fi

if [ "$TEST" = "1" ]; then
  PIPE='videotestsrc is-live=true pattern=smpte ! video/x-raw,width=1280,height=720,framerate=30/1 ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=2000 key-int-max=30 ! rtph264pay config-interval=-1 pt=96'
else
  PIPE="udpsrc port=$RTP_PORT buffer-size=4194304 caps=\"application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96\" ! rtph264depay ! h264parse ! rtph264pay config-interval=-1 pt=96"
fi

# ---------- RTP 桥: 每路一个，独立日志与端口 ----------
# RTMP mode reads RTSP directly; no RTP bridge / UDP port is needed.
if [ "$TEST" != "1" ] && [ "$PUSH_MODE" = "whip" ]; then
  if [ -z "$(bridge_pids "$CH")" ]; then
    : > "$BRIDGE_LOG"
    LOG="$BRIDGE_LOG" setsid /usr/local/bin/rtp_bridge.sh "$SRC" \
      "rtp://127.0.0.1:$RTP_PORT" > /dev/null 2>&1 < /dev/null &
    sleep 3
    if [ -z "$(bridge_pids "$CH")" ]; then
      echo "BRIDGE_FAILED: $BRIDGE_LOG"
      tail -3 "$BRIDGE_LOG" 2>/dev/null
      exit 2
    fi
  fi
fi

# ---------- 本流已在推: 只按本流判断，健康就零中断沿用 ----------
if [ -n "$(whip_pids "$STREAM")" ]; then
  B1=$(get_recv)
  sleep 8
  B2=$(get_recv)
  DELTA8=$((B2 - B1))
  if [ "$DELTA8" -gt "$MIN_DELTA_ALIVE" ]; then
    echo "ALREADY_PUSHING stream=$STREAM ch=$CH recv_8s=$DELTA8 bytes (未打断现有流)"
    exit 0
  fi
  echo "whip_push 在跑但本流无码流 (8s 增量=$DELTA8)，重建会话"
  for p in $(whip_pids "$STREAM"); do kill "$p" 2>/dev/null; done
  wait_whip_gone "$STREAM"
  wait_release || echo "WARN: SRS 60s 内未释放会话，仍继续尝试"
fi

# ---------- 冷启动前: 先确认 SRS 上没有残留的 publish 会话 ----------
# 上一轮 Ctrl+C / kill 后，SRS 约需 40s 才回收 publisher；这段时间内直接 POST
# WHIP 会被拒（whip_push 报 "HTTP 0"），白等一轮 9 秒才进重试。先等回收，
# 让「中断后立刻重跑」也能首轮成功。
if [ "$(publish_state)" = "true" ]; then
  echo "WAIT_RELEASE: SRS 仍在回收 stream=$STREAM 的旧 publish 会话（最多 60s，会自动继续，请勿 Ctrl+C）..."
  wait_release || echo "WARN: SRS 60s 内未释放会话，仍继续尝试"
fi

# ---------- 冷启动: 每次尝试都用本流 recv_bytes 增量校验真实流入 ----------
i=0
while [ $i -lt "$MAX_TRY" ]; do
  # 每次尝试前清端口：绝不让两个 udpsrc 共用同一个 UDP 端口
  [ "$TEST" != "1" ] && cleanup_port "$RTP_PORT"
  BASE=$(get_recv)
  : > "$WHIP_LOG"
  setsid whip_push "$URL" "$PIPE" > "$WHIP_LOG" 2>&1 < /dev/null &
  OWN_PIDS="$OWN_PIDS $!"
  sleep "$PROBE_CONNECT"
  if ! grep -q 'connection established' "$WHIP_LOG"; then
    echo "try=$i not-connected ($(grep -E 'HTTP [0-9]+' "$WHIP_LOG" | head -1))"
    for p in $(whip_pids "$STREAM"); do kill "$p" 2>/dev/null; done
    wait_whip_gone "$STREAM"
    wait_release
    i=$((i+1)); continue
  fi
  sleep "$PROBE_RECV"
  B=$(get_recv)
  DELTA=$((B - BASE))
  if [ "$DELTA" -gt "$MIN_DELTA" ]; then
    echo "PUSH_OK stream=$STREAM ch=$CH src=$SRC rtp_port=$RTP_PORT recv_delta_KB=$((DELTA/1024))"
    [ "$TEST" = "1" ] && echo "TEST_OK: 彩条链路正常，问题应在码流源(flex/RTP桥)"
    exit 0
  fi
  echo "try=$i fake-connection (delta_bytes=$DELTA), retrying..."
  echo "  诊断: udp=$RTP_PORT 占用者=[$(port_owners "$RTP_PORT" | tr '\n' ',')] bridge=[$(bridge_pids "$CH" | tr '\n' ',')] $(grep -oE 'bufs=[0-9]+' "$WHIP_LOG" | tail -1)"
  for p in $(whip_pids "$STREAM"); do kill "$p" 2>/dev/null; done
  wait_whip_gone "$STREAM"
  wait_release
  i=$((i+1))
done
echo "PUSH_FAIL stream=$STREAM ch=$CH"
[ "$TEST" != "1" ] && tail -3 "$BRIDGE_LOG" 2>/dev/null
tail -3 "$WHIP_LOG" 2>/dev/null
exit 1
