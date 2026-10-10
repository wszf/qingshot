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
APP=".build/packaging/QingShot.app"
./scripts/package-app.sh "$APP"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
# Finish and verify the staged bundle before replacing the installed local build.
if [[ -d ../QingShot.app ]]; then
    BACKUP=".build/previous-QingShot-$(date +%s)-$$.app"
    mv ../QingShot.app "$BACKUP"
fi
mv "$APP" ../QingShot.app
echo "Built: ../QingShot.app"
