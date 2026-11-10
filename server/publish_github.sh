#!/bin/sh
# ============================================================
# publish_github.sh — 把交付包发布到 GitHub（仓库 + Release）
# ============================================================
# 在 PC 的 Git Bash 里执行。需要一枚 GitHub Personal Access Token。
#
# 准备 token（只需一次）:
#   打开 https://github.com/settings/tokens  →  Generate new token (classic)
#   勾选 repo 权限 → 生成后复制，然后:
#     echo "ghp_xxxxxxxx" > ~/.gh_token
#     chmod 600 ~/.gh_token
#
# 用法:
#   sh publish_github.sh                    # 建仓库 + 推代码 + 发 Release
#   sh publish_github.sh --no-push          # 只发 Release（代码已推过）
#   REPO=BranWangQiZhi/xxx TAG=1.22.12-r1 sh publish_github.sh
#
# 发布完成后，别人在板子上:
#   curl -fsSL https://raw.githubusercontent.com/<REPO>/main/board/gst_install.sh | sh
# ============================================================
set -e

REPO=${REPO:-BranWangQiZhi/ax650-gstreamer-delivery}
TAG=${TAG:-1.22.12-r$(date +%Y%m%d)}
BRANCH=${BRANCH:-main}
API=https://api.github.com
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
PKG=${PKG:-$ROOT/gstreamer_module/gstreamer-aarch64-deploy.tar.gz}
NO_PUSH=0

for a in "$@"; do
  case "$a" in
    --no-push) NO_PUSH=1 ;;
    -h|--help) sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "未知参数: $a" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
die() { printf '\n[失败] %s\n' "$1" >&2; exit 1; }

# ---------- token ----------
TOKEN=${GITHUB_TOKEN:-${GH_TOKEN:-}}
if [ -z "$TOKEN" ] && [ -f "$HOME/.gh_token" ]; then
  TOKEN=$(tr -d ' \t\r\n' < "$HOME/.gh_token")
fi
[ -n "$TOKEN" ] || die "没有找到 token。请按脚本头部说明把 token 写入 ~/.gh_token"

OWNER=${REPO%%/*}
NAME=${REPO#*/}
say "== 目标仓库 $REPO   标签 $TAG"

command -v git >/dev/null 2>&1 || die "本机没有 git"
[ -f "$PKG" ] || die "找不到部署包: $PKG（先 bash build.sh install）"

PSIZE=$(du -k "$PKG" | awk '{print $1}')
[ "$PSIZE" -gt 1024 ] || die "部署包只有 ${PSIZE}KB，不像正常产物"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

api() { # $1=method $2=path [$3=json body]
  if [ -n "${3:-}" ]; then
    curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      -d "$3" "$API$2"
  else
    curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$API$2"
  fi
}

# ---------- 1. 账号确认 ----------
say "[1/5] 校验 token"
ME=$(api GET /user)
printf '%s' "$ME" | grep -q '"login"' || die "token 无效或已过期（API 返回: $(printf '%s' "$ME" | head -c 120)）"
LOGIN=$(printf '%s' "$ME" | sed -n 's/.*"login": *"\([^"]*\)".*/\1/p' | head -1)
say "      已认证为 $LOGIN"
[ "$LOGIN" = "$OWNER" ] || say "      注意: token 属于 $LOGIN，与目标 owner $OWNER 不同"

# ---------- 2. 仓库 ----------
say "[2/5] 确认仓库 $REPO"
CODE=$(curl -s -o "$TMP/repo.json" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  "$API/repos/$REPO")
if [ "$CODE" = "200" ]; then
  say "      已存在"
elif [ "$CODE" = "404" ]; then
  say "      不存在，创建公开仓库"
  api POST /user/repos "{\"name\":\"$NAME\",\"private\":false,\"has_issues\":true,\"has_wiki\":false,\"description\":\"AX650 GStreamer 1.22.12 + WebRTC 推流交付包（预编译 aarch64 运行时）\"}" \
    > "$TMP/create.json"
  printf '%s' "$TMP/create.json" | grep -q '"full_name"' || die "创建仓库失败: $(head -c 300 "$TMP/create.json")"
else
  die "查询仓库返回 HTTP $CODE（token 权限不足？需要 repo 权限）"
fi

# ---------- 3. 推送代码 ----------
if [ "$NO_PUSH" = "1" ]; then
  say "[3/5] 跳过推送（--no-push）"
