# AX650 WebRTC 推流项目 — 交付包

> 摄像头实时视频经 AX650 板推流到公网，浏览器低延迟观看。
> 详细技术资料见 **[docs/PROJECT_DOC.md](docs/PROJECT_DOC.md)**；SDK 编译/移植细节见 **[docs/GStreamer_WebRTC集成指南.md](docs/GStreamer_WebRTC集成指南.md)**。

---

## 现状（一屏速览）

```
flex_vision axstreamN (2592×1944 @ 2Mbps) → ffmpeg RTP 桥 → whip_push (WHIP/WebRTC)
  → 阿里云 SRS 121.196.101.253:1985  →  浏览器 WHEP / HTTP-FLV
```

**观看地址**

- WebRTC（低延迟，自带诊断面板）：`http://121.196.101.253:8080/players/webrtc_live.html?stream=live1`
- HTTP-FLV（稳定，约 1s 延迟）：`http://121.196.101.253:8080/players/flv_live.html?stream=live1`
- **IMU 叠加显示**（六轴数值 / 波形 / 驱动诊断）：`http://121.196.101.253:8080/players/flv_live.html?stream=live1&imu=auto`
  （`?imu=demo` 可脱离板子直接看 UI 效果）
- 播放器直连：`ffplay http://121.196.101.253:8080/live/live1.flv`

---

## 从 GitHub 获取（给外部同事 / 新板子）

仓库：`https://github.com/BranWangQiZhi/ax650-gstreamer-delivery`

访问 GitHub 的能力通常在 **PC 上**，不在板子上（板子经 PC 的 ICS 共享上网，
`raw.githubusercontent.com` 基本超时）。所以推荐顺序是：**PC 拉仓库 → 下发到板 → 板端本地装**。

### 方式 A：PC 一条命令（推荐，已实测）

```bash
git clone https://github.com/BranWangQiZhi/ax650-gstreamer-delivery.git
cd ax650-gstreamer-delivery

bash tools/board_deploy.sh                        # 默认板 192.168.137.77：下发 + 安装 + 自检
bash tools/board_deploy.sh -b root@192.168.1.50   # 换一块板
bash tools/board_deploy.sh -r test                # 装完直接彩条自测推流
bash tools/board_deploy.sh -r live1               # 装完直接推正式流
```

前提：PC 能 ssh 到板子，建议先配免密 `ssh-copy-id root@<板IP>`。
脚本串联：连通性检查 → 打包 → scp 到 `/tmp/delivery` → 板端离线安装 → 自检。

### 方式 B：板子自己能上外网

板上 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/BranWangQiZhi/ax650-gstreamer-delivery/main/board/gst_install.sh | sh
```

Release 1.0.0 已包含 `gstreamer-aarch64-deploy.tar.gz` 与 `sha256` 资产（下载链接已实测 200）。
被墙时套镜像：`GST_MIRROR=https://ghproxy.net/ ...`。

> ⚠️ 实测（2026-11-11，AX650 / glibc 2.30）：板上只有 busybox `wget` 且没有 `curl`，
> busybox 的 TLS 握手直接被拒（alert 40，疑似不带 SNI），
> raw.githubusercontent.com / github.com / ghproxy.net 在板上**全部不通**。
> 所以本板走不了在线安装，**请用方式 A**。方式 B 只适合 TLS 栈完整的设备。

### 方式 C：手工在板上装

```bash
sh board/gst_install.sh -l /tmp/delivery                        # 指向下发到板上的仓库目录
sh board/gst_install.sh -l /tmp/gstreamer-aarch64-deploy.tar.gz  # 只有部署包
GST_MIRROR=https://ghproxy.net/ sh board/gst_install.sh          # 在线装（同方式 B）
sh board/gst_install.sh -n                                      # 只体检，不动文件
```

脚本做的事：解压到 `/usr/local` → 用仓库 `board/` 补齐业务脚本与开机脚本
→ 写 `/etc/profile.d/gstreamer.sh` → 自检 `webrtcbin/x264enc/rtph264pay/rtspsrc`。

---

## 5 分钟上手

**开发板（192.168.137.77）**

