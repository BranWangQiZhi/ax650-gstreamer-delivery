#!/bin/sh
# ============================================================
# flex_vision RTSP -> WebRTC(WHIP) 转发（局域网 mediamtx 场景）
# ============================================================
# 链路: flex RTSP --ffmpeg 桥(rtspsrc 不兼容 flex RTP 序号)--> 本机 UDP 5004
#       --> whip_push --> mediamtx WHIP (https://<pc>:8889/live2/whip)
# 用法: flex_whip.sh [通道ch0/ch1/ch3/ch4] [whip_url]
# 部署路径: /usr/local/bin/flex_whip.sh
CH="${1:-ch1}"
URL="${2:-https://192.168.137.1:8889/live2/whip}"

# 1) ffmpeg 桥: flex RTSP(TCP) -> 本机 RTP/UDP 5004
export LD_LIBRARY_PATH=/usr/local/lib:/usr/lib PATH=/usr/local/bin:/bin:/usr/bin
ffmpeg -loglevel error -rtsp_transport tcp -i rtsp://127.0.0.1:8554/$CH -an -c copy -f rtp rtp://127.0.0.1:5004 &
BRIDGE=$!
sleep 2

# 2) whip_push: RTP/UDP -> WebRTC (需要 /soc/lib: AX 硬件库)
export LD_LIBRARY_PATH=/soc/lib:/usr/local/lib LD_PRELOAD=/usr/local/lib/libglibc230_compat.so \
  GST_PLUGIN_SYSTEM_PATH=/usr/local/lib/gstreamer-1.0 \
  GST_PLUGIN_SCANNER=/usr/local/libexec/gstreamer-1.0/gst-plugin-scanner \
  GST_REGISTRY=/usr/local/var/gst-registry.bin PATH=/usr/local/bin:/bin:/usr/bin
whip_push "$URL" "udpsrc port=5004 caps=\"application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96\" ! rtph264depay ! h264parse ! rtph264pay config-interval=-1 pt=96"
kill $BRIDGE 2>/dev/null
