#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/ClayHub.app"
BUNDLE_ID="com.clayhub.app"

pkill -x ClayHub 2>/dev/null || true

"$ROOT_DIR/Scripts/build-app.sh" >/dev/null

# Permissions now survive rebuilds because ClayHub uses a stable signing identity.
# Reset only when explicitly requested while debugging permission state.
if [ "${RESET_PERMISSIONS:-0}" = "1" ]; then
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

open "$APP_DIR"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
echo "Restarted $APP_DIR"
if [ "${RESET_PERMISSIONS:-0}" = "1" ]; then
    echo "Privacy permissions were reset for $BUNDLE_ID; approve the prompts again."
fi
