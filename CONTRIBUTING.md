# Contributing to RoonSage

Thanks for considering a contribution. RoonSage is now a **native macOS/iOS
app** (Swift/SwiftUI). The bar for a good contribution is: **does it work
reliably on someone else's machine?**

## Repository layout

| Path | What |
|------|------|
| [`native/`](native/) | **Primary** — native macOS & iOS apps (Swift Package + xcodegen iOS app + analyzer) |
| [`legacy-docker/`](legacy-docker/) | **Deprecated** — original FastAPI web app + MCP server, kept for reference only |
| `docs/` | Architecture audit, setup guides |
| `data/` | Runtime data + a few tracked templates (used by the legacy backend) |

## Native app (primary)

```bash
git clone https://github.com/Georgemvp/roonsage.git
cd roonsage/native

# Run the Swift test suites
(cd RoonProtocol && swift test)
(cd RoonSage && swift test)

# Release build (CI is stricter than a debug build — run this before tagging)
(cd RoonSage && swift build -c release --product RoonSage)

# Build the macOS DMG (see native/SIGNING.md for signing/notarization env)
./scripts/build-release.sh 1.0.0

# Generate + open the iOS Xcode project
cd iosapp && xcodegen generate && open RoonSageiOS.xcodeproj
```

CI for native code runs in `.github/workflows/native-tests.yml` (the primary
CI) and the `release-macos`/`release-ios`/`release-analyzer` workflows, which
trigger on the `v*`, `ios-v*`, and `analyzer-v*` tag namespaces respectively.

### Code style (Swift)

- SwiftUI views; shared logic in `RoonSageCore`/`RoonSageUI`. GRDB for storage.
- Comments explain *why* (hidden constraints, workarounds), not *what*.
- **UI text is Dutch; code and commit messages are English** (repo convention).

## Legacy Docker web-app

The Python/FastAPI stack lives under [`legacy-docker/`](legacy-docker/) and is
**deprecated** — only touch it for reference fixes. Its setup, tests, and
architecture rules are documented in
[`legacy-docker/README.md`](legacy-docker/README.md). Its tests run via
`.github/workflows/test.yml` (path-filtered to `legacy-docker/**`).

## Pull requests

- Keep PRs focused — one feature or fix per PR.
- Include a short description of *why* the change is needed, not just what.
- Screenshots for UI changes.
- Read [`CLAUDE.md`](CLAUDE.md) for the repository structure and Roon API
  constraints before working on anything Roon-adjacent.
