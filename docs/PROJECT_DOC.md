# AX650 摄像头视频流 WebRTC 推流项目 — 交付文档

| 项目项 | 内容 |
|---|---|
| 项目目标 | 将 AX650 开发板摄像头实时视频，以 WebRTC 方式发布到公网，供浏览器低延迟观看 |
| 交付日期 | 2026-11-10 |
| 状态 | ✅ 已上线运行（WHIP 直推阿里云 SRS，2592×1944 @ 2Mbps） |
| 涉及端 | 开发板（采集/编码/推流） → 阿里云服务器（SRS 转分发） → 浏览器（播放） |

---

## 1. 最终架构

### 1.1 生产链路（当前运行中）

```
┌─────────────────────────── AX650 开发板 (192.168.137.77) ───────────────────────────┐
│                                                                                      │
│  flex_vision (5MP 鱼眼摄像头)                                                         │
│      │  RTSP  tcp://127.0.0.1:8554/axstream1   2592×1944 H264 @ 2Mbps CBR                  │
│      ▼                                                                               │
│  ffmpeg RTP 桥                                                                        │
│      │  ffmpeg -c copy -f rtp rtp://127.0.0.1:5004   （必须，见 5.2）                  │
│      ▼                                                                               │
│  whip_push (自研 WHIP 客户端, webrtcbin)                                              │
│      │  WHIP 信令: HTTP POST offer/answer → http://121.196.101.253:1985/rtc/v1/whip/     │
│      │  媒体:      DTLS-SRTP over UDP → 121.196.101.253:8000                            │
└──────────────────────────────────────┬───────────────────────────────────────────────┘
                                       │  公网
                                       ▼
┌──────────────────── 阿里云服务器 121.196.101.253 (SRS 6.0.195) ────────────────────────┐
│  1985  HTTP-API (WHIP 推流 / WHEP 拉流)                                               │
│  8000  WebRTC 媒体 (UDP+TCP)                                                          │
│  8080  HTTP-FLV / 播放页 (players/)                                                   │
│  1935  RTMP（SRS rtmp_to_rtc=on，可自动转 WebRTC）                                     │
└──────────────────────────────────────┬───────────────────────────────────────────────┘
                                       │
                                       ▼
        浏览器播放：webrtc_live.html（WHEP，最低延迟）/ flv_live.html（HTTP-FLV，稳定）
```

### 1.2 备选链路

| 链路 | 脚本 | 适用场景 | 代价 |
|---|---|---|---|
| WHIP 直推（**默认**） | `board/flex_srs.sh` | 码率 ≤ 2~3Mbps，要最低延迟 | 公网 UDP 丢包敏感 |

---

## 2. 环境清单

### 2.1 开发板

| 项 | 值 |
|---|---|
| IP  | `192.168.137.77` |
| 系统 | AX650 (aarch64)，glibc **2.30** |
| 摄像头 | OG05B10 5MP 鱼眼，原生 2592×1944 |
| 采集服务 | flex_vision，启动脚本 `/opt/bin/flex_vision_run.sh`，配置 `/opt/etc/cfg_og05b10_5cam_2lan.ini` |
| RTSP 端口 | **8554**（不是 554），通道 `axstream0` ~ `axstream4`（`chN` 会被回落到通道 0） |
| GStreamer | 1.22.12，装在 `/usr/local`，环境脚本 `/etc/profile.d/gstreamer.sh` |

### 2.2 阿里云服务器

| 项 | 值 |
|---|---|
| IP  | `121.196.101.253` |
| 流媒体 | SRS 6.0.195，路径 `/usr/local/srs/srs-server-6.0-r3`，配置 `trunk/conf/whip.conf` |
| 端口 | 1985(API/WHIP/WHEP)、8000(WebRTC 媒体)、8080(HTTP-FLV/播放页)、1935(RTMP) |
| 安全组 | 需放行 TCP 1985/8080/1935 与 UDP 8000 |

### 2.3 PC（编译 / 运维机）

| 项 | 值 |
|---|---|
| 角色 | 交叉编译服务器中继、播放端、脚本下发 |
| 网络 | 板子经 PC 的 ICS（192.168.137.1）共享上网 |

---

## 3. 交付文件清单

