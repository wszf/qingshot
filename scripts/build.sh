#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Keep one signing identity across builds; never silently fall back to ad-hoc signing.
IDENTITY="${QINGSHOT_SIGNING_IDENTITY:-}"
if [[ -z "$IDENTITY" && -f .signing-identity ]]; then
    IDENTITY="$(cat .signing-identity)"
fi
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="QingShot Self-Signed"
fi
if [[ "$IDENTITY" == "-" ]]; then
    echo "Ad-hoc signing is not allowed for local builds." >&2
    exit 1
fi
if ! security find-identity -p codesigning | grep -q "QingShot Self-Signed\|$IDENTITY"; then
    echo "Signing identity '$IDENTITY' was not found in the Keychain." >&2
    exit 1
fi
if /usr/bin/pgrep -x QingShot >/dev/null; then
    echo "Quit QingShot before rebuilding, to preserve the running process code signature." >&2
    exit 1
fi
swift build -c release
APP=".build/packaging/QingShot.app"
./scripts/package-app.sh "$APP"
./scripts/sign-app.sh "$IDENTITY" "$APP"
# Finish and verify the staged bundle before replacing the installed local build.
if [[ -d ../QingShot.app ]]; then
    BACKUP=".build/previous-QingShot-$(date +%s)-$$.app"
    mv ../QingShot.app "$BACKUP"
fi
mv "$APP" ../QingShot.app
echo "Built: ../QingShot.app"
