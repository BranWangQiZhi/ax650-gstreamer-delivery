#!/bin/sh
# ============================================================
# flex_vision 启动器（含 PWM 多机同步前置，每次上电都必须重跑）
# ============================================================
# 背景: sync_mode=2(PWM) 时, 缺 ax_vsync_ctrl.ko 会导致
#       media_flow_setup failed ret=0x80000004, 表现为 8554 无监听
# 用法: flex_start.sh [ini路径]
# 部署路径: /usr/local/bin/flex_start.sh
INI=${1:-/opt/etc/cfg_og05b10_5cam_2lan.ini}

if ps | grep -v grep | grep -q '[f]lex_vision -p'; then
  echo "flex_vision already running (pid $(ps | grep -v grep | grep '[f]lex_vision -p' | awk '{print $1}'))"
  exit 0
fi

# --- PWM 同步前置（顺序不能换）---
ax_lookat 0x425023c -s 0x10003
ax_lookat 0x4250248 -s 0x10003
if ! lsmod | grep -q ax_vsync_ctrl; then
  insmod /soc/ko/ax_vsync_ctrl.ko && echo "ax_vsync_ctrl.ko loaded"
fi

cd /opt/bin || exit 1
LD_LIBRARY_PATH=/usr/local/lib:/usr/lib:/opt/lib:/soc/lib \
  setsid ./flex_vision -p "$INI" > /tmp/flex_vision.log 2>&1 < /dev/null &

# --- 等 RTSP 端口就绪 ---
n=0
while [ $n -lt 30 ]; do
  if netstat -lnt 2>/dev/null | grep -q ':8554'; then
    echo "RTSP_READY (0.0.0.0:8554)"
    exit 0
  fi
  if ! ps | grep -v grep | grep -q '[f]lex_vision -p'; then
    echo "FLEX_VISION_EXITED"
    grep -iE 'ERROR|fail' /tmp/flex_vision.log | head -3
    exit 1
  fi
  sleep 1
  n=$((n+1))
done
echo "TIMEOUT: 30s 内 8554 未监听"
exit 1
