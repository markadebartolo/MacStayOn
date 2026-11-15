# Distribute MacStayOn (first-time Apple Developer guide)

This is the practical path: **Developer ID + notarization**, then put the zip on GitHub Releases (or your website). Not the Mac App Store — this app needs admin/`pmset`, which is a poor fit for App Store sandboxing.

Installed copies (1.3.0+) update via **Sparkle** from the GitHub Releases **appcast**.

## What you’ll end up with

1. A signed `MacStayOn.app`
2. Apple notarization (Gatekeeper trusts it)
3. A zip colleagues can download and open normally
4. An `appcast.xml` on the release so existing installs see **Check for Updates…**

## One-time setup (Apple Developer)

### 1. Enroll
- https://developer.apple.com/programs/ (~$99/year)
- Wait until the account is active

### 2. Create a **Developer ID Application** certificate
1. Open **Xcode → Settings → Accounts**
2. Add your Apple ID → select the team → **Manage Certificates…**
3. **+** → **Developer ID Application**
4. Confirm it appears in Keychain Access as  
   `Developer ID Application: Your Name (TEAMID)`

### 3. Create an app-specific password (for notarization)
1. https://appleid.apple.com → **Sign-In and Security** → **App-Specific Passwords**
2. Generate one named `MacStayOn Notary`
3. Save it somewhere safe (you’ll paste it once into Keychain via `notarytool`)

### 4. Store notary credentials in Keychain
In Terminal (replace placeholders):

```bash
xcrun notarytool store-credentials "MacStayOn-notary" \
  --apple-id "you@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

- **Team ID**: developer.apple.com → Membership details (10 characters)
- Use the **app-specific password**, not your Apple ID password

### 5. Find your signing identity name

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Copy the full quoted string, e.g.  
`Developer ID Application: Mark DeBartolo (QA3AY5HLGM)`

The Xcode project is already set to automatic signing for team **QA3AY5HLGM** (Mark DeBartolo). A local `./scripts/build.sh` signs with Developer ID when that identity is in the keychain (needed for Touch ID on the admin prompt). Notarization still uses `./scripts/notarize.sh` with the profile above.

### 6. Sparkle EdDSA keys (one-time, for in-app updates)

```bash
./scripts/build.sh                         # pulls Sparkle via SPM
./scripts/generate-sparkle-keys.sh         # private key → Keychain account MacStayOn; public → Info.plist
./scripts/build.sh                         # rebuild so the public key is inside the app
```

- **Public key** (`SUPublicEDKey`) is committed in `MacStayOn/Info.plist`.
- **Private key** stays in this Mac’s Keychain under account **`MacStayOn`** (separate from other Sparkle apps). Back it up in a password manager:
  ```bash
  # After Sparkle is in DerivedData:
  SPARKLE_BIN=$(find build ~/Library/Developer/Xcode/DerivedData -path '*/artifacts/sparkle/Sparkle/bin' -type d 2>/dev/null | head -1)
  mkdir -p ~/Documents/MacStayOn-secrets
  "$SPARKLE_BIN/generate_keys" --account MacStayOn -x ~/Documents/MacStayOn-secrets/macstayon-sparkle-eddsa.key
  chmod 600 ~/Documents/MacStayOn-secrets/macstayon-sparkle-eddsa.key
  ```
- Never commit the private key. If it leaks, generate new keys, bump the app, and ship a manual download once.
- `publish-release.sh` uses Keychain account `MacStayOn`, or `SPARKLE_ED_KEY_FILE` / `~/Documents/MacStayOn-secrets/macstayon-sparkle-eddsa.key` when Keychain ACL blocks automation.

**Feed URL** (already in Info.plist):

`https://github.com/markadebartolo/MacStayOn/releases/latest/download/appcast.xml`

## Build, sign, notarize

From the repo (after the one-time setup):

```bash
# 1. Bump MARKETING_VERSION / CURRENT_PROJECT_VERSION in project.yml
# 2. Build + notarize
export SIGN_IDENTITY="Developer ID Application: Mark DeBartolo (QA3AY5HLGM)"
export NOTARY_PROFILE="MacStayOn-notary"

./scripts/build.sh
./scripts/notarize.sh
```

This produces:

- `dist/MacStayOn.app` — signed + notarized + stapled
- `dist/MacStayOn-macos-arm64.zip` — ready to upload

## Publish release + appcast (so installs can update)

```bash
# Tag must match marketing version, e.g. v1.3.0
./scripts/publish-release.sh v1.3.0
```

That script:

1. Signs the zip with your Sparkle EdDSA key
2. Writes `appcast.xml` at the repo root
3. Creates (or updates) the GitHub Release with **both** `MacStayOn-macos-arm64.zip` and `appcast.xml`

Clients on **1.3.0+** use **Updates** in the menu bar panel (or the daily auto-check). Pre-1.3.0 users still need a one-time manual download from Releases.

### Manual equivalent

```bash
gh release create v1.3.0 \
  dist/MacStayOn-macos-arm64.zip \
  appcast.xml \
  --title "v1.3.0" \
  --notes "…"
```

## Ship the next update (checklist)

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`
2. `./scripts/build.sh && ./scripts/notarize.sh`
3. `./scripts/publish-release.sh vX.Y.Z`
4. On a Mac already running MacStayOn 1.3.0+: open the panel → **Updates** (or wait up to ~24h)

## First open on another Mac

Users download the zip, open `MacStayOn.app`. With notarization they should **not** need right-click → Open.  
(Still unsigned/not notarized builds need that workaround.)

## Troubleshooting

| Problem | Fix |
|--------|-----|
| `no identity found` | Create Developer ID Application cert in Xcode; check Team |
| `notarytool` auth failed | Recreate app-specific password; re-run `store-credentials` |
| Gatekeeper still blocks | Confirm `spctl -a -vv dist/MacStayOn.app` says “accepted” / notarized |
| Staple failed | Wait a minute, re-run `xcrun stapler staple dist/MacStayOn.app` |
| Updates: signature invalid | Same Mac (or restored private key) that generated `SUPublicEDKey` |
| Updates: You’re up to date | New release must have a **higher** `CFBundleVersion` than the installed app |
| `appcast.xml` 404 | Upload `appcast.xml` as a release asset; feed uses `…/latest/download/appcast.xml` |

## App Store?

Skip for now. Would need sandbox + a privileged helper redesign, and Apple often rejects “disable sleep” utilities.
