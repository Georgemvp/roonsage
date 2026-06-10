# RoonSage Native + Analyzer — Improvement Roadmap

> Status snapshot: main app **v1.5.28**, analyzer **v1.0.5**.
> Goal: a more professional, faster, better-looking native app; smarter features; and a
> codebase from which an **iOS app ships alongside the Mac version** with minimal duplication.
> Technical text is English (matches repo convention); user-facing UI labels are Dutch.

---

## 0. Where we are (verified against the code)

| Area | State |
|------|-------|
| App architecture | `RoonClient` = one `@MainActor @Observable` god-object (~842 lines) holding **all** state + actions. `DatabaseManager` ~806 lines. |
| Navigation | `NavigationSplitView` + 12-item sidebar (`ContentView.swift`). Cmd+1…9 tab shortcuts. |
| Theme | `Theme.swift`: 3 hardcoded colors (gold `#e5a00d` / dark `#1a1a1a` / surface), one `Badge`. No light/system mode, no accent picker. |
| Persistence | GRDB; schema in `RoonSageCore/Database/`. |
| Analyzer | Standalone app + CLI on the Mac mini, serves `/features` over HTTP; consumed by the app over ZeroTier. |
| iOS readiness | **Strong.** `RoonSageCore`, `AudioAnalysis`, `AnalyzerCore`, `RoonProtocol` are platform-clean (zero AppKit). Networking is `Network`/`URLSession`. macOS-only code is contained to: `RoonSageApp.swift` (MenuBarExtra/Settings scene), `SettingsView`/`UpdateView` (`NSAlert`), and the DMG updater (`UpdateInstaller.swift`, `AnalyzerUpdater.swift`). |
| Known bug | Analyzer↔app audio-feature join stuck at ~41% due to `TrackIdentity.matchKey` divergence (Roon title prefixes + classical metadata). Durable fix designed but not shipped. |

**Implication:** an iOS app is a UI + packaging exercise, not a rewrite. The analyzer never needs to run on iOS — the phone consumes `/features` over the network like the Mac does.

---

## Track A — iOS-readiness foundation (do first; unlocks everything)

**Outcome:** one codebase, `RoonSage` (macOS) + `RoonSageiOS` targets, sharing a new `RoonSageUI` library. A working iOS build that connects, browses, plays, curates, and builds DJ sets — without breaking the Mac app.

> **Progress (2026-06-10, branch `feat/ios-foundation-shared-ui`):** A1, A2 (updater), A4 ✅.
> Extracted the `RoonSageUI` library (13 views + Theme + `AlbumArtView` + `Compat.swift`),
> kept the app shell (App/ContentView/MenuBar/Settings/Update) in the macOS executable.
> Guarded the DMG updater (`UpdateInstaller`) behind `#if os(macOS)` (uses `Process`).
> Added cross-platform shims in `Compat.swift`: `.help()` no-op + `Color.platformQuaternaryFill`/`platformCardBackground`.
> **Verified:** the whole shared stack (`RoonProtocol` + `RoonSageCore` + GRDB + `AudioAnalysis` + all 13 views)
> compiles for the **iOS Simulator SDK**; macOS debug + release builds clean; all 12 tests pass.
> iOS verify command (no simulator runtime installed locally):
> `swift build --target RoonSageUI -Xswiftc -sdk -Xswiftc $(xcrun --sdk iphonesimulator --show-sdk-path) -Xswiftc -target -Xswiftc arm64-apple-ios17.0-simulator -Xcc -isysroot -Xcc $(xcrun --sdk iphonesimulator --show-sdk-path) -Xcc -target -Xcc arm64-apple-ios17.0-simulator`