```bash
# 板子重启后：先起相机服务（含 PWM 同步前置 + ax_vsync_ctrl.ko），再推流
flex_start.sh                     # 看到 RTSP_READY 才算相机就绪
. /etc/profile.d/gstreamer.sh     # 非交互 SSH 必须
flex_srs.sh                # 默认：摄像头 1(axstream1) → live1（WHIP/WebRTC）
flex_srs.sh live2          # 摄像头 2(axstream2) → live2，可与上一路并存
flex_srs.sh start live2    # 等价写法（start 是子命令，可省略）
flex_srs.sh status         # 查看 5 路映射 / 帧率 / 进程
flex_srs.sh stop           # 停全部（也可 stop live2 只停一路）
flex_srs.sh test           # 彩条自测推流，不依赖摄像头/RTSP/RTP 桥
tail -f /tmp/srs_whip_live1.log
```

> `liveN` 的 N 同时是摄像头通道号和 SRS 流名，全程 WHIP/WebRTC、不经 RTMP。
> 直接写 `flex_srs.sh liveN` 即可，`flex_srs.sh start liveN` 是等价写法；
> `start` 是子命令不是流名（旧版误当流名会推出 `stream=start` 的僵尸流）。
> 同一路已在正常推流时，重复执行会在 8 秒内返回 `ALREADY_PUSHING`，不会打断现有流；
> 只有该流 `recv_bytes` 8 秒增量为 0 才重建会话。
> Ctrl+C 中断时脚本会清理本次拉起的后台进程，不留下占端口的僵尸。

**服务器（121.196.101.253）验证**

```bash
curl -s http://127.0.0.1:1985/api/v1/streams/          # active=true 才有流
timeout 6 curl -s http://127.0.0.1:8080/live/live1.flv | wc -c   # >0 才出流
```

---

## IMU 数据显示（ICM-45686）

播放页右下角浮层可显示 **加计/陀螺六轴数值、实时波形、ODR/量程/DRDY 中断等驱动诊断**。
IMU 数据取自板端驱动，浏览器拿不到，所以多了一条独立链路：

```
sample_icm45686 → imu_agent.sh → POST :8090 → imu_hub.py → players/imu_latest.json → 页面同源 fetch
                              └→ 板端 HTTP :8099/cgi-bin/imu → 页面 JSONP（局域网直连）
```

```bash
# 服务器（PC 上执行一次，会打印 token）
cd server && sh deploy_imu.sh

# 板端（先确认 /etc/init.d/S98imu 已装载驱动）
scp board/imu_agent.sh root@<板IP>:/usr/local/bin/imu_agent.sh
SRS_HOST=121.196.101.253 IMU_TOKEN=<deploy_imu.sh 打印的 token> imu_agent.sh start both
imu_agent.sh status
```

`?imu=auto`（默认）优先同源转发的 JSON、失败自动退到板端直连；也可显式用
`?imu=hub` / `?imu=board&board=http://<板IP>:8099` / `?imu=demo` / `?imu=off`。
服务器需放行 TCP 8090（仅板端上报用，浏览器仍只访问 8080）。
完整说明、数据格式与排障见 **[docs/IMU_WEB_DISPLAY.md](docs/IMU_WEB_DISPLAY.md)**。

---

## 多路摄像头（live0 ~ live4）—— WHIP/WebRTC 一一对应

`flex_srs.sh liveN` 里的 **N 同时是摄像头通道号与 SRS 流名**，全程走 WHIP/WebRTC，不经 RTMP：

| 摄像头 | RTSP 源 | 流名 | 播放页（`http://121.196.101.253:8080/players/` 下） |
|---|---|---|---|
| 0 | `axstream0` | `live0` | `webrtc_live.html?stream=live0` |
| 1 | `axstream1` | `live1` | `webrtc_live.html?stream=live1` |
| 2 | `axstream2` | `live2` | `webrtc_live.html?stream=live2` |
| 3 | `axstream3` | `live3` | `webrtc_live.html?stream=live3` |
| 4 | `axstream4` | `live4` | `webrtc_live.html?stream=live4` |

```sh
flex_start.sh                 # 1) 等 RTSP_READY
flex_srs.sh live1             # 2) 摄像头 1 -> live1
flex_srs.sh start live2       # 3) 摄像头 2 -> live2（start 可省略，两路并存）
flex_srs.sh live4             # 4) 摄像头 4 -> live4
flex_srs.sh status            #    查看 5 路映射 / VENC 帧率 / 进程
flex_srs.sh stop live4        #    只停这一路
flex_srs.sh stop              #    停全部
flex_srs.sh test              #    彩条自测，排查是环境还是码流源
```

