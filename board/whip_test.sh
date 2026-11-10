#!/bin/sh
# ============================================================
# AX650 GStreamer WebRTC 彩条自测推流（不依赖摄像头/RTSP）
# ============================================================
# 用途: 验证 GStreamer 环境 + whip_push + 信令是否完好（排除码流源问题）
# 用法:
#   whip_test.sh                          # 默认推彩条 720p 到 mediamtx
#   whip_test.sh <whip_url> "<pipeline>"  # 自定义
# 部署路径: /usr/local/bin/whip_test.sh
URL="${1:-https://192.168.137.1:8889/live/whip}"
PIPE="${2:-videotestsrc is-live=true pattern=smpte ! video/x-raw,width=1280,height=720,framerate=30/1 ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=2000 key-int-max=30 ! rtph264pay config-interval=-1 pt=96}"
export PATH=/usr/local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
export LD_PRELOAD=/usr/local/lib/libglibc230_compat.so
export GST_PLUGIN_SYSTEM_PATH=/usr/local/lib/gstreamer-1.0
export GST_PLUGIN_SCANNER=/usr/local/libexec/gstreamer-1.0/gst-plugin-scanner
export GST_REGISTRY=/usr/local/var/gst-registry.bin
echo "URL: $URL"
echo "PIPE: $PIPE"
exec whip_push "$URL" "$PIPE"
