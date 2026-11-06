#!/bin/bash
# 编译并打包成 build/拾帧.app，用项目内的固定证书签名。
# 用法：./scripts/build.sh [debug|release]   默认 release
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP_NAME="拾帧"
APP="$ROOT/build/$APP_NAME.app"
KEYCHAIN="$ROOT/.signing/jietu-signing.keychain-db"
IDENTITY="Jietu Local Signing"

cd "$ROOT"
swift build --disable-sandbox -c "$CONFIG"
BIN="$(swift build --disable-sandbox -c "$CONFIG" --show-bin-path)/Jietu"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Jietu"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

if [ ! -f "$KEYCHAIN" ]; then
  "$ROOT/scripts/setup-signing.sh"
fi

# codesign 只在钥匙串搜索列表里找身份：签名时临时加入，签完恢复原列表。
ORIGINAL_KEYCHAINS=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%\"}"; line="${line#\"}"
  [ -n "$line" ] && ORIGINAL_KEYCHAINS+=("$line")
done < <(security list-keychains -d user)

restore_keychains() { security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}"; }
trap restore_keychains EXIT

security unlock-keychain -p jietu-local "$KEYCHAIN"
security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" "$KEYCHAIN"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" "$APP"

echo "已生成：$APP"
