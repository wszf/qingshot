#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.3.0}"
BUILD_NUMBER="${2:-3}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "Usage: release.sh MAJOR.MINOR.PATCH POSITIVE_BUILD_NUMBER" >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo "Release packaging requires an Apple Silicon host." >&2
    exit 1
fi
./scripts/check.sh
STAGING="$(mktemp -d "$PWD/.build/release-package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/QingShot.app"
./scripts/package-app.sh "$APP" "$VERSION" "$BUILD_NUMBER"
[[ "$(lipo -archs "$APP/Contents/MacOS/QingShot")" == arm64 ]]
SIGNING_IDENTITY="${QINGSHOT_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && "${GITHUB_ACTIONS:-}" != "true" ]]; then
    SIGNING_IDENTITY="QingShot Self-Signed"
fi
if [[ -n "$SIGNING_IDENTITY" ]]; then
    ./scripts/sign-app.sh "$SIGNING_IDENTITY" "$APP"
    AUTHORITY="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
    echo "Signed with Authority: $AUTHORITY"
else
    ./scripts/sign-app.sh - "$APP"
    echo "Signed ad-hoc (no signing identity provided)"
fi
"$APP/Contents/MacOS/QingShot" --shortcut-self-test
"$APP/Contents/MacOS/QingShot" --localization-self-test
QINGSHOT_TEST_OUTPUT="$STAGING" "$APP/Contents/MacOS/QingShot" --self-test
mkdir -p .build/dist
ARCHIVE="QingShot-${VERSION}-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" ".build/dist/$ARCHIVE"
(cd .build/dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
echo "Packaged: .build/dist/$ARCHIVE"
