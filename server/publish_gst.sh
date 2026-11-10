#!/bin/sh
# ============================================================
# publish_gst.sh — 把 GStreamer 运行时发布成「官网可一键拉取」的静态目录
# ============================================================
# 在 PC 的 Git Bash 里执行（需要能 ssh/scp 到服务器）。
#
# 用法:
#   sh publish_gst.sh                      # 版本号自动取 1.22.12-r<今天>
#   VERSION=1.22.12-r20261110 sh publish_gst.sh
#   PKG=/path/to/gstreamer-aarch64-deploy.tar.gz sh publish_gst.sh
#   sh publish_gst.sh --no-latest          # 发旧版本，不动 latest 指针
#
# 发布后的目录结构（服务器 $WEBROOT/gst/）:
#   index.html                     官网页面（含复制按钮）
#   install.sh                     一键安装脚本
#   latest                         纯文本，当前版本号
#   versions.json                  版本列表（页面动态渲染用）
#   1.22.12-r20261110/
#     ├── gstreamer-aarch64-deploy.tar.gz
#     ├── sha256
#     └── manifest.json
#
# 别人在板子上只需:
#   curl -fsSL <PUBLIC_BASE>/install.sh | sh
# ============================================================
set -e

SRV=${SRV:-root@121.40.107.62}
PUBLIC_BASE=${PUBLIC_BASE:-http://121.40.107.62:8080/gst}
WEBROOT=${WEBROOT:-/usr/local/srs/srs-server-6.0-r3/trunk/objs/nginx/html}
REL=gst
HERE=$(cd "$(dirname "$0")" && pwd)
PKG=${PKG:-$HERE/../gstreamer_module/gstreamer-aarch64-deploy.tar.gz}
INSTALLER=$HERE/../board/gst_install.sh
INDEX=$HERE/gst_index.html
VERSION=${VERSION:-1.22.12-r$(date +%Y%m%d)}
NO_LATEST=0

for a in "$@"; do
  case "$a" in
    --no-latest) NO_LATEST=1 ;;
    -h|--help) sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf '\n[失败] %s\n' "$1" >&2; exit 1; }

# ---------- 0. 前置检查 ----------
say "== 发布 $VERSION"
[ -f "$PKG" ]      || die "找不到部署包: $PKG（先在 gstreamer_module 里 sh build.sh install）"
[ -f "$INSTALLER" ] || die "找不到安装脚本: $INSTALLER"
[ -f "$INDEX" ]     || die "找不到页面模板: $INDEX"

PSIZE=$(du -k "$PKG" | awk '{print $1}')
[ "$PSIZE" -gt 1024 ] || die "部署包只有 ${PSIZE}KB，不像正常产物（应约 16MB）"

# 结构体检：缺 scanner 的包会在板上报 External plugin loader failed，不要发出去
if [ "${SKIP_LAYOUT_CHECK:-0}" != "1" ]; then
  say "[0/5] 检查包结构"
  for must in bin/whip_push bin/gst-inspect-1.0 lib/libgstreamer-1.0.so.0 lib/libglibc230_compat.so; do
    tar -tzf "$PKG" | grep -q "^$must" || die "包内缺少 $must，产物不完整"
  done
  if tar -tzf "$PKG" | grep -qx 'libexec/gstreamer-1.0/gst-plugin-scanner'; then
    say "      scanner: OK"
  else
    cat >&2 <<'EOM'

[失败] 包内缺少 libexec/gstreamer-1.0/gst-plugin-scanner

  这个包装上后板子会报 "External plugin loader failed"（插件扫描器找不到）。
  在编译机上重新打包即可（stage/ 还在的话几十秒）:
      cd gstreamer_module
      tar -czf gstreamer-aarch64-deploy.tar.gz -C stage bin lib libexec
  或直接:
      bash build.sh install

  确认 stage/libexec 里确实有文件; 若本就为空, 说明当初编译没产出, 需要检查
  gstreamer core 的 meson 是否被 -Dtests=disabled 之类选项连带关掉了 scanner。

  已知残缺包仍要发布时, 加: SKIP_LAYOUT_CHECK=1 sh publish_gst.sh
