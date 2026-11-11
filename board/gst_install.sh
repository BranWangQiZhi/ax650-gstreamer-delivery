#!/bin/sh
# ============================================================
# gst_install.sh — AX650 GStreamer 运行时 + 业务脚本一键安装（板端执行）
# ============================================================
# 新版部署包(gstreamer-aarch64-deploy.tar.gz)内含业务脚本
# (flex_start.sh/flex_srs.sh/rtp_bridge.sh), 本脚本解压后一并装入
# $DEST/bin, 因此一条命令即可完成板端全部安装, 无需 PC 侧 scp 下发。
# ============================================================
# 在线安装（默认走 GitHub Release）:
#   curl -fsSL https://raw.githubusercontent.com/BranWangQiZhi/ax650-gstreamer-delivery/main/board/gst_install.sh | sh
#
# 指定版本 / GitHub 镜像:
#   sh install.sh -v 1.22.12-r20261110
#   GST_MIRROR=https://ghproxy.net/ sh install.sh
#
# 离线安装（板子访问不了 GitHub 时, PC 把仓库整个下发到板上再执行）:
#   sh install.sh -l /tmp/delivery
#   sh install.sh -l /tmp/delivery/gstreamer_module/gstreamer-aarch64-deploy.tar.gz
#
# 参数:
#   -g, --github [o/r] GitHub 源（默认内置仓库，本脚本默认模式）
#   -v, --version V    指定版本/tag；默认取最新
#   -d, --dest DIR     安装前缀（默认 /usr/local）
#   -l, --local PATH   本地安装源：仓库目录或 tar.gz（跳过网络下载）
#   -n, --check        只体检，不安装
#   -F, --force        检测到 whip_push 在跑时强制停止并安装
#   -h, --help         显示帮助
#
# 注意: 本脚本可能被 curl | sh 方式执行，标准输入是管道，
#       因此全程不做交互式提问。
# ============================================================
set -e

GH_REPO=${GST_GH:-BranWangQiZhi/ax650-gstreamer-delivery}
GH_BASE=https://github.com
VERSION=
DEST=/usr/local
FORCE=0
CHECK=0
LOCAL=
LOCAL_BOARD=
TAR=
TARNAME=gstreamer-aarch64-deploy.tar.gz

usage() {
  cat <<'USAGE'
用法: sh install.sh [选项]

  -g, --github [o/r]  从 GitHub Release 安装（默认，仓库内置）
  -v, --version V     指定版本或 tag，默认取最新
  -d, --dest DIR      安装前缀（默认 /usr/local）
  -l, --local PATH    本地安装源（仓库目录或 tar.gz），离线安装，不走网络
  -n, --check         只体检当前安装情况，不改动任何文件
  -F, --force         检测到 whip_push 在跑时强制停止并安装
  -h, --help          显示本帮助

示例:
  curl -fsSL https://raw.githubusercontent.com/BranWangQiZhi/ax650-gstreamer-delivery/main/board/gst_install.sh | sh
  sh install.sh -n
  GST_MIRROR=https://ghproxy.net/ sh install.sh
  sh install.sh -l /tmp/delivery            # 离线：仓库已下发到板上
  sh install.sh -l /tmp/pkg.tar.gz          # 离线：只有部署包
USAGE
  exit 0
}

die() { printf '\n[失败] %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
step() { printf '\n=== %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--github)
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then GH_REPO=$2; shift; fi
      shift ;;
    -v|--version) VERSION=$2; shift 2 ;;
    -d|--dest)    DEST=$2; shift 2 ;;
    -l|--local)   LOCAL=$2; shift 2 ;;
    -n|--check)   CHECK=1; shift ;;
    -F|--force)   FORCE=1; shift ;;
    -h|--help)    usage ;;
    *) die "未知参数: $1（用 -h 查看用法）" ;;
  esac
done

# 以目标安装目录的运行环境执行命令。只注入实际存在的项：
# LD_PRELOAD 指向不存在的 .so 会让所有子进程直接起不来。
gst_env() {
  ENVARGS="LD_LIBRARY_PATH=$DEST/lib"
  if [ -f "$DEST/lib/libglibc230_compat.so" ]; then
    ENVARGS="LD_PRELOAD=$DEST/lib/libglibc230_compat.so $ENVARGS"
  fi
  if [ -f "$DEST/libexec/gstreamer-1.0/gst-plugin-scanner" ]; then
    ENVARGS="$ENVARGS GST_PLUGIN_SCANNER=$DEST/libexec/gstreamer-1.0/gst-plugin-scanner"
  fi
  ENVARGS="$ENVARGS GST_PLUGIN_SYSTEM_PATH=$DEST/lib/gstreamer-1.0 GST_REGISTRY=$DEST/var/gst-registry.bin"
  env $ENVARGS "$@"
}

