# Distribute MacStayOn (first-time Apple Developer guide)

This is the practical path: **Developer ID + notarization**, then put the zip on GitHub Releases (or your website). Not the Mac App Store — this app needs admin/`pmset`, which is a poor fit for App Store sandboxing.

## What you’ll end up with

1. A signed `MacStayOn.app`
2. Apple notarization (Gatekeeper trusts it)
3. A zip colleagues can download and open normally

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

The Xcode project is already set to automatic signing for team **QA3AY5HLGM** (Mark DeBartolo). A local `./scripts/build.sh` still builds unsigned. Notarization uses the Developer ID identity above, which is separate from the Apple Development certificate already on this Mac.

## Build, sign, notarize

From the repo (after the one-time setup):

```bash
export SIGN_IDENTITY="Developer ID Application: Mark DeBartolo (QA3AY5HLGM)"
export NOTARY_PROFILE="MacStayOn-notary"

./scripts/build.sh
./scripts/notarize.sh
```

This produces:

- `dist/MacStayOn.app` — signed + notarized + stapled
- `dist/MacStayOn-macos-arm64.zip` — ready to upload

## Upload to GitHub Releases

```bash
gh release upload v1.0.1 dist/MacStayOn-macos-arm64.zip --clobber
# or create a new release:
# gh release create v1.0.1 dist/MacStayOn-macos-arm64.zip --title "v1.0.1" --notes "Signed & notarized Mac build"
```

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

## App Store?

Skip for now. Would need sandbox + a privileged helper redesign, and Apple often rejects “disable sleep” utilities.
