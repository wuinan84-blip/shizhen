#!/bin/bash
# 打包发布用的 zip；加 --publish 时同时在 GitHub 上创建 Release 并上传。
# 用法：./scripts/release.sh             只打包到 dist/
#       ./scripts/release.sh --publish   打包并发布（需要先用 gh 登录 GitHub）
# 版本号取自 Resources/Info.plist 的 CFBundleShortVersionString，发布前先改它。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/拾帧.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
TAG="v$VERSION"
# GitHub 会改写附件名里的中文，所以 zip 用英文名；解压出来仍是「拾帧.app」。
ZIP="$ROOT/dist/shizhen-$VERSION-macOS-arm64.zip"

cd "$ROOT"
"$ROOT/scripts/build.sh" release
codesign --verify --strict "$APP"

mkdir -p "$ROOT/dist"
rm -f "$ZIP"
# ditto 会保留签名和扩展属性；普通 zip 命令可能破坏签名。
ditto -c -k --keepParent "$APP" "$ZIP"
echo "已打包：$ZIP"
shasum -a 256 "$ZIP"

[ "${1:-}" = "--publish" ] || exit 0

GH="$(command -v gh || echo "$ROOT/.tools/bin/gh")"
if [ -z "${GH_CONFIG_DIR:-}" ] && [ -d "$ROOT/.tools/gh-config" ]; then
  export GH_CONFIG_DIR="$ROOT/.tools/gh-config"
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "还有未提交的改动，请先提交并推送后再发布。" >&2
  exit 1
fi
git push origin HEAD
REPO="$("$GH" repo view --json nameWithOwner -q .nameWithOwner)"

NOTES="$(cat <<EOF
## 下载安装

1. 下载下面的 \`shizhen-$VERSION-macOS-arm64.zip\`，双击解压，把「拾帧」拖进「应用程序」文件夹。
2. 第一次打开时，macOS 会提示无法验证开发者，先点「完成」。
3. 打开「系统设置 → 隐私与安全性」，滚动到底部，在「拾帧」那一行点「仍要打开」，输入开机密码确认。
4. 按引导授予「屏幕录制」权限，然后重启应用。之后按 \`⌃⌥A\` 开始截图或录屏。

要求 macOS 15 及以上、Apple 芯片（M1 及以后）。完整说明见 [README](https://github.com/$REPO#readme)。
EOF
)"

"$GH" release create "$TAG" "$ZIP" --title "拾帧 $VERSION" --notes "$NOTES" --target "$(git rev-parse HEAD)"
echo "已发布：https://github.com/$REPO/releases/tag/$TAG"
