# gstreamer_module — AX650 GStreamer 1.22.12 交叉编译模块

> 一句话定位：把 GStreamer 1.22.12 + webrtcbin + 自研 `whip_push` 交叉编译成 aarch64 部署包，
> 供 AX650 开发板（glibc 2.30）通过 `board/gst_install.sh` 一条命令安装。
> 编译/移植细节看 [`docs/GStreamer_WebRTC集成指南.md`](../docs/GStreamer_WebRTC集成指南.md)。

---

## 1. 目录结构

```
gstreamer_module/
├── download.sh                       # 源码包下载（幂等，可重复执行）
├── build.sh                          # 交叉编译主脚本（build / install / clean）
├── Makefile                          # SDK third-party 构建入口（make gstreamer）
├── apps/                             # 自研源码
│   ├── whip_push.c                   #   WHIP 信令客户端（webrtcbin + 极简 HTTP/HTTPS）
│   ├── glibc230_compat.c/.map        #   glibc 2.30 兼容层（stat64/pthread_sigmask 等）
│   └── patch_glibc_ver.py            #   ELF glibc 版本号降级补丁
├── tarballs/                         # [产物] 19 个源码包（download.sh 生成）
├── stage/  src/  out/  build/        # [产物] 编译暂存 sysroot / 解包源码 / 中间目录
├── whip_push  libglibc230_compat.so  # [产物] 交叉编译输出的散装二进制（build.sh 生成）
└── gstreamer-aarch64-deploy.tar.gz   # [产物] 开发板部署包（install 步骤生成，约 16MB）
```

**源码只有 4 个文件 + 3 个脚本**；其余全部是构建产物，均已 gitignore（见仓库根 `.gitignore`），
可随时用 `bash build.sh clean` 清掉、重新生成。

## 2. 快速开始（阿里云编译服务器）

```bash
# 0) 进入 SDK（本模块在 SDK 内的正式位置，见 §4）
cd /root/sdk/AX650_SDK_V3.16.0_20261103160857_NO5387

# 1) 下载源码包（首次约 15~40 分钟）
bash third-party/gstreamer/download.sh

# 2) 交叉编译（增量，重复执行跳过已完成步骤；30~60 分钟）
cd third-party/gstreamer && bash ./build.sh
# 成功输出: GST_BUILD_ALL_DONE

# 3) 装入 SDK rootfs + 生成开发板部署包
bash ./build.sh install
#   → rootfs/rootfs/usr/local/{bin,lib,libexec}
#   → gstreamer-aarch64-deploy.tar.gz（含业务脚本与开机 init 脚本，见 §3）

# 4) 清理（全部中间产物）
bash ./build.sh clean

# 等价入口：走 SDK 构建系统（全量编译，时间较长）
cd ../build && make p=AX650_emmc clean all install axp -j8
```

依赖的本机工具：`meson`、`ninja`（`pip3 install --user meson ninja`）、
`libglib2.0-dev-bin`（宿主 glib-compile-resources）、`bison/flex`。

## 3. 部署包内容（gstreamer-aarch64-deploy.tar.gz）

```
bin/                  whip_push + gst-launch/gst-inspect 等运行时
                      + flex_start.sh / flex_srs.sh / rtp_bridge.sh   ← 业务脚本(打包时取自 ../board)
lib/                  GStreamer 库 + 插件 + libglibc230_compat.so
libexec/gstreamer-1.0/  gst-plugin-scanner
etc/init.d/           S50vsync（PWM 同步前置）+ S98imu（ICM-45686 IMU 驱动装载）
```

打包逻辑在 `build.sh` 的 `install_rootfs`：从 `../board/` 取业务脚本与开机脚本一并打入
（SDK 内镜像无 `../board` 目录时打印 WARN 跳过，包退化为纯运行时）。

板端安装：上传 `board/gst_install.sh` 后执行（或 `curl | sh`），自动完成
下载 → SHA256 校验 → 解压 → 生成 `/etc/profile.d/gstreamer.sh` → 转装 init 脚本 → 自检。

## 4. 双份镜像说明（位置不可挪）

| 位置 | 说明 |
|---|---|
| `gstreamer_module/`（本目录） | 交付仓库内的编译模块镜像（本 README 所述） |
| `AX650_SDK.../third-party/gstreamer/` | SDK 内的正式位置 |

`build.sh` 依赖 `../../` 相对路径定位 SDK，因此本地镜像不可挪动；两份内容保持对应，
修改任一侧后需手动同步。`install_rootfs` 打包业务脚本时依赖 `../board/` 存在——
只有交付仓库侧的镜像有，SDK 内镜像打包会跳过（纯运行时包）。

## 5. 编译组件清单（按依赖顺序）

zlib → libffi → pcre2 → pcre-8.45 → **glib-2.72.4** → libsrtp-2.5.0 → json-glib（可选）→
libunistring → libidn2 → libpsl（soup 链，当前跳过 sqlite/libsoup）→ **x264** →
**gstreamer 1.22.12** → **gst-plugins-base** → **good**(rtp/rtpmanager/udp/v4l2) →
**ugly**(x264enc，需 `-Dx264=enabled -Dgpl=enabled`) → openssl(取自 SDK) →
**libnice-0.1.21** → **gst-plugins-bad**(webrtc/dtls/srtp) → whip_push → glibc230_compat

## 6. 常见问题

编译踩坑（meson 选项类型、libidn2 交叉编译、glibc 2.30 符号降级、SRS SSRC 协商等 13 条）
集中记录在 [`docs/GStreamer_WebRTC集成指南.md` §6](../docs/GStreamer_WebRTC集成指南.md)。
