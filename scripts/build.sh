#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is required (install Xcode)" >&2
  exit 1
fi

xcodegen generate
mkdir -p build dist

xcodebuild \
  -project LidAwake.xcodeproj \
  -scheme LidAwake \
  -configuration Release \
  -derivedDataPath "$ROOT/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_SRC="$ROOT/build/DerivedData/Build/Products/Release/LidAwake.app"
APP_DST="$ROOT/dist/LidAwake.app"

rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "Built: $APP_DST"
echo "Run with: open \"$APP_DST\""
