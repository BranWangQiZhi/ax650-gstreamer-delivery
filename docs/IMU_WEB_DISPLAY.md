# 播放页 IMU 数据显示（ICM-45686）

> 在 `flv_live.html` 上看板端 IMU 实时数据：六轴数值、实时波形、驱动诊断、原始输出。
> 新增于 2026-11-13；服务器 IP 已更新为 `121.196.101.253`。

---

## 1. 为什么需要多一条链路

视频走 `flex_vision → WHIP → SRS 8080 → 浏览器`，但 IMU 数据只存在于**板端驱动**
（`/dev/ax_imu`、`/sys/bus/spi/devices/spi0.0/imu_reg`、`/opt/bin/sample_icm45686`）。
浏览器既访问不到板子的私网地址，也没有读驱动节点的权限，所以不能只改 HTML。

因此加了「采集 → 传输 → 展示」三段，两套传输链路可任选或同时开：

```
                         ┌─ push ──POST /api/imu──> 阿里云 imu_hub.py (:8090)
板端 imu_agent.sh ───────┤                              │ 原子写
  采集 sample_icm45686   │                              ▼
  --duration N --dump    │              players/imu_latest.json  ← 页面同源 fetch（公网可看）
                         └─ serve ─> 板端 HTTP :8099/cgi-bin/imu ← 页面 JSONP（局域网直连）
                                      (python3 或 busybox httpd CGI)
```

| 链路 | 页面参数 | 适用 | 前提 |
|---|---|---|---|
| 服务器中转 | `?imu=hub` 或默认 `auto` | 公网任何人看直播时都能看 IMU | 服务器跑 `imu_hub.py`，安全组放行 TCP 8090 给板端 |
| 板端直连 | `?imu=board&board=http://<板IP>:8099` | 局域网调试、服务器没部署 hub | 浏览器能访问板子 8099，页面为 http（非 https） |
| 自动 | `?imu=auto`（默认） | 自动先试同源 JSON，再退到板端 JSONP | 两种都部署时最省心 |
| 演示 | `?imu=demo` | 只看 UI 效果 / 前端调试 | 无 |

> 板端直连走 JSONP 而不是 fetch，是为了绕开「公网页面 → 私网 IP」的跨域预检
> （Chrome Private Network Access）；CGI 同时带 `Access-Control-Allow-Private-Network: true`。

---

## 2. 文件清单

| 文件 | 部署到 | 作用 |
|---|---|---|
| `server/imu_panel.js` | `players/` | 面板本体：解析、数值、双 Canvas 波形、诊断、数据源切换 |
| `server/flv_live.html` | `players/` | 顶栏加「IMU 数据」开关 + 引入 `imu_panel.js`（其余播放逻辑不变） |
| `server/imu_hub.py` | `/usr/local/bin/` | 服务器中转：收 POST、缓存历史、原子写静态 JSON、SSE、CORS |
| `server/deploy_imu.sh` | PC 上执行 | 一键下发页面 + hub，生成 token、注册 systemd、校验 HTTP |
| `board/imu_agent.sh` | `/usr/local/bin/` | 板端采集/上报/本地 HTTP，`start/stop/status/once/sample` |
| `board/S99zimu_web` | `/etc/init.d/` | 可选开机自启（排在 S98imu 与 S99zflex_start 之后） |

其它播放页（如 `webrtc_live.html`）想接同一面板，只需加一行
`<script src="imu_panel.js"></script>`，可选再放个 `<button id="imu-toggle">`。

---

## 3. 快速开始

### 3.1 服务器（121.196.101.253）

```bash
# PC 上（需免密 ssh/scp）
cd server && sh deploy_imu.sh
```

脚本会：上传 `flv_live.html` / `imu_panel.js` / `imu_hub.py` → 生成随机 token 写入
`/etc/imu_hub.env`(600) → 注册并启动 `imu-hub.service` → 校验 4 个 HTTP 端点。
**把打印出来的 token 记下来**，板端要用同一个。

手工等价操作：

```bash
python3 /usr/local/bin/imu_hub.py --port 8090 \
  --html /usr/local/srs/srs-server-6.0-r3/trunk/objs/nginx/html/players \
  --token <TOKEN>
```

> ⚠️ **阿里云安全组必须放行 TCP 8090**（只给板端 POST 用；浏览器仍只访问 8080）。
> 2026-11-13 实测：服务器本机 `curl 127.0.0.1:8090/health` 正常、`ufw inactive`，
> 但从公网 `curl http://121.196.101.253:8090/health` 返回 000 —— 就是安全组没放行。
> 在 ECS 安全组「入方向」加一条 `TCP 8090 / 源 IP 可限制为板端出口 IP` 即可，
> 放行后可用 `curl http://121.196.101.253:8090/health` 从 PC 复验。
> 若暂时不能放行，可先用 `?imu=board` 局域网直连（不经过 8090）。

