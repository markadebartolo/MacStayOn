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
  -project MacStayOn.xcodeproj \
  -scheme MacStayOn \
  -configuration Release \
  -derivedDataPath "$ROOT/build/DerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_SRC="$ROOT/build/DerivedData/Build/Products/Release/MacStayOn.app"
APP_DST="$ROOT/dist/MacStayOn.app"

rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

# Ad-hoc / linker-signed builds often get password-only admin dialogs.
# Prefer Developer ID (or SIGN_IDENTITY) so macOS can offer Touch ID.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
      | head -1 || true
  )"
fi
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -1 || true
  )"
fi

if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --deep --options runtime \
    --sign "$IDENTITY" \
    --entitlements "$ROOT/MacStayOn/MacStayOn.entitlements" \
    "$APP_DST"
  codesign --verify --deep --strict --verbose=2 "$APP_DST" || true
else
  echo "warning: no signing identity found — admin prompt may be password-only (no Touch ID)" >&2
fi

echo "Built: $APP_DST"
echo "Run with: open \"$APP_DST\""
