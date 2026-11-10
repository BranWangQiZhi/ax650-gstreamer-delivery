#!/bin/sh
# flex ch1 -> ffmpeg RTP 桥 -> whip_push (WHIP/UDP) -> 阿里云 SRS
# 成功标准: connection established 且 SRS recv_bytes 真实增长(防"假连接空推")
. /etc/profile.d/gstreamer.sh
STREAM=${1:-live1}
API="http://121.40.107.62:1985/api/v1/streams/"
URL="http://121.40.107.62:1985/rtc/v1/whip/?app=live&stream=$STREAM"
PIPE='udpsrc port=5004 buffer-size=4194304 caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" ! rtph264depay ! h264parse ! rtph264pay config-interval=-1 pt=96'

# 取 SRS 当前 recv_bytes(纯数字, 空则输出 0)
get_recv() {
  busybox wget -q -O - "$API" 2>/dev/null \
    | tr ',' '\n' | grep recv_bytes | head -1 | tr -dc '0-9'
  echo 0
}

# 1) RTP 桥（缺了就起）
if ! ps | grep -v grep | grep -q 'rtsp://127.0.0.1:8554/ch1'; then
  setsid /usr/local/bin/ffmpeg -loglevel error -rtsp_transport tcp -i rtsp://127.0.0.1:8554/ch1 \
    -an -c copy -f rtp rtp://127.0.0.1:5004 > /tmp/ffmpeg_bridge.log 2>&1 < /dev/null &
  sleep 3
fi

# 2) WHIP 推流（重试 + SRS 侧媒体验证）
i=0
while [ $i -lt 8 ]; do
  kill $(ps | grep whip_push | grep -v grep | awk '{print $1}') 2>/dev/null
  sleep 1
  setsid whip_push "$URL" "$PIPE" > /tmp/srs_whip.log 2>&1 < /dev/null &
  sleep 9
  if ! grep -q 'connection established' /tmp/srs_whip.log; then
    echo "try=$i not-connected"
    i=$((i+1)); continue
  fi
  # 连接已建立, 再等 6 秒后查 SRS 是否真的收到 RTP
  sleep 6
  B=$(get_recv)
  if [ -n "$B" ] && [ "$B" -gt 100000 ]; then
    echo "PUSH_OK try=$i recv_MB=$((B/1048576))"
    exit 0
  fi
  echo "try=$i fake-connection (recv_bytes=$B), retrying..."
  i=$((i+1))
done
echo "PUSH_FAIL"
tail -3 /tmp/srs_whip.log
