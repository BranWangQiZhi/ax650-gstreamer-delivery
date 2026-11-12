#!/bin/sh
# ============================================================
# flex_multi.sh - 多路摄像头 -> 多个 SRS 流（RTMP 直推）
# ============================================================
# 背景: flex_srs.sh 的参数是「SRS 流名」，不是摄像头通道，源固定 ch1；
#       且只要检测到任意 whip_push 在跑就返回 ALREADY_PUSHING 直接退出。
#       所以 `flex_srs.sh live0/live2/...` 根本不会创建新流，播放页必然黑屏
#       （SRS 上只有 WHEP 播放器建的空流: publish.active=false, video=null）。
#
# 映射: rtsp://127.0.0.1:8554/chN -> rtmp://121.40.107.62:1935/live/liveN
#   ch0 -> live0, ch1 -> live1, ch2 -> live2, ch3 -> live3, ch4 -> live4
# 每路由 rtmp_bridge.sh 守护（断线自动重连），互不干扰。
# live1 默认由 flex_srs.sh 用 WHIP 推（低延迟），本脚本默认只补 0/2/3/4；
# 若某流已有 publisher（whip_push 或 ffmpeg），自动跳过，不打断。
#
# 用法:
#   flex_multi.sh start            # 补齐 ch0/2/3/4（默认）
#   flex_multi.sh start 3          # 只起 ch3 -> live3
#   flex_multi.sh start 0 1 2 3 4  # 指定全部（live1 已推则跳过）
#   flex_multi.sh stop             # 停掉本脚本起的默认 4 路
#   flex_multi.sh stop 3           # 只停 ch3
#   flex_multi.sh status           # 查看每路进程与 SRS 流状态
#
# 部署路径: /usr/local/bin/flex_multi.sh（依赖 rtmp_bridge.sh）
# ============================================================
SRS_API=http://121.40.107.62:1985/api/v1/streams/
RTMP_BASE=rtmp://121.40.107.62:1935/live/
ALL="0 2 3 4"
CMD=${1:-status}
shift 2>/dev/null
CHS=${*:-$ALL}

[ -f /etc/profile.d/gstreamer.sh ] && . /etc/profile.d/gstreamer.sh
export PATH=/usr/local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
[ -f /usr/local/lib/libglibc230_compat.so ] && \
  export LD_PRELOAD=/usr/local/lib/libglibc230_compat.so

pub_running() {  # $1=通道号；用 [x] 技巧避免 grep 匹配自身 / 远端 shell
  ps | grep '[w]hip_push' | grep -q "stream=live$1" && return 0
  ps | grep '[f]fmpeg -loglevel' | grep -q "live$1" && return 0
  return 1
}

start_one() {
  n=$1
  stream=live$n
  src="rtsp://127.0.0.1:8554/ch$n"
  dst="$RTMP_BASE$stream"
  log=/tmp/rtmp_ch$n.log

  if pub_running "$n"; then
    echo "ch$n -> $stream: ALREADY (已有 publisher，跳过，不打断)"
    return 0
  fi
  if ! netstat -lnt 2>/dev/null | grep -q ':8554'; then
    echo "ch$n -> $stream: SOURCE_MISSING (8554 未监听，先跑 flex_start.sh)"
    return 1
  fi
  : > "$log"
  setsid /usr/local/bin/rtmp_bridge.sh "$src" "$dst" "$log" \
    > /dev/null 2>&1 < /dev/null &
  echo "ch$n -> $stream: STARTED (log=$log)"
}

stop_one() {
  n=$1
  stream=live$n
  # 只杀这一路：守护脚本 + 它派生的 ffmpeg（绝不 pkill -f）
  for p in $(ps | grep '[r]tmp_bridge.sh' | grep "ch$n" | awk '{print $1}'); do
    kill "$p" 2>/dev/null
  done
  for p in $(ps | grep '[f]fmpeg -loglevel' | grep "live$n" | awk '{print $1}'); do
    kill "$p" 2>/dev/null
  done
  echo "ch$n -> $stream: STOPPED"
}

status_one() {
  n=$1
  stream=live$n
  b=$(ps | grep '[r]tmp_bridge.sh' | grep "ch$n" | awk '{print $1}' | tr '\n' ',')
  f=$(ps | grep '[f]fmpeg -loglevel' | grep "live$n" | awk '{print $1}' | tr '\n' ',')
  w=$(ps | grep '[w]hip_push' | grep "stream=$stream" | awk '{print $1}' | tr '\n' ',')
  echo "ch$n -> $stream  rtmp_bridge=[$b] ffmpeg=[$f] whip=[$w]"
}

case "$CMD" in
  start)
    for n in $CHS; do start_one "$n"; done
    echo "--- 等待 12s 建流 ---"
    sleep 12
    echo "--- 各路日志尾部 ---"
    for n in $CHS; do
      printf 'ch%s: ' "$n"
      tail -2 /tmp/rtmp_ch$n.log 2>/dev/null | tr '\n' ' '
      echo
    done
    echo "--- SRS streams ---"
    busybox wget -q -O - "$SRS_API" 2>/dev/null | head -c 1200; echo
    ;;
  stop)
    for n in $CHS; do stop_one "$n"; done
    ;;
  status|*)
    for n in $CHS; do status_one "$n"; done
    echo "--- SRS streams ---"
    busybox wget -q -O - "$SRS_API" 2>/dev/null | head -c 1200; echo
    ;;
esac
