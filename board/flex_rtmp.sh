#!/bin/sh
# ============================================================
# flex ch1 -> ffmpeg RTMP(TCP,可靠) -> 阿里云 SRS -> 自动转 WebRTC/FLV/RTMP
# ============================================================
# 适用场景: 需要原画质高码率(4~8Mbps)推公网时使用
# 原因: 公网 UDP(WHIP) 丢包会打碎大分辨率 IDR, SRS 的 RTC->RTMP 桥组不出关键帧;
#       RTMP 走 TCP 无此问题, SRS 配置 rtmp_to_rtc=on 后 WebRTC 播放不受影响
# 代价: 延迟比 WHIP 高约 1 秒
# 用法: flex_rtmp.sh [流名, 默认 live1]
# 部署路径: /usr/local/bin/flex_rtmp.sh
export PATH=/usr/local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
STREAM=${1:-live1}
kill $(ps | grep whip_push | grep -v grep | awk '{print $1}') 2>/dev/null
if ! ps | grep -v grep | grep -q 'rtsp://127.0.0.1:8554/ch1.*flv'; then
  kill $(ps | grep 'rtsp://127.0.0.1:8554/ch1' | grep -v grep | awk '{print $1}') 2>/dev/null
  sleep 2
  setsid ffmpeg -loglevel warning -rtsp_transport tcp -i rtsp://127.0.0.1:8554/ch1 \
    -c copy -f flv "rtmp://121.40.107.62:1935/live/$STREAM" > /tmp/rtmp_push.log 2>&1 < /dev/null &
fi
sleep 3
ps | grep -E 'ffmpeg|whip_push' | grep -v grep
tail -2 /tmp/rtmp_push.log