### 3.2 板端（AX650）

```bash
# 方式 A：板子能访问公网 8080 时，直接从服务器下载（推荐，不用 PC 中转）
wget -q -O /usr/local/bin/imu_agent.sh http://121.196.101.253:8080/players/imu_agent.sh
chmod 755 /usr/local/bin/imu_agent.sh
wget -q -O /etc/init.d/S99zimu_web http://121.196.101.253:8080/players/S99zimu_web
chmod 755 /etc/init.d/S99zimu_web

# 方式 B：PC 上 scp 下发
scp board/imu_agent.sh root@<板IP>:/usr/local/bin/imu_agent.sh
ssh root@<板IP> "chmod 755 /usr/local/bin/imu_agent.sh"

# 板端：先确认驱动在
/etc/init.d/S98imu status 2>/dev/null || grep icm45686 /proc/interrupts
/opt/bin/sample_icm45686 --frame          # 能出数才算就绪

# 试采一帧（前台打印 JSON，不联网、不起服务）
imu_agent.sh once

# 启动（默认 both：既上报服务器，也开本地 8099）
SRS_HOST=121.196.101.253 IMU_TOKEN=<TOKEN> imu_agent.sh start both
imu_agent.sh status
```

开机自启（可选）：把 `S99zimu_web` 放到 `/etc/init.d/`（755），把
`SRS_HOST` / `IMU_TOKEN` / `IMU_MODE` 写进 `/etc/imu_agent.env`（600），
不要写进仓库脚本。

### 3.3 打开页面

| 用途 | URL |
|---|---|
| 公网（服务器中转） | `http://121.196.101.253:8080/players/flv_live.html?stream=live1&imu=hub` |
| 自动（推荐） | `...&imu=auto` |
| 局域网直连板子 | `...&imu=board&board=http://192.168.137.226:8099` |
| 先看 UI 效果 | `...&imu=demo` |
| 关闭面板 | `...&imu=off` |

面板右下角浮层，顶栏「IMU 数据」按钮可开关，头部可折叠，数据源下拉框可实时切换并记住选择
（localStorage）。`&poll=200` 调轮询间隔，`&raw=1` 强制把数值当原始 LSB 换算。

---

## 4. 数据格式与解析

### 4.1 统一信封（板端 / hub / 页面通用）

```json
{
  "src":  "icm45686",
  "ts":   1731467890,
  "seq":  123,
  "lines": ["ts_us=123456 ax=0.012 ay=-0.003 az=9.801 gx=0.12 gy=-0.05 gz=0.01 temp=32.5", "..."],
  "conf": "acc_odr=200 Hz gyr_odr=200 Hz acc_fs=16 g gyr_fs=1000 dps power=low-noise",
  "caps": "...",
  "irq":  123456
}
```

- `lines` 是 `sample_icm45686 --duration N --dump` 的原始文本行（降采样到 `IMU_MAX_LINES`，默认 40 行/帧）。
  **原始文本始终会在面板「原始驱动输出」里显示**，即使解析器不认识也不会白屏。
- `conf` 来自 `--conf`，`irq` 来自 `/proc/interrupts` 里 `icm45686-int1` 的累计计数。
- hub 会补 `hub_ts` / `hub_seq` / `peer`；页面用 `hub_ts` 算链路延迟，避免板端 RTC 不准。

### 4.2 页面解析策略（`imu_panel.js` 的 `parseLine`）

按优先级尝试：

1. `key=value` / `key: value`：识别 `ax/acc_x/accel_x/...`、`gx/gyr_x/gyro_x/...`、
   `temp/temperature`、`ts_us/timestamp` 等别名；
2. `acc=[a,b,c]` / `gyr=[a,b,c]` 分组；
3. CSV / 纯数字序列：自动跳过首列 us/ns 时间戳，按 `ax,ay,az,gx,gy,gz,temp` 映射；
4. 数值明显是原始 LSB（`|acc|>40` 或 `|gyr|>5000`）时，按驱动默认
   ±16g / ±1000dps、16bit 自动换算（`acc/2048`、`gyr/32.768`）。

`parseConf` 从 `--conf` / `--caps` / `--duration ...` 统计输出里抽 ODR、量程、功耗模式、
实测速率、丢样；ODR 支持 `0x8 → 200Hz` 这类编码（映射表取自
`config/cfg_og05b10_5cam_2lan.ini` 注释）。

