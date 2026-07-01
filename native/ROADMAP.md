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
  - [x] `NSWorkspace` (`SettingsView.swift`) → `openURL`; `SettingsView` is now shared & cross-platform.
  - [ ] `RoonSageApp.swift` — `MenuBarExtra`, `Settings` scene, window styling stay macOS-only (the iOS app has its own root scene — fine as-is).
  - [ ] `NSAlert` (`RoonSageApp.swift` manual update check) → SwiftUI `.alert` (macOS-only path, low priority).
  - [ ] Define an `UpdateService` protocol with a macOS impl + iOS no-op (optional).
- [x] **A3. Adaptive navigation.** `RootView` in `RoonSageUI`: `NavigationSplitView` on regular width (macOS/iPad), `TabView` on compact (iPhone). Shared destination switch + zone/transport toolbar. `ContentView`/`SidebarItem` moved to `RoonSageUI` and made public.
- [x] **A4. Audit `RoonClient` for Mac assumptions** — compiles clean for iOS; no AppKit leaked into the shared path (the only `Process`/AppKit use was the now-guarded updater).
- [x] **A5. iOS app target.** `native/iosapp/` — `RoonSageiOSApp.swift` (@main → shared `ContentView`) + `project.yml` (xcodegen) referencing the local `RoonSage` package (RoonSageUI + RoonSageCore), synthesized Info.plist with `NSLocalNetworkUsageDescription`, iPhone+iPad, iOS 17. `xcodegen generate` succeeds; package graph + `RoonSageiOS` scheme resolve.
- [x] **A6. Verify (Simulator).** iOS 26.5 Simulator runtime installed; `RoonSage.app` **builds, installs, launches and renders** on iPhone 17 Pro sim (ConnectView with gold accent). Build: `cd native/iosapp && xcodebuild -scheme RoonSageiOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`. **Still TODO for device/TestFlight:** a real Apple Developer Team for signing, app icon, and a live connect test over ZeroTier.

**Acceptance:** Mac app unchanged; iOS app connects over ZeroTier, browses library, plays, curates, builds a DJ set from synced features.

---

## Track B — Design, theme & professionalism

**Outcome:** a polished, configurable, "feels native on both platforms" look.

- [x] **B2. Appearance settings.** `Appearance.swift` in `RoonSageUI`: `@AppStorage` ThemeMode (Systeem/Licht/Donker) + AccentChoice (7 presets, Roon gold default) + `.roonSageAppearance()` applied at the shared root. Dutch "Verschijning" section in Settings. (Done out of order — highest-visibility win.)
- [x] **B1. Real design system.** `Theme.swift`: semantic state colors (`roonSuccess/Warning/Danger/Info`, adaptive via system palette), `Radius` scale, `Motion` tokens; ad-hoc `.green/.red/.orange` + exact cornerRadius literals swept across RoonSageUI + macOS shell; dead hardcoded-dark `roonBg`/`roonSurface` removed. (Asset-catalog backing deferred — system palette already resolves light/dark.)
- [x] **B2. Appearance settings** — done (see Track B header note).
- [x] **B3. Album-art-driven dynamic color** — Now Playing cards get a gradient backdrop tinted by the art's dominant colour (CIAreaAverage, cached), animated on track change.
- [x] **B4. Per-screen polish pass.** SkeletonRows on Library/Ask/LiveDJ/Discovery; every list view has a proper empty state; refresh toolbar button consistent across Library/MusicMap/SonicFingerprint/Discovery/Playlists/TasteProfile.
- [~] **B5. Proper signing & notarization (Mac).** Infra DONE: `build-release.sh` already signs+notarizes when env set; the release workflow now imports a Developer ID cert + passes notarization creds **when secrets exist** (ad-hoc fallback otherwise). `native/SIGNING.md` documents the cert + GitHub secrets + iOS TestFlight path. **Needs Casper:** Apple Developer membership, the 6 macOS secrets, and his Team ID for iOS.
- [x] **B6. App icon** — gold `music.note.house` glyph on a dark gradient; `make-icon.swift` + `RoonSage.icns` (macOS) + `AppIcon.appiconset` (iOS), wired into both apps. (Analyzer app icon = future.)

**Acceptance:** user can switch theme + accent; Now Playing adapts to art; notarized DMG installs without quarantine workarounds.

---

## Track C — Speed & code quality (existing features)

