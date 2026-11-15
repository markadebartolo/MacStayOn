#!/usr/bin/env bash
# Publish a notarized MacStayOn zip + Sparkle appcast to GitHub Releases.
#
# Prerequisites:
#   ./scripts/build.sh && ./scripts/notarize.sh
#   ./scripts/generate-sparkle-keys.sh  (once — private key in Keychain)
#   gh auth login
#
# Usage:
#   ./scripts/publish-release.sh v1.3.0
#   ./scripts/publish-release.sh v1.3.0 --notes-file notes.md
#
# Uploads:
#   MacStayOn-macos-arm64.zip  (human download + Sparkle enclosure)
#   appcast.xml                (SUFeedURL → …/releases/latest/download/appcast.xml)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="$ROOT/dist/MacStayOn-macos-arm64.zip"
APP="$ROOT/dist/MacStayOn.app"
STAGING="$ROOT/dist/sparkle-staging"
APPCAST="$ROOT/appcast.xml"
REPO="${GITHUB_REPOSITORY:-markadebartolo/MacStayOn}"

TAG="${1:-}"
shift || true
NOTES_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --notes-file)
      NOTES_ARGS+=(--notes-file "$2")
      shift 2
      ;;
    --notes)
      NOTES_ARGS+=(--notes "$2")
      shift 2
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$TAG" || "$TAG" != v* ]]; then
  echo "usage: $0 vX.Y.Z [--notes '…' | --notes-file path]" >&2
  exit 1
fi

if [[ ! -f "$ZIP" ]]; then
  echo "error: missing $ZIP — run ./scripts/build.sh && ./scripts/notarize.sh first" >&2
  exit 1
fi
if [[ ! -d "$APP" ]]; then
  echo "error: missing $APP" >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI required (brew install gh)" >&2
  exit 1
fi

MARKETING="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
EXPECTED_TAG="v${MARKETING}"
if [[ "$TAG" != "$EXPECTED_TAG" ]]; then
  echo "error: tag $TAG does not match app marketing version $MARKETING (expected $EXPECTED_TAG)" >&2
  exit 1
fi

PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [[ -z "$PUBLIC_KEY" || "$PUBLIC_KEY" == REPLACE* ]]; then
  echo "error: SUPublicEDKey is not set — run ./scripts/generate-sparkle-keys.sh and rebuild" >&2
  exit 1
fi

find_sparkle_bin() {
  local found
  found="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    "$ROOT/build" \
    -path '*/artifacts/sparkle/Sparkle/bin/generate_appcast' \
    -type f 2>/dev/null | head -1 || true)"
  if [[ -n "$found" ]]; then
    dirname "$found"
    return 0
  fi
  return 1
}

SPARKLE_BIN="${SPARKLE_BIN:-}"
ACCOUNT="${SPARKLE_ACCOUNT:-MacStayOn}"
if [[ -z "$SPARKLE_BIN" ]]; then
  SPARKLE_BIN="$(find_sparkle_bin || true)"
fi
if [[ -z "$SPARKLE_BIN" || ! -x "$SPARKLE_BIN/generate_appcast" ]]; then
  echo "error: Sparkle generate_appcast not found — build once so SPM fetches Sparkle" >&2
  exit 1
fi

DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"

echo "Preparing Sparkle staging…"
rm -rf "$STAGING"
mkdir -p "$STAGING"
# Keep the stable asset name used by README / latest download links.
cp "$ZIP" "$STAGING/MacStayOn-macos-arm64.zip"

# Prefer an exported EdDSA key file when Keychain ACL blocks non-interactive tools.
ED_KEY_FILE="${SPARKLE_ED_KEY_FILE:-}"
if [[ -z "$ED_KEY_FILE" && -f "$HOME/Documents/MacStayOn-secrets/macstayon-sparkle-eddsa.key" ]]; then
  ED_KEY_FILE="$HOME/Documents/MacStayOn-secrets/macstayon-sparkle-eddsa.key"
fi

APPCAST_ARGS=(
  --download-url-prefix "$DOWNLOAD_PREFIX"
  --maximum-deltas 0
  -o "$APPCAST"
)
if [[ -n "$ED_KEY_FILE" ]]; then
  echo "Signing zip + generating appcast.xml (EdDSA key file: $ED_KEY_FILE)…"
  APPCAST_ARGS+=(--ed-key-file "$ED_KEY_FILE")
else
  echo "Signing zip + generating appcast.xml (Keychain account: $ACCOUNT)…"
  APPCAST_ARGS+=(--account "$ACCOUNT")
fi

"$SPARKLE_BIN/generate_appcast" "${APPCAST_ARGS[@]}" "$STAGING"

if [[ ! -f "$APPCAST" ]]; then
  echo "error: appcast.xml was not created" >&2
  exit 1
fi

# Sanity: appcast should mention this marketing version.
if ! grep -q "$MARKETING" "$APPCAST"; then
  echo "error: appcast.xml does not mention version $MARKETING" >&2
  exit 1
fi

TITLE="v${MARKETING}"
DEFAULT_NOTES="## MacStayOn ${MARKETING} (${BUILD})

Signed & notarized Apple Silicon build with Sparkle in-app updates.

### Install / update
- **New install:** download \`MacStayOn-macos-arm64.zip\`
- **Existing 1.3.0+:** menu bar → **Updates** (or wait for the daily check)

### Feed
\`appcast.xml\` on this release — clients use \`…/releases/latest/download/appcast.xml\`."

if [[ ${#NOTES_ARGS[@]} -eq 0 ]]; then
  NOTES_ARGS=(--notes "$DEFAULT_NOTES")
fi

echo "Creating GitHub release ${TAG} on ${REPO}..."
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "Release ${TAG} already exists — uploading assets (clobber)..."
  gh release upload "$TAG" \
    "$ZIP" \
    "$APPCAST" \
    --repo "$REPO" \
    --clobber
else
  gh release create "$TAG" \
    "$ZIP" \
    "$APPCAST" \
    --repo "$REPO" \
    --title "$TITLE" \
    "${NOTES_ARGS[@]}"
fi

echo
echo "Done."
echo "  Release:  https://github.com/${REPO}/releases/tag/${TAG}"
echo "  Zip:      https://github.com/${REPO}/releases/download/${TAG}/MacStayOn-macos-arm64.zip"
echo "  Appcast:  https://github.com/${REPO}/releases/latest/download/appcast.xml"
echo "  Version:  ${MARKETING} (${BUILD})"
echo
echo "Installed 1.3.0+ apps will see this on Check for Updates / daily auto-check."
