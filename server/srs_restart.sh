#!/bin/sh
# ============================================================
# 阿里云 SRS 重启脚本（改配置后使用）
# ============================================================
# 部署路径: 服务器任意位置, 如 /usr/local/bin/srs_restart.sh
# 用法: srs_restart.sh
pkill -x srs 2>/dev/null
sleep 2
cd /usr/local/srs/srs-server-6.0-r3/trunk || exit 1
ASAN_OPTIONS=detect_leaks=0 setsid ./objs/srs -c conf/whip.conf > /usr/local/srs/srs.log 2>&1 < /dev/null &
sleep 6
curl -s -m 5 http://127.0.0.1:1985/api/v1/versions; echo