**Outcome:** no main-thread hitches on a 31k-track library; smaller, testable units.

- [x] **C1. Heavy DB reads off the main thread.** The 9 bulk reads (filter/browse/search/candidate/playlist/discovery) are now `async` on `RoonClient`, running the blocking `pool.read` off the main actor via `Task.detached`; light count queries stay sync. Call sites (5 views + MCP) updated. (Future: `ValueObservation` for live lists.)
- [~] **C2. Split `RoonClient`** — done as a behaviour-neutral `extension` split: 853-line file → 382-line core + `RoonClient+{Transport,Library,Features,Qobuz,Playlists}.swift` (type-level `private`→`internal` so cross-file extensions reach state). Smaller/navigable units with zero runtime change. (Full service-object extraction with separate `PlaybackService`/`SyncService` deferred — needs live-Core verification.)
- [x] **C3. Album-art caching** — `ImageCache` actor (NSCache + in-flight dedupe) + `CachedArtImage`; `AlbumArtView` no longer re-fetches/re-decodes on scroll. **+ on-disk layer** (`DiskImageCache` in Core): lookup is memory → disk → Roon Core HTTP, so art survives app launches and the Core's image server isn't re-hit for already-fetched art (a connection-load win too); LRU-ish prune to 200 MB once per session; load runs detached so disk/network I/O doesn't serialise on the cache actor. 5 unit tests.
- [x] **C4. Sonic library cache.** `SonicLibraryCache` actor (single-flight, off-main) caches the tracks↔features join used by similarTracks/sonicFingerprint/sonicLibrary (Live DJ re-ran it per track change); invalidated on feature+library sync and the Reload buttons. 2 unit tests.
- [x] **C5. Split `DatabaseManager`** — behaviour-neutral extension split: 806-line file → 22-line core (pool + init) + DatabaseManager+{Tracks,History,Filter,Discovery,AudioFeatures}.swift.
- [ ] **C6. Tests** around the new services (currently mostly DB/Sonic). Reminder: always `swift build -c release` before tagging — release strict-concurrency catches what debug misses.

**Acceptance:** scrolling/filtering a 31k library is smooth; `RoonClient` < ~300 lines; new services unit-tested.

---

## Track D — New features (pick by taste)

- [x] **D1. Live DJ mode** — "Live DJ" tab suggests harmonically-compatible next tracks (Camelot + BPM) for the now-playing track, with one-tap play/queue. (Full-screen beat-synced view = future.)
- [ ] **D2. Smart endless radio ("Sonic Radio++")** — infinite stream that learns from skips/likes.
- [x] **D3. Energy/mood timeline** — DJ Set view now shows a BPM curve, a fixed-scale energy arc, and a harmonic-transition strip (gold=harmonic, green=same key, grey=tempo-only) with an "X/Y harmonische overgangen" summary.
- [x] **D4. In-app natural-language search** — "Vraag het" tab: a vibe prompt → LLM `analyzeForFilters` → local filter → instantly-playable results (play now / queue next / play all). Lighter than Generate (one LLM call, no second curation stage).
- [ ] **D5. Port watchlist + scheduler/automations** to native (still missing per project notes).
- [~] **D6. iOS Widgets + Live Activities** — v1 SHIPPED: `RoonSageWidgets` extension + Live Activity (lock screen + Dynamic Island, system-side elapsed timer; controller keyed on nowPlaying/state/zone). Future: push-token updates (stays live when app suspended), home-screen widget (needs App Group).
- [ ] **D7. Handoff / Continuity** — build a set on Mac, continue on iPhone.
- [x] **D8. Export DJ set** — `SetlistExport` (readable tracklist + M3U, with BPM/Camelot) via a ShareLink in the DJ Set view.
- [x] **D9. Local playback on iOS/Mac** — phone (or Mac) as control *and* listening endpoint. SHIPPED: `LocalPlaybackController` (own AVPlayer + queue + audio session) streams library tracks from the analyzer `/audio` endpoint; `NowPlayingCenter` routes lock-screen/Control-Center/CarPlay commands; `UIBackgroundModes: audio` keeps it alive when backgrounded. `LocalPlayButton` ("speel op dit apparaat", no zone required) is wired into Generate, library album/artist detail, Discovery, Recommend, Sonic DNA, Song Paths, Song Alchemy and Sonic Search. Only locally-analysed on-disk tracks play (Qobuz/stream-only are skipped and reported); experimental opt-in Qobuz-CDN fallback in Settings. Remaining: native AirPlay route picker.