```
gstreamer_delivery/               ← 仓库根 = 交付包根
├── README.md                       ← 快速上手（先看这个）
│
├── docs/                           全部技术文档
│   ├── PROJECT_DOC.md              ← 本文档（完整技术资料）
│   ├── GStreamer_WebRTC集成指南.md   SDK 交叉编译 + 阿里云 SRS 推流验证细节
│   └── images/                     链路验证截图（01→05 按链路顺序）
│       ├── 01_ch0_板端采集.jpg
│       ├── 02_ch1_webrtc拉流.jpg
│       ├── 03_彩条推流回放.jpg
│       ├── 04_relay链路_回放.jpg
│       └── 05_画面质量验证.jpg       FLV 抽帧验证图（鱼眼画面清晰无花屏）
│
├── board/                          开发板文件
│   ├── S50vsync                     → /etc/init.d/S50vsync          ★ 开机自动 PWM 前置 + 装载 ax_vsync_ctrl.ko
│   ├── S98imu                       → /etc/init.d/S98imu            ★ 开机装载 ICM-45686 IMU 驱动
│   ├── flex_srs.sh                  → /usr/local/bin/                ★ 生产：WHIP 直推（test 参数 = 彩条自测）
│   └── gst_install.sh               板端一键安装（运行时+业务脚本，在线下载执行）
│
├── server/                         阿里云服务器文件
│   ├── flv_live.html                → players/flv_live.html          HTTP-FLV 播放页
│   ├── webrtc_live.html             → players/webrtc_live.html       WebRTC 播放页（带诊断）
│   ├── srs_restart.sh               → /usr/local/bin/                SRS 重启
│   └── deploy_server.sh             PC 侧一键下发脚本
│
├── tools/                          运维/诊断工具（PC 侧）
│   ├── srs_relay.py                 用户态 TCP+UDP 中转（ICS 失效应急）
│   ├── stun_test.py                 STUN 连通性探测
│   └── udp_echo_srv.py              多端口 UDP 回显（排查 UDP 可达性）
│
└── gstreamer_module/               GStreamer 交叉编译模块（源码 + 部署包，位置不可挪）
```

### 3.1 交叉编译相关（`gstreamer_module/` 与 SDK third-party 双份）

`gstreamer_module/` 是 SDK 内 `third-party/gstreamer` 的本地镜像，两者内容对应：

| 位置 | 说明 |
|---|---|
| `gstreamer_module/README.md` | 模块文档入口（目录结构 / 快速开始 / 部署包内容 / 双份镜像说明） |
| `gstreamer_module/` | 本交付包内的编译模块镜像（download.sh / build.sh / Makefile + apps/） |
| `gstreamer_module/apps/whip_push.c` | WHIP 客户端源码（自研，含 SSRC 补丁） |
| `docs/GStreamer_WebRTC集成指南.md` | SDK 集成与编译细节（**编译/移植看这份**） |
| `AX650_SDK.../third-party/gstreamer/` | SDK 内的正式位置（`build.sh` 依赖 `../../` 相对路径，故本地镜像不可挪动） |
| `.../gstreamer-aarch64-deploy.tar.gz` | 板端部署包（build.sh 产物，已 gitignore，需自行编译生成） |

---

## 4. 部署步骤

### 4.1 开发板（首次部署）

```bash
# 1) GStreamer 运行时 + 业务脚本, 一条命令装齐（含自动生成 /etc/profile.d/gstreamer.sh）
curl -fsSL https://raw.githubusercontent.com/BranWangQiZhi/ax650-gstreamer-delivery/main/board/gst_install.sh | sh
#    确认 /usr/local/bin/ 下 whip_push、flex_start.sh、flex_srs.sh、rtp_bridge.sh 存在

# 2) 板子重连或手动生效环境
. /etc/profile.d/gstreamer.sh

# 3) 自测（推彩条，排除摄像头/编码问题）
flex_srs.sh test

# 4) 正式推流
flex_srs.sh live1
# 期望输出: PUSH_OK try=N recv_MB=xx
```

### 4.2 阿里云服务器

```bash
# 1) 下发播放页（在 PC 的 Git Bash）
cd delivery/server && sh deploy_server.sh

# 2) 确认 SRS 在跑
curl -s http://127.0.0.1:1985/api/v1/versions
```

