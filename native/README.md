# RoonSage — native (primary product)

The actively-developed RoonSage: native **macOS** & **iOS** apps plus a macOS
**Analyzer** (the audio-analysis server-of-record). Pure Swift/SwiftUI on a local
**GRDB** database — no Python backend. For the product overview, features, and
build/run instructions see the root **[README](../README.md)**.

## Layout

| Path | What it is |
|------|------------|
| `RoonSage/` | Shared SPM package. Targets: **RoonSageCore** (Roon client, sync, DB, services), **RoonSageUI** (SwiftUI views, shared by both apps), **RoonSageMCP** (Claude Desktop stdio bridge), **AudioAnalysis** (DSP/ML), **AnalyzerCore** (analyzer orchestration + feature server), and the app/CLI executables (`RoonSage`, `RoonSageAnalyzerApp`, `roonsage-analyzer`, `roonsage-mcp`). |
| `RoonProtocol/` | Dependency-free Roon transport protocol codec (MOO/SOOD) + `protocol-check`. |
| `iosapp/` | iOS/iPadOS app (xcodegen — `project.yml` is the source of truth; the `.xcodeproj` is generated, not committed). Includes the Widgets/Live-Activity extension. |
| `assets/` | App icons + generators (`make-icon.swift`, `make-analyzer-icon.swift`, `make-launch-logo.swift`, `make-icns.sh`). |
| `scripts/` | Release builds (`build-release.sh`, `build-analyzer-release.sh`) + model setup. |
| `docs/`, `ROADMAP.md`, `SIGNING.md` | Native docs. Architecture deep-dive: [`../docs/NATIVE_APP_AUDIT.md`](../docs/NATIVE_APP_AUDIT.md). |

## Common commands

```bash
# Tests (run from each package dir)
cd RoonSage      && swift test
cd RoonProtocol  && swift test

# Release-build sanity (CI is stricter than debug — run before tagging)
cd RoonSage && swift build -c release

# Lint (config at repo root)
swiftlint lint --config ../.swiftlint.yml

# iOS project (regenerate after editing project.yml)
cd iosapp && xcodegen generate

# Package the apps
./scripts/build-release.sh          # macOS app + DMG
./scripts/build-analyzer-release.sh # Analyzer app + DMG
```

## Releases

Three independent tag tracks, each triggering its own GitHub Actions workflow:
`vX.Y.Z` (macOS), `ios-vX.Y.Z` (iOS → TestFlight), `analyzer-vX.Y.Z` (Analyzer).
Versions are stamped into Info.plist from the tag at build time.
