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

# Fail closed if Info.plist does not match project.yml (v1.1.5 shipped labeled 1.1.4).
EXPECTED_MARKETING="$(sed -n 's/.*MARKETING_VERSION: *"\([^"]*\)".*/\1/p' "$ROOT/project.yml" | head -1)"
EXPECTED_BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION: *"\([^"]*\)".*/\1/p' "$ROOT/project.yml" | head -1)"
ACTUAL_MARKETING="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DST/Contents/Info.plist")"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DST/Contents/Info.plist")"
if [[ -z "$EXPECTED_MARKETING" || -z "$EXPECTED_BUILD" ]]; then
  echo "error: could not read MARKETING_VERSION / CURRENT_PROJECT_VERSION from project.yml" >&2
  exit 1
fi
if [[ "$ACTUAL_MARKETING" != "$EXPECTED_MARKETING" || "$ACTUAL_BUILD" != "$EXPECTED_BUILD" ]]; then
  echo "error: Info.plist is $ACTUAL_MARKETING ($ACTUAL_BUILD) but project.yml is $EXPECTED_MARKETING ($EXPECTED_BUILD)" >&2
  echo "hint: clean DerivedData and rebuild (rm -rf build/DerivedData)" >&2
  exit 1
fi
echo "Version OK: $ACTUAL_MARKETING ($ACTUAL_BUILD)"

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
