#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OffTick"
VERSION="${MARKETING_VERSION:-0.1.0}"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_DIR="$DIST_DIR/$APP_NAME-$VERSION-local"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION-local.zip"

APP_DIR="$("$ROOT_DIR/Scripts/build-app.sh" | tail -n 1)"

rm -rf "$PACKAGE_DIR" "$ZIP_PATH"
mkdir -p "$PACKAGE_DIR"
cp -R "$APP_DIR" "$PACKAGE_DIR/"

cat > "$PACKAGE_DIR/README-FIRST.txt" <<'TEXT'
OffTick 本地测试版打开说明

这是一个未经过 Apple Developer ID 公证的本地测试包。
第一次打开时，macOS 可能提示“无法验证开发者”或“可能包含恶意软件”。

打开方式：
1. 将 OffTick.app 拖到“应用程序”文件夹。
2. 按住 Control 键点击 OffTick.app，选择“打开”。
3. 如果仍被拦截，打开“系统设置 > 隐私与安全性”，在底部点击“仍要打开”。
4. 启动后如菜单栏没有显示，请到“系统设置 > 菜单栏 > 允许在菜单栏显示”打开 OffTick。

注意：此包仅适合小范围测试分发。正式公开分发建议使用 Apple Developer ID 签名和 notarization 公证。
TEXT

(
    cd "$DIST_DIR"
    ditto -c -k --sequesterRsrc --keepParent "$(basename "$PACKAGE_DIR")" "$(basename "$ZIP_PATH")"
)

codesign --verify --deep --strict "$PACKAGE_DIR/$APP_NAME.app"
echo "$ZIP_PATH"
