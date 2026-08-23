#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/ClayHub.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUNDLE_ID="com.clayhub.app"

cd "$ROOT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BIN_DIR/ClayHub" "$MACOS_DIR/ClayHub"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

SIGNING_IDENTITY="${CODE_SIGN_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
        | awk '/"Apple Development:|"Developer ID Application:/ { print $2; exit }')"
fi
if [ -z "$SIGNING_IDENTITY" ]; then
    signing_info="$($ROOT_DIR/Scripts/ensure-signing-identity.sh)"
    SIGNING_IDENTITY="${signing_info%%|*}"
fi

codesign --force --deep --options runtime --timestamp=none \
    --sign "$SIGNING_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

# 可选：安装到 /Applications（开机自启 SMAppService 要求 app 位于 /Applications）。
# 用法：INSTALL=1 ./Scripts/build-app.sh
if [ "${INSTALL:-0}" = "1" ]; then
    old_requirement=""
    if [ -d "/Applications/ClayHub.app" ]; then
        old_requirement="$(codesign -dr - "/Applications/ClayHub.app" 2>&1 \
            | sed -n 's/.*designated => //p')"
    fi
    new_requirement="$(codesign -dr - "$APP_DIR" 2>&1 \
        | sed -n 's/.*designated => //p')"

    rm -rf "/Applications/ClayHub.app"
    cp -R "$APP_DIR" "/Applications/ClayHub.app"
    codesign --verify --deep --strict "/Applications/ClayHub.app"

    if [ -n "$old_requirement" ] && [ "$old_requirement" != "$new_requirement" ]; then
        tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
        echo "Reset stale ClayHub privacy records after the signing identity changed."
    fi
    echo "Installed to /Applications/ClayHub.app"
fi

echo "$APP_DIR"
