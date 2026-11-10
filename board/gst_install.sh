#!/bin/sh
# ============================================================
# gst_install.sh — AX650 GStreamer 运行时一键安装（板端执行）
# ============================================================
# 在线安装（默认走 GitHub Release）:
#   curl -fsSL https://raw.githubusercontent.com/BranWangQiZhi/ax650-gstreamer-delivery/main/board/gst_install.sh | sh
#
# 指定版本 / GitHub 镜像 / 静态源 / 离线包:
#   sh install.sh -v 1.22.12-r20261110
#   GST_MIRROR=https://ghproxy.net/ sh install.sh
#   sh install.sh --static -b http://121.40.107.62:8080/gst
#   sh install.sh -f /tmp/gstreamer-aarch64-deploy.tar.gz
#
# 参数:
#   -g, --github [o/r] GitHub 源（默认内置仓库，本脚本默认模式）
#       --static       改用静态目录源（-b 指定的 http 站点）
#   -b, --base URL     静态源根地址（隐含 --static）
#   -v, --version V    指定版本/tag；默认取最新
#   -d, --dest DIR     安装前缀（默认 /usr/local）
#   -f, --file PATH    使用本地 tar 包，不联网
#   -n, --check        只体检，不安装
#   -F, --force        检测到 whip_push 在跑时强制停止并安装
#   -h, --help         显示帮助
#
# 注意: 本脚本可能被 curl | sh 方式执行，标准输入是管道，
#       因此全程不做交互式提问。
# ============================================================
set -e

BASE=${GST_BASE:-http://121.40.107.62:8080/gst}
GH_REPO=${GST_GH:-BranWangQiZhi/ax650-gstreamer-delivery}
GH_BASE=https://github.com
MODE=github
VERSION=
DEST=/usr/local
LOCAL_TAR=
FORCE=0
CHECK=0
TARNAME=gstreamer-aarch64-deploy.tar.gz

usage() {
  cat <<'USAGE'
用法: sh install.sh [选项]

  -g, --github [o/r]  从 GitHub Release 安装（默认，仓库内置）
      --static        改用静态目录源（配合 -b）
  -b, --base URL      静态源根地址，隐含 --static
  -v, --version V     指定版本或 tag，默认取最新
  -d, --dest DIR      安装前缀（默认 /usr/local）
  -f, --file PATH     用本地 tar 包安装，不联网
  -n, --check         只体检当前安装情况，不改动任何文件
  -F, --force         检测到 whip_push 在跑时强制停止并安装
  -h, --help          显示本帮助

示例:
  curl -fsSL https://raw.githubusercontent.com/BranWangQiZhi/ax650-gstreamer-delivery/main/board/gst_install.sh | sh
  sh install.sh -n
  GST_MIRROR=https://ghproxy.net/ sh install.sh
  sh install.sh --static -b http://121.40.107.62:8080/gst
  sh install.sh -f /tmp/gstreamer-aarch64-deploy.tar.gz
USAGE
  exit 0
}

die() { printf '\n[失败] %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
step() { printf '\n=== %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -g|--github)
      MODE=github
      if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then GH_REPO=$2; shift; fi
      shift ;;
    --static)     MODE=static; shift ;;
    -b|--base)    MODE=static; BASE=$2; shift 2 ;;
    -v|--version) VERSION=$2; shift 2 ;;
    -d|--dest)    DEST=$2; shift 2 ;;
    -f|--file)    LOCAL_TAR=$2; shift 2 ;;
    -n|--check)   CHECK=1; shift ;;
    -F|--force)   FORCE=1; shift ;;
    -h|--help)    usage ;;
    *) die "未知参数: $1（用 -h 查看用法）" ;;
  esac
done

BASE=${BASE%/}

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
  if [ "$FORCE" = "1" ]; then
    say "运行中    : 检测到 whip_push，按 --force 要求停止"
    killall whip_push 2>/dev/null || true
    sleep 1
  else
    die "whip_push 正在推流（pid $RUNNING），请先 'killall whip_push' 再装，或加 --force"
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
  say "发布源    : $( [ "$MODE" = "github" ] && echo "GitHub $GH_REPO" || echo "$BASE")"
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
if [ -n "$LOCAL_TAR" ]; then
  step "使用本地安装包"
  [ -f "$LOCAL_TAR" ] || die "文件不存在: $LOCAL_TAR"
  TAR="$LOCAL_TAR"
  VERSION=${VERSION:-local}
  say "包        : $LOCAL_TAR ($(du -k "$LOCAL_TAR" | awk '{print int($1/1024)}')MB)"
