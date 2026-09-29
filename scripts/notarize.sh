#!/usr/bin/env bash
# Sign + notarize dist/MacStayOn.app (Developer ID).
# Prerequisites: see docs/DISTRIBUTE-MAC.md
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP:-$ROOT/dist/MacStayOn.app}"
IDENTITY="${SIGN_IDENTITY:-}"
PROFILE="${NOTARY_PROFILE:-MacStayOn-notary}"
ZIP="$ROOT/dist/MacStayOn-macos-arm64.zip"

if [[ ! -d "$APP" ]]; then
  echo "error: missing $APP — run ./scripts/build.sh first" >&2
  exit 1
fi

if [[ -z "$IDENTITY" ]]; then
  echo "error: set SIGN_IDENTITY to your Developer ID Application identity" >&2
  echo "  security find-identity -v -p codesigning | grep 'Developer ID Application'" >&2
  exit 1
fi

echo "Signing with: $IDENTITY"
codesign --force --deep --options runtime \
  --sign "$IDENTITY" \
  --timestamp \
  "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"

echo "Zipping for notarization…"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple notary service (profile: $PROFILE)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "Stapling ticket…"
xcrun stapler staple "$APP"

# Re-zip stapled app for distribution
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Done."
echo "  App: $APP"
echo "  Zip: $ZIP"
echo "Check: spctl -a -vv \"$APP\""
