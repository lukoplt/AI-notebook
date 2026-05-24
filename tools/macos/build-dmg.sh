#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

VERSION="$(cat VERSION)"
APP_NAME="AI Notebook"
APP_PATH="dist/$APP_NAME.app"
DMG_NAME="AINotebook-v$VERSION-macos.dmg"
DMG_PATH="dist/$DMG_NAME"
STAGING="dist/dmg-staging"

if [ ! -d "$APP_PATH" ]; then
    echo "App bundle not found at $APP_PATH — run build-app.sh first." >&2
    exit 1
fi

echo "→ Staging DMG layout"
rm -rf "$STAGING" "$DMG_PATH"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "→ Creating compressed DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "→ Ad-hoc signing the DMG"
IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$IDENTITY" "$DMG_PATH"

echo "✓ Built: $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
