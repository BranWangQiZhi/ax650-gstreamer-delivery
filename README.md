# AX650 WebRTC 推流项目 — 交付包

> 摄像头实时视频经 AX650 板推流到公网，浏览器低延迟观看。
> 详细技术资料见 **[docs/PROJECT_DOC.md](docs/PROJECT_DOC.md)**；SDK 编译/移植细节见 **[docs/GStreamer_WebRTC集成指南.md](docs/GStreamer_WebRTC集成指南.md)**。

---

## 现状（一屏速览）

```
flex_vision ch1 (2592×1944 @ 2Mbps) → ffmpeg RTP 桥 → whip_push (WHIP/UDP)
  → 阿里云 SRS 121.40.107.62:1985  →  浏览器 WHEP / HTTP-FLV
```

**观看地址**

- WebRTC（低延迟，自带诊断面板）：`http://121.40.107.62:8080/players/webrtc_live.html?stream=live1`
- HTTP-FLV（稳定，约 1s 延迟）：`http://121.40.107.62:8080/players/flv_live.html?stream=live1`
- 播放器直连：`ffplay http://121.40.107.62:8080/live/live1.flv`

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
flex_srs.sh                # 默认：flex ch1 → RTP 桥 → whip_push → SRS（流名 live1）
flex_srs.sh live2          # 正常链路，指定流名
flex_srs.sh test           # 彩条自测推流（默认流名 test），不依赖摄像头/RTSP/RTP桥
flex_srs.sh test mytest    # 彩条自测，指定流名
tail -f /tmp/srs_whip.log
```

> 推流已在正常运行时，`flex_srs.sh` 会 8 秒内返回 `ALREADY_PUSHING`，不会打断现有流；只有码流确实为 0 才重建会话。

**服务器（121.40.107.62）验证**

```bash
curl -s http://127.0.0.1:1985/api/v1/streams/          # active=true 才有流
timeout 6 curl -s http://127.0.0.1:8080/live/live1.flv | wc -c   # >0 才出流
```

---

## 多路摄像头（live0 ~ live4）

⚠️ **`flex_srs.sh` 的参数是 SRS 流名，不是摄像头通道**，视频源固定 `ch1`；而且只要检测到
已有 `whip_push` 在推，它就返回 `ALREADY_PUSHING` 直接退出。所以执行
`flex_srs.sh live0 / live2 / live3 / live4` **不会创建新流**，播放页会出现
「信令已应答 / ICE connected / 连接 connected」却黑屏——SRS 上那几个流只有播放器建的空对象
（`publish.active=false`、`video=null`、`recv_bytes≈0`）。

板端 5 路 RTSP 通道是 `rtsp://127.0.0.1:8554/ch0` ~ `ch4`（都是 H.264 2592×1944@30fps）。
多路用 `flex_multi.sh` 启，走 **RTMP 直推**（`rtmp_bridge.sh` 守护，每路一条独立 TCP 连接；
SRS 配了 `rtmp_to_rtc on`，WHEP / HTTP-FLV 播放页都能拉）：

```sh
flex_start.sh                 # 1) 等 RTSP_READY
flex_srs.sh live1             # 2) ch1 -> live1（WHIP，低延迟，保持原样）
flex_multi.sh start           # 3) ch0/2/3/4 -> live0/2/3/4（RTMP）
flex_multi.sh status          #    查每路进程与 SRS 流状态
flex_multi.sh stop            #    停掉这 4 路（不动 live1）
flex_multi.sh start 3         #    只起/补一路 ch3 -> live3
```

| 摄像头 | 流名 | 播放地址（`N` 换 0~4） |
|---|---|---|
| ch0 | live0 | `http://121.40.107.62:8080/players/webrtc_live.html?stream=liveN` |
| ch1 | live1 | 同上（WHIP 推，延迟最低） |
| ch2 / ch3 / ch4 | live2 / live3 / live4 | 同上；FLV 备选 `flv_live.html?stream=liveN` |

> 为什么不用多个 `whip_push`：`whip_push` 把 `rtph264pay` 的 SSRC 硬编码成 `1111111`，
> 多实例同时 WHIP 会出现 `publish.active=true` 但 `recv_bytes≈0` 的假连接；RTMP 没有这个问题。
> 5 路合计约 10Mbps 上行，若卡顿把 ini 的 `[Encode] u32Bitrate` 降到 800~1000 并重启 `flex_vision`。
> **推流起来后要刷新播放页**：旧 WHEP 会话是在没有 publisher 时建立的，SRS 不会给它补流。

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
| `flex_srs.sh` | `/usr/local/bin/` | ★ 生产：WHIP 直推阿里云，内置源检查 / 会话回收等待 / 桥守护 / 假连接检测；`flex_srs.sh test` 彩条自测（排查是环境问题还是码流问题） |
| `rtp_bridge.sh` | `/usr/local/bin/` | ★ RTP 桥守护：ffmpeg RTSP→UDP:5004，断开自动重连（不要直接裸跑 ffmpeg） |
| `rtmp_bridge.sh` | `/usr/local/bin/` | ★ RTMP 桥守护：ffmpeg 把 `chN` 原样封 FLV 直推 SRS 1935，断线自动重连（多路用） |
| `flex_multi.sh` | `/usr/local/bin/` | ★ 多路管理：`chN → liveN`，`start / stop / status`；默认补 ch0/2/3/4，live1 仍由 `flex_srs.sh` 推 |
| `gst_install.sh` | 不部署，在线下载执行 | ★ 板端一条命令装齐：GStreamer 运行时 + 业务脚本（自动生成 `/etc/profile.d/gstreamer.sh`） |

### server/ 文件对照

| 文件 | 部署到 | 作用 |
|---|---|---|
| `flv_live.html` | `players/` | HTTP-FLV 播放页（mpegts.js，走 TCP 最稳） |
| `webrtc_live.html` | `players/` | WHEP 播放页，顶栏显示 信令/ICE/连接/分辨率/丢包 |
| `srs_restart.sh` | `/usr/local/bin/` | 重启 SRS（改配置后用） |
| `deploy_server.sh` | PC 上执行 | 一键下发播放页并校验 HTTP |

---

## 应急方案

**推流看着在跑但播放端黑屏/卡** —— 大概率是"假连接空推"（板上 `connection established`、SRS `recv_bytes=0`）：

```bash
# 板上重跑（v3 脚本会自动检测并重试）
flex_srs.sh live1
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
