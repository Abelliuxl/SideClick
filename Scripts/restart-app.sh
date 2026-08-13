#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/ClayHub.app"
BUNDLE_ID="com.clayhub.app"

pkill -x ClayHub 2>/dev/null || true

"$ROOT_DIR/Scripts/build-app.sh" >/dev/null

# TCC permissions are tied to the app identity. During local ad-hoc signing,
# rebuilds can leave stale Accessibility/Input Monitoring decisions behind.
# macOS does not allow scripts to grant these permissions, only to reset them.
tccutil reset All "$BUNDLE_ID" >/dev/null 2>&1 || true

open "$APP_DIR"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" >/dev/null 2>&1 || true
echo "Restarted $APP_DIR"
echo "Privacy permissions were reset for $BUNDLE_ID; approve the prompts again."
