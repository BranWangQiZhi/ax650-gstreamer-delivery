#!/usr/bin/env bash
# ============================================================
# board_deploy.sh — PC 侧一键：取仓库 → 下发到 AX650 板 → 离线安装 → 自检
# ============================================================
# 为什么不用板端 curl | sh：
#   1) 板子通常访问不了 raw.githubusercontent.com（国内网络）
#   2) 一键脚本依赖 GitHub Release，仓库没发 Release 时会 404
# 本脚本把"下载"放在能上 GitHub 的 PC 上做，板子只负责本地解包安装。
#
# 用法（在 PC 上执行，需能 ssh 到板子，建议先配好免密）:
#   bash tools/board_deploy.sh                       # 装到默认板 192.168.137.77
#   bash tools/board_deploy.sh -b root@192.168.1.50  # 指定板子
#   bash tools/board_deploy.sh -r test               # 装完再跑彩条自测推流
#   bash tools/board_deploy.sh -r live1              # 装完直接推正式流
#   bash tools/board_deploy.sh -s                    # 装完只做环境自检
#
# 说明:
#   - 不在本仓库目录下执行时，会自动 git clone 到临时目录（需要 PC 能上 GitHub）
#   - 板上落点默认 /tmp/delivery，装完不会自动删除（方便回滚/复查）
#   - Windows 上用 Git Bash 执行
# ============================================================
set -e

BOARD=${BOARD:-root@192.168.137.77}
REMOTE_DIR=${REMOTE_DIR:-/tmp/delivery}
REPO_URL=${REPO_URL:-https://github.com/BranWangQiZhi/ax650-gstreamer-delivery.git}
DEST=${DEST:-/usr/local}
RUN=

die() { printf '\n[失败] %s\n' "$1" >&2; exit 1; }
say() { printf '%s\n' "$*"; }
step() { printf '\n=== %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -b|--board)  BOARD=$2; shift 2 ;;
    -d|--dest)   DEST=$2; shift 2 ;;
    -r|--run)    RUN=$2; shift 2 ;;
    -s|--self)   RUN=self; shift ;;
    -h|--help)   sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数: $1（用 -h 查看用法）" ;;
  esac
done

# ---------------- 1. 定位仓库 ----------------
step "定位仓库"
CLEANUP=
if [ -f board/gst_install.sh ]; then
  # 只看脚本是否在仓库目录，部署包缺失由后面从 Release 自动补
  REPO=$(pwd)
  say "使用当前目录: $REPO"
else
  command -v git >/dev/null 2>&1 || die "本机没有 git，且当前不在仓库目录内"
  TMPREPO=/tmp/ax650-repo.$$
  [ -d /tmp ] || TMPREPO=./ax650-repo.$$
  mkdir -p "$TMPREPO"
  CLEANUP=$TMPREPO
  say "当前不在仓库目录，克隆到: $TMPREPO"
  git clone --depth 1 "$REPO_URL" "$TMPREPO/repo" >/dev/null 2>&1 \
    || die "git clone 失败（PC 能访问 GitHub 吗？）: $REPO_URL"
  REPO=$TMPREPO/repo
fi
[ -n "$CLEANUP" ] && trap 'rm -rf "$CLEANUP"' EXIT INT TERM

PKG=$REPO/gstreamer_module/gstreamer-aarch64-deploy.tar.gz
if [ ! -f "$PKG" ]; then
  # 仓库 .gitignore 排除了二进制部署包（编译机本地才有），clone/zip 下载后需从 Release 补
  ASSET_URL="${GST_MIRROR:-}https://github.com/BranWangQiZhi/ax650-gstreamer-delivery/releases/latest/download/gstreamer-aarch64-deploy.tar.gz"
  say "仓库内无部署包（.gitignore 不入库），从 Release 下载..."
  say "地址      : $ASSET_URL"
  mkdir -p "$(dirname "$PKG")"
  curl -fL --connect-timeout 10 --retry 3 -o "$PKG" "$ASSET_URL" \
    || die "部署包下载失败: $ASSET_URL
  排查: PC 能访问 GitHub 吗？被墙时加镜像重跑: GST_MIRROR=https://ghproxy.net/ bash tools/board_deploy.sh"
  # 校验: 连接中断会留下截断的包, 必须对照 Release 的 sha256
  SHA_URL="${GST_MIRROR:-}https://github.com/BranWangQiZhi/ax650-gstreamer-delivery/releases/latest/download/sha256"
  SHA_TMP=/tmp/ax650-deploy.sha256
  if curl -fsL --connect-timeout 10 --retry 3 -o "$SHA_TMP" "$SHA_URL"; then
    WANT=$(awk '{print $1}' "$SHA_TMP")
    GOT=$(sha256sum "$PKG" | awk '{print $1}')
    if [ "$GOT" != "$WANT" ]; then
      rm -f "$PKG"
      die "部署包校验失败（下载不完整或被替换）期望 $WANT 实际 $GOT，已删除坏包，请重跑"
    fi
    say "校验      : $GOT"
  else
    say "警告      : 取不到 Release sha256，跳过校验"
  fi
