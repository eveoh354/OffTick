#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="OffTick"
VERSION="${MARKETING_VERSION:-0.1.0}"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_DIR="$DIST_DIR/$APP_NAME-$VERSION"
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"
CHECKSUM_PATH="$ZIP_PATH.sha256"
RELEASE_NOTES_PATH="$DIST_DIR/RELEASE_NOTES-$VERSION.md"

APP_DIR="$("$ROOT_DIR/Scripts/build-app.sh" | tail -n 1)"

rm -rf "$PACKAGE_DIR" "$ZIP_PATH" "$CHECKSUM_PATH" "$RELEASE_NOTES_PATH" \
    "$DIST_DIR/$APP_NAME-$VERSION-local" "$DIST_DIR/$APP_NAME-$VERSION-local.zip"
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
    shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

CHECKSUM="$(awk '{print $1}' "$CHECKSUM_PATH")"
cat > "$RELEASE_NOTES_PATH" <<TEXT
# OffTick $VERSION

This is a locally signed, non-notarized macOS test build.

## Download

- App package: \`$(basename "$ZIP_PATH")\`
- SHA256: \`$CHECKSUM\`

## First Launch

1. Download and unzip \`$(basename "$ZIP_PATH")\`.
2. Drag \`OffTick.app\` to Applications.
3. Control-click \`OffTick.app\`, then choose Open.
4. If macOS still blocks it, open System Settings > Privacy & Security, then choose Open Anyway.

## Notes

This build is not notarized with Apple Developer ID. macOS may show a security warning on first launch.
TEXT

codesign --verify --deep --strict "$PACKAGE_DIR/$APP_NAME.app"
echo "$ZIP_PATH"
