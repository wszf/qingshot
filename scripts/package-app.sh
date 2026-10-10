#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build-icon.sh
APP="${1:?Usage: package-app.sh APP_PATH [VERSION] [BUILD_NUMBER]}"
VERSION="${2:-0.2.0}"
BUILD_NUMBER="${3:-2}"
BIN_DIR="$(swift build -c release --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/QingShot" "$APP/Contents/MacOS/QingShot"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto "$BIN_DIR/QingShot_QingShot.bundle" "$APP/Contents/Resources/QingShot_QingShot.bundle"
for lang in en zh-Hans; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "assets/$lang.lproj/InfoPlist.strings" "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>QingShot</string>
<key>CFBundleDisplayName</key><string>QingShot</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
<key>CFBundleIdentifier</key><string>local.qingshot.capture</string>
<key>CFBundleExecutable</key><string>QingShot</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>QingShot captures your screen only when you start a screenshot or recording.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