fi
SZ_KB=$(du -k "$PKG" | awk '{print $1}')
[ "$SZ_KB" -gt 1024 ] || die "部署包过小（${SZ_KB}KB），下载可能拿到的是错误页"
say "部署包    : $PKG ($(( SZ_KB / 1024 ))MB)"

# ---------------- 2. 连通性 ----------------
step "检查板子连通性"
ssh -o BatchMode=yes -o ConnectTimeout=6 "$BOARD" 'uname -m' >/dev/null 2>&1 \
  || die "无法免密登录 $BOARD
  排查: 1) 板子是否开机并联在同一网段（ping 一下）
        2) 是否配了免密: ssh-copy-id $BOARD
        3) 系统时间是否正常（2026 年的板子会拒绝旧时间戳）"
say "登录      : $BOARD OK"

# ---------------- 3. 打包下发 ----------------
step "打包并下发到 $REMOTE_DIR"
# 注意: Windows Git Bash 里不要把 C:\... 形式传给 tar（会被当成 主机:路径），统一用 /tmp
TARBALL=/tmp/ax650-delivery.$$.tar.gz
[ -d /tmp ] || TARBALL=./ax650-delivery.$$.tar.gz
tar -czf "$TARBALL" -C "$REPO" board gstreamer_module/gstreamer-aarch64-deploy.tar.gz README.md \
  || die "打包失败"
say "包大小    : $(( $(du -k "$TARBALL" | awk '{print $1}') / 1024 ))MB"

ssh -o BatchMode=yes "$BOARD" "rm -rf $REMOTE_DIR && mkdir -p $REMOTE_DIR" || die "清理远端目录失败"
scp -q "$TARBALL" "$BOARD:$REMOTE_DIR/delivery.tar.gz" || die "scp 下发失败"
ssh -o BatchMode=yes "$BOARD" "cd $REMOTE_DIR && tar -xzf delivery.tar.gz" || die "远端解压失败"
rm -f "$TARBALL"
say "完成      : $REMOTE_DIR/{board,gstreamer_module}"

# ---------------- 4. 板端安装 ----------------
step "板端离线安装（-d $DEST）"
ssh -tt -o BatchMode=yes "$BOARD" "sh $REMOTE_DIR/board/gst_install.sh -l $REMOTE_DIR -d $DEST" \
  || die "板端安装失败，看上面输出"

# ---------------- 5. 可选：跑起来 ----------------
case "$RUN" in
  "")
    step "完成"
    say "安装已完成。手动跑:"
    say "  ssh $BOARD"
    say "  flex_start.sh        # 起相机服务（看到 RTSP_READY）"
    say "  flex_srs.sh          # 推流（默认流名 live1）"
    say "  flex_srs.sh test     # 彩条自测，不依赖摄像头"
    ;;
  self)
    step "环境自检"
    ssh -tt -o BatchMode=yes "$BOARD" ". /etc/profile.d/gstreamer.sh 2>/dev/null || true
      gst-inspect-1.0 --version
      for e in webrtcbin x264enc rtph264pay rtspsrc; do
        if gst-inspect-1.0 \$e >/dev/null 2>&1; then echo \"元素 \$e : OK\"; else echo \"元素 \$e : 缺失\"; fi
      done
      echo \"whip_push: \$(command -v whip_push || echo 未找到)\"
      echo \"flex_srs : \$(command -v flex_srs.sh || echo 未找到)\""
    ;;
  *)
    step "启动推流: $RUN"
    ssh -tt -o BatchMode=yes "$BOARD" "flex_srs.sh $RUN" || die "推流启动失败，看上面输出"
    ;;
esac
