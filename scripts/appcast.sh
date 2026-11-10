#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: appcast.sh VERSION [DIST_DIR]}"
DIST="${2:-.build/dist}"
SPARKLE_VERSION="2.10.1"
ARCHIVE="QingShot-${VERSION}-macOS-arm64.zip"
NOTES="QingShot-${VERSION}-macOS-arm64.md"
: "${SPARKLE_ED_PRIVATE_KEY:?SPARKLE_ED_PRIVATE_KEY is required}"
[[ -f "$DIST/$ARCHIVE" ]] || { echo "Missing release archive: $DIST/$ARCHIVE" >&2; exit 1; }
WORK="$(mktemp -d "$PWD/.build/appcast-work.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cp "$DIST/$ARCHIVE" "$WORK/$ARCHIVE"
cat > "$WORK/$NOTES" <<NOTES_EOF
QingShot $VERSION

Apple Silicon (arm64) only. Requires macOS 15 or later.

仅支持 Apple Silicon，要求 macOS 15 或更新版本。
NOTES_EOF
TOOLS="$PWD/.build/sparkle-tools/$SPARKLE_VERSION"
if [[ ! -x "$TOOLS/bin/generate_appcast" ]]; then
    mkdir -p "$TOOLS"
    curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" -o "$TOOLS/Sparkle.tar.xz"
    tar -xf "$TOOLS/Sparkle.tar.xz" -C "$TOOLS"
fi
printf '%s\n' "$SPARKLE_ED_PRIVATE_KEY" | "$TOOLS/bin/generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/wszf/qingshot/releases/download/v${VERSION}/" \
    --embed-release-notes \
    --link "https://github.com/wszf/qingshot" \
    -o "$DIST/appcast.xml" \
    "$WORK"
