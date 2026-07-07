---
name: deploy-mini
description: Build, sign, install and restart the RoonSage ANALYZER SERVER on the Mac mini (server of record). Use when asked to deploy/redeploy to the mini, push the analyzer live, or verify what's running there. HARD CONSTRAINT — never deploy the client app (RoonSage.app) to the mini; only the analyzer. Requires Developer-ID signing; kill by PID, never by image name.
---

# deploy-mini — analyzer server → Mac mini

The Mac mini is the **server of record**: it runs the Roon sync, `library.db`, and the two
token-gated HTTP servers (:5767 library share, :5766 analyzer/audio). Mac + iOS apps are
thin clients. GUI automation on the mini is blocked — drive everything from the shell.

## Hard constraints (do not violate)

- **Only deploy the analyzer server** (`RoonSage Analyzer.app`, `com.roonsage.analyzer`).
  **NEVER** deploy the client app (`RoonSage.app`) to the mini — it is not the client's job
  and it is an explicit project constraint. If asked to "deploy to the mini", that means the
  analyzer.
- **Developer-ID signed only** — an ad-hoc build hangs on a keychain prompt and never binds
  the port. Never kill by image name (`pkill RoonSage…`) — find the PID and kill that.

## Steps

1. **Compile gate + build the signed app** (release build runs first as a compile gate):
   ```
   cd native && SIGN_IDENTITY="Developer ID Application: Casper Jansen (5W3QDZ94FH)" \
     ./scripts/build-analyzer-release.sh analyzer-vX.Y.Z    # → native/build/RoonSage Analyzer.app
   ```
   The script strips the `analyzer-v` prefix and copies the `*.bundle` resources into the
   `.app` (a missing bundle caused the v1.10.117 launch-crash). Notarization is skipped
   locally — fine for the mini.
2. **Stop the running server by PID** (never by image name):
   ```
   pgrep -f "RoonSage Analyzer.app/Contents/MacOS"     # get the PID
   kill -TERM <PID>                                     # wait for exit; kill -9 only if it hangs
   ```
3. **Install** — replace the app in /Applications:
   ```
   rm -rf "/Applications/RoonSage Analyzer.app"
   cp -R "native/build/RoonSage Analyzer.app" /Applications/
   ```
4. **Restart** and wait for the port to listen:
   ```
   open -a "/Applications/RoonSage Analyzer.app"
   ```
5. **Verify on loopback** (token-exempt). Expect no launch-crash and real data:
   ```
   curl -s localhost:5767/health   ;  curl -s localhost:5766/health
   curl -s localhost:5767/on-this-day | head -c 400
   ```
   After a restart the first ~2 min is an opstart-piek (Last.fm + artist-radio sync reading
   the whole library) — do NOT hammer endpoints in a loop then; GRDB readers pile up. Wait
   for it to settle, then measure once.

## Report

Record the result in docs/STATE.md `## Done`: `analyzer-vX.Y.Z live on mini (PID …, was …)`,
what you verified on loopback, and `Client-app NIET gedeployd (constraint)`.
