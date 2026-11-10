#!/bin/sh
# ============================================================
# flex ch1 -> whip_push(WHIP) -> PC 本地 SRS 中转 (192.168.137.1:1985)
# ============================================================
# 适用场景: PC 上跑着 SRS(或 srs_relay.py 中转), 板子经 PC 转发到公网
# 依赖: PC 侧 1985 有服务监听(本地 SRS 或 python srs_relay.py)
# 注意: PC 中转服务停掉时, whip_push 的 HTTP POST 会挂起(无超时), 表现为空推
# 用法: flex_srs_pc.sh [流名, 默认 live1]
# 部署路径: /usr/local/bin/flex_srs_pc.sh
. /etc/profile.d/gstreamer.sh
STREAM=${1:-live1}
URL="http://192.168.137.1:1985/rtc/v1/whip/?app=live&stream=$STREAM&eip=192.168.137.1"
PIPE='udpsrc port=5004 caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" ! rtph264depay ! h264parse ! rtph264pay config-interval=-1 pt=96'
if ! ps | grep -v grep | grep -q 'rtsp://127.0.0.1:8554/ch1'; then
  setsid /usr/local/bin/ffmpeg -loglevel error -rtsp_transport tcp -i rtsp://127.0.0.1:8554/ch1 \
    -an -c copy -f rtp rtp://127.0.0.1:5004 > /tmp/ffmpeg_bridge.log 2>&1 < /dev/null &
  sleep 3
fi
setsid whip_push "$URL" "$PIPE" > /tmp/srs_whip.log 2>&1 < /dev/null &
sleep 15
grep -E 'answer|connection|established|failed|error' /tmp/srs_whip.log | tail -8
tail -2 /tmp/srs_whip.log
