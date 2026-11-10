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

## 5 分钟上手

**开发板（192.168.137.77）**

```bash
. /etc/profile.d/gstreamer.sh     # 非交互 SSH 必须
flex_srs.sh live1                 # 启动推流，看到 PUSH_OK 即成功
tail -f /tmp/srs_whip.log
```

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
│   ├── GStreamer_WebRTC集成指南.md   SDK 交叉编译与 mediamtx 验证
│   └── images/                      链路各环节验证截图
├── board/               板端推流脚本 + 一键下发
├── server/              服务端播放页 + SRS 重启 + 一键下发
├── tools/               PC 端应急诊断工具
└── gstreamer_module/    GStreamer 交叉编译模块（SDK third-party，位置不可挪）
```

| 目录 | 内容 | 怎么用 |
|---|---|---|
| `board/` | 板上全部脚本 + 一键下发 | `cd board && sh deploy_board.sh` |
| `server/` | 播放页 + SRS 重启 + 一键下发 | `cd server && sh deploy_server.sh` |
| `tools/` | 应急诊断工具（中转/UDP 探测） | 见下方「应急方案」 |
| `docs/` | 交付文档 + 集成指南 | 按需查阅 |
| `docs/images/` | 验证截图（按链路顺序 01→05 编号） | 画面质量佐证 |
| `gstreamer_module/` | 交叉编译源码与脚本 | `make` / `sh build.sh`，见集成指南 |

### board/ 脚本对照

| 文件 | 部署到 | 作用 |
|---|---|---|
| `gstreamer.sh` | `/etc/profile.d/` | GStreamer 环境变量（PATH/LD_PRELOAD/插件路径） |
| `flex_srs.sh` | `/usr/local/bin/` | ★ 生产：WHIP 直推阿里云，内置假连接检测 + 8 次重试 |
| `flex_rtmp.sh` | `/usr/local/bin/` | 备选：RTMP(TCP) 推流，适合 4~8Mbps 原画质 |
| `flex_srs_pc.sh` | `/usr/local/bin/` | 备选：经 PC 本地 SRS 中转（需 PC 中转服务在跑） |
| `flex_whip.sh` | `/usr/local/bin/` | 局域网 mediamtx 调试链路 |
| `whip_test.sh` | `/usr/local/bin/` | 彩条自测（排查是环境问题还是码流问题） |
| `deploy_board.sh` | PC 上执行 | 一键下发全部脚本 + chmod |

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

**板上出不了公网（PC 的 ICS NAT 卡死）** —— 管理员重启 `SharedAccess` 服务，或用用户态中转：

```bash
# PC 上跑（转发 TCP 1985 + UDP 8000）
python tools/srs_relay.py
# 板上改用
flex_srs_pc.sh live1
```

**怀疑 UDP 8000 不通**：

```bash
# 服务器上起回显（避开 SRS 端口，勿占用 8000）
ssh root@121.40.107.62 "python3 /tmp/udp_echo_srv.py"   # 先上传 tools/udp_echo_srv.py
python tools/stun_test.py                               # PC 侧探测
```

---

## 关键红线（务必记住）

1. **码率上限 2~3Mbps**：公网 WHIP 直推超过就丢 IDR 分片，FLV 输出 0 字节。要高码率用 `flex_rtmp.sh`。
2. **ffmpeg RTP 桥不可省**：`rtspsrc` 与 flex RTP 序号不兼容，直连必然 0 buffer 死锁。
3. **`whip_push` 二进制不能随便换**：内含 SRS 兼容补丁（offer 注入 `a=ssrc` + 固定 SSRC=1111111），换回旧版会拿到 131 字节残缺 answer。
4. **别用 `pkill -f 关键字`**：会连同远端 SSH shell 一起杀掉。

更多排障条目见 [docs/PROJECT_DOC.md 第 7 章](docs/PROJECT_DOC.md)。