- 每路独立：UDP 端口 `5200+2*N`、RTP 桥、日志 `/tmp/ffmpeg_bridge_liveN.log` 与
  `/tmp/srs_whip_liveN.log`；进程判断按流名隔离，互不打断，重复执行同一路返回 `ALREADY_PUSHING`。
- **端口争抢防护**：`udpsrc` 默认 `reuse=true`，两个 whip_push 能同时 bind 同一 UDP 端口并静默抢包
  （现象：HTTP 201 + `connection established`，但 `bufs=0`、`recv_bytes` 几乎不涨、脚本反复
  `fake-connection`）。新版启动前会 `CLEANUP_PORT` 清掉该端口所有僵尸 whip_push，Ctrl+C 自动
  清理本次后台进程，`stop all` 也会杀掉所有 whip_push 而不只 `liveN`。
- 启动前读 `/proc/ax_proc/venc` 的 OutFps，通道没出帧直接报 `SOURCE_NO_FRAMES` 并列出可用通道，
  避免把黑流推上去。
- ⚠️ 板端 RTSP **只认 `axstream0`~`axstream4`**；写 `chN` 会被服务端回落到 `axstream0`（通道 0）。
  `flex_multi.sh` / `rtmp_bridge.sh` 的 RTMP 方案仍保留作为备选，本项目主链路不用。
- 实测 3 路（live1/2/4）并发稳定，每路约 2.6Mbps。`whip_push` 的 SSRC 相同**不影响**多实例
  （每个 WHIP 会话是独立 PeerConnection）；早期多路失败的根因是旧脚本全局进程判断、共用
  UDP 5004、按全局取 `recv_bytes`，均已修复。
- 5 路合计约 10Mbps 上行，若卡顿把 ini 的 `[Encode] u32Bitrate` 降到 800~1000 并重启 `flex_vision`。
- **推流起来后要刷新播放页**：旧 WHEP 会话是在没有 publisher 时建立的，SRS 不会给它补流。

---

## 5 合 1 拼接流 `axstream5`（可选，默认关闭）

SDK `flex_vision` 给 N 路摄像头各出一路主流（`axstream0`~`axstreamN-1`），并把缩略图拼成一张画布，
用 VENC[N] 单独编码成 **`axstreamN`** —— 5 摄像头下就是 `rtsp://<板IP>:8554/axstream5`。
默认 `[multiGrideDisplay] enable=0`，该通道不注册（DESCRIBE 返回 200 但 SDP 没有 `m=` 媒体行，
播放端拉不出画面）。

板端一键启用（会备份 ini、停推流、重启 `flex_vision`、验证并恢复原有 liveN 推流）：

```sh
chmod +x /usr/local/bin/enable_grid_stream.sh
enable_grid_stream.sh enable     # 开启 axstream5
enable_grid_stream.sh status     # 查看 enable / 8554 / axstream5 SDP / 日志
enable_grid_stream.sh disable    # 回退
```

PC 侧一键下发（上传板端脚本 + 执行 + DESCRIBE 验证；密码交互式输入或 `BOARD_PASSWORD`
环境变量，不落盘）：

```sh
python tools/apply_grid_stream.py                    # 默认 enable
python tools/apply_grid_stream.py --action status   # 只体检
python tools/apply_grid_stream.py --action disable  # 回退
```

- 画布按 `media_cfg.c` 的列数规则：**5 格 → 3 列 × 2 行**，每格 960×720，
  合计 **2880×1440@30fps**，右下角空一格；编码格式随 `[Encode]`（当前 H.264 / 2048Kbps CBR）。
  2026-11-13 板端实测抽帧见 [`docs/images/06_axstream5_5in1.jpg`](docs/images/06_axstream5_5in1.jpg)。
- `[multiGrideDisplay]` 段**只有 `enable` 生效**；段内 `stream_out_mode` / `nEncoderType` /
  `enRcMode` / `u32Bitrate` / `s32FixedQp` 是历史遗留参数，**原样保留但不被解析**。
  真正生效的编码类型 / 码率 / 输出方式都在 `[Encode]`（`stream_out_mode` 缺省即 0=RTSP），
  且被全部 6 路 VENC 共用 —— 单独调高码率会同时抬高 5 路主流，公网 WHIP 仍需守 2~3Mbps 上限。
  配置段注释统一用英文，事实以 `media_cfg.c` 为准（旧注释里的 2×2 / 1920×1440 / VENC[3] 不适用 5cam）。