> **待校准**：目前按截图里的命令族做了宽松解析。拿到 `sample_icm45686 --frame`、
> `--duration 2 --dump`、`--conf` 的真实输出后，只需改 `imu_panel.js` 里的
> `parseLine()` / `parseConf()`（必要时给板端加 `IMU_FILTER` 过滤表头/统计行）。
> 传输层不用动。

### 4.3 诊断项

| 项 | 来源 |
|---|---|
| ODR / 量程 / 功耗模式 | `--conf` 文本 |
| DRDY 中断累计、中断速率 | 相邻两帧 `irq` 差值 / 时间差 |
| 实测速率、丢样/丢帧 | 帧内时间戳差、`seq` 跳变、与 ODR 比较 |
| 本帧样本、链路延迟 | `lines` 解析成功数、`hub_ts` |
| 数值单位 | 是否触发原始 LSB 换算 |

---

## 5. 排障

| 现象 | 检查 |
|---|---|
| 面板一直「无数据」 | 服务器 `curl 127.0.0.1:8090/health` 看 `frames` 是否增长；不增长说明板端没上报 |
| `frames` 不涨、板端 `last_post: fail` | ① 安全组没放行 TCP 8090；② `IMU_TOKEN` 与服务器不一致（hub 返回 401）；③ 板端无外网出口，可先 `wget -q -O- http://<服务器>:8090/health` 测 |
| 面板显示「无数据」但有帧 | 页面取的是同源 `/players/imu_latest.json`，确认该文件存在且 HTTP 200；浏览器控制台看是否被缓存（页面已带 `_=` 破缓存） |
| 有数值但全是大整数 | 驱动输出的是原始 LSB，加 `&raw=1` 强制换算，或让 `parseLine` 识别真实字段名 |
| 直连模式报「板端服务不可达」 | 浏览器要能访问 `<板IP>:8099`；`imu_agent.sh status` 看 `httpd : RUNNING`；确认 URL 是 `/cgi-bin/imu` |
| 波形不动 / 数值不变 | `lines` 里没有可解析的数值行；展开「原始驱动输出」看原文，用 `IMU_FILTER` 或校准 `parseLine` |
| 板端 `httpd : STOPPED` | 板端既无 `python3` 也无 `busybox httpd`，只能用 `imu_agent.sh start push`（服务器中转） |
| 视频正常但想关掉 IMU | 顶栏按钮，或 `&imu=off` |

常用验证命令：

```bash
# 服务器
curl -s http://127.0.0.1:8090/health
curl -s http://127.0.0.1:8090/api/imu | head -c 400
curl -s http://127.0.0.1:8080/players/imu_latest.json | head -c 400
journalctl -u imu-hub -n 30 --no-pager

# 模拟一帧（不依赖板子）
curl -s -X POST -H 'X-Imu-Token: <TOKEN>' -H 'Content-Type: application/json' \
  -d '{"lines":["ts_us=123456 ax=0.01 ay=-0.02 az=9.81 gx=0.1 gy=0.2 gz=-0.3 temp=32.5"],"conf":"acc_odr=200 Hz acc_fs=16 g gyr_fs=1000 dps","irq":1}' \
  http://127.0.0.1:8090/api/imu

# 板端
imu_agent.sh status
imu_agent.sh once
curl -s 'http://127.0.0.1:8099/cgi-bin/imu?cb=test'

# 页面 UI 自检（无需任何后端）
http://121.196.101.253:8080/players/flv_live.html?stream=live1&imu=demo
```

---

## 6. 设计取舍

- **解析集中在页面**：板端和 hub 只搬运原始文本行，字段适配只改 `imu_panel.js` 一处，
  避免三端同时改。驱动升级/换芯片时改动面最小。
- **静态 JSON 同源**：hub 把最新帧原子写进 `players/imu_latest.json`，页面从 8080 同源
  fetch，不需要给浏览器额外开端口，也没有 CORS/PNA 麻烦。
- **降采样传输**：IMU 200Hz，但每帧只带 40 行、约 1 秒一帧，上行开销几 KB/s，
  不会和 2Mbps 视频抢带宽；波形在页面侧按帧累积。
- **不依赖板端 python**：采集用 POSIX sh + awk，HTTP 服务有 python3 用 python3、
  没有就用 busybox httpd CGI、再没有就只走上报。
- **鉴权**：`/api/imu` 的 POST 支持 `X-Imu-Token` 或 `?token=`，GET 只读不鉴权。
  token 存服务器 `/etc/imu_hub.env`(600)，不进仓库。
