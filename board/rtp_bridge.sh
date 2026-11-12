#!/bin/sh
# ============================================================
# RTP 桥守护进程: flex RTSP -> 本机 RTP/UDP (5004)
# ============================================================
# 背景: rtspsrc 与 flex RTP 序号不兼容, 必须用 ffmpeg 做桥(见 PROJECT_DOC §5.2)。
#       ffmpeg 在 RTSP 源断开时会直接退出, 所以外面套一层循环自愈。
# 用法: rtp_bridge.sh [源 rtsp] [目标 rtp]
# 部署路径: /usr/local/bin/rtp_bridge.sh
. /etc/profile.d/gstreamer.sh
SRC=${1:-rtsp://127.0.0.1:8554/axstream1}
DST=${2:-rtp://127.0.0.1:5004}
LOG=${LOG:-/tmp/ffmpeg_bridge.log}

while true; do
  /usr/local/bin/ffmpeg -loglevel error -rtsp_transport tcp -i "$SRC" \
    -an -c copy -f rtp "$DST" >> "$LOG" 2>&1
  RC=$?
  echo "[$(date +%H:%M:%S)] ffmpeg exited rc=$RC, restart in 2s" >> "$LOG"
  sleep 2
done