# ---------------- 基础环境体检 ----------------
step "体检"
ARCH=$(uname -m)
say "架构      : $ARCH"
case "$ARCH" in
  aarch64|arm64) ;;
  *) die "此包为 aarch64 构建，当前 $ARCH 无法使用" ;;
esac

[ "$(id -u)" = "0" ] || die "需要 root 权限（写 $DEST 与 /etc/profile.d）"

LIBC=$(ldd --version 2>/dev/null | head -1 | tr -d '\r')
if [ -n "$LIBC" ]; then say "glibc     : $LIBC"; fi

FREE_KB=$(df -k "$DEST" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "$FREE_KB" ] && [ "$FREE_KB" -lt 40960 ] 2>/dev/null; then
  say "磁盘告警  : $DEST 仅剩 $((FREE_KB / 1024))MB，建议先清理（需要约 40MB）"
fi

# 正在推流时替换 .so 会报 Text file busy
RUNNING=0
if pidof whip_push >/dev/null 2>&1; then
  RUNNING=$(pidof whip_push 2>/dev/null || echo 1)
elif ps 2>/dev/null | grep -v grep | grep -q whip_push; then
  RUNNING=1
fi
if [ "$RUNNING" != "0" ]; then
  EXE=$(ls -l "/proc/$RUNNING/exe" 2>/dev/null | sed 's/.*-> //')
  case "$EXE" in
    "$DEST"/*) IN_USE=1 ;;
    *)         IN_USE=0 ;;
  esac
  if [ "$IN_USE" = "0" ]; then
    # 推流进程不在本次安装目录（例如演练装到 /tmp），替换文件不会 Text file busy
    say "运行中    : whip_push(pid $RUNNING) 位于 ${EXE:-未知}，与 $DEST 不冲突"
  elif [ "$FORCE" = "1" ]; then
    say "运行中    : 检测到 whip_push，按 --force 要求停止"
    killall whip_push 2>/dev/null || true
    sleep 1
  else
    die "whip_push 正在推流（pid $RUNNING, $EXE），请先 'killall whip_push' 再装，或加 --force"
  fi
else
  say "运行中    : 无 whip_push 进程"
fi

if [ "$CHECK" = "1" ]; then
  step "当前安装情况"
  if [ -x "$DEST/bin/gst-inspect-1.0" ]; then
    _ver=$(gst_env "$DEST/bin/gst-inspect-1.0" --version 2>/dev/null | head -1)
    say "已安装版本: ${_ver:-（无法执行）}"
    say "安装路径  : $DEST"
  else
    say "未安装（$DEST/bin/gst-inspect-1.0 不存在）"
  fi
  say "发布源    : GitHub $GH_REPO"
  exit 0
fi

# ---------------- 下载器 ----------------
http_get() { # $1=url $2=输出文件
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 10 --retry 2 -o "$2" "$1" && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$2" "$1" && return 0
  fi
  return 1
}

TMP=$(mktemp -d 2>/dev/null || echo "/tmp/gst-install.$$")
mkdir -p "$TMP"
cleanup() { rm -rf "$TMP" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

# ---------------- 定位版本与安装包 ----------------
MIRROR=${GST_MIRROR:-}
if [ -n "$LOCAL" ]; then
  # ---------- 离线模式: 仓库/部署包已由 PC 下发到板上 ----------
  [ -e "$LOCAL" ] || die "本地路径不存在: $LOCAL"
  if [ -d "$LOCAL" ]; then
    SRC=$(cd "$LOCAL" && pwd)
    for cand in "$SRC/$TARNAME" "$SRC/gstreamer_module/$TARNAME"; do
      if [ -f "$cand" ]; then TAR=$cand; break; fi
    done
    [ -n "$TAR" ] || die "在 $SRC 下找不到 $TARNAME（确认下发的是整个仓库而不是部分文件）"
    if [ -d "$SRC/board" ]; then
      LOCAL_BOARD=$SRC/board
    elif [ -d "$SRC/../board" ]; then
      LOCAL_BOARD=$(cd "$SRC/../board" && pwd)
    fi
  else
    TAR=$(cd "$(dirname "$LOCAL")" && pwd)/$(basename "$LOCAL")
    [ -f "$TAR" ] || die "本地包不存在: $TAR"
    [ -d "$(dirname "$TAR")/board" ] && LOCAL_BOARD=$(dirname "$TAR")/board
  fi
  cp -f "$TAR" "$TMP/$TARNAME" || die "无法读取本地包: $TAR"
  TAR="$TMP/$TARNAME"
  VERSION="local"
  say "来源      : 本地 $LOCAL"
  if [ -n "$LOCAL_BOARD" ]; then
    say "业务脚本  : $LOCAL_BOARD（解压后一并装入 $DEST/bin）"
  fi
else
  if [ -n "$VERSION" ]; then
    REL="download/$VERSION"
  else
    REL="latest/download"
    VERSION="latest"
  fi
  PKG_URL="${MIRROR}${GH_BASE}/${GH_REPO}/releases/${REL}/${TARNAME}"
  SHA_URL="${MIRROR}${GH_BASE}/${GH_REPO}/releases/${REL}/sha256"
  say "来源      : GitHub ${GH_REPO}"
  say "版本      : $( [ "$VERSION" = "latest" ] && echo "latest（跟随最新 Release）" || echo "$VERSION")"
  if [ -n "$MIRROR" ]; then say "镜像      : $MIRROR"; fi

  step "下载安装包"
  say "地址      : $PKG_URL"
  http_get "$PKG_URL" "$TMP/$TARNAME" || die "下载失败: $PKG_URL
  排查: 板子能否访问外网？GitHub 慢/被墙可加 GST_MIRROR=https://ghproxy.net/ 重试
        板子完全不能出网时，改离线安装: sh install.sh -l <仓库目录>
        仓库或 Release 是否已发布？$GH_BASE/$GH_REPO/releases"
  TAR="$TMP/$TARNAME"
fi

SZ=$(du -k "$TAR" | awk '{print $1}')
say "大小      : $((SZ / 1024))MB"
[ "$SZ" -gt 1024 ] || die "安装包过小（${SZ}KB），可能拿到的是错误页或包不完整"

step "校验 SHA256"
if [ -z "$SHA_URL" ]; then
  say "跳过      : 离线安装（来源为本地下发文件，不做远端校验）"
elif http_get "$SHA_URL" "$TMP/sha256" 2>/dev/null && [ -s "$TMP/sha256" ]; then
  WANT=$(awk '{print $1}' "$TMP/sha256")
  if command -v sha256sum >/dev/null 2>&1; then
    GOT=$(sha256sum "$TAR" | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    GOT=$(openssl dgst -sha256 "$TAR" | sed 's/.*= //')
  else
    GOT=
    say "跳过      : 板上没有 sha256sum/openssl，无法校验"
  fi
  if [ -n "$GOT" ]; then
    if [ "$GOT" = "$WANT" ]; then
      say "一致      : $GOT"
    else
      die "校验失败！期望 $WANT，实际 $GOT（下载损坏或被替换）"
    fi
  fi
else
  say "跳过      : 发布源未提供 sha256"
fi

# ---------------- 解包 ---------------- #
step "校验包结构"
TARLIST=$(tar -tzf "$TAR" 2>/dev/null) || die "tar 包损坏，无法解压"
echo "$TARLIST" | grep -qx 'bin/whip_push' || die "包内缺少 bin/whip_push，不是预期的部署包"

# 离线模式下业务脚本/开机脚本可能只在 board/ 里，安装时再补齐
board_has() { [ -n "$LOCAL_BOARD" ] && [ -f "$LOCAL_BOARD/$1" ]; }

SCANNER_OK=1
for must in bin/gst-inspect-1.0 lib/libgstreamer-1.0.so.0 lib/gstreamer-1.0 lib/libglibc230_compat.so; do
  echo "$TARLIST" | grep -q "^$must" || say "警告      : 包内未找到 $must"
done
if echo "$TARLIST" | grep -qx 'libexec/gstreamer-1.0/gst-plugin-scanner'; then
  say "scanner   : OK"
else
  SCANNER_OK=0
  say "警告      : 包内缺少 libexec/gstreamer-1.0/gst-plugin-scanner"
  say "            装上会报 External plugin loader failed（可继续，但插件扫描会退回进程内）"
fi
SCRIPTS_OK=1
for s in flex_start.sh flex_srs.sh rtp_bridge.sh; do
  if echo "$TARLIST" | grep -qx "bin/$s"; then
    say "脚本      : bin/$s OK"
  elif board_has "$s"; then
    say "脚本      : bin/$s 取自本地 board/（安装时补齐）"
  else
    SCRIPTS_OK=0
    say "警告      : 包内未找到 bin/$s，本地也没有（业务脚本需另行下发）"
  fi
done
INIT_OK=1
for f in S50vsync S98imu; do
  if echo "$TARLIST" | grep -qx "etc/init.d/$f"; then
    say "开机脚本  : etc/init.d/$f OK"
  elif board_has "$f"; then
    say "开机脚本  : etc/init.d/$f 取自本地 board/（安装时补齐）"
  else
    INIT_OK=0
    say "警告      : 包内未找到 etc/init.d/$f，本地也没有（对应开机前置需手工执行）"
  fi
done
say "结构      : OK"

step "解压到 $DEST"
mkdir -p "$DEST"
printf '解压中（约 16MB，板上可能需 10~40 秒）...\n'
tar -xzf "$TAR" -C "$DEST" || die "解压失败"

# 离线模式: 仓库里的部署包可能只含运行时, 业务脚本/开机脚本从本地 board/ 补齐
# (开机脚本先落到 $DEST/etc/init.d 暂存位置, 由下面统一转装到 /etc/init.d)
if [ -n "$LOCAL_BOARD" ]; then
  BADDED=""
  for s in flex_start.sh flex_srs.sh rtp_bridge.sh; do
    if [ -f "$LOCAL_BOARD/$s" ]; then
      cp -f "$LOCAL_BOARD/$s" "$DEST/bin/$s" && chmod 755 "$DEST/bin/$s" && BADDED="$BADDED $s"
    fi
  done
  if [ -f "$LOCAL_BOARD/S50vsync" ] || [ -f "$LOCAL_BOARD/S98imu" ]; then
    mkdir -p "$DEST/etc/init.d"
    for f in S50vsync S98imu; do
      if [ -f "$LOCAL_BOARD/$f" ]; then
        cp -f "$LOCAL_BOARD/$f" "$DEST/etc/init.d/$f" && chmod 755 "$DEST/etc/init.d/$f" && BADDED="$BADDED $f"
      fi
    done
  fi
  if [ -n "$BADDED" ]; then
    say "本地补齐  :$BADDED"
  fi
fi

# 业务脚本确保可执行(打包方 cp 可能丢失执行位)
for s in "$DEST"/bin/*.sh; do
  [ -f "$s" ] && chmod 755 "$s"
done
# 开机 init 脚本: 包内是暂存位置($DEST/etc/init.d), 转装到系统 /etc/init.d/
if [ -f "$DEST/etc/init.d/S50vsync" ] || [ -f "$DEST/etc/init.d/S98imu" ]; then
  mkdir -p /etc/init.d
  for f in S50vsync S98imu; do
    if [ -f "$DEST/etc/init.d/$f" ]; then
      cp "$DEST/etc/init.d/$f" "/etc/init.d/$f"
      chmod 755 "/etc/init.d/$f"
    fi
  done
  rm -rf "$DEST/etc"
fi
GOT_DIRS=$(tar -tzf "$TAR" | awk -F/ 'NF>1{print $1}' | sort -u | tr '\n' ',')
say "完成      : $DEST/{${GOT_DIRS%,}}"

# ---------------- 运行环境变量 ----------------
PROFILE=${GST_PROFILE:-/etc/profile.d/gstreamer.sh}
step "写入 $PROFILE"
mkdir -p "$DEST/var"
mkdir -p "$(dirname "$PROFILE")"
{
  printf '# GStreamer runtime — 由 gst_install.sh 生成（%s）\n' "$VERSION"
  printf '# 必须 source 或重新登录，whip_push 才能找到兼容层与插件\n'
  printf 'export PATH=%s/bin:$PATH\n' "$DEST"
  printf 'export LD_LIBRARY_PATH=%s/lib:$LD_LIBRARY_PATH\n' "$DEST"
  if [ -f "$DEST/lib/libglibc230_compat.so" ]; then
    printf 'export LD_PRELOAD=%s/lib/libglibc230_compat.so\n' "$DEST"
  else
    printf '# 未发现 libglibc230_compat.so，跳过 LD_PRELOAD（板子 glibc >= 2.33 时本就不需要）\n'
  fi
  printf 'export GST_PLUGIN_SYSTEM_PATH=%s/lib/gstreamer-1.0\n' "$DEST"
  if [ -f "$DEST/libexec/gstreamer-1.0/gst-plugin-scanner" ]; then
    printf 'export GST_PLUGIN_SCANNER=%s/libexec/gstreamer-1.0/gst-plugin-scanner\n' "$DEST"
  else
    printf '# 未发现 gst-plugin-scanner，不设 GST_PLUGIN_SCANNER（改用进程内扫描）\n'
  fi
  printf 'export GST_REGISTRY=%s/var/gst-registry.bin\n' "$DEST"
} > "$PROFILE"
chmod 644 "$PROFILE"
say "完成      : $PROFILE"

# 版本变更后旧 registry 可能缓存失效路径，删掉让它重扫
rm -f "$DEST/var/gst-registry.bin"

# ---------------- 自检 ----------------
step "自检"

FAIL=0
# 首次执行要扫全部插件并生成 registry, 直接取版本容易拿到空输出/警告行,
# 先预热一次(丢弃结果), 再取版本行
gst_env "$DEST/bin/gst-inspect-1.0" --version >/dev/null 2>&1 || true
VER_LINE=$(gst_env "$DEST/bin/gst-inspect-1.0" --version 2>/dev/null | grep 'GStreamer' | head -1)
case "$VER_LINE" in
  *GStreamer*) ;;
  *) FAIL=1 ;;
esac
say "gst-inspect : ${VER_LINE:-（执行失败）}"

for el in webrtcbin x264enc rtph264pay rtspsrc; do
  if gst_env "$DEST/bin/gst-inspect-1.0" "$el" >/dev/null 2>&1; then
    say "元素 $el : OK"
  else
    say "元素 $el : 缺失"
    FAIL=1
  fi
done

# ---------------- 收尾 ----------------
step "完成"
say "版本      : $VERSION"
say "安装路径  : $DEST"
say "环境文件  : $PROFILE"
printf '\n当前 shell 立即生效:  . %s\n' "$PROFILE"
say "验证         :  gst-inspect-1.0 webrtcbin"
if [ "$SCRIPTS_OK" = "1" ]; then
  say "业务脚本     :  flex_start.sh / flex_srs.sh / rtp_bridge.sh（已装 $DEST/bin）"
fi
if [ "$INIT_OK" = "1" ]; then
  say "开机前置     :  /etc/init.d/S50vsync（PWM 寄存器 + ax_vsync_ctrl.ko）"
  say "                /etc/init.d/S98imu（ICM-45686 IMU 驱动装载）"
  say "                重启自动生效, 无需登录"
fi
if [ "$SCRIPTS_OK" = "1" ]; then
  say "推流自测     :  flex_srs.sh test"
  say "正式推流     :  flex_start.sh && flex_srs.sh"
else
  say "推流自测     :  flex_srs.sh test（业务脚本未随包, 需另行下发）"
fi
say "卸载         :  rm -rf $DEST/bin/whip_push $DEST/lib/gstreamer-1.0 \\"
say "                 $DEST/libexec/gstreamer-1.0 $PROFILE \\"
say "                 $DEST/bin/flex_*.sh $DEST/bin/rtp_bridge.sh \\"
say "                 /etc/init.d/S50vsync /etc/init.d/S98imu"

if [ "$SCANNER_OK" = "0" ]; then
  printf '\n[注意] 缺 gst-plugin-scanner，插件注册改走进程内扫描（能用，但首次启动更慢）。\n' >&2
  printf '       要补齐需在编译机重打包: cd gstreamer_module && bash build.sh install\n' >&2
fi

if [ "$FAIL" != "0" ]; then
  printf '\n[注意] 自检有项目未通过，请检查上面的输出（常见原因: 磁盘满、包不完整、glibc 过低）\n' >&2
  exit 3
fi
