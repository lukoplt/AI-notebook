#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(cat VERSION)"
APP_NAME="AI Notebook"
EXEC_NAME="AINotebookApp"
BUNDLE_ID="com.aino.AINotebook"

DIST="dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "→ Cleaning $DIST"
rm -rf "$DIST"
mkdir -p "$MACOS" "$RESOURCES"

echo "→ swift build -c release (universal)"
swift build -c release \
    --arch arm64 --arch x86_64 \
    --disable-sandbox

BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$EXEC_NAME"
if [ ! -f "$BIN" ]; then
    echo "Build output not found at $BIN"
    exit 1
fi

echo "→ Copying executable into bundle"
cp "$BIN" "$MACOS/$EXEC_NAME"

echo "→ Copying icon"
cp tools/macos/AppIcon.icns "$RESOURCES/AppIcon.icns"

# Copy any SwiftPM-generated resource bundles (e.g. AINotebookCore_AINotebookCoreTests.bundle is test-only;
# release deps may emit *.bundle that the executable needs at runtime).
BIN_DIR="$(dirname "$BIN")"
shopt -s nullglob
for b in "$BIN_DIR"/*.bundle; do
    cp -R "$b" "$RESOURCES/"
done
shopt -u nullglob

echo "→ Rendering Info.plist (version=$VERSION)"
sed "s/__VERSION__/$VERSION/g" tools/macos/Info.plist.template \
    > "$CONTENTS/Info.plist"

echo "→ Ad-hoc signing the bundle (no Developer ID required)"
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"

echo "→ Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "✓ Built: $APP"
