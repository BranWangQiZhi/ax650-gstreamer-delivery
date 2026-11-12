#!/bin/sh
# ============================================================
# RTMP 桥守护: flex RTSP chN -> SRS RTMP（每路一个独立进程）
# ============================================================
# 与 rtp_bridge.sh 的区别: 不走本机 UDP/5004 + whip_push，直接把 H.264
# 原样封成 FLV 推到 SRS 1935。SRS 配了 rtmp_to_rtc on / http_remux，
# 所以 WHEP(WebRTC) 和 HTTP-FLV 播放页都能拉到这一路。
#
# 为什么多路要用 RTMP: whip_push 把 rtph264pay 的 SSRC 硬编码成 1111111，
# 多个实例同时 WHIP 会出现「publish.active=true 但 recv_bytes≈0」的假连接；
# RTMP 每路一条独立 TCP 连接，天然不冲突，也不需要 UDP 端口规划。
#
# 用法: rtmp_bridge.sh <rtsp源> <rtmp目标> [日志]
# 部署路径: /usr/local/bin/rtmp_bridge.sh
# ============================================================
[ -f /etc/profile.d/gstreamer.sh ] && . /etc/profile.d/gstreamer.sh
export PATH=/usr/local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
[ -f /usr/local/lib/libglibc230_compat.so ] && \
  export LD_PRELOAD=/usr/local/lib/libglibc230_compat.so

SRC=${1:-rtsp://127.0.0.1:8554/ch1}
DST=${2:-rtmp://121.40.107.62:1935/live/live1}
LOG=${3:-/tmp/rtmp_bridge.log}

while true; do
  /usr/local/bin/ffmpeg -loglevel error -rtsp_transport tcp -i "$SRC" \
    -an -c copy -f flv "$DST" >> "$LOG" 2>&1
  RC=$?
  echo "[$(date +%H:%M:%S)] ffmpeg exited rc=$RC, restart in 2s" >> "$LOG"
  sleep 2
done
