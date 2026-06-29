#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
BUNDLE_ID="${BUNDLE_ID:-online.eveoh.offtick}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_VERSION="${BUILD_VERSION:-1}"
swift build -c "$CONFIGURATION" --package-path "$ROOT_DIR"
BUILD_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
APP_DIR="$ROOT_DIR/.build/OffTick.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/OffTick" "$MACOS_DIR/OffTick"

if [[ -d "$BUILD_DIR/OffTick_OffTick.bundle" ]]; then
    cp -R "$BUILD_DIR/OffTick_OffTick.bundle" "$RESOURCES_DIR/"
fi

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>OffTick</string>
    <key>CFBundleIdentifier</key>
    <string>__BUNDLE_ID__</string>
    <key>CFBundleName</key>
    <string>OffTick</string>
    <key>CFBundleDisplayName</key>
    <string>OffTick</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>__MARKETING_VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__BUILD_VERSION__</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

env BUNDLE_ID="$BUNDLE_ID" MARKETING_VERSION="$MARKETING_VERSION" BUILD_VERSION="$BUILD_VERSION" \
    perl -0pi -e 's/__BUNDLE_ID__/$ENV{BUNDLE_ID}/g; s/__MARKETING_VERSION__/$ENV{MARKETING_VERSION}/g; s/__BUILD_VERSION__/$ENV{BUILD_VERSION}/g' "$CONTENTS_DIR/Info.plist"

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
