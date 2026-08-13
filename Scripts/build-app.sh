#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/ClayHub.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/ClayHub" "$MACOS_DIR/ClayHub"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClayHub</string>
    <key>CFBundleIdentifier</key>
    <string>com.clayhub.app</string>
    <key>CFBundleName</key>
    <string>ClayHub</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSInputMonitoringUsageDescription</key>
    <string>ClayHub listens for mouse side button events so it can trigger your configured shortcuts.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP_DIR"

# 可选：安装到 /Applications（开机自启 SMAppService 要求 app 位于 /Applications）。
# 用法：INSTALL=1 ./Scripts/build-app.sh
if [ "${INSTALL:-0}" = "1" ]; then
    rm -rf "/Applications/ClayHub.app"
    cp -R "$APP_DIR" "/Applications/ClayHub.app"
    codesign --force --sign - "/Applications/ClayHub.app"
    echo "Installed to /Applications/ClayHub.app"
fi

echo "$APP_DIR"
