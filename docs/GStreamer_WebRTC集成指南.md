# AX650 SDK 集成 GStreamer 1.22.12 + WebRTC(WHIP) 推流阿里云 SRS 指南

> 环境：阿里云编译服务器（Ubuntu 22.04，交叉工具链 gcc-arm-10.3-2021.07 aarch64）→ AX650 开发板（glibc 2.30）
> 模块位置：`third-party/gstreamer/`；已验证彩条 720p H264 通过 WHIP 推流到阿里云 SRS 并成功拉流回放。

---

## 1. 总体架构

```
┌────────────── 阿里云编译服务器 ──────────────┐   ┌──── 开发板 ────┐   ┌─── 阿里云 SRS 媒体服务器 (121.196.101.253) ───┐
│ ax650_sdk/third-party/gstreamer              │   │ /usr/local/{   │   │ WHIP/WHEP(HTTP-API)      :1985              │
│   tarballs/  源码包(19个)                     │   │   bin, lib,    │   │ WebRTC ICE(TCP+UDP)      :8000              │
│   build.sh   交叉编译 21 步                    │ tar→│  libexec}    │   │ HTTP-FLV / HLS          :8080              │
│   apps/whip_push.c  WHIP 信令客户端           │ scp→│  whip_push   │WHIP│ RTMP                     :1935             │
│   apps/patch_glibc_ver.py  glibc 版本降级     │   │  flex_srs.sh   │ ──→│ API: /api/v1/streams/                      │
│   gstreamer-aarch64-deploy.tar.gz  部署包     │   │  gst-launch-1.0│   │ 播放页: /players/rtc_player.html           │
└──────────────────────────────────────────────┘   └────────────────┘   └────────────────────────────────────────────┘
```

数据链路：`videotestsrc → videoconvert → x264enc → rtph264pay → webrtcbin → WHIP(HTTP) → SRS → WHEP/HTTP-FLV/RTMP 拉流`

## 2. third-party/gstreamer 模块结构

```
third-party/gstreamer/
├── download.sh                  # 源码包下载（幂等，可重复执行）
├── build.sh                     # 交叉编译主脚本（build / install / clean）
├── Makefile                     # SDK third-party 构建入口（make gstreamer）
├── tarballs/                    # 19 个源码包
├── apps/
│   ├── whip_push.c              # 自研 WHIP 信令客户端（webrtcbin + 极简 HTTP/HTTPS）
│   ├── glibc230_compat.c/.map   # glibc 2.30 兼容层（stat64/pthread_sigmask 等）
│   └── patch_glibc_ver.py       # ELF glibc 版本号降级补丁
├── stage/                       # 编译暂存 sysroot（bin/lib/libexec/include）
├── src/                         # 解包后的源码
└── gstreamer-aarch64-deploy.tar.gz   # 开发板部署包（bin+lib+libexec，约 16MB）
```

**编译组件清单**（按依赖顺序）：
zlib → libffi → pcre2 → pcre-8.45 → **glib-2.72.4** → libsrtp-2.5.0 → json-glib（可选）→
libunistring → libidn2 → libpsl（soup 链，当前跳过 sqlite/libsoup）→ **x264** →
**gstreamer 1.22.12** → **gst-plugins-base** → **good**(rtp/rtpmanager/udp/v4l2) →
**ugly**(x264enc，需 `-Dx264=enabled -Dgpl=enabled`) → openssl(取自 SDK) →
**libnice-0.1.21** → **gst-plugins-bad**(webrtc/dtls/srtp) → whip_push → glibc230_compat

## 3. 编译步骤（阿里云服务器）

```bash
# 1) 进入 SDK
cd /root/sdk/AX650_SDK_V3.16.0_20261103160857_NO5387

# 2) 下载源码包（首次约 15~40 分钟，取决于网络）
bash third-party/gstreamer/download.sh

# 3) 编译（增量，重复执行会跳过已完成的步骤）
cd third-party/gstreamer && bash ./build.sh
# 成功输出: GST_BUILD_ALL_DONE

# 4) 安装进 SDK rootfs + 生成开发板部署包
bash ./build.sh install
#   → rootfs/rootfs/usr/local/{bin,lib,libexec}
#   → gstreamer-aarch64-deploy.tar.gz

# (可选) 通过 SDK 构建系统整体编译（等价，全量编译时间较长）
cd /root/sdk/AX650_SDK_V3.16.0_20261103160857_NO5387/build
make p=AX650_emmc clean all install axp -j8     # gstreamer 已注册进 third-party/Makefile 的 SUBDIRS
```