### 4.3 修改 flex_vision 码率（关键前置）

```bash
# 板上：把码率从 8192 降到 2048 Kbps（CBR）
cp /opt/etc/cfg_og05b10_5cam_2lan.ini /opt/etc/cfg_og05b10_5cam_2lan.ini.bak_8M
sed -i 's/^u32Bitrate      = 8192/u32Bitrate      = 2048/' /opt/etc/cfg_og05b10_5cam_2lan.ini
# 重启采集服务（会断流数秒）
kill <flex_vision_pid>; cd /opt/bin && nohup ./flex_vision_run.sh > /tmp/flex_restart.log 2>&1 &
```

---

## 5. 关键技术决策与权衡

### 5.1 为什么用 WHIP 而不是 GStreamer 原生 whipsink

GStreamer 1.22 没有 `whipsink`（1.24 才引入），因此自研 `whip_push.c`：

- `webrtcbin` + 手工构造 **非 trickle WHIP** offer（offer 里带完整 ICE candidate）
- HTTPS 用 OpenSSL 直连（`SSL_VERIFY_NONE`），SRS 的 1985 是明文 HTTP，两者都支持
- 先 `PAUSED` 等 answer 协商完成 → pad-added 链接 → `PLAYING`
- `valve drop=true` 门控，等 `connection-state=CONNECTED` 才放数据，避免 not-linked 报错

### 5.2 为什么必须有 ffmpeg RTP 桥（不能直接 rtspsrc）

GStreamer 的 `rtspsrc` 与 flex_vision 的 RTP 序号机制不兼容：jitterbuffer 一直等不到期望的 seq，**收 0 buffer 并死锁**（已试过 latency/protocols/buffer-mode 各种组合，均无效）。

解决方案：`ffmpeg -rtsp_transport tcp -i <rtsp> -c copy -f rtp rtp://127.0.0.1:5004`，本机回环零丢包，`udpsrc` 侧只当普通 RTP 源处理。**这条路是唯一稳定方案，不是可选优化。**

### 5.3 分辨率 vs 码率：为什么最终降的是码率

需求原本是「降到 1920×720」。实测做不到：

| 途径 | 结论 |
|---|---|
| flex_vision 配置 | `[sensor*]` 是传感器原生 2592×1944，VENC 直接编 ISP 输出，**ini 无 crop/scale 选项** |
| `h264_axenc` 硬编 | 需 `-init_hw_device axmm`，创建失败（与 flex_vision 占用编码器冲突） |
| `h264_v4l2m2m` | 板上无 `/dev/video*` 设备，不可用 |
| 板 CPU 软编 | 8 核负载已 12.8（采集占满），软编会拖死采集 |

**改用降码率**，效果等价且更优：公网 UDP 丢包打碎 IDR 的根因是「8Mbps 下单个 IDR 有数百个 RTP 分片」，降到 2Mbps 后 IDR 缩小约 4 倍，可稳定存活。

> 实测红线：**公网 WHIP 直推可用上限约 2~3Mbps**；超过即出现「SRS 反复识别 IDR 起始但组帧不完整 → FLV 输出 0 字节」。

### 5.4 SRS 的两个必踩坑（已在代码修复）

**坑 1：SRS 返回 131 字节残缺 answer（无 m-line）**

SRS 的协商逻辑（`srs_app_rtc_conn.cpp: negotiate_publish_capability`）只有在 offer 的 video m-line 带 `a=ssrc:` 行时才把 track 加入 stream_desc。浏览器会带，`webrtcbin` 的 offer 不带 → SRS 生成无 m-line 的 answer → webrtcbin 报 `Answer doesn't have the same number of m-lines as the offer`。

修复（`whip_push.c`）：offer 末尾注入

```
a=ssrc:1111111 msid:live video0
a=ssrc:1111111 cname:whippush
```

**坑 2：SSRC 不匹配（`no publisher for ssrc:3730882712`）**

`rtph264pay` 启动后才随机分配 SSRC，此时再读再设都无效。修复：**pipeline 启动前**就把 `rtph264pay ssrc=1111111` 固定，与 offer 声明保持一致。

### 5.5 播放端：WebRTC 与 HTTP-FLV 双通道

