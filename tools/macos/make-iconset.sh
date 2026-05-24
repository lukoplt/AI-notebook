#!/usr/bin/env bash
set -euo pipefail
SRC="tools/macos/AppIcon.iconset/icon_512x512@2x.png"
SET="tools/macos/AppIcon.iconset"
ICNS="tools/macos/AppIcon.icns"

for spec in "16:icon_16x16.png" "32:icon_16x16@2x.png" \
            "32:icon_32x32.png" "64:icon_32x32@2x.png" \
            "128:icon_128x128.png" "256:icon_128x128@2x.png" \
            "256:icon_256x256.png" "512:icon_256x256@2x.png" \
            "512:icon_512x512.png" "1024:icon_512x512@2x.png"; do
    px="${spec%%:*}"; name="${spec#*:}"
    sips -z "$px" "$px" "$SRC" --out "$SET/$name" >/dev/null
done

iconutil -c icns "$SET" -o "$ICNS"
