#!/bin/sh
# ============================================================
# 一键部署播放端页面到阿里云 SRS（在 PC 的 Git Bash 里执行）
# ============================================================
# 用法: sh deploy_server.sh
# 前提: 能 ssh root@<服务器IP>
set -e
SRV=${SRV:-root@121.40.107.62}
PLAYERS=/usr/local/srs/srs-server-6.0-r3/trunk/objs/nginx/html/players
HERE=$(cd "$(dirname "$0")" && pwd)

echo "[1/3] 上传播放页"
scp "$HERE"/flv_live.html "$HERE"/webrtc_live.html "$SRV":"$PLAYERS"/

echo "[2/3] 上传 srs_restart.sh"
scp "$HERE"/srs_restart.sh "$SRV":/usr/local/bin/srs_restart.sh
ssh "$SRV" "chmod +x /usr/local/bin/srs_restart.sh"

echo "[3/3] 校验 HTTP 可达"
ssh "$SRV" "curl -s -o /dev/null -w 'flv_live.html    HTTP %{http_code}\n' http://127.0.0.1:8080/players/flv_live.html; \
            curl -s -o /dev/null -w 'webrtc_live.html HTTP %{http_code}\n' http://127.0.0.1:8080/players/webrtc_live.html"

echo "完成。观看: http://<服务器IP>:8080/players/flv_live.html?stream=live1"