| 通道 | 延迟 | 稳定性 | 页面 |
|---|---|---|---|
| WHEP (WebRTC) | ~200–500ms | 依赖 UDP 8000 路径质量 | `webrtc_live.html`（自带信令/ICE/分辨率/丢包诊断面板） |
| HTTP-FLV (TCP) | ~1s | 高，不受 UDP 影响 | `flv_live.html`（mpegts.js，256KB 预缓冲 + 延迟追赶 4s） |

浏览器只走 TCP 播放时更稳；WebRTC 流畅但受网络影响。

---

## 6. 运行手册

### 6.1 日常操作（板子上）

```bash
. /etc/profile.d/gstreamer.sh      # 非交互 SSH 必须先 source

flex_srs.sh live1                  # 启动/重启 WHIP 推流（自动重试 + 媒体验证）
ps | grep -E 'whip_push|ffmpeg'    # 查看链路进程
tail -f /tmp/srs_whip.log          # 推流日志（PUSH_OK 即成功）
tail -f /tmp/ffmpeg_bridge.log     # RTP 桥日志

# 停止
kill $(ps | grep whip_push | grep -v grep | awk '{print $1}')
kill $(ps | grep 'rtsp://127.0.0.1:8554/axstream1' | grep -v grep | awk '{print $1}')
```

> ⚠️ 禁止用 `pkill -f 'whip_push'`：SSH 命令行自身含同样关键字，会把远端 shell 一起杀掉。

### 6.2 状态验证（服务器上）

```bash
# 流是否活跃、收到多少字节、是否有视频轨
curl -s http://127.0.0.1:1985/api/v1/streams/

# FLV 是否真的出流（0 字节 = 关键帧组不出来）
timeout 6 curl -s http://127.0.0.1:8080/live/live1.flv | wc -c

# 抽帧看画面（验证不是花屏）
timeout 10 curl -s http://127.0.0.1:8080/live/live1.flv -o /tmp/c.flv
ffmpeg -v error -i /tmp/c.flv -frames:v 1 -y /tmp/f.jpg
```

### 6.3 观看地址

| 方式 | 地址 |
|---|---|
| WebRTC（低延迟） | `http://121.196.101.253:8080/players/webrtc_live.html?stream=live1` |
| HTTP-FLV（稳定） | `http://121.196.101.253:8080/players/flv_live.html?stream=live1` |
| ffplay / VLC | `http://121.196.101.253:8080/live/live1.flv` |
| RTMP | `rtmp://121.196.101.253:1935/live/live1` |

---

## 7. 故障排查手册