依赖的本机工具：`meson`、`ninja`（`pip3 install --user meson ninja`）、`libglib2.0-dev-bin`
（glib 交叉编译需要宿主 glib-compile-resources）、`bison/flex`。

## 4. 部署到开发板

```bash
# 在编译服务器上打包后传到板子
scp third-party/gstreamer/gstreamer-aarch64-deploy.tar.gz root@192.168.137.77:/tmp/

# 板子上解压到 /usr/local
ssh root@192.168.137.77
tar -xzf /tmp/gstreamer-aarch64-deploy.tar.gz -C /usr/local
```

板子环境变量已由 `gst_install.sh` 写入 `/etc/profile.d/gstreamer.sh`（登录 shell 自动生效）：

```sh
export PATH=/usr/local/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
export LD_PRELOAD=/usr/local/lib/libglibc230_compat.so
export GST_PLUGIN_SYSTEM_PATH=/usr/local/lib/gstreamer-1.0
export GST_PLUGIN_SCANNER=/usr/local/libexec/gstreamer-1.0/gst-plugin-scanner
export GST_REGISTRY=/usr/local/var/gst-registry.bin
```

验证：

```bash
. /etc/profile.d/gstreamer.sh
gst-inspect-1.0 --version     # GStreamer 1.22.12
gst-inspect-1.0 webrtcbin     # WebRTC Bin
gst-inspect-1.0 x264enc       # x264 H.264 Encoder
```

## 5. WebRTC 推流到阿里云 SRS

### 5.1 whipsink 的替代品：whip_push

GStreamer **1.22 没有 whipsink**（1.24+ 才有，且依赖 libsoup3/nghttp2/sqlite）。
本方案用 `webrtcbin` + 自研 `whip_push` 完成信令（纯 socket，HTTPS 用 SDK OpenSSL，自签证书免校验）：

1. `create-offer → set-local-description → 等 ICE gathering 完成`（非 trickle，一次 POST 搞定）
2. `POST SDP → WHIP 端点`，解析 201 应答 SDP → `set-remote-description`
3. answer 生效后 webrtcbin 创建 sink pad → 链接编码器 → 切 PLAYING

### 5.2 推流命令

```bash
# 彩条测试流（快捷方式，flex_srs.sh test = 彩条自测推流）
flex_srs.sh test

# 完整写法
whip_push http://121.196.101.253:1985/rtc/v1/whip/?app=live&stream=test \
  "videotestsrc is-live=true pattern=smpte ! video/x-raw,width=1280,height=720,framerate=30/1 \
   ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast bitrate=2000 key-int-max=30 \
   ! rtph264pay config-interval=-1 pt=96"
```

- SRS 的 WHIP 端口 1985 是 **HTTP**，URL 写 `http://` 即可（无证书问题）。
- 换真实码流时，把第一个元素换成实际源（如 `v4l2src`），其余编码部分不变。

### 5.3 拉流验证（浏览器 / ffprobe）

- **浏览器 WebRTC 播放页**：打开 `http://121.196.101.253:8080/players/rtc_player.html?autostart=true&stream=test`
- **HTTP-FLV**：`ffprobe http://121.196.101.253:8080/live/test.flv`
- **SRS 状态 API**：
  ```bash
  curl http://121.196.101.253:1985/api/v1/streams/   # publish.active:true, video 1280x720, recv_bytes 增长
  ```

本次验证结果：FLV 拉流 `recv_bytes 2.3MB+`、抽帧彩条图像无花屏。

### 5.4 RTSP → WebRTC 转发（flex_vision / 任意 RTSP 源，不转码直通）

whip_push 现已支持**动态 pad 源**（rtspsrc），可以直接把板子上 flex_vision 或任何 RTSP 流
转发为 WebRTC，**不重新编码**（depay → parse → pay 纯透传，CPU 占用极低）：