- 仓库 `config/cfg_og05b10_5cam_2lan.ini` 已置 `enable=1`，2026-11-13 已把英文注释同步到板端，
  两份 ini 去注释后逐行一致。`enable_grid_stream.sh` 平时仍只做定点修改，**不整份覆盖**
  （避免把 sensor tuning bin 等板端差异带偏）。
- 拼接流目前只在板端 RTSP：PC 上 `ffplay -rtsp_transport tcp rtsp://<板IP>:8554/axstream5` 可直接看。
  `flex_srs.sh` 的通道校验仍是 0~4，要把它推到 SRS 需另行扩展通道范围。
- ⚠️ 重启 `flex_vision` 会中断当前推流约 20~40 秒；`NO_RESTART=1` 可只改 ini 不重启。

---

## 目录结构

```
gstreamer_delivery/
├── README.md            ← 本文件：交付门面 / 5 分钟上手
├── docs/                技术文档与验证截图
│   ├── PROJECT_DOC.md               完整交付文档（架构/部署/排障）
│   ├── GStreamer_WebRTC集成指南.md   SDK 交叉编译与阿里云 SRS 推流验证
│   └── images/                      链路各环节验证截图
├── board/               板端推流脚本 + 一键下发
├── server/              服务端播放页 + SRS 重启 + 一键下发
├── tools/               PC 端应急诊断工具
└── gstreamer_module/    GStreamer 交叉编译模块（SDK third-party，位置不可挪）
```

| 目录 | 内容 | 怎么用 |
|---|---|---|
| `board/` | 板上全部脚本 + 板端一键安装 | `curl .../gst_install.sh \| sh`（见下文） |
| `server/` | 播放页 + SRS 重启 + 一键下发 + 发布工具 | `cd server && sh deploy_server.sh` |
| `tools/` | PC 侧工具：`board_deploy.sh` 一键下发安装、应急诊断脚本 | `bash tools/board_deploy.sh` |
| `docs/` | 交付文档 + 集成指南 | 按需查阅 |
| `docs/images/` | 验证截图（按链路顺序 01→05 编号） | 画面质量佐证 |
| `gstreamer_module/` | 交叉编译源码与脚本 | 见 [`gstreamer_module/README.md`](gstreamer_module/README.md)，细节见集成指南 |

### board/ 脚本对照

| 文件 | 部署到 | 作用 |
|---|---|---|
| `flex_start.sh` | `/usr/local/bin/` | ★ 启动相机服务：PWM 同步前置 + insmod + 等 8554 就绪（重启后必跑） |
| `S50vsync` | `/etc/init.d/` | ★ 开机自动做 PWM 寄存器写入 + 装载 ax_vsync_ctrl.ko（无需登录，先于相机服务） |
| `S98imu` | `/etc/init.d/` | ★ 开机装载 ICM-45686 IMU 驱动（insmod + 探测 /dev/ax_imu + DRDY 中断检查，支持 start/stop/restart） |
| `imu_agent.sh` | `/usr/local/bin/` | IMU 采集：读 `sample_icm45686`，上报服务器 + 本地 HTTP 直连（`start/stop/status/once/sample`） |
| `S99zimu_web` | `/etc/init.d/` | 可选：开机自启 `imu_agent.sh`（排在 S98imu / S99zflex_start 之后） |
| `flex_srs.sh` | `/usr/local/bin/` | ★ 生产：`liveN → axstreamN` 一一对应（也支持 `start liveN`），WHIP/WebRTC 直推；支持多路并存 / `stop` / `status` / `test`，内置源帧率检查、端口僵尸清理、中断自清理、会话回收、桥守护、假连接检测 |
| `enable_grid_stream.sh` | `/usr/local/bin/` | 可选：启用/关闭 5 合 1 拼接流 `axstream5`（备份 ini + 重启 flex_vision + 验证 SDP + 恢复推流，`enable / disable / status`） |
| `rtp_bridge.sh` | `/usr/local/bin/` | ★ RTP 桥守护：ffmpeg RTSP→UDP `5200+2*N`，每路一个、断开自动重连（不要直接裸跑 ffmpeg） |
| `rtmp_bridge.sh` | `/usr/local/bin/` | RTMP 桥守护（备选）：ffmpeg 把 RTSP 原样封 FLV 直推 SRS 1935；本项目主链路不用 |
| `flex_multi.sh` | `/usr/local/bin/` | RTMP 多路管理（备选）：`axstreamN → liveN`，`start / stop / status`；本项目主链路不用 |
| `gst_install.sh` | 不部署，在线下载执行 | ★ 板端一条命令装齐：GStreamer 运行时 + 业务脚本（自动生成 `/etc/profile.d/gstreamer.sh`） |

