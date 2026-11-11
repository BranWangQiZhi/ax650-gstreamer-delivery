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

### 方式 B：板子自己能上外网（需先发布 Release）

板上 root 执行：

```bash
curl -fsSL https://raw.githubusercontent.com/BranWangQiZhi/ax650-gstreamer-delivery/main/board/gst_install.sh | sh
```

> ⚠️ 这个方式读的是 **GitHub Release**。仓库目前**还没有发布任何 Release**，
> 直接跑会停在"下载安装包"并 404。发布 Release 后才可用。
> 被墙时套镜像：`GST_MIRROR=https://ghproxy.net/ ...`（镜像不通就退回方式 A）。
>
> 发布方法：`sha256sum gstreamer_module/gstreamer-aarch64-deploy.tar.gz > sha256`，
> 然后在 Releases → Draft a new release，tag 例如 `1.22.12-r20261111`，
> 上传 `gstreamer-aarch64-deploy.tar.gz` 与 `sha256` 两个文件并 Publish。

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

## 已知问题（待处理）

1. **部署包里的 `whip_push` 与 `whip_push.c` 不是同一版本**。实测运行日志里没有源码
   `main()` 必然打印的 `[whip] srcbin: ...` 和 `[whip] fixed rtph264pay ssrc=1111111`，
   `flex_srs.sh test` 会卡在 `videotestsrc0 ... reason not-linked (-1)`。
   上游链路本身没问题（同参数 `gst-launch ... ! fakesink` 返回 0），
   需要在编译机用当前源码重编 `whip_push` 并重新打包发布。
2. **部署包缺 `gst-plugin-scanner`**。安装时会告警，插件扫描退回进程内（能跑，首次启动慢）。
   补齐需在编译机 `cd gstreamer_module && bash build.sh install` 重新打包。
