---
name: native-check
description: Verify a RoonSage native change compiles and passes tests with the REAL exit code. Use before saying "works/passing/done", or when you just want a quick "does this build?" gate without the full ship flow. Runs swift build + swift test (+ optional release build / swiftlint) bare — no grep|echo that would mask a non-zero exit.
---

# native-check — the RoonSage build/test gate

Run these **bare** and read the actual exit code. Never pipe the build/test through
`grep`/`echo`/`tee` to "check for errors" — a pipe returns the *last* command's exit
code, so a red build reads as green (this exact mistake pushed v1.10.106/107 broken).

## Steps

1. **Protocol package** (only if you touched `native/RoonProtocol`):
   ```
   cd native/RoonProtocol && swift test
   ```
2. **Main package** (the usual gate):
   ```
   cd native/RoonSage && swift build && swift test
   ```
   Read the trailing `Compiling…`/`Test Suite … passed`/exit line. `swift test` prints
   the failure count; a debug build passing does **not** guarantee release passes.
3. **Release sanity** — required before tagging (CI is stricter than debug):
   ```
   cd native/RoonSage && swift build -c release --product RoonSage
   ```
   Full CI also builds `--product RoonSageAnalyzerApp roonsage-analyzer roonsage-mcp`.
4. **Lint gate** (when asked or before release):
   ```
   swiftlint lint --config .swiftlint.yml
   ```
5. **iOS** (only if you touched `native/iosapp`): `cd native/iosapp && xcodegen generate`
   regenerates `RoonSageiOS.xcodeproj` — never hand-edit the `.xcodeproj`.

## Report

Report only in the two legal forms (docs/guardrails/VERIFY.md):
- `Verified: cd native/RoonSage && swift build && swift test -> N tests, 0 failures (exit 0)`
- `UNVERIFIED — to confirm, run: <command>`

If a check is red: quote the failure, propose the change, **wait for approval** — never
weaken a test to make it green (hard stop). If you only edited files, and did not run the
gate this turn, say `EDITED-UNVERIFIED: <file>` instead of "works".
