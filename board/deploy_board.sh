#!/bin/sh
# ============================================================
# 一键部署板上脚本（在 PC 的 Git Bash 里执行）
# ============================================================
# 用法: sh deploy_board.sh
# 前提: PC 能 ssh root@<板子IP>（免密已配置）
set -e
BOARD=${BOARD:-root@192.168.137.77}
HERE=$(cd "$(dirname "$0")" && pwd)

echo "[1/3] 上传脚本 -> $BOARD:/usr/local/bin/"
scp "$HERE"/flex_srs.sh "$HERE"/flex_rtmp.sh "$HERE"/flex_srs_pc.sh \
    "$HERE"/flex_whip.sh "$HERE"/whip_test.sh "$BOARD":/usr/local/bin/

echo "[2/3] 上传运行环境 -> /etc/profile.d/gstreamer.sh"
scp "$HERE"/gstreamer.sh "$BOARD":/etc/profile.d/gstreamer.sh

echo "[3/3] 赋可执行权限 + 校验"
ssh "$BOARD" "chmod 755 /usr/local/bin/flex_srs.sh /usr/local/bin/flex_rtmp.sh /usr/local/bin/flex_srs_pc.sh /usr/local/bin/flex_whip.sh /usr/local/bin/whip_test.sh; \
  ls -l /usr/local/bin/flex_*.sh /usr/local/bin/whip_test.sh | awk '{print \$1, \$NF}'"

echo "完成。下一步在板子上执行: /usr/local/bin/flex_srs.sh live1"
