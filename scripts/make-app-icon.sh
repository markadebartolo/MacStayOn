#!/usr/bin/env bash
# Regenerate the app icon (close-up of a laptop corner, lid open, screen glowing)
# from scripts/app-icon/main.swift: every AppIcon.appiconset size, the README
# image, and docs/media/MacStayOn.icns.
#
# Usage: ./scripts/make-app-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET="$ROOT/MacStayOn/Assets.xcassets/AppIcon.appiconset"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 "$ROOT/scripts/app-icon/main.swift" -o "$WORK/render-icon"
"$WORK/render-icon" "$WORK/icon-1024.png"

size() { sips -z "$2" "$2" "$WORK/icon-1024.png" --out "$1" >/dev/null; }
size "$SET/icon_16x16.png" 16
size "$SET/icon_16x16@2x.png" 32
size "$SET/icon_32x32.png" 32
size "$SET/icon_32x32@2x.png" 64
size "$SET/icon_128x128.png" 128
size "$SET/icon_128x128@2x.png" 256
size "$SET/icon_256x256.png" 256
size "$SET/icon_256x256@2x.png" 512
size "$SET/icon_512x512.png" 512
cp "$WORK/icon-1024.png" "$SET/icon_512x512@2x.png"
cp "$WORK/icon-1024.png" "$SET/AppIcon-1024.png"
cp "$WORK/icon-1024.png" "$ROOT/docs/media/macstayon-appicon-1024.png"

ICONSET="$WORK/MacStayOn.iconset"
mkdir -p "$ICONSET"
cp "$SET"/icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$ROOT/docs/media/MacStayOn.icns"
echo "App icon regenerated."