| 现象 | 根因 | 处理 |
|---|---|---|
| 板上日志 `connection established` 但 SRS `recv_bytes=0` | **假连接空推**（只收到 RTCP，无 RTP） | 重跑 `flex_srs.sh`（v3 已内置检测与重试） |
| SRS answer 只有 131 字节、无 m-line | offer 缺 `a=ssrc` 行 | 用已修复的 `whip_push` 二进制 |
| `no publisher for ssrc:xxxx` | offer SSRC 与 payloader 实际 SSRC 不一致 | 同上（启动前固定 SSRC=1111111） |
| FLV/RTMP 输出 0 字节，API 显示 video 有 SPS | 码率过高，IDR 分片被丢包打碎 | 码率降到 ≤2Mbps |
| `whip_push ... bad HTTP response / HTTP 0` | **旧 publish 会话还占着 stream**（SRS 约 37s 才回收已断的推流会话），新 WHIP POST 被直接拒 | `flex_srs.sh` 现已等会话释放后再推，冷启动首次即可成功 |
| 推流进程在，但播放端无画面；`8554` 无监听 | **板子重启后 flex_vision 没起来**（`/tmp/ffmpeg_bridge.log` 里是 `Connection refused`） | 跑 `flex_start.sh`（含 PWM 同步前置），再跑 `flex_srs.sh` |
| `flex_vision` 一启动就退出，日志 `media_flow_setup failed ret=0x80000004` | 缺 `ax_vsync_ctrl.ko`（sync_mode=2 的前置，每次上电都要重做） | `flex_start.sh` 已内置；手动见 §7.2 |
| 板上 `curl: not found` | 板子未装 curl | 用 `busybox wget -q -O -` |
| 浏览器 WebRTC 黑屏，FLV 正常 | UDP 8000 路径问题或 WHEP 未协商 | 用 `webrtc_live.html` 看诊断面板定位；临时用 FLV 页 |
| RTSP 拉流 0 buffer 死锁 | `rtspsrc` 与 flex RTP 序号不兼容 | 必须走 ffmpeg RTP 桥 |
| 板上 `LD_PRELOAD` 报找不到 glibc 符号 | 未加载兼容层（非交互 SSH 不读 profile） | `. /etc/profile.d/gstreamer.sh` |
| **新板** `flex_start.sh` 打印 `FLEX_VISION_EXITED`，日志 `[sensor0] SDR tuning bin not found: /opt/etc/AX650-OG05B10-auto.bin` | 出厂 `/opt/etc` 没有这个 tuning bin，而 ini 的 `[sensor0]` 仍指向它（sensor1~4 已是 `null.bin`）；`com_cfg_loadIni` 直接返回 `0x80000005` | 把 `[sensor0] sdrSensorTuningBinName` 改成 `null.bin`（官方 sample `og05b10_single_sdr_offline_2lane_entry.ini` 也是 null.bin）。仓库 `config/cfg_og05b10_5cam_2lan.ini` 已修正 |
| **新板** `ffmpeg/ffprobe` 报 `version 'GLIBC_2.33' not found` | SDK 工具链 sysroot 是 glibc 2.33，单独安装的 FFmpeg 7.1 动态库没打降级补丁（GStreamer 部署包出厂已打过） | 用 `gstreamer_module/apps/patch_glibc_ver.py` 处理 `/usr/local/lib/libavformat.so.61.*`、`libavutil.so.59.*`，并保持 `LD_PRELOAD=/usr/local/lib/libglibc230_compat.so` 提供 `stat64/fstat64/lstat64` |
| **新板** `gst-inspect-1.0: not found`、手工跑 `rtp_bridge.sh` 失败 | 板端缺 `/etc/profile.d/gstreamer.sh`（该文件由 `gst_install.sh` 生成，手工装的 GStreamer 没有） | 补写 PATH/LD_LIBRARY_PATH/LD_PRELOAD/GST_* 环境变量文件；`flex_srs.sh` 自带兜底，但从它启动的 `rtp_bridge.sh` 会继承 |
| 板子能起相机但 SRS API `Connection refused`、服务器 `streams:[]` | 阿里云服务器重启后 SRS 没有开机自启 | 服务器上 `sh /usr/local/bin/srs_restart.sh`；已加 `srs.service` 开机自启 |
| 旧版 `flex_srs.sh live0/live2/...` 返回 `ALREADY_PUSHING` 或黑屏 | 旧脚本源固定 ch1、全局判断 whip_push、共用 UDP 5004、按全局取 `recv_bytes`，且 `chN` 路径会被回落到 axstream0 | 已修复：新版 `flex_srs.sh liveN` 按流名隔离进程/端口/指标，`axstreamN → liveN` 走 WHIP，支持多路并存；见 §7.3 |
| `flex_srs.sh start live1` 后 Ctrl+C，再跑 `live1` 反复 `try=N fake-connection (delta_bytes≈1800)`、SRS `video=null` | 旧版把 `start` 当流名、`live1` 当通道号，推出 `stream=start` 的僵尸 whip_push 占着 UDP 5202；Ctrl+C 只杀前台脚本，`setsid` 起的后台进程残留，随后 `live1` 的 whip_push 与僵尸同时 bind 5202（`udpsrc reuse=true`）静默抢包 → `bufs=0` | 已修复：新版把 `start` 识别为子命令、校验流名合法性；启动前 `cleanup_port` 清掉该端口所有僵尸，Ctrl+C 用 trap 清理本次拉起的进程，`stop all` 改为杀掉所有 whip_push；见 §7.1 / §7.3 |

### 7.1 板上 shell 的两个坑（写脚本必看）

