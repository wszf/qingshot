#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep one signing identity across builds; never silently fall back to ad-hoc signing.
IDENTITY="${QINGSHOT_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f .signing-identity ]]; then
    IDENTITY="$(cat .signing-identity)"
fi
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
    echo "Set QINGSHOT_SIGNING_IDENTITY to a valid Apple Development/Developer ID certificate (security find-identity -v -p codesigning)." >&2
    exit 1
fi
if /usr/bin/pgrep -x QingShot >/dev/null; then
    echo "Quit QingShot before rebuilding, to preserve the running process code signature." >&2
    exit 1
fi
swift build -c release
./scripts/build-icon.sh
APP=".build/packaging/QingShot.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/QingShot "$APP/Contents/MacOS/QingShot"
cp .build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
ditto .build/release/QingShot_QingShot.bundle "$APP/Contents/Resources/QingShot_QingShot.bundle"
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
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
# Finish and verify the staged bundle before replacing the installed local build.
if [[ -d ../QingShot.app ]]; then
    BACKUP=".build/previous-QingShot-$(date +%s)-$$.app"
    mv ../QingShot.app "$BACKUP"
fi
mv "$APP" ../QingShot.app
echo "Built: ../QingShot.app"