else
  say "[3/5] 推送代码到 $BRANCH"
  cd "$ROOT"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$ROOT 不是 git 仓库"
  if [ -n "$(git status --porcelain)" ]; then
    say "      警告: 工作区有未提交改动，只推送已提交内容"
  fi
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "https://github.com/$REPO.git"
  else
    git remote add origin "https://github.com/$REPO.git"
  fi
  if ! git push --quiet "https://x-access-token:$TOKEN@github.com/$REPO.git" "HEAD:$BRANCH" 2>"$TMP/push.err"; then
    sed "s|$TOKEN|***|g" "$TMP/push.err" >&2
    die "推送失败"
  fi
  git branch --set-upstream-to="origin/$BRANCH" "$BRANCH" >/dev/null 2>&1 || true
  say "      已推送 $(git rev-parse --short HEAD) → $BRANCH"
fi

# ---------- 4. Release ----------
say "[4/5] 创建 Release $TAG"
OLD=$(api GET /repos/$REPO/releases/tags/$TAG)
OLD_ID=$(printf '%s' "$OLD" | grep -o '"id": *[0-9]*' | head -1 | grep -o '[0-9]*')
if [ -n "$OLD_ID" ]; then
  say "      同名 Release 已存在（id=$OLD_ID），先删除再发"
  api DELETE /repos/$REPO/releases/$OLD_ID >/dev/null
fi

SHA=$(command -v sha256sum >/dev/null 2>&1 && sha256sum "$PKG" | awk '{print $1}' \
      || openssl dgst -sha256 "$PKG" | sed 's/.*= //')
printf '%s  %s\n' "$SHA" "gstreamer-aarch64-deploy.tar.gz" > "$TMP/sha256"

RELREQ="$TMP/release.json"
{
  printf '{"tag_name":"%s","name":"%s","body":' "$TAG" "$TAG"
  printf '"AX650 板端 GStreamer 1.22.12 预编译运行时（aarch64，glibc 2.30 兼容层内置）。\\n\\n'
  printf '一键安装（板子上以 root 执行）：\\n\\n'
  printf 'curl -fsSL https://raw.githubusercontent.com/%s/%s/board/gst_install.sh | sh\\n\\n' "$REPO" "$BRANCH"
  printf '包含：bin（gst-* 工具、whip_push）、lib（GStreamer 核心+插件+glibc 兼容层）、libexec（插件扫描器）。\\n\\n'
  printf 'SHA256：%s",' "$SHA"
  printf '"draft":false,"prerelease":false}'
} > "$RELREQ"

REL=$(api POST /repos/$REPO/releases "$(cat "$RELREQ")")
UP=$(printf '%s' "$REL" | sed -n 's/.*"upload_url": *"\([^"]*\)".*/\1/p' | sed 's/{.*}//')
[ -n "$UP" ] || die "创建 Release 失败: $(printf '%s' "$REL" | head -c 300)"
say "      已创建: https://github.com/$REPO/releases/tag/$TAG"

# ---------- 5. 上传资产 ----------
say "[5/5] 上传资产（约 $((PSIZE / 1024))MB，可能需 1~3 分钟）"
curl -sS --retry 2 --max-time 900 -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@$PKG" "$UP?name=gstreamer-aarch64-deploy.tar.gz&label=$TAG" > "$TMP/a1.json"
printf '%s' "$TMP/a1.json" | grep -q '"browser_download_url"' || die "上传 tar.gz 失败: $(head -c 300 "$TMP/a1.json")"

curl -sS --retry 2 -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: text/plain" \
  --data-binary "@$TMP/sha256" "$UP?name=sha256&label=$TAG" > "$TMP/a2.json"

say "      完成"

cat <<EOF

== 发布成功

  仓库     : https://github.com/$REPO
  Release  : https://github.com/$REPO/releases/tag/$TAG
  直链     : https://github.com/$REPO/releases/latest/download/gstreamer-aarch64-deploy.tar.gz
  校验值   : $SHA

  别人在板子上一条命令:
      curl -fsSL https://raw.githubusercontent.com/$REPO/$BRANCH/board/gst_install.sh | sh

  GitHub 慢/被墙时加镜像:
      GST_MIRROR=https://ghproxy.net/ curl -fsSL https://raw.githubusercontent.com/$REPO/$BRANCH/board/gst_install.sh | sh

EOF