1. **`pkill -f '关键字'` 会杀掉远端 shell 自己**（命令行含同样关键字）→ 改用 `kill <pid>` 或 `pkill -x <进程名>`。
2. **按流名取 SRS 指标**：BusyBox 无 jq/python，`flex_srs.sh` 用 `grep -oE` 抽出 `"name"` / `"recv_bytes"` / `"publish":{"active"` 再用 awk 配对；旧写法 `tr ',' '\n' | grep recv_bytes | head -1` 只取到全局第一条流，多路时必然误判。
3. **`udpsrc` 默认 `reuse=true`**：两个 `whip_push` 能同时 bind 同一 UDP 端口且不报错，RTP 包被静默分走，表现为「HTTP 201 + `connection established` 但 `bufs=0`、`recv_bytes` 不涨」。所以每路必须独占端口，启动前要按 `udpsrc port=N` 反查并清掉残留进程（`port_owners` / `cleanup_port`），不能只靠 `stream=liveN` 过滤。

### 7.2 板子重启后的启动顺序（每次上电必须执行）

flex_vision 的 `sync_mode=2`（PWM 多机同步）依赖内核模块和两个寄存器，**掉电即失效**，这是"重启后没流"的头号原因：

```sh
# 1) PWM 同步前置（顺序不能换）
ax_lookat 0x425023c -s 0x10003
ax_lookat 0x4250248 -s 0x10003
insmod /soc/ko/ax_vsync_ctrl.ko

# 2) 起相机服务（会自动重跑上面的前置，并等 8554 就绪）
/usr/local/bin/flex_start.sh

# 3) 起推流（桥 + whip_push，含源检查/会话回收/增量校验）
/usr/local/bin/flex_srs.sh live1
```

`flex_start.sh` 做的事：前置寄存器 → insmod → 带 `LD_LIBRARY_PATH=...:/soc/lib` 启动 flex_vision（**非交互 SSH 不读 `/etc/profile`，缺 `libax_sys.so` 会直接报错退出**）→ 轮询 8554 就绪，失败时打印日志里的 ERROR 行。

> 部分板子还需把引脚复用成 PWM35：`ax_lookat 0x425083c -s 0x20003`。当前这块板不需要。

### 7.3 多路摄像头（live0 ~ live4）—— WHIP/WebRTC 一一对应

板端 5 路 RTSP 通道是 `rtsp://127.0.0.1:8554/axstream0` ~ `axstream4`
（H.264 2592×1944@30fps，支持并发客户端）。**写 `chN` 会被服务端回落到 `axstream0`（通道 0）**，
服务端日志会显示 `DESCRIBE axstream0 ... playing channel 0`。

`flex_srs.sh liveN` 的 N 同时是通道号与流名，全程 WHIP/WebRTC，不经 RTMP：

| 摄像头 | 0 | 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| RTSP 源 | axstream0 | axstream1 | axstream2 | axstream3 | axstream4 |
| 流名 | live0 | live1 | live2 | live3 | live4 |
| UDP 端口 | 5200 | 5202 | 5204 | 5206 | 5208 |

```sh
flex_start.sh                      # 等 RTSP_READY
flex_srs.sh live1                  # 摄像头 1 -> live1
flex_srs.sh start live2            # 等价写法；start 是子命令不是流名
flex_srs.sh live4                  # 其它路，可并存
flex_srs.sh status                 # 映射 / VENC 帧率 / 进程 / SRS 流
flex_srs.sh stop [liveN|all]       # 停一路或全部
```

- 每路独立 RTP 桥、UDP 端口、日志；`whip_pids` / `get_recv` / `publish_state` 都按流名隔离，
  不会互相打断；重复执行同一路返回 `ALREADY_PUSHING`。
- **端口独占**：启动前 `cleanup_port` 按 `udpsrc port=N` 清掉该端口上的所有 whip_push
  （含异常流名 / Ctrl+C 残留），Ctrl+C 用 trap 清理本次拉起的进程，`stop all` 杀全部 whip_push。
  两个 udpsrc 抢同一端口会静默 `bufs=0`，是「连接成功却无画面」的常见原因。
- 启动前检查 `/proc/ax_proc/venc` 的 OutFps，无帧通道报 `SOURCE_NO_FRAMES` 并列出可用通道。
- 2026-11-12 实测 live1/2/4 **三路 WHIP 并发稳定**，每路 12s 约 3.9MB（≈2.6Mbps）。
  `whip_push` 把 `rtph264pay` SSRC 硬编码成 `1111111` **并不妨碍多实例**（每个 WHIP 会话是
  独立 PeerConnection）；早期多路假连接的根因是旧脚本的全局进程判断、共用 UDP 5004、
  按全局取 `recv_bytes`，以及失效的 `chN` 源路径。
