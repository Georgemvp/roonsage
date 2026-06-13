# Code signing & notarization

The build pipeline already signs + notarizes **when the credentials are present**,
and falls back to ad-hoc signing otherwise. This doc lists exactly what *you* need
to provide. It needs an **Apple Developer Program** membership (€99/yr).

---

## 1. macOS — Developer ID + notarization (removes the Gatekeeper "right-click → Open" hack)

### One-time: create the certificate
1. developer.apple.com → **Certificates** → **+** → **Developer ID Application** → follow the steps (upload a CSR from Keychain Access → Certificate Assistant).
2. Download the `.cer`, double-click to add it to your **login** keychain.
3. In Keychain Access, find **"Developer ID Application: <Name> (TEAMID)"**, right-click → **Export** → save as `cert.p12`, set an export password.
4. Base64-encode it:
   ```bash
   base64 -i cert.p12 | pbcopy   # now on your clipboard
   ```

### One-time: create an app-specific password
appleid.apple.com → Sign-In & Security → **App-Specific Passwords** → generate one (used by `notarytool`).

### Add these GitHub repo secrets (Settings → Secrets and variables → Actions)
| Secret | Value |
|--------|-------|
| `APPLE_CERTIFICATE` | the base64 string from step 4 |
| `APPLE_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `KEYCHAIN_PASSWORD` | any throwaway password for the CI keychain |
| `APPLE_ID` | your Apple ID email |
| `APPLE_APP_PASSWORD` | the app-specific password |
| `APPLE_TEAM_ID` | `5W3QDZ94FH` |

The signing identity (`Developer ID Application: … (5W3QDZ94FH)`) is **auto-detected**
from the imported certificate — no separate secret needed.

That's it — the next `vX.Y.Z` tag will produce a **signed + notarized + stapled** DMG.
Without these secrets the workflow still builds an ad-hoc DMG (current behaviour).

### Build a signed DMG locally
```bash
cd native
SIGN_IDENTITY="Developer ID Application: <Name> (TEAMID)" \
APPLE_ID="you@example.com" \
APPLE_APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
APPLE_TEAM_ID="ABCDE12345" \
./scripts/build-release.sh 1.0.0
```

---

## 2. iOS — device / TestFlight

iOS apps must be signed with an Apple Developer Team (no ad-hoc App Store path).

### In Xcode (simplest)
1. `cd native/iosapp && xcodegen generate && open RoonSageiOS.xcodeproj`
2. Select the **RoonSageiOS** target → **Signing & Capabilities** → tick **Automatically manage signing** → choose your **Team**.
3. Pick a real device (or "Any iOS Device") → **Product → Archive** → **Distribute App → TestFlight & App Store**.

### Or from the command line
```bash
cd native/iosapp && xcodegen generate
xcodebuild -scheme RoonSageiOS -destination 'generic/platform=iOS' \
  -archivePath build/RoonSage.xcarchive \
  DEVELOPMENT_TEAM=ABCDE12345 archive
# then export/upload with an ExportOptions.plist or Transporter
```

### App Store Connect
Create the app record (bundle id `com.roonsage.ios`) at appstoreconnect.apple.com before the first TestFlight upload.

---

## Status
- iOS `DEVELOPMENT_TEAM` is wired in `project.yml` (`5W3QDZ94FH`) — iOS archives sign automatically.
- macOS notarization is fully wired in CI and waits only on the **6 GitHub secrets** above. Add them and the next `vX.Y.Z` tag is a clean signed + notarized release.
- Your `MACOS_SIGN_IDENTITY` will read `Developer ID Application: <Your Name> (5W3QDZ94FH)`.
