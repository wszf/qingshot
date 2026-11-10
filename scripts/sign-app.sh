#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${1:?Usage: sign-app.sh IDENTITY APP_PATH}"
APP="${2:?Usage: sign-app.sh IDENTITY APP_PATH}"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [[ -d "$FRAMEWORK" ]]; then
    VERSIONS="$FRAMEWORK/Versions/B"
    for xpc in "$VERSIONS/XPCServices/"*.xpc; do
        [[ -d "$xpc" ]] && codesign --force --preserve-metadata=entitlements --sign "$IDENTITY" "$xpc"
    done
    [[ -d "$VERSIONS/Updater.app" ]] && codesign --force --preserve-metadata=entitlements --sign "$IDENTITY" "$VERSIONS/Updater.app"
    [[ -f "$VERSIONS/Autoupdate" ]] && codesign --force --preserve-metadata=entitlements --sign "$IDENTITY" "$VERSIONS/Autoupdate"
    codesign --force --preserve-metadata=entitlements --sign "$IDENTITY" "$FRAMEWORK"
fi
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