```bash
# 板子上运行（源为 flex_vision 的 RTSP，改为实际地址）
whip_push http://121.196.101.253:1985/rtc/v1/whip/?app=live&stream=rtsp2 \
  "rtspsrc location=rtsp://127.0.0.1:554/ch0 protocols=tcp latency=100 \
   ! rtph264depay ! h264parse ! rtph264pay config-interval=-1 pt=96"
```

工具内部自动处理了三个关键问题（也是最容易踩的坑）：

1. **valve 门控**：自动在流水线尾部加 `valve drop=true`，等 webrtcbin 的
   `connection-state` 变为 CONNECTED 后才放行数据。否则 rtspsrc 这类零缓冲源
   在 ICE/DTLS 建立完成前就灌数据，会被 webrtcbin 以 `not-linked` 拒绝并立即报错退出。
2. **动态 pad 补链**：rtspsrc 在解析时没有 pad，`gst_parse_bin_from_description`
   不会为它建立延迟链接（反而把 depay 的 sink 误 ghost 成 bin 的外部端口）。
   工具会给"无 sink pad 的源元素"手动挂 `pad-added` 补链，并清掉误建的 ghost sink pad。
3. **glibc 兼容**：部署时需 `libglibc230_compat.so`（LD_PRELOAD），见 `/etc/profile.d/gstreamer.sh`。

实测结果（2026-11-10）：板子拉本地 RTSP（彩条）→ WHIP 推 SRS 双路流 → FLV 拉流解码，彩条无花屏。

### 5.5 取流方式选型：RTSP vs VENC 直连

| 方式 | 链路 | 优点 | 缺点 | 适用 |
|---|---|---|---|---|
| **RTSP（flex_vision）** | VENC→flex_vision RTSP→rtspsrc→WebRTC | 零代码、不转码、即改即用 | 多一跳回环网络、依赖 flex_vision 运行、延迟 +100~500ms | 快速验证、Demo、与现有业务共存 |
| **VENC 直连（appsrc）** | AX_VENC_GetStream→appsrc→WebRTC | 延迟最低、无回环、不依赖其他进程、可自主控制码流 | 需写 C 程序对接 SDK msp 库（/soc/lib），要处理 ISP 管线初始化 | 生产部署、低延迟场景 |
| 422/YUV 直读 | ISP frame → appsrc → 编码 → WebRTC | 完全自主（编码参数、分辨率实时可调） | 需要实现整条 ISP→编码链路 | 特殊需求 |

**建议**：先用 RTSP 方案跑通业务（改动为零），有低延迟/独立进程需求再写 VENC 直连程序。
VENC 直连的程序骨架：

```c
// 板子上编译: gcc venc_webrtc.c $(pkg-config --cflags --libs gstreamer-1.0 ...) \
//   -I/soc/include -L/soc/lib -lax_venc -lax_sys -lax_isp
gst_init(...);
pipeline: appsrc(is-live=true, format=time) ! h264parse ! rtph264pay ! (whip_push 同款 webrtcbin+WHIP)
// VENC 回调线程:
AX_VENC_ChnFd = AX_VENC_GetChnFd(...);  // 或 AX_VENC_GetStream 循环
select()/poll fd → AX_VENC_GetStream(chn, 100ms) → 拿到 AX_VENC_STREAM_T
→ gst_app_src_push_buffer(appsrc, 将 stream.pu8Addr 每帧打包成 GstBuffer, PTS 用 AX_SYS_GetCurPTS)
→ AX_VENC_ReleaseStream
```

### 5.6 推流到阿里云 SRS（公网）

服务器 `121.196.101.253` 已装 SRS 6.0.195（`/usr/local/srs/srs-server-6.0-r3`，配置
`conf/whip.conf`），端口：1985 HTTP-API(WHIP/WHEP)、8000 TCP+UDP WebRTC、
8080 HTTP-FLV、1935 RTMP。

**WHIP 直推**：板上 `/usr/local/bin/flex_srs.sh`
→ `http://121.196.101.253:1985/rtc/v1/whip/?app=live&stream=live1`。

