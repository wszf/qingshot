#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.2.0}"
BUILD_NUMBER="${2:-2}"
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
# Explicit preview distribution only; local development still requires a stable certificate.
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/QingShot" --shortcut-self-test
"$APP/Contents/MacOS/QingShot" --localization-self-test
QINGSHOT_TEST_OUTPUT="$STAGING" "$APP/Contents/MacOS/QingShot" --self-test
mkdir -p .build/dist
ARCHIVE="QingShot-${VERSION}-macOS-arm64.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" ".build/dist/$ARCHIVE"
(cd .build/dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
echo "Packaged: .build/dist/$ARCHIVE"