EOM
    exit 1
  fi
fi

# ---------- 1. 组装本地发布目录 ----------
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT INT TERM
OUT=$STAGE/$REL
mkdir -p "$OUT/$VERSION"

cp "$PKG" "$OUT/$VERSION/gstreamer-aarch64-deploy.tar.gz"

say "[1/5] 计算校验值"
if command -v sha256sum >/dev/null 2>&1; then
  SHA=$(sha256sum "$PKG" | awk '{print $1}')
elif command -v openssl >/dev/null 2>&1; then
  SHA=$(openssl dgst -sha256 "$PKG" | sed 's/.*= //')
else
  die "本机缺少 sha256sum/openssl，无法生成校验值"
fi
printf '%s  gstreamer-aarch64-deploy.tar.gz\n' "$SHA" > "$OUT/$VERSION/sha256"
say "      $SHA"

say "[2/5] 生成 manifest"
GSTVER=$(printf '%s' "$VERSION" | cut -d- -f1)
cat > "$OUT/$VERSION/manifest.json" <<EOF
{
  "version": "$VERSION",
  "gstreamer": "$GSTVER",
  "file": "gstreamer-aarch64-deploy.tar.gz",
  "sha256": "$SHA",
  "size": $((PSIZE * 1024)),
  "arch": "aarch64",
  "glibc_min": "2.30",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "contains": ["bin", "lib", "libexec"],
  "notes": "GStreamer runtime for AX650; LD_PRELOAD compat layer included"
}
EOF

say "[3/5] 准备页面与安装脚本"
cp "$INDEX" "$OUT/index.html"
# 把安装脚本里内置的默认源地址替换成本次发布地址
sed "s|http://121.40.107.62:8080/gst|$PUBLIC_BASE|g" "$INSTALLER" > "$OUT/install.sh"
chmod 755 "$OUT/install.sh"
[ "$NO_LATEST" = "1" ] || printf '%s\n' "$VERSION" > "$OUT/latest"

# ---------- 2. 上传 ----------
say "[4/5] 上传到 $SRV:$WEBROOT/$REL"
ssh "$SRV" "mkdir -p '$WEBROOT/$REL'"
scp -q -r "$OUT/." "$SRV:$WEBROOT/$REL/"

# 服务器侧补 versions.json（按目录名倒序，天然就是版本降序）
ssh "$SRV" "cd '$WEBROOT/$REL' && \
  ls -1d */ 2>/dev/null | tr -d '/' | grep -E '^[0-9]' | sort -rV | \
  python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()], indent=2))' \
  > versions.json && chmod -R a+rX . && echo '版本列表:' && cat versions.json"

# ---------- 3. 验证 ----------
say "[5/5] HTTP 校验"
CODE=$(ssh "$SRV" "curl -s -o /dev/null -w '%{http_code}' '$PUBLIC_BASE/index.html'")
BYTES=$(ssh "$SRV" "curl -s -o /dev/null -w '%{size_download}' '$PUBLIC_BASE/$VERSION/sha256'")
say "      index.html   HTTP $CODE"
say "      sha256       $BYTES bytes"

[ "$CODE" = "200" ] || die "页面不可达（HTTP $CODE），检查 nginx 根目录是否为 $WEBROOT"
[ "$BYTES" -gt 0 ] || die "版本文件不可达"

cat <<EOF

== 发布完成

  官网页面 : $PUBLIC_BASE/
  一键安装 : curl -fsSL $PUBLIC_BASE/install.sh | sh
  指定版本 : sh install.sh -v $VERSION
  包地址   : $PUBLIC_BASE/$VERSION/gstreamer-aarch64-deploy.tar.gz
  校验值   : $SHA

EOF
