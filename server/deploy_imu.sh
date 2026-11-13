#!/bin/sh
# ============================================================================
# 一键部署 IMU 显示链路到阿里云 SRS（在 PC 的 Git Bash 里执行）
# ----------------------------------------------------------------------------
# 用法:
#   sh deploy_imu.sh                       # 用默认服务器 / 路径，自动生成 token
#   SRV=root@1.2.3.4 sh deploy_imu.sh     # 换服务器
#   IMU_TOKEN=xxxx sh deploy_imu.sh       # 沿用已有 token（板端不用改）
#
# 前提: 能免密 ssh/scp 到服务器（ssh-copy-id root@<服务器IP>）
# 做完会打印板端 imu_agent.sh 需要用的 token 与启动命令。
# ============================================================================
set -e
SRV=${SRV:-root@121.196.101.253}
PORT=${IMU_HUB_PORT:-8090}
PLAYERS=${PLAYERS:-/usr/local/srs/srs-server-6.0-r3/trunk/objs/nginx/html/players}
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [ -z "${IMU_TOKEN:-}" ]; then
  IMU_TOKEN=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi
echo "[1/5] token: $IMU_TOKEN  (请保存，板端要用同一个)"

echo "[2/5] 上传播放页与面板脚本"
scp "$HERE/flv_live.html" "$HERE/imu_panel.js" "$SRV":"$PLAYERS"/
scp "$HERE/imu_hub.py" "$SRV":/usr/local/bin/imu_hub.py

echo "[3/5] 写服务配置与 systemd unit"
printf 'IMU_HUB_TOKEN=%s\n' "$IMU_TOKEN" >"$TMP/imu_hub.env"
scp "$TMP/imu_hub.env" "$SRV":/etc/imu_hub.env
cat >"$TMP/imu-hub.service" <<EOF
[Unit]
Description=AX650 IMU data relay (imu_hub.py)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/imu_hub.env
ExecStart=/usr/bin/python3 /usr/local/bin/imu_hub.py --host 0.0.0.0 --port ${PORT} --html ${PLAYERS} --token \${IMU_HUB_TOKEN}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
scp "$TMP/imu-hub.service" "$SRV":/etc/systemd/system/imu-hub.service
ssh "$SRV" "chmod 600 /etc/imu_hub.env; chmod 755 /usr/local/bin/imu_hub.py; \
            systemctl daemon-reload; systemctl enable --now imu-hub >/dev/null 2>&1 || systemctl restart imu-hub; \
            sleep 1; systemctl is-active imu-hub"

echo "[4/5] 校验 HTTP"
ssh "$SRV" "curl -s http://127.0.0.1:${PORT}/health; echo; \
  curl -s -o /dev/null -w 'flv_live.html    HTTP %{http_code}\n' http://127.0.0.1:8080/players/flv_live.html; \
  curl -s -o /dev/null -w 'imu_panel.js     HTTP %{http_code}\n' http://127.0.0.1:8080/players/imu_panel.js; \
  curl -s -o /dev/null -w 'imu_latest.json  HTTP %{http_code}\n' http://127.0.0.1:8080/players/imu_latest.json"

echo "[5/5] 完成"
echo "----------------------------------------------------------------"
echo "观看: http://<服务器IP>:8080/players/flv_live.html?stream=live1&imu=hub"
echo "演示: http://<服务器IP>:8080/players/flv_live.html?stream=live1&imu=demo"
echo "局域网直连: ...&imu=board&board=http://<板IP>:8099"
echo
echo "板端执行（SRS_HOST 与 token 一致）:"
echo "  SRS_HOST=${SRV#*@} IMU_HUB_PORT=${PORT} IMU_TOKEN=${IMU_TOKEN} imu_agent.sh start both"
echo
echo "阿里云安全组需放行 TCP ${PORT}（供板端 POST），浏览器只需 8080。"