**WHIP 直推公网的码率红线（重要实测结论）**：WHIP 走 UDP，公网丢包对大 IDR
帧致命。8Mbps CBR 下一个 IDR 有数百个 RTP 分片，被打碎后 SRS 的 RTC→RTMP 桥
永远组不出完整关键帧（FLV/RTMP 输出 0 字节）。把 flex_vision `[Encode]`
`u32Bitrate` 从 8192 降到 **2048 Kbps**（重启 flex_vision 生效）后，
IDR 体积缩小约 4 倍，WHIP 直推阿里云完全打通（8s FLV 拉 1.9MB≈2Mbps，
抽帧验证无花屏）。**公网 WHIP 直推的可用码率上限约 2~3Mbps**。
局域网推 WHIP 丢包≈0，8Mbps 也无此问题。板上无法输出低分辨率：flex_vision 的 sensor 配置是
传感器原生 2592×1944，VENC 直接编码 ISP 输出，ini 无 crop/scale 项；
axenc 硬编需 axmm 设备 ctx（与 flex 冲突），板上也没有 /dev/video*。

**WHIP 方式**：板上 `/usr/local/bin/flex_srs.sh`
→ `http://121.196.101.253:1985/rtc/v1/whip/?app=live&stream=live1`。

**关键坑（WHIP+SRS）**：SRS 的 SDP 协商要求 offer 的 video m-line 带 `a=ssrc:`
行（浏览器会带，webrtcbin 不带），否则 SRS 返回**没有 m-line 的残缺 answer**，
webrtcbin 报 "Answer doesn't have the same number of m-lines as the offer"。
`whip_push` 已内置修复：pipeline 启动前把 rtph264pay 的 SSRC 固定为 1111111，
并在 offer 末尾注入 `a=ssrc:1111111 msid:live video0` + `cname` 行。

观看方式（任选，RTMP 推流和 WHIP 推流均适用）：

| 方式 | 地址 |
|---|---|
| 浏览器 WebRTC 播放页 | `http://121.196.101.253:8080/players/rtc_player.html?autostart=true&stream=live1` |
| WHEP 拉流信令 | `http://121.196.101.253:1985/rtc/v1/whep/?app=live&stream=live1` |
| HTTP-FLV（VLC/ffplay） | `http://121.196.101.253:8080/live/live1.flv` |
| RTMP | `rtmp://121.196.101.253:1935/live/live1` |

实测（2026-11-10）：
- WHIP 直推 @8Mbps：信令/DTLS 正常、API 显示 video=Baseline 5.1 2592×1944，
  但公网丢包下 FLV/RTMP 输出 0 字节（IDR 组帧失败）；
- 降码率到 2Mbps 后 WHIP 直推：FLV 8 秒拉 1.9MB，抽帧画面清晰无花屏；
- 改 RTMP 推（8Mbps）：FLV 6 秒拉 5.4MB，画面正常，WebRTC 播放页可用。

## 6. 踩坑记录（重要）