---

## Track E — Analyzer improvements

- [x] **E1a. Durable `matchKey` normaliser (shipped).** `TrackIdentity.matchKey` is `artist|title` + leading-position-prefix strip (`^(\d+-\d+|\d+\.)\s*`) + feat-only paren strip (keeps Live/Remix/Edit) + remaster/edition strip, on **both** app and analyzer; analyzer recomputes match_key at `/features` export time (`FeatureStore.exportJSON`). Schema migrations v6–v8 NULL `tracks.match_key` so resync regenerates. (The old Python `library.db` patch is now moot — Docker is being decommissioned, native uses its own GRDB DB.)
- [x] **E1b. Primary-artist convergence (shipped, needs resync to take effect).** `TrackIdentity.primaryArtist` reduces a multi-artist string to its first credited artist (cuts ` feat./ft./featuring `, then first `, ; / &`) so Roon's "A" matches file tags' "A feat. B" / "A & B". Used in `matchKey`; migration `v9_primary_artist_matchkey` NULLs match_keys; 8 unit tests in `TrackIdentityTests`. **App + analyzer must ship/tag together, then resync.**
- [x] **E1c. Measure the residual (shipped).** `RoonClient.diagnoseAudioFeatures` + `DatabaseManager.reconcileFeatureMatches(apply:false)` report exact/fuzzy/unmatched counts, match-rate and up to 30 unmatched "artist — title" examples — read-only, mutates nothing. Surfaced via a "Diagnose match-rate" button in Settings → Audio analyzer. Gives a real baseline (the "~41%" predates E1a/E1b).
- [x] **E1d. Fuzzy fallback join (shipped).** `reconcileFeatureMatches(apply:true)` (run automatically after every feature sync) fuzzy-matches still-unmatched library tracks to feature rows *within the same primary artist* using a token-containment score (`FuzzyMatch`, threshold 0.85 — handles classical truncation "Symphony No. 5" ⊂ "…in C Minor, Op. 67") and rewrites `tracks.match_key` to the feature's key so the existing DJ/Sonic joins pick them up with no query change. 14 unit tests (`TrackIdentityTests` + `FuzzyMatchTests`).
- [~] **E2. Accuracy.** Shipped two low-risk, validated-on-synthetic-signals gains: **(a)** parabolic autocorr-peak interpolation in `TempoAnalyzer` for sub-frame BPM precision (kept the proven log-Gaussian prior for octave choice); **(b)** per-frame chroma normalisation + silent-frame gating in `KeyAnalyzer` so a loud chorus no longer outweighs a quiet verse. 4 synthetic tests (`AudioAccuracyTests`: 120/90 BPM click tracks lock the right octave; C major/minor scales detect root+mode).
  **Tried and reverted:** a comb-filter octave corrector — it *regressed* a clean 120-BPM click to 60 because a periodic signal's half-tempo harmonics align exactly on integer autocorr lags while the true period falls between them. Don't re-attempt blind.
  **Validation harness SHIPPED:** `roonsage-analyzer validate <musicdir> --reference <csv>` (CSV `artist,title,bpm,camelot`; matches files→reference by `TrackIdentity.matchKey`, analyzes, reports BPM exact/half/double-tempo + key exact/relative(major-minor swap)/neighbour/off percentages). Logic in `AnalyzerCore.AccuracyValidator`, 9 unit tests. **Casper: supply a reference CSV** (export the old Docker `track_audio_features` to artist,title,bpm,camelot, or hand-label a sample) and run it to get the real baseline.
  **Then (needs that baseline):** real octave-correction on hard cases + robust major/minor — now *measurable*, so tune against the harness, *or* vendor **aubio**/**libKeyFinder** into the isolated analyzer process (GPL, separate process — doesn't touch the app license).
- [ ] **E3. CoreML tagging** as an option beside Ollama — faster, no local LLM dependency.
- [ ] **E4. Throughput** on the slow USB drive — already well-optimized (120s start-excerpt, streaming walk, concurrency 3); revisit the decode pipeline only if needed.
- [~] **E5. Sonic embeddings (CLAP via Core ML).** Lift the analyzer from 7 scalars to a learned 512-dim embedding per track + mood scores, so Similar/Map/Path/Alchemy/Fingerprint run on a real vector index (k-NN) instead of rule-based BPM/Camelot/tag distance. Model: `laion/larger_clap_music_and_speech`. See `docs/EMBEDDING_NOTES.md`.
  - [x] **E5a. Conversion spike (shipped).** `scripts/convert_clap_to_coreml.py` exports the audio + text encoders to `CLAPAudio.mlpackage` / `CLAPText.mlpackage`, dumps the slaney mel config + filter bank + Core-ML-computed mood-label embeddings + a deterministic golden vector set. Custom torch op maps HTSAT's unsupported `upsample_bicubic2d` → exact-size bilinear resize. Spike: converts + runs on Apple Silicon, embeddings discriminate, PyTorch↔Core ML rankings preserved (per-vector parity 0.93–0.99 from the bilinear approx — common-mode, cancels in retrieval).
  - [x] **E5b. Swift mel front-end + Core ML inference (shipped).** `CLAPMel` reproduces `ClapFeatureExtractor` (periodic-Hann STFT via `RealFFT.powerSpectrum`, reflect-pad, slaney filter bank, power-to-dB) and `CLAPModel` wraps both `.mlpackage` for `embed()` / `moods(forEmbedding:)` / low-level `textEmbedding`. Golden test proves it: mel mean|Δ| = 0.0008 dB, full Swift→Core ML embedding cosine 1.0 vs PyTorch. Models load best-effort (graceful scalar-only fallback when absent). `CLAPEmbeddingTests`.
  - [x] **E5c. Persist + serve (shipped).** `AudioFeatures` carries embedding/moods/version; `FeatureStore` got BLOB columns via idempotent `ALTER TABLE` + version-gated walk (embedding-only re-analysis, no scalar recompute). Analyzer serves moods/model on `/features` (vector base64 via `?embed=1`) + a compact binary `/embeddings` (RSEB). App migration v15 + `applyEmbeddingsBlob` attaches vectors by match_key. Round-trip tested.
  - [x] **E5d. Vector index + rewire (shipped).** `VectorIndex` (brute-force cosine via `vDSP_mmul`) memoized in `SonicLibraryCache`. Similar/Fingerprint/Path/Alchemy use it when seeds carry vectors (rule-based fallback otherwise); Song Path = cosine walk with Camelot/BPM secondary tie-break. Music Map → `PCAProjector` 2D (power iteration, no LAPACK), stored in `map_x/map_y`. Free-text search: native RoBERTa-BPE tokenizer (golden-matched to HF) → analyzer `/text-embed` → `VectorIndex.nearest`, new `SonicSearchView`. A/B flag `useSonicEmbeddings` (Settings toggle) keeps the scalar baseline.
  - **OPEN:** how to ship the `.mlpackage` weights + tokenizer/mel resources to the analyzer host (Git LFS / build-time download / SPM resource bundle) — currently git-ignored and loaded from a dev path / `ROONSAGE_CLAP_DIR`. Decide before the analyzer release build wires `Bundle.module`.
- [~] **E6. Hybrid AI retrieval (shipped).** The LLM playlist features now consult the embeddings: `RoonClient.sonicRerank` embeds the free-text request via the analyzer `/text-embed` and reorders the LLM-filtered candidate pool by cosine to that vector (per-artist cap for variety, pure core in `rankCandidates`, 3 tests). **Vraag het** ranks its pool sonically instead of random; **Genereer** feeds the LLM a sonically-ordered pool so its selection is grounded. Both fall back to the old behaviour when the analyzer text model / embeddings are unavailable, gated by `useSonicEmbeddings`. (`analyzer-app` must serve `/text-embed`: load CLAP on the main actor — see the v1.1.1 fix.)
  - **Next:** mood-explicit generation (LLM picks a mood centroid), and reranking Recommend/album flows.

**Acceptance:** match-rate measurably above 41%; BPM octave-stable; keys major/minor-correct on a validation sample.

---

## Track F — Discovery Engine ("Ontdekkingen")

**Outcome:** an *outward*-facing recommendation engine — artists/albums you don't
own yet — adapting [digarr](https://github.com/iuliandita/digarr)'s 7-stage
pipeline (Collect→Discover→Resolve→Score→Filter→Store) to Roon+Qobuz. Distinct
from `DiscoveryView`/"Ontdek" (editorial, library-only). Server-of-record only
(`RoonSageCore/Discovery/`); clients fetch the feed + POST accept/play/reject over
`LibraryShareServer` (5767). Full plan + scoring formula in the session that shipped it.

- [x] **F1. Pipeline skeleton + storage.** Migrations v23–v25 (`recommendation_batches`/`_items`, `artist_watchlist`, `discovery_rejections` — additive, no forced resync). Pure stages: `DiscoveryScoring` (digarr's weighted composite: 0.30 consensus/0.25 similarity/0.20 genre/0.15 AI/0.10 feedback + ±0.15 album modifier), `DiscoveryFilter` (in-library/listened/blocked/cooldown/threshold), `DiscoveryPipeline` (merge→resolve→score→filter). New `MusicBrainzDiscoveryClient` (RoonSageCore-local; `AnalyzerCore`'s MB client is genre-only and unreachable from here) — artist resolve + studio release-groups + relationships, reusing the analyzer's rate-limit reservation pattern. `QobuzClient` gained album resolution (`resolveAlbums`/`scoreAlbumCandidate`/`appendAlbumToPlaylist`) — Qobuz is the primary "is-it-playable" resolver (search gives free cover art + release date); MB handles dedup/relationships/gap-fill. 30 unit tests.
- [x] **F2. Producers (buildable now — no new accounts needed).** `SimilarArtistWebProducer` (Last.fm `artist.getsimilar`), `ChartsProducer` (`chart.gettopartists`), `ReleaseRadarProducer` (watchlist → MB studio release-groups newer than a per-artist `last_seen_rg` watermark — pure `newReleasesSinceSeen`, tested), `GapFillProducer` (top-played artists' missing studio albums, `gapPriority=1.0`), `ArtistRelationshipsProducer` (MB collaboration graph, `member of band`/`collaboration` only), `ListenBrainzRadioProducer` (LB's own similarity graph via `/1/lb-radio/artist/{mbid}` + `/1/user/{u}/similar-users` — a second, independent discovery angle from Last.fm). 6 tests.
  - **Scoped out (not a bug — a real follow-up):** LB **Tag Radio** (`/1/lb-radio/tags`) returns recordings, not artists — needs a per-recording MB `lookupRecording` resolve (a second rate-limited pass); revisit once F1's MB budget has headroom.
- [x] **F3. Accept/reject actions.** Accept = save album to the stable Qobuz "Ontdekkingen" playlist (additive `appendAlbumToPlaylist`, never replaces) + follow the artist (watchlist, feeds F2's release-radar). Play = separate action (queue/play now via the existing `qobuz_search::` synthetic-key path — no new command wiring). Reject = persistent block/cooldown (`discovery_rejections`, 60-day default).
- [x] **F4. UI.** New `SidebarItem.discover` ("Ontdekkingen", `wand.and.stars.inverse`) — deliberately separate from the existing `.discovery`/"Ontdek". `DiscoverFeedView`: cards (art/score-chip/source-badges/explanation/Accept·Play·Reject), kind filter, empty/loading states, "Ververs" → `/discovery/run`.
- [x] **F5. AI producer + explanation cards.** `AIPicksProducer`: LLM-proposed artists/albums from the taste profile (top/liked/disliked artists), `aiConfidence`-scored; still MB-validated in Resolve like every other producer, so a hallucinated name just drops rather than becoming a wrong recommendation. `DiscoveryExplanations`: one BATCHED LLM call per run writes a short Dutch "waarom past dit" per item, cached by `explanation_sig` (artist+album+sources+genres, FNV-1a via the existing `RoonClient.seed64`) keyed on the persistent `dedup_key` — a recommendation that keeps reappearing across daily runs is explained once, not regenerated every day. LLM down/unreachable → templated Dutch fallback, never blocks the batch. Reuses `LLMClient`/`LLMConfigStore` — no new provider code. 16 tests.
- [x] **F6. Scheduler.** Daily auto-run wired (`startDiscoveryRefresh`, `.direct`-gated, from `RoonSageAnalyzerApp`). Skip-if-unchanged guard (`DiscoveryPipeline.tasteSignature` + `shouldSkipRun`, pure/tested): a stable, order-independent hash over top/liked/disliked artists + watchlist is compared to the last stored batch's `taste_sig`; if unchanged AND that batch is still fresh, the whole MB/LLM-costed pipeline is skipped and the existing batch id is returned. One guard serves both gaps — scheduled runs get a 6h grace (so charts/new-releases still drift-refresh even with static taste) and manual "Ververs" gets 30 min (mainly guards against impatient repeat taps); a genuine taste change always forces a full run regardless of recency. 10 tests.
- [ ] **F7. Gated producers** (each needs a NEW client + the user's own account — ship one at a time): Discogs **Labels**, Deezer **Flow**, Spotify **Saved Albums** (OAuth — biggest lift, sequence last).

**Experience layer (F8–F12) — priority-ordered *before* F7.** The engine is digarr-class; these make it *show* what it already knows. Adapts digarr's swipe-approve UX, analytics dashboard, and tunable weights.

- [x] **F8. Feed-as-experience (mooier).** `DiscoverFeedView` rebuilt from a flat 64px-thumbnail list into hero-art cards: full-width cover (190pt, `CachedArtImage` crop-to-fill, with a legibility scrim + the total score as a chip), the persisted `ScoreComponents` surfaced as a compact "Score-opbouw" equaliser (consensus/similarity/genre/AI/feedback — the data was already in `score_json`, just never shown), and native `.swipeActions` (leading full-swipe = Bewaar/Volg; trailing reveal-and-tap = Overslaan + Speel). Deliberately List-based, **not** a custom ZStack card-stack, to stay clear of the iOS-26 over-wide NavigationStack bug the ScrollView views were rebuilt to dodge. On-card buttons stay for macOS/accessibility. Client UI only — no server/DB/API change. (ios-v1.7.40 / v1.10.68)
- [x] **F9. Swipe-stack polish (1b).** Full-swipe Overslaan restored behind an **undo** affordance — delayed-commit (`reject()` holds the POST ~4.5 s inside a cancellable `rejectTask`; a floating "Ongedaan maken" bar cancels it and restores the card; `commitPendingRejectNow()` flushes on a new skip / refresh / `onDisappear` so nothing is silently dropped; no new endpoint) — plus an onboarding empty-state that explains Ontdekkingen (outward, Qobuz-playable) vs. Ontdek (library-only). (ios-v1.7.41 / v1.10.69)
- [ ] **F10. Ontdek-inzichten (professioneler).** New `GET /discovery/stats` on `LibraryShareServer` aggregating `recommendation_items` + `discovery_rejections`: approval rate, new-this-week, per-producer **source effectiveness** (accept-ratio), genre trend. New `DiscoverInsightsView` (metric cards + producer bars). Source-effectiveness is the feedback loop that later prunes/auto-tunes weak producers. Read-only aggregation — no schema change.
- [ ] **F11. Afstembaar (Fase 3).** Persist `ScoringWeights` (currently hardcoded `.default` in `DiscoveryPipeline`) + a Settings "veilig ↔ avontuurlijk" dial reusing `SonicRadioView`'s novelty-dial pattern (one slider maps onto the six weights), per-producer on/off toggles, and a configurable rejection cooldown.
- [ ] **F12. Mood + wekelijkse digest (Fase 4).** `mood` parameter on `/discovery/run` biasing producers/score toward one of the 8 existing mood centroids / CLAP moods (Track E5) — "iets als X maar donkerder". Weekly digest as a separate cached Qobuz playlist ("Ontdekkingen — week NN") + one push via the existing Live Activity/notification infra.

**Acceptance:** `curl localhost:5767/discovery/run` then `/discovery/recommendations` returns MB-validated, Qobuz-resolved albums from ≥4 independent producers; accept lands one in "Ontdekkingen" + the artist on the watchlist; reject survives a re-run (cooldown honoured).

**Relation to D2/D5 above:** F1–F4 give the native app its first artist-watchlist / "new releases from artists you follow" primitive (`artist_watchlist`, Release-Radar) — the sliver of **D5** that's release-driven. D5's *scheduler/automations* (cron playlist regen, trigger-action workflows) remain unported. **D2** ("Sonic Radio++, learns from skips/likes") is a different, in-library radio concept — untouched by Track F.

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
- Three **separate** tag schemes drive three release workflows — never share a namespace:
  Mac app `vX.Y.Z`, analyzer `analyzer-vX.Y.Z`, iOS/TestFlight `ios-vX.Y.Z`. Pushing the tag triggers the matching workflow.
  (iOS marketing version must stay **> 1.6.1** — a 1.6.1 build was uploaded to TestFlight once; current floor is `ios-v1.6.2`.)
- `swift build -c release` **before** tagging (release strict-concurrency > debug).
- UI text Dutch, code/API/commits English.
```