- [x] **A1. Multiplatform package.** `Package.swift`: `platforms: [.macOS(.v14), .iOS(.v17)]` + `RoonSageUI` library target; reusable views moved out of the `RoonSage` executable.
- [~] **A2. Isolate macOS chrome behind `#if os(macOS)`:**
  - [x] DMG updater (`UpdateInstaller.swift`) — guarded; irrelevant on iOS (App Store).
  - [ ] `RoonSageApp.swift` — `MenuBarExtra`, `Settings` scene, window styling (still macOS-only; an iOS app target gets its own root scene).
  - [ ] `NSAlert` (`RoonSageApp.swift`) + `NSWorkspace` (`SettingsView.swift`) → SwiftUI `.alert` / `openURL` when those move to shared code.
  - [ ] Define an `UpdateService` protocol with a macOS impl + iOS no-op.
- [ ] **A3. Adaptive navigation.** Keep `NavigationSplitView` for Mac/iPad; add a `TabView` path for iPhone (5 primary tabs + "Meer"). One `AppNavigation` view that switches on `horizontalSizeClass`. (`MainAppView` currently lives in the macOS exe — move it / fork it into `RoonSageUI`.)
- [x] **A4. Audit `RoonClient` for Mac assumptions** — compiles clean for iOS; no AppKit leaked into the shared path (the only `Process`/AppKit use was the now-guarded updater).
- [ ] **A5. iOS app target + entitlements** — needs an Xcode project (SPM can't emit an `.app`/`.ipa`); local-network usage description (ZeroTier/SOOD), background audio mode if needed.
- [ ] **A6. Verify:** TestFlight-able iOS build that connects and plays (needs simulator runtime / device + signing).

**Acceptance:** Mac app unchanged; iOS app connects over ZeroTier, browses library, plays, curates, builds a DJ set from synced features.

---

## Track B — Design, theme & professionalism

**Outcome:** a polished, configurable, "feels native on both platforms" look.

- [ ] **B1. Real design system.** Expand `Theme.swift` into tokens backed by an **asset catalog** (so light/dark resolve automatically): semantic colors (success/warning/danger/info), elevation levels, radius scale, motion tokens. Keep `Spacing`/`Typography`/`Badge`.
- [ ] **B2. Appearance settings** (Dutch labels): "Verschijning" (Licht / Donker / Systeem) + "Accentkleur" picker. Today everything is hardcoded gold via `.tint(.roonGold)` at the app root — make the tint user-driven via `@AppStorage`.
- [ ] **B3. Album-art-driven dynamic color** on Now Playing — extract dominant color → subtle gradient backdrop. High perceived-quality win.
- [ ] **B4. Per-screen polish pass:** consistent empty-states, loading **skeletons** instead of spinners, consistent toolbar + SF Symbols, refined Connect/onboarding flow (`ConnectView.swift`).
- [ ] **B5. Proper signing & notarization (Mac).** Replace the ad-hoc-sign + quarantine-strip hack with Developer ID + notarization → Gatekeeper hack gone, updater becomes reliable. (iOS requires the Developer Program anyway.)
- [ ] **B6. Icon refresh** for both the main app and the analyzer; consistent iconography.

**Acceptance:** user can switch theme + accent; Now Playing adapts to art; notarized DMG installs without quarantine workarounds.

---

## Track C — Speed & code quality (existing features)

**Outcome:** no main-thread hitches on a 31k-track library; smaller, testable units.

- [ ] **C1. DB reads off the main thread.** `filterTracks`, `browseTracks`, `searchTracks`, `topTags` run synchronously on `@MainActor` today. Make them `async` via GRDB `DatabasePool.read`, or `ValueObservation` for live lists.
- [ ] **C2. Split `RoonClient`** (842 lines) into feature services that feed the `@Observable` store: `PlaybackService`, `LibraryQueryService`, `CurationService`, `SyncService`. Smaller units, testable, and required for clean iOS reuse.
- [ ] **C3. Album-art caching** — verify/harden `AlbumArtView` (44 lines): memory + disk cache; avoid re-fetching on scroll.
- [ ] **C4. Precompute heavy vectors** — Music Map / Sonic similarity cached in the DB instead of recomputed per view (`SonicEngine`/`SonicSimilarity`).
- [ ] **C5. Split `DatabaseManager`** (806 lines) by domain (queries vs schema vs sync).
- [ ] **C6. Tests** around the new services (currently mostly DB/Sonic). Reminder: always `swift build -c release` before tagging — release strict-concurrency catches what debug misses.

**Acceptance:** scrolling/filtering a 31k library is smooth; `RoonClient` < ~300 lines; new services unit-tested.

---

## Track D — New features (pick by taste)

- [ ] **D1. Live DJ mode ("Tonight's Set")** — full-screen, beat-synced, next-track suggestions on Camelot + BPM while you play; key-clash warnings + transition hints.
- [ ] **D2. Smart endless radio ("Sonic Radio++")** — infinite stream that learns from skips/likes.
- [ ] **D3. Energy/mood timeline** — visualize the energy curve of a playlist or DJ set.
- [ ] **D4. In-app natural-language search** (not just via Claude Desktop MCP) — "speel iets donkers en hypnotisch rond 122 BPM".
- [ ] **D5. Port watchlist + scheduler/automations** to native (still missing per project notes).
- [ ] **D6. iOS Widgets + Live Activities** — now-playing on lockscreen / Dynamic Island.
- [ ] **D7. Handoff / Continuity** — build a set on Mac, continue on iPhone.
- [ ] **D8. Export DJ set** → Rekordbox / Serato / M3U.
- [ ] **D9. AirPlay / local playback on iOS** (later) — phone as control *and* listening endpoint.

---

## Track E — Analyzer improvements

- [ ] **E1. Durable `matchKey` fix (highest priority).** Switch `TrackIdentity.matchKey` to `artist|title` + leading-position-prefix strip (`^(\d+-\d+|\d+\.)\s*`) + feat-only paren strip (NOT Live/Remix/Edit) in **both** app and analyzer, and compute match_key at `/features` export time (FeatureStore stores it as PK, so old keys otherwise persist). Lifts the join off the ~41% ceiling. **Warn before any resync/re-key until both sides ship together** (a one-off Python patch to `library.db` is currently holding it).
- [ ] **E2. Accuracy.** Tempo octave correction + prior; constant-Q chroma + major/minor disambiguation. *Or* vendor **aubio** (tempo) / **libKeyFinder** (key) into the isolated analyzer process (GPL, doesn't touch the app's license). Biggest DJ-set quality lever.
- [ ] **E3. CoreML tagging** as an option beside Ollama — faster, no local LLM dependency.
- [ ] **E4. Throughput** on the slow USB drive — already well-optimized (120s start-excerpt, streaming walk, concurrency 3); revisit the decode pipeline only if needed.

**Acceptance:** match-rate measurably above 41%; BPM octave-stable; keys major/minor-correct on a validation sample.

---

## Recommended sequencing

```
Phase 1 (foundation)   A1–A4   +   E1            → iOS-ready core, biggest bug fixed
Phase 2 (visible win)  B1–B4   +   C1–C2         → polish + responsiveness
Phase 3 (ship iOS)     A5–A6   +   B5            → TestFlight + notarized Mac
Phase 4 (depth)        C3–C6, E2, then D (taste) → quality + new features
```

Track A is the lever: once Core is multiplatform and the chrome is isolated, the iOS app comes almost for free and every later improvement pays off on both platforms.

## Conventions (don't regress)

- Keep protocol/business logic in `RoonSageCore` / `AudioAnalysis` — never import AppKit there.
- Mac app & analyzer have **separate** tag schemes: `vX.Y.Z` vs `analyzer-vX.Y.Z`. Pushing the tag triggers the release workflow.
- `swift build -c release` **before** tagging (release strict-concurrency > debug).
- UI text Dutch, code/API/commits English.
```