| # | 问题 | 根因 | 解决 |
|---|------|------|------|
| 1 | meson 报 `Option dtrace value disabled is not boolean` | glib 的 dtrace/systemtap 是 boolean，selinux 是 feature | build.sh 按选项类型自动转换 enabled/disabled ↔ true/false |
| 2 | `Dependency 'libpcre' required` | glib 2.72 仍用 PCRE1（PCRE2 是 2.73 才换） | 补编 pcre-8.45（sourceforge） |
| 3 | 链接 undefined `ffi_*` | libffi 3.4.4 在 Debian 系默认装到 `lib64` | 所有构建显式 `--libdir=$STAGE/lib`，并把 lib64 内容合并回 lib |
| 4 | libidn2 编译 `./gendata: Exec format error` | gendata/gentr46map 是用目标架构编的、却要在宿主上运行 | 用宿主 gcc 预生成 `data.c`/`tr46map_data.c`，再交叉编译库本体 |
| 5 | libidn2 examples 链接失败 | examples 需要目标 libidn2 可执行环境 | 只 `make -C lib && make -C lib install`，跳过 examples |
| 6 | libnice 报需要 GnuTLS/OpenSSL | openssl staging 步骤排在 libnice 之后 | 调整顺序；且 SDK rootfs 里没有 openssl 头文件，改用 `third-party/openssl/{include,lib}` |
| 7 | 板子报 `GLIBC_2.33 not found` | 工具链 sysroot 是 glibc 2.33，板子是 2.30 | `apps/patch_glibc_ver.py` 三步降级（.dynstr 字符串等长替换 + vna_hash 重算 + versym→无版本） |
| 8 | 补丁后报 `undefined symbol: stat64, version GLIBC_2.17` | aarch64 glibc 2.30 没有 stat64（2.33 才新增） | `libglibc230_compat.so` 用 syscall 实现这 4 个符号，`LD_PRELOAD` 加载 |
| 9 | `External plugin loader failed` | 打包漏了 libexec | install/tarball 增加 `libexec/`（gst-plugin-scanner） |
| 10 | `Client sent an HTTP request to an HTTPS server` | 早期本地 HTTPS 接收端强制 HTTPS | whip_push 支持 https（OpenSSL，VERIFY_NONE）；SRS WHIP 为 HTTP 无此问题 |
| 11 | `streaming stopped, reason not-linked` | sink pad 在 answer 协商后才出现，源先 PLAYING 就报错 | 先 PAUSED，pad-added 链接成功后再切 PLAYING |
| 12 | x264 插件没编出来 | ugly 默认 `-Dx264=disabled` 且属 GPL | `-Dx264=enabled -Dgpl=enabled` |
| 13 | SRS 返回 131B 残缺 answer，报 `Answer doesn't have the same number of m-lines` | SRS 协商代码只有在 offer 带 `a=ssrc:` 行时才把 track 加入 stream_desc；webrtcbin 的 offer 不带 ssrc | whip_push 固定 rtph264pay ssrc=1111111 并在 offer 注入 `a=ssrc` + `cname` 行 |

## 7. 常见排查

```bash
# 板子：插件扫描
GST_DEBUG=3 gst-inspect-1.0 webrtcbin

# 板子：看推流日志
tail -f /tmp/whip_push.log

# 板子：手动跑（前台，带详细日志）
GST_DEBUG=3 whip_push http://121.196.101.253:1985/rtc/v1/whip/?app=live&stream=test "flex_srs.sh test 里的 pipeline"

# SRS 状态：推流会话与码率
curl http://121.196.101.253:1985/api/v1/streams/

# 检查 glibc 版本需求是否还有残留
objdump -T /usr/local/lib/libglib-2.0.so.0 | grep GLIBC_2.3
```

## 8. 已知限制与后续工作

- **真实摄像头**：当前板子 `/dev/video*` 不存在，AX650 的 camera/ISP/VENC 走 SDK msp 管线（`/dev/dri` 存在）。
  要推真实画面需把 SDK 的 VENC 输出接入 GStreamer（自定义 appsrc 桥接，或 `v4l2src` 若后续 BSP 暴露 V4L2 节点）。
- **音频**：当前仅视频轨；需要音频再补 `alsasrc ! opusenc ! rtpopuspay` 并在 add-transceiver 处加音频 transceiver。
- **sqlite/libsoup**：tarballs 已备好但未编（1.22 无 whipsink 用不上）；升级 GStreamer ≥1.24 用官方 whipsink 时再启用。
- 硬件编码（AX650 VENC）与本 GStreamer 管线的桥接是下一步优化方向（x264enc 720p30 在 8 核 A55 上 CPU 占用较高）。

## 9. 快速命令速查

```bash
# ===== 阿里云服务器 =====
cd /root/sdk/AX650_SDK_V3.16.0_20261103160857_NO5387/third-party/gstreamer
bash download.sh          # 下载源码
bash build.sh             # 编译
bash build.sh install     # 装入 rootfs + 生成部署包
bash build.sh clean       # 全部清理

# ===== 开发板 =====
. /etc/profile.d/gstreamer.sh
flex_srs.sh test          # 彩条自测推流（默认推到阿里云 SRS，流名 test）
flex_srs.sh [流名]        # flex ch1 推流到阿里云 SRS（默认 live1）
killall whip_push         # 停止推流

# ===== 观看（浏览器 / 拉流）=====
# 浏览器: http://121.196.101.253:8080/players/rtc_player.html?autostart=true&stream=live1
ffplay http://121.196.101.253:8080/live/live1.flv
curl http://121.196.101.253:1985/api/v1/streams/
```