### server/ 文件对照

| 文件 | 部署到 | 作用 |
|---|---|---|
| `flv_live.html` | `players/` | HTTP-FLV 播放页（mpegts.js，走 TCP 最稳），已叠加 IMU 数据面板 |
| `imu_panel.js` | `players/` | IMU 浮层：六轴数值 + 实时波形 + ODR/量程/中断诊断 + 原始输出 |
| `imu_hub.py` | `/usr/local/bin/` | 服务器 IMU 中转：收板端 POST、写同源 `imu_latest.json`、SSE/CORS |
| `webrtc_live.html` | `players/` | WHEP 播放页，顶栏显示 信令/ICE/连接/分辨率/丢包 |
| `srs_restart.sh` | `/usr/local/bin/` | 重启 SRS（改配置后用） |
| `deploy_server.sh` | PC 上执行 | 一键下发播放页并校验 HTTP |
| `deploy_imu.sh` | PC 上执行 | 一键下发 IMU 页面 + hub，生成 token、注册 systemd、校验 HTTP |

---

## 应急方案

**推流看着在跑但播放端黑屏/卡** —— 大概率是"假连接空推"（板上 `connection established`、SRS `recv_bytes=0`）：

```bash
# 板上重跑（脚本会自动检测并重试）
flex_srs.sh live1
```

若反复 `try=N fake-connection (delta_bytes≈1800)`，先查是不是两个 whip_push 抢同一 UDP 端口
（常见于旧版 `flex_srs.sh start liveN` + Ctrl+C 留下的僵尸）：

```bash
netstat -lnup | grep 520        # 同一端口出现两个 whip_push 就是端口争抢
flex_srs.sh stop                # 新版 stop 会清掉所有 whip_push / 桥 / ffmpeg
flex_srs.sh live1               # 新版启动前自动 CLEANUP_PORT，一次即可恢复
```

---

## 关键红线（务必记住）

1. **码率上限 2~3Mbps**：公网 WHIP 直推超过就丢 IDR 分片，FLV 输出 0 字节。
2. **ffmpeg RTP 桥不可省**：`rtspsrc` 与 flex RTP 序号不兼容，直连必然 0 buffer 死锁。

更多排障条目见 [docs/PROJECT_DOC.md 第 7 章](docs/PROJECT_DOC.md)。

---

## 新板首次部署检查（2026-11-12，192.168.137.103 实测）

新板出厂镜像与旧板不同，装完 GStreamer 后还要确认这 4 件事，否则 `flex_start.sh` 起不来、推流链路断在中途：

1. `/opt/etc/cfg_og05b10_5cam_2lan.ini` 的 `[sensor0] sdrSensorTuningBinName` 必须是 `null.bin`。新板 `/opt/etc` 没有 `AX650-OG05B10-auto.bin`，指向它会导致 `com_cfg_loadIni failed, ret=0x80000005` → `FLEX_VISION_EXITED`。仓库 `config/` 里的 ini 已修正。
2. 板端要有 `/etc/profile.d/gstreamer.sh`（`gst_install.sh` 会生成，手工装的要补写 PATH / LD_LIBRARY_PATH / LD_PRELOAD / GST_*）。
3. 单独安装的 FFmpeg 7.1 动态库若报 `version GLIBC_2.33 not found`，用 `gstreamer_module/apps/patch_glibc_ver.py` 给 `/usr/local/lib/libavformat.so.61.*`、`libavutil.so.59.*` 打降级补丁，并保持 `LD_PRELOAD=libglibc230_compat.so`。
4. 阿里云服务器重启后 SRS 不会自己起（1985 拒绝连接）；执行 `sh /usr/local/bin/srs_restart.sh`，现已加 `srs.service` 开机自启。

顺序不变：`flex_start.sh`（看到 `RTSP_READY`）→ `flex_srs.sh live1`（看到 `PUSH_OK`）。