else
  MIRROR=${GST_MIRROR:-}
  if [ "$MODE" = "github" ]; then
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
  else
    if [ -z "$VERSION" ]; then
      step "查询最新版本"
      http_get "$BASE/latest" "$TMP/latest" || die "无法访问 $BASE/latest（检查网络/源地址）"
      VERSION=$(tr -d ' \t\r\n' < "$TMP/latest")
      [ -n "$VERSION" ] || die "latest 文件为空，发布源可能不完整"
    fi
    say "来源      : $BASE"
    say "版本      : $VERSION"
    PKG_URL="$BASE/$VERSION/$TARNAME"
    SHA_URL="$BASE/$VERSION/sha256"
  fi

  step "下载安装包"
  say "地址      : $PKG_URL"
  http_get "$PKG_URL" "$TMP/$TARNAME" || die "下载失败: $PKG_URL
  排查: 板子能否访问外网？GitHub 慢/被墙可加 GST_MIRROR=https://ghproxy.net/ 重试
        仓库或 Release 是否已发布？$GH_BASE/$GH_REPO/releases"
  TAR="$TMP/$TARNAME"

  SZ=$(du -k "$TAR" | awk '{print $1}')
  say "大小      : $((SZ / 1024))MB"
  [ "$SZ" -gt 1024 ] || die "下载文件过小（${SZ}KB），可能拿到的是错误页"

  step "校验 SHA256"
  if http_get "$SHA_URL" "$TMP/sha256" 2>/dev/null && [ -s "$TMP/sha256" ]; then
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
fi

# ---------------- 解包 ---------------- #
step "校验包结构"
tar -tzf "$TAR" >/dev/null 2>&1 || die "tar 包损坏，无法解压"
tar -tzf "$TAR" | grep -qx 'bin/whip_push' || die "包内缺少 bin/whip_push，不是预期的部署包"

SCANNER_OK=1
for must in bin/gst-inspect-1.0 lib/libgstreamer-1.0.so.0 lib/gstreamer-1.0 lib/libglibc230_compat.so; do
  tar -tzf "$TAR" | grep -q "^$must" || say "警告      : 包内未找到 $must"
done
if tar -tzf "$TAR" | grep -qx 'libexec/gstreamer-1.0/gst-plugin-scanner'; then
  say "scanner   : OK"
else
  SCANNER_OK=0
  say "警告      : 包内缺少 libexec/gstreamer-1.0/gst-plugin-scanner"
  say "            装上会报 External plugin loader failed（可继续，但插件扫描会退回进程内）"
fi
say "结构      : OK"

step "解压到 $DEST"
mkdir -p "$DEST"
printf '解压中（约 16MB，板上可能需 10~40 秒）...\n'
tar -xzf "$TAR" -C "$DEST" || die "解压失败"
GOT_DIRS=$(tar -tzf "$TAR" | awk -F/ 'NF>1{print $1}' | sort -u | tr '\n' ',')
say "完成      : $DEST/{${GOT_DIRS%,}}"

# ---------------- 运行环境变量 ----------------
step "写入 /etc/profile.d/gstreamer.sh"
mkdir -p "$DEST/var"
PROFILE=/etc/profile.d/gstreamer.sh
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
VER_LINE=$(gst_env "$DEST/bin/gst-inspect-1.0" --version 2>&1 | head -1) || FAIL=1
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
say "推流自测     :  whip_test.sh"
say "卸载         :  rm -rf $DEST/bin/whip_push $DEST/lib/gstreamer-1.0 \\"
say "                 $DEST/libexec/gstreamer-1.0 $PROFILE"

if [ "$SCANNER_OK" = "0" ]; then
  printf '\n[注意] 缺 gst-plugin-scanner，插件注册改走进程内扫描（能用，但首次启动更慢）。\n' >&2
  printf '       要补齐需在编译机重打包: cd gstreamer_module && bash build.sh install\n' >&2
fi

if [ "$FAIL" != "0" ]; then
  printf '\n[注意] 自检有项目未通过，请检查上面的输出（常见原因: 磁盘满、包不完整、glibc 过低）\n' >&2
  exit 3
fi