- `flex_multi.sh` / `rtmp_bridge.sh` 的 RTMP 方案保留为备选，本项目主链路不用。
- 5 路合计约 10Mbps 上行，卡顿就把 ini 的 `[Encode] u32Bitrate` 降到 800~1000 并重启 `flex_vision`。
- **推流起来后要刷新播放页**：旧 WHEP 会话是在没有 publisher 时建立的，SRS 不补流。

---

## 8. 验证记录（2026-11-10）

| 时间 | 项目 | 结果 |
|---|---|---|
| 13:35 | GStreamer 1.22.12 交叉编译（21 步） | ✅ stage/bin 产物齐全 |
| 13:45 | 部署到板 + 彩条推流验证 | ✅ 浏览器可看，无花屏 |
| 15:00 | flex ch1 RTSP → WebRTC 转发（局域网） | ✅ 25MB+ 流入，抽帧清晰 |
| 16:14 | 首次 WHIP 直推阿里云 SRS | ✅ FLV 5s 收 4.7MB |
| 17:30 | 排查公网丢包致 IDR 破碎 | ✅ 定位为 8Mbps 码率问题 |
| 17:40 | 码率 8192→2048 Kbps 后 WHIP 直推 | ✅ FLV 8s 收 1.9MB，抽帧画面清晰 |
| 18:50 | 播放页交付（WebRTC + FLV 双通道） | ✅ PC 拉流 8s 2MB |
| 19:30 | flex_srs.sh v3（假连接检测）上线 | ✅ 偶发失败可自动重试成功 |
| 19:33 | 交付前巡检 | ✅ active=True、recv 59MB+、FLV 6s 1.48MB |
| 21:32 | 板子重启后无流排查 | ✅ 根因：flex_vision 未启动 + 缺 `ax_vsync_ctrl.ko`；补前置后 `ch1` 恢复 2592×1944@30fps |
| 21:45 | flex_srs.sh v4（源检查 / 会话回收等待 / 桥守护 / 增量校验） | ✅ 冷启动 try=0 成功，桥断开可在原会话续流 |

---

## 9. 已知限制与后续工作

**限制**

1. 所有 flex 通道共享 `[Encode] u32Bitrate` 配置——降码率对 ch0/1/3/4 全部生效。
2. 板端无法输出 720p（传感器原生 5MP，VENC 无缩放），画质受 2Mbps 压制偏软。
3. WHIP 会话 30 秒无数据即被 SRS 销毁；v4 已让 RTP 桥带守护循环，源短断可自愈，但会话被销毁后仍需重跑一次 `flex_srs.sh`（重跑有健康检查，不会打断正常推流）。
4. `whip_push` 的 `HTTP 0` 根因是旧 publish 会话未回收（SRS 约 37s），v4 用"等会话释放再推"绕开，未解决 SRS 侧回收慢的问题。

**建议后续**

1. **掉线自愈**：`flex_srs.sh` 已是幂等的（正常推流时 8s 内返回 `ALREADY_PUSHING`，不打断），可直接用 cron 每分钟巡检：`* * * * * /usr/local/bin/flex_srs.sh live1 >> /tmp/srs_cron.log 2>&1`。
2. **开机自启**：在 `/etc/init.d/` 加一个 `S99flex`，内容依次是前置寄存器 → `insmod ax_vsync_ctrl.ko` → `flex_start.sh` → `flex_srs.sh live1`。
3. **NACK 重传**：给 webrtcbin 的 rtpbin 配置 NACK/RTX，提升公网 UDP 抗丢包能力，可把码率上限推到 4Mbps。
4. **720p 真降分辨率**：PC 侧用 ffmpeg 拉板子 RTSP 转码 720p@15fps 再推 WHIP（需在 PC 装带 libx264 的 ffmpeg）。
5. **鉴权**：当前 SRS 无推流鉴权，公网任何人可向 `live` 应用推流，建议加 `http_hooks` 或 token 校验。