---

## 已修复记录（2026-11-11）

1. **部署包内 `whip_push` 与源码不同步**（旧包内二进制 md5 `bcd670d8…`）。已在阿里云编译机
   `/root/sdk/AX650_SDK_V3.16.0_20261103160857_NO5387/third-party/gstreamer` 用仓库
   `apps/whip_push.c` 重编并重新打包，新二进制 md5 `16467ec3…`，含 `a=ssrc` 注入与
   `rtph264pay ssrc=1111111` 固定。旧二进制会让 SRS 返回 131 字节无 m-line 的 answer，
   `webrtcbin` 永远无法 `connection established`。
2. **部署包缺 `gst-plugin-scanner`**。新包已包含 `libexec/gstreamer-1.0/`，
   包顶层为 `bin / lib / libexec`。
3. **真实相机流全链路已验证通过（14:23–14:27）**。`board_deploy.sh` 下发安装后自检
   `webrtcbin / x264enc / rtph264pay / rtspsrc` 全 OK、`scanner OK`；`flex_start.sh` 起相机，
   `flex_srs.sh live1` 首轮即 `PUSH_OK try=0 recv_delta_MB=2`。SRS `publish.active=true`、
   `recv_30s≈2085 kbps`、`video=H264 Baseline 2592x1944`；服务器端 HTTP-FLV 6 秒拉到
   1.5MB，ffprobe 出 h264 / 2592x1944，WHEP 与 FLV 播放页均返回 200。
   日志出现 `[whip] offer ssrc=…`、`[whip] fixed rtph264pay ssrc=1111111`、
   `connection established`，131 字节残缺 answer 问题消失。

4. **一键自动安装 + 运行复验通过（15:29–15:32）**。停流后重跑 `bash tools/board_deploy.sh`
   （下发 → 离线安装 → 自检），再 `flex_srs.sh live1`，首轮 `PUSH_OK try=0 recv_delta_MB=3`；
   whip 日志 `[whip] offer ssrc=1111111`、`got answer (HTTP 201), 578 bytes`、
   `connection established, opening valve`（旧版是 131 字节无 m-line answer）。
   SRS `recv_30s≈2083 kbps` 稳定、18 秒 +3.9MB；HTTP-FLV 6 秒 1.48MB、h264 2592×1944，播放页 200。

> ⚠️ **待办：Release 资产仍未更新（板端在线安装不可用）**。
> 1.0.2（Latest）与 1.0.1 的 `assets` **都是空的**；页面那两个 `Source code` 是
> GitHub 自动生成的**整仓库快照**，安装脚本不会去解它找里面的部署包。只有 1.0.0 挂了
> `gstreamer-aarch64-deploy.tar.gz` + `sha256`，且是旧二进制。
> 实测 `releases/latest/download/gstreamer-aarch64-deploy.tar.gz` → 302 到 1.0.2 → **404**。
>
> **包本身没问题**：修复版 tar.gz 已提交进源码树（1.0.2 tag 与 main 都有），
> `git hash-object` = `f064ebd…` 与 GitHub Contents API 的 blob sha 完全一致，
> 即与仓库内 `gstreamer_module/gstreamer-aarch64-deploy.tar.gz`（md5 `70abfc8b…`）字节级相同。
>
> 为此 `tools/board_deploy.sh` 已加源码树兜底（Contents API → git blobs API → blob sha 校验）
> 及 `GST_PKG_URL` / `GST_REF` 逃生口。但本机实测 GitHub 16MB 大文件被代理截断
> （45 秒仅 1.3MB，raw 与 api blob 皆然），该兜底在国内网络不保证成功。
> **最稳的两条**：① 直接用仓库内本地包（当前默认路径）；② 把同一个文件上传为 1.0.2 的
> Release asset（附 `sha256: 4a7b6c8e39cf87a6b0d3be314b892c4b8cf176658f04d1d408bd4da66a1fe9ab`），
> 之后板端在线 `curl … | sh` 安装才会通。
>
> 另：板子 15:37 左右再次自重启（uptime 归零、tmpfs 清空、推流进程全无），已重新执行
> `flex_start.sh` + `flex_srs.sh live1`，首轮假连接后 `PUSH_OK try=1` 恢复出流。
> dmesg 无 panic/OOM，重启根因仍需从串口/电源侧确认。
