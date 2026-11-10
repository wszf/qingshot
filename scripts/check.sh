#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
.build/release/QingShot --shortcut-self-test
.build/release/QingShot --localization-self-test
QINGSHOT_TEST_OUTPUT="$PWD/.build" .build/release/QingShot --self-test

# Sparkle packaging/signature smoke test (ad-hoc signing is sufficient here).
CHECK_DIR="$PWD/.build/sparkle-check"
rm -rf "$CHECK_DIR"
./scripts/package-app.sh "$CHECK_DIR/QingShot.app" 0.3.0 3 >/dev/null
CHECK_APP="$CHECK_DIR/QingShot.app"
CHECK_PLIST="$CHECK_APP/Contents/Info.plist"
CHECK_FRAMEWORK="$CHECK_APP/Contents/Frameworks/Sparkle.framework"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$CHECK_PLIST")" == "https://github.com/wszf/qingshot/releases/latest/download/appcast.xml" ]]
[[ -n "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$CHECK_PLIST")" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$CHECK_PLIST")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUScheduledCheckInterval' "$CHECK_PLIST")" == "86400" ]]
[[ -d "$CHECK_FRAMEWORK" ]]
otool -l "$CHECK_APP/Contents/MacOS/QingShot" | grep -q "@executable_path/../Frameworks"
./scripts/sign-app.sh - "$CHECK_APP" >/dev/null
codesign --verify --deep --strict "$CHECK_APP"
for component in "$CHECK_FRAMEWORK" "$CHECK_FRAMEWORK/Versions/B/Autoupdate" "$CHECK_FRAMEWORK/Versions/B/Updater.app" "$CHECK_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" "$CHECK_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"; do
    codesign --verify --strict "$component"
done
rm -rf "$CHECK_DIR"
echo "PASS Sparkle packaging, Info.plist keys, rpath and nested signatures"
