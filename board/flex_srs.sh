#!/bin/sh
# flex ch1 -> ffmpeg RTP 桥 -> whip_push (WHIP/UDP) -> 阿里云 SRS
# 成功标准: connection established 且 SRS recv_bytes 相对本次推流的基线真实增长
#          (防"假连接空推": 会话 active 但一个 RTP 包都没进去)
# 用法: flex_srs.sh [流名, 默认 live1]
# 部署路径: /usr/local/bin/flex_srs.sh
. /etc/profile.d/gstreamer.sh
STREAM=${1:-live1}
API="http://121.40.107.62:1985/api/v1/streams/"
URL="http://121.40.107.62:1985/rtc/v1/whip/?app=live&stream=$STREAM"
SRC="rtsp://127.0.0.1:8554/ch1"
BRIDGE_LOG=/tmp/ffmpeg_bridge.log
WHIP_LOG=/tmp/srs_whip.log
PIPE='udpsrc port=5004 buffer-size=4194304 caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96" ! rtph264depay ! h264parse ! rtph264pay config-interval=-1 pt=96'

# 取 SRS 当前 recv_bytes(纯数字, 取不到输出 0)
get_recv() {
  V=$(busybox wget -q -O - "$API" 2>/dev/null | tr ',' '\n' | grep recv_bytes | head -1 | tr -dc '0-9')
  echo "${V:-0}"
}

# SRS 上是否还有 publish 会话占着该 stream。旧 whip_push 被杀后 SRS 约需 40s 才回收,
# 期间新 WHIP POST 会被拒(whip_push 打印 "HTTP 0")。
publish_active() {
  busybox wget -q -O - "$API" 2>/dev/null | tr -d ' \n' | grep -c '"publish":{"active":true'
}

wait_publish_released() {
  n=0
  while [ $n -lt 60 ]; do
    [ "$(publish_active)" = "0" ] && return 0
    sleep 1
    n=$((n+1))
  done
  return 1
}

bridge_alive() {
  ps | grep -v grep | grep -q 'rtp_bridge.sh'
}

kill_whip() {
  kill $(ps | grep whip_push | grep -v grep | awk '{print $1}') 2>/dev/null
}

# RTP 桥: 独立守护脚本(rtp_bridge.sh 内部自带重连循环)
start_bridge() {
  : > "$BRIDGE_LOG"
  setsid /usr/local/bin/rtp_bridge.sh "$SRC" rtp://127.0.0.1:5004 \
    > /dev/null 2>&1 < /dev/null &
  sleep 3
}

kb_since() {  # $1=起始字节, 输出最近这段的近似 kbps
  B1=$1
  sleep 8
  B2=$(get_recv)
  echo $(( (B2 - B1) * 8 / 8 / 1000 )) $B2
}

# 0) 源检查: 8554 没监听时 ffmpeg 会瞬间退出, 直接报清楚原因, 不要傻等
if ! netstat -lnt 2>/dev/null | grep -q ':8554'; then
  echo "SOURCE_MISSING: 127.0.0.1:8554 无监听 (flex_vision 没起来?)"
  echo "  先执行: /usr/local/bin/flex_start.sh"
  exit 2
fi

# 1) 先保证 RTP 桥活着(源曾断过 / 板子重启后, 桥走的是重启循环)
if ! bridge_alive; then
  if [ -s "$BRIDGE_LOG" ] && tail -5 "$BRIDGE_LOG" | grep -q 'Connection refused'; then
    echo "SOURCE_NOT_READY: 8554 在监听但 ch1 被拒, 检查 flex_vision 是否真的编码出流"
  fi
  start_bridge
fi

# 2) whip_push 还在跑: 只要码流恢复就沿用原会话(零中断), 不重启
if ps | grep -v grep | grep -q whip_push; then
  set -- $(kb_since "$(get_recv)")
  if [ "$1" -gt 500 ]; then
    echo "ALREADY_PUSHING kbps≈$1 recv_MB=$(( $2 / 1048576 ))"
    exit 0
  fi
  echo "whip_push 在跑但码流为 0, 需要重建会话"
  kill_whip
  wait_publish_released || echo "WARN: SRS 60s 内未释放会话, 仍继续尝试"
fi

# 3) 冷启动推流(每次尝试都基于新的基线校验真实流入)
i=0
while [ $i -lt 8 ]; do
  BASE=$(get_recv)
  setsid whip_push "$URL" "$PIPE" > "$WHIP_LOG" 2>&1 < /dev/null &
  sleep 9
  if ! grep -q 'connection established' "$WHIP_LOG"; then
    echo "try=$i not-connected ($(grep -E 'HTTP [0-9]+' "$WHIP_LOG" | head -1))"
    kill_whip
    wait_publish_released
    i=$((i+1)); continue
  fi
  sleep 6
  B=$(get_recv)
  DELTA=$((B - BASE))
  if [ "$DELTA" -gt 500000 ]; then
    echo "PUSH_OK try=$i recv_delta_MB=$((DELTA/1048576)) recv_total_MB=$((B/1048576))"
    exit 0
  fi
  echo "try=$i fake-connection (delta_bytes=$DELTA), retrying..."
  kill_whip
  wait_publish_released
  i=$((i+1))
done
echo "PUSH_FAIL"
[ -s "$BRIDGE_LOG" ] && tail -3 "$BRIDGE_LOG"
tail -3 "$WHIP_LOG" 2>/dev/null
