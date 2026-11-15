#!/usr/bin/env bash
# One-time: generate Sparkle EdDSA keys for MacStayOn and write the public key into Info.plist.
# Uses Keychain account "MacStayOn" so it does not overwrite other apps' Sparkle keys.
# The private key stays in this Mac's Keychain (used by generate_appcast / sign_update).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFO="$ROOT/MacStayOn/Info.plist"
ACCOUNT="${SPARKLE_ACCOUNT:-MacStayOn}"

find_sparkle_bin() {
  local found
  found="$(find "$ROOT/build" "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*/artifacts/sparkle/Sparkle/bin/generate_keys' \
    -type f 2>/dev/null | head -1 || true)"
  if [[ -n "$found" ]]; then
    dirname "$found"
    return 0
  fi
  return 1
}

SPARKLE_BIN="${SPARKLE_BIN:-}"
if [[ -z "$SPARKLE_BIN" ]]; then
  SPARKLE_BIN="$(find_sparkle_bin || true)"
fi
if [[ -z "$SPARKLE_BIN" || ! -x "$SPARKLE_BIN/generate_keys" ]]; then
  echo "error: Sparkle generate_keys not found." >&2
  echo "  Build once first so SPM downloads Sparkle:" >&2
  echo "    ./scripts/build.sh" >&2
  echo "  Then re-run: ./scripts/generate-sparkle-keys.sh" >&2
  exit 1
fi

echo "Using Sparkle tools: $SPARKLE_BIN"
echo "Keychain account: $ACCOUNT"
echo "Ensuring EdDSA key pair exists (private key → Keychain)…"

PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -z "$PUBLIC_KEY" ]]; then
  "$SPARKLE_BIN/generate_keys" --account "$ACCOUNT"
  PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" --account "$ACCOUNT" -p 2>/dev/null | tr -d '[:space:]' || true)"
fi

if [[ -z "$PUBLIC_KEY" ]]; then
  echo "error: could not read public key for account $ACCOUNT" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $PUBLIC_KEY" "$INFO" \
  || /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$INFO"

echo
echo "Wrote SUPublicEDKey into MacStayOn/Info.plist:"
echo "  $PUBLIC_KEY"
echo
echo "Private key is in your Keychain (account: $ACCOUNT)."
echo "Back it up securely (password manager). Never commit the private key."
echo "Export:"
echo "  \"$SPARKLE_BIN/generate_keys\" --account $ACCOUNT -x ~/Documents/macstayon-sparkle-eddsa.key"
echo
echo "Next: rebuild so the public key is inside the app, then notarize + publish:"
echo "  ./scripts/build.sh && ./scripts/notarize.sh && ./scripts/publish-release.sh vX.Y.Z"
