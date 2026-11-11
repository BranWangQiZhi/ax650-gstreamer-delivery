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

**板子上一条命令搞定**（需要能出外网，root 执行）：

```bash
curl -fsSL https://raw.githubusercontent.com/BranWangQiZhi/ax650-gstreamer-delivery/main/board/gst_install.sh | sh
```

脚本自动完成：读最新 Release → 下载约 16MB 包 → SHA256 校验 → 解压到 `/usr/local`
→ 写 `/etc/profile.d/gstreamer.sh` → 自检 `webrtcbin/x264enc/rtph264pay/rtspsrc`。

GitHub 慢或被墙时套镜像：

```bash
GST_MIRROR=https://ghproxy.net/ curl -fsSL https://raw.githubusercontent.com/BranWangQiZhi/ax650-gstreamer-delivery/main/board/gst_install.sh | sh
```

其他用法：`sh install.sh -n`（只体检）、`-v <tag>`（指定版本）。

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
| `tools/` | 应急诊断工具（PC 侧） | 按需使用 |
| `docs/` | 交付文档 + 集成指南 | 按需查阅 |
| `docs/images/` | 验证截图（按链路顺序 01→05 编号） | 画面质量佐证 |
| `gstreamer_module/` | 交叉编译源码与脚本 | `make` / `sh build.sh`，见集成指南 |

### board/ 脚本对照

| 文件 | 部署到 | 作用 |
|---|---|---|
| `flex_start.sh` | `/usr/local/bin/` | ★ 启动相机服务：PWM 同步前置 + insmod + 等 8554 就绪（重启后必跑） |
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
