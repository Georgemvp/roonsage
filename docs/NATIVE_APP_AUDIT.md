# RoonSage Native (macOS + iOS) — Volledige Code-, Performance-, Design- & Feature-audit

> Datum: 2026-06-12 · Scope: `macos/RoonSage`, `macos/RoonProtocol`, `macos/iosapp` (~108 Swift-bestanden, ~14k regels)
> Methode: 5 parallelle diepte-audits (architectuur, UI/UX, performance, iOS-platform, feature-parity).

## ✅ Voortgang (2026-06-12, zelfde dag)

**Fase 0 volledig geïmplementeerd + quick wins + eerste Fase 1-hero (alle 57 tests groen):**
- A2/A4/C2: per-request timeout (15s), receive-loop guard op socket-identiteit, registration-send-failure fix (`RoonTransport.swift`)
- A5: sync prune-guard — `finishSyncRun(pruneStale:)`, prune alleen bij 0 mislukte albums
- A3: `RoonClient.ActionError` + `runAction` helper; alle transport-acties + `curateTracks` + `transferZone` rapporteren falen → `ActionErrorToast` in `RootView.swift`
- A1/B5/B9: `libraryStats`/`recentListens`/`topArtistsListened`/`totalListens`/`topTags`/`playlists`/`audioFeaturesStats`/`buildDJSet`/`buildRadio` async + `Task.detached`; `refreshTrackCount` fire-and-forget; DJSetView & SettingsView body-DB-reads → `@State` + `.task`; alle call-sites (UI + MCP) bijgewerkt
- B1: FTS5 external-content index (`v12_fts_search` migratie, triggers, `ftsQuery`-sanitizer) → `searchTracks`/`browseTracks`/`filterTracks` keywords; + unit test
- B2: `LibraryView.sortedTracks` → gecachte `displayTracks` (recompute alleen op tracks/sort-change, off-main)
- B4/F13: ImageCache `totalCostLimit` 96MB + cost per image, `CGImageSourceCreateThumbnailAtIndex`-downsampling (target uit URL-width), colorCache cap 256
- S1: Keychain `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
- P2/P3: `busyMode .timeout(5)`, gedeelde `DatabaseManager.isoFormatter` (6 call-sites)
- Quick wins: goud+wit→zwart-op-goud contrast, `.accessibilityLabel` op icon-knoppen (Playlists/Library), `Motion.*` tokens toegepast (Library/MusicMap/NowPlaying/ContentView), Skeleton respecteert reduce-motion, `Motion.spring` token toegevoegd
- **Hero #1 — Immersive Now Playing geleverd**: full-bleed geblurde art-backdrop + materiaal + dominantColor-scrim, 420pt art met spring-pop (pauze-krimp, track-change transition), zone-switcher chips, grote gouden transport (56pt), royale scrubber met resterende-tijd, Badge-component hergebruikt, reduce-motion gerespecteerd
- N.B. `DiscoveredRoonCore` bleek **niet** dood (gebruikt door `protocol-check`) — laten staan.

**Fase 1-vervolg (zelfde dag, ronde 2):**
- `Card`/`.cardStyle()`-component + `Haptics`-helper (tap/success/error, no-op op macOS) in Theme.swift; alle 7 Discovery-kaarten + StatCard geünificeerd
- "Deal-out" reveal in GenerateView: rijen dealen met 30ms stagger + spring, gouden `wand.and.stars`-bounce, success-haptic, reduce-motion-pad; haptics op Play again/Save
- A8 ✅: `ScrobbleCoordinator`-actor — per zone één gegate commit (min(length/2, 240s), ≥30s vloer), cancel bij trackwissel/zone-weg, LF now-playing direct, scrobble-timestamp = starttijd; vervangt de ongeordende `Task.detached`
- N2 ✅: zones-subscribe retry (3s bij send-faal) + 10s-watchdog die her-subscribet als de initiële state nooit aankomt

**Ronde 3 (zelfde dag) — taal-unificatie ✅ + Fase 2 gestart:**
- **Taal-unificatie afgerond**: alle UI-views, Core-strings (ConnectionState, actie-fouten, sync-fases, transport-errors), menubar, macOS-menu's, updater-dialoog → consistent Nederlands. Featurenamen (DJ Set, Live DJ, Sonic DNA, Music Map, Sonic Radio) en LLM-prompts blijven Engels; MCP-output blijft Engels (voor de LLM). `SidebarItem.title` / `SortField.label` toegevoegd zodat rawValue-ID's stabiel blijven.
- **MPNowPlayingInfoCenter + MPRemoteCommandCenter** (`iosapp/Sources/NowPlayingCenter.swift`): Lock Screen/Control Center/AirPods/CarPlay-bediening, incl. artwork via ImageCache en seek via changePlaybackPosition. Beperking gedocumenteerd: zonder lokale audio-sessie kan iOS de controls bij suspensie aan een andere app geven.
- **Live Activity `staleDate`**: activity dimt nu na verwacht trackeinde i.p.v. bevroren verkeerde track.
- **Interactieve Live Activity + Siri/Shortcuts**: `RoonClient.shared` + `ensureConnected()` (auto-reconnect voor background-intents); `PlayPauseIntent`/`NextTrackIntent`/`PreviousTrackIntent` als `LiveActivityIntent` in `Shared/` (type in beide targets via `WIDGET_EXTENSION`-conditie, perform draait in app-proces); transport-knoppen in Dynamic Island expanded + Lock Screen-banner; `RoonSageShortcuts` met NL Siri-frases.
- Extra haptics: Library/Ask/Queue play- en queue-acties, DJ-set-build success.

**Ronde 4 — releases + widget:**
- **Uitgebracht**: macOS **v1.5.36** (DMG op GitHub Releases, in-app updater pikt hem op) en iOS **ios-v1.6.9** (TestFlight) — beide CI-runs groen.
- **App Group + home-screen widget** (ios-v1.6.10): `group.com.roonsage.ios` entitlements op app + widget-extensie; `SharedNowPlaying`-snapshot (app schrijft bij elke wissel + reloadTimelines); `ZoneControlWidget` (systemSmall/Medium + accessoryRectangular Lock Screen-complicatie) met interactieve play/pause/next via de LiveActivityIntents; `syncSystemSurfaces()` bundelt Live Activity + MPNowPlayingInfo + widget-snapshot.

**Ronde 5 — alle drie hero-redesigns (macOS v1.5.37):**
- **Hero #5 Sonic DNA living fingerprint**: radar springt uit centrum + ademt (TimelineView, reduce-motion-gated), radiale goud→amber fill + vertex-dots, "personality"-headline, gestaggerde tag-drift, deelbaar via ImageRenderer, ViewThatFits voor iPhone.
- **Hero #3 Live DJ mix-radar**: Camelot-wiel met huidige track in centrum, orbitende suggesties (A binnen/B buiten, grootte=tempo-match, kleur=hue), gloed+puls op compatibele keys, neon-gouden bogen, tap→snap-select + actiebalk; lijst blijft als detail.
- **Hero #4 Discovery editorial**: hero "Herontdek"-kaart, cover-forward shelves (horizontale scroll + play-overlay), Swift Charts (gouden area-chart decennia + balkgrafiek genres) met tappbare chips, sectiekoppen met SF Symbol.

**Hero-redesigns uit het audit-rapport: 5/5 geleverd** (Now Playing #1 + curatie deal-out #2 in eerdere rondes; #3/#4/#5 nu).

**Nog open (Fase 2-rest):** art in Live Activity/widget via App Group-bestand, APNs/ActivityKit-push, BGTaskScheduler, Handoff — plus de eenmalige **App Group-registratie** (taak #18) die ios-v1.6.10 deblokkeert.
**Ronde 6 — Fase 3 gestart + release-discipline:**
- **Templates-pariteit** (macOS v1.5.39): alle 63 backend-sjablonen geport naar `PlaylistTemplates.swift` (8 NL-categorieën, prompts blijven Engels), met featured-rij + gecategoriseerde "Alle sjablonen"-sheet in GenerateView.
- **Release-build-discipline**: v1.5.37 faalde op CI (release-modus is stricter: `ambiguous use of cos`); sindsdien `swift build -c release` lokaal vóór elke tag → v1.5.38 + v1.5.39 groen. Vastgelegd in geheugen.

**Uitgebrachte versies vandaag:** macOS v1.5.36 · v1.5.38 (heroes) · v1.5.39 (templates) — alle DMG-releases groen. iOS ios-v1.6.9 (TestFlight, groen). iOS ios-v1.6.10 geblokkeerd op App Group-registratie (taak Casper).

**Fase 3 features (nog te doen):** scrobble-import, taste LB/LF-merge, Song Paths/Alchemy, Year-in-Review.
**Perf-diepte (nog te doen):** B3 (sonic feature-vectors/bitsets), B6 (vDSP-analyzer), B7 (batch-sync).
**Tech-debt (nog te doen):** A10 (controllers extraheren), A11 (Codable responses), A12 (chunkedInsert-helper). **Fase 3:** features (templates-pariteit, Sonic Radio-knop bestaat al, scrobble-import, taste LB/LF-merge, Song Paths/Alchemy) + B3/B6/B7-perf + A10/A11/A12-techdebt + Discovery-editorial (Hero #4), Live DJ mix-radar (Hero #3), Sonic DNA living fingerprint (Hero #5).

---

## 0. Eindoordeel in één alinea

De fundering is **echt goed**: een actor-gebaseerde transportlaag, een serieel-gelockte Roon Browse-laag, hervatbare sync met checkpoints, een handgeschreven MOO/SOOD-protocolcodec, GRDB met WAL, een gevectoriseerde FFT, en — uniek — een **on-device Swift audio-analyzer** (BPM/Camelot/energy) die librosa/Docker volledig vervangt. Maar de app oogt vandaag als een *competente native tool*, niet als een Apple Design Award-kandidaat. De kloof zit in drie dingen: (1) het design-systeem bestaat maar wordt in ~60% van de views genegeerd, (2) er is **geen hero Now Playing-moment** — het paradepaardje van elke muziek-app ontbreekt, en (3) de iOS-app is een dunne shell zonder de native superkrachten (widgets, Lock Screen-bediening, Live Activity-knoppen, Shortcuts). Daarnaast lekt er functionaliteit weg vs. de Python-backend (113 → 26 MCP-tools) en zitten er een handvol echte correctheids-/dataverlies-randen in error-handling en sync.

**Drie hoogste hefbomen:** ① bouw een echte immersive Now Playing-ervaring, ② maak de iOS-app native (MPNowPlayingInfoCenter + interactieve widgets + Live Activity-knoppen + App Group), ③ haal de DB-reads van de main thread af en zet FTS5 op zoeken.

---

## DEEL A — Code & Architectuur

### Sterke punten
- Netwerk- en Roon-transport correct geïsoleerd in `actor`s (`RoonTransport`, `BrowseService`, `TransportService`, `LibrarySyncService`, `SonicLibraryCache`).
- `RoonClient` is `@MainActor @Observable`; zware reads worden via `Task.detached` van de main thread gehaald.
- Schone mixin-split van `RoonClient` en `DatabaseManager`. Pure, testbare cores (`SonicSimilarity`, `DJSetBuilder`, `Camelot`, `TrackIdentity`). Geen `try!`, `fatalError`, `as!` of TODO/FIXME. Uitstekende "waarom"-comments.

### Kritieke & hoge bevindingen
| # | Bestand:regel | Sev | Probleem | Fix |
|---|---|---|---|---|
| A1 | `RoonClient+Library.swift` (`libraryStats`, `recentListens`, `topArtistsListened`, `totalListens`, `topTags`) + `RoonClient+Playlists.playlists()` | High | `@MainActor` getters doen **blocking** `pool.read` met full-table aggregaten (`COUNT(DISTINCT …)`, GROUP BY) → zichtbare UI-hitch op 30k tracks | Maak `async` + `Task.detached` (patroon bestaat al), of cache stats en refresh op sync-einde |
| A2 | `Transport/RoonTransport.swift:133-142` (`request`) | High | Geen per-request timeout; enige backstop is de 20s connection-watchdog die *alle* pending requests tegelijk laat falen → één hangende browse stalt tot 20s | Per-request `Task.sleep`-timeout die de continuation met error hervat en uit `pendingRequests` haalt |
| A3 | `RoonClient+Transport/+Playlists/+Qobuz` (overal `_ = try? await …`) | High | Elke gebruikersactie (play/next/volume/seek/curate) slikt fouten stil; `curateTracks` no-opt als `browseService==nil` zonder feedback | Geef `Result`/throw terug óf zet observable `lastActionError` → toast in UI; log minimaal |
| A4 | `Transport/RoonTransport.swift:193-215` (`processReceived`) | High | Receive-loop wordt onvoorwaardelijk her-armed met de *oude* `wsTask`; na reconnect kan een stale socket continuations van een nieuwe verbinding resolven | `guard self.wsTask === wsTask, isConnected else { return }` vóór `startReceiving` |
| A5 | `LibrarySyncService.sync` (`:117-123`, `:209-211`) + `DatabaseManager+Sync.swift:103-116` (`finishSyncRun`) | High (dataverlies-rand) | Per-album browse-fouten worden stil geslikt; daarna **verwijdert** `finishSyncRun` rijen die deze generatie niet gecheckpoint zijn → flaky sync die tóch "voltooit" kan de library laten krimpen | Tel mislukte albums; prune alléén als failed-count == 0 |

### Medium / tech-debt
- **A6** `RoonClient.init` (`:103`): `database = try? …` → bij DB-faal draait de hele app stil met lege library. Voeg `databaseError` + herstelbare banner toe.
- **A7** `BrowseService.genreMapping` (`:190-208`): re-popt de genres-root één keer *per genre* (ephemeral keys) → O(genres²) browse-verkeer; correct maar traag.
- **A8** `RoonClient.applyZoneUpdate` (`:368-396`): scrobbles via ongeordende `Task.detached` per track-wissel; scrobblet élke now-playing-change op `timestamp=now` → korte plays scrobblen. Serialiseer via één actor met min-speelduur-gate + persisted last-scrobbled state.
- **A9** Subscriptions (`RoonTransport.subscribe` `:157-171`) timen nooit uit; een gemiste subscribe-COMPLETE = permanent lege Now Playing tot full reconnect. Detecteer & resubscribe.
- **A10** `RoonClient` groeit naar god-object (~10 verantwoordelijkheden). Extraheer `PlaybackController`/`LibraryController`/`ConnectionController` achter protocollen.
- **A11** `[String: Any]` JSON-dicts overal door transport→browse→models met ad-hoc `as? String ?? ""`. Decodeer Roon-responses één keer naar `Codable` structs in de transportlaag.
- **A12** Gedupliceerde chunked-insert-loop in 5+ plekken → generieke `chunkedInsert(table:columns:rows:)`.

### Security
- **S1 (Medium)** `Auth/KeychainStore.swift:13-22`: geen `kSecAttrAccessible` → Roon-token & Last.fm session-key synct via iCloud Keychain en zit in backups. Zet `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- **S2 (Medium)** `QobuzClient.tryLogin` (`:66-82`): wachtwoord als GET-queryparam (belandt in logs/proxies). POST in body.
- **S3 (Medium)** `LibraryShareServer`: ongeauthenticeerd, bindt alle interfaces → volledige library leesbaar op poort 5767. Eis een shared secret of bind alléén op de ZeroTier-interface.
- **Positief:** DMG-updater doet echte codesign + Team-ID-verificatie vóór swap; quarantine-strip staat correct ná de signatuurcheck.

**Top-10 fixes (code):** A1 · A2 · A3+A5 · A4 · S1 · A8 · (FTS5, zie Deel B) · S3 · A9 · A11+A12.

---

## DEEL B — Performance & Snelheid

### Sterke punten (niet aankomen)
Gevectoriseerde `RealFFT` met hergebruikte scratch-buffers; `vDSP_svesq` RMS; batched multi-row upserts; zware reads off-main; resumable per-album checkpoints; `[weak self]` overal (geen retain cycles); zone seek-frame-filtering tegen observable-churn.

### Top-10 speedups
| # | Bestand:regel | Sev | Kost | Fix & impact |
|---|---|---|---|---|
| B1 | `DatabaseManager+Discovery.swift:108-111`, `+Tracks.swift:74-84`, `+Filter.swift:40` | High | `LIKE '%q%'` met leading wildcard → **full table scan** per toetsaanslag; `LOWER()` per rij verslaat indexen | **FTS5** virtual table over (title,artist,album) + `MATCH`. Grootste interactieve win op 10k+ |
| B2 | `LibraryView.swift:25-42` (`sortedTracks`) | High | Re-sort + re-dedupe (`localizedCaseInsensitiveCompare`) bij **elke** body-eval (selectie, keystroke, sync-tick); `.random` herschudt elke render | Cache in `@State`, herbereken alleen op `tracks`/`sort`-change; dedupe bij fetch |
| B3 | `Sonic/SonicEngine.swift:43-63` + `SonicSimilarity.distance` | High | Fingerprint = ~1.2M `distance()`-calls; elke call alloceert `Set<String>` tags + parse't Camelot-string | Precompute numerieke feature-vector + tag-bitset per track → branchless float-math + `popcount`. Seconden → sub-seconde |
| B4 | `RoonSageUI/ImageCache.swift:11-13` | High | NSCache `countLimit=400` zonder `totalCostLimit`, geen downsampling → 400 full-res bitmaps; kritiek op iOS | Zet `totalCostLimit` (64–128MB) + `cost:`; downsample via `CGImageSourceCreateThumbnailAtIndex` |
| B5 | `RoonClient+Library.swift:177` → `DatabaseManager+Discovery.swift:143-154` (`topTags`) | High | Full feature-table fetch + N JSON-decodes **op main**, bij elke Library-appear | Async/detached + precompute tag-counts tabel bij feature-sync |
| B6 | `AudioAnalysis/TempoAnalyzer.swift` (windowing/flux/autocorrelatie) | High | Scalar loops; O(L²) autocorrelatie per lag — heetste loop van de analyzer | `vDSP_vmul`/`vDSP_dotpr` of FFT-based autocorrelatie (Wiener–Khinchin) → 5–20× |
| B7 | `LibrarySyncService.swift:154` → `DatabaseManager+Sync.swift` | Medium | Eén transactie (WAL fsync) **per album** ~9.5k keer | Batch ~25 albums per transactie |
| B8 | `DatabaseManager+Discovery.swift:10-21,42-85` | Medium | Joins op `LOWER(title)=LOWER(artist)` (geen functionele index) + `ORDER BY RANDOM()` over alle albums | `title_lower`/`artist_lower` geïndexeerde kolommen; gesamplede random |
| B9 | `RoonClient+Library.swift:18-32`, `RoonClient+Features.swift:15,91` | Medium | `libraryStats`/`recentListens`/`audioFeaturesStats` synchroon op main | `Task.detached` |
| B10 | `Sonic/SonicLibraryCache.swift` | Medium | Houdt hele 30k-track array sessielang vast | Drop op `didReceiveMemoryWarning` (iOS) |

**Quick wins:** `KeyAnalyzer` windowing → één `vDSP_vmul`; hoist `ISO8601DateFormatter` naar `static let` (`+History.logListen`, fired elke track-wissel); cap unbounded `colorCache`; verhoog Roon browse `pageSize` boven 100.

---

## DEEL C — Design, UX & Animatie (de "100 designers"-as)

### Diagnose
Er ís een design-systeem (`Theme.swift`: 4-pt `Spacing`, `Radius`, `Typography`, `Motion`, semantische `Color.roon*`, `Badge`) — maar het wordt in slechts ~4 van de 20 views consequent gebruikt. `Motion.*` en `Typography.*` worden door **nul** views gebruikt. De componentbibliotheek is half af: `Badge` bestaat (en wordt 3× geforkt), maar `Card`, `SectionHeader`, `TrackRow`, `PromptComposer` worden gekopieerd.

### Visuele polish — Top 15 (geprioriteerd)
1. **Bouw een echte hero Now Playing** (`NowPlayingView.swift`) — nu een lijst zone-kaarten met 56pt thumbnail. *Hoogste impact.* (zie Hero #1)
2. **Unificeer de taal** — Nederlands en Engels staan dóór elkaar binnen views (`DJSetView`: "Build DJ Set" naast "Exporteer"/"Energie"; `SettingsView`; `LiveDJView` volledig NL, `GenerateView` volledig EN). *Meest amateuristisch ogende issue.* → één `String catalog`, kies Nederlands.
3. **Adopteer je eigen tokens** — vervang inline `Spacing`/`Radius`/`Motion`/`Typography`-literals (Generate `spacing:22`/`padding(24)`, NowPlaying, Discovery `cornerRadius:10`).
4. **Eén gedeelde `Card`-container** — 3 verschillende kaart-recepten coëxisteren (`.background.secondary` vs `platformCardBackground.opacity(0.5)` vs `cornerRadius:10`).
5. **Verwijder de 3 geforkte `badge`/`featBadge`-helpers** (`NowPlaying:224`, `Library:296`, `DJSet:150`) → route alles via `Badge`.
6. **Fix goud+wit contrast** (actieve tag-chip `LibraryView:191` ~2.3:1 — onder WCAG AA) → zwarte tekst op goud.
7. **44pt hit-targets** op alle iOS-rij-glyphknoppen (Library/Ask/LiveDJ/Playlists/NowPlaying ~22pt).
8. **Vervang `.help()`-only labels door `.accessibilityLabel`** — `.help()` is een no-op op iOS (`Compat.swift:17`) → iOS-knoppen hebben nu géén toegankelijke labels.
9. **Animeer resultaatlijsten** (Generate/Recommend/Ask/Discovery) met staggered `.transition` + `Motion.standard`.
10. **iOS-haptics** op play/queue/save/zone-select/DJ-build (nu nul `sensoryFeedback`).
11. **Respecteer reduce-motion** (Skeleton-pulse, repeating `symbolEffect`, art-crossfade).
12. **`.onHover` rij-highlighting op macOS** + maak hele library-rij speelbaar (nu alleen het kleine knopje).
13. **`.swipeActions`** (play/queue/delete) op iOS-lijsten.
14. **Discovery als cover-forward shelves** + Swift Charts i.p.v. handgetekende `GeometryReader`-bars.
15. **Herschrijf developer-speak empty states** (`PlaylistsView:24` "save_playlist via Claude Desktop").

### Vijf "wow-factor" hero-herontwerpen (art direction)
1. **Immersive Now Playing — het paradepaardje.** Full-bleed achtergrond = albumart zwaar geblurred (`.blur(60)`) + verticale scrim met de al-berekende `ImageCache.dominantColor` (de pipeline bestaat al, maar voedt nu enkel een 30%-rechthoekje). Albumart ~70% breed, `Radius.xl`, zachte schaduw, spring-scale 0.94→1.0 bij trackwissel (krimpt bij pauze — de "card pop"). Royale custom scrubber met groeiende thumb, monospaced elapsed/remaining; grote gouden `play.circle.fill` (44pt). Achtergrond-tint cross-fade met `Motion.ambient` (0.8s). iOS: swipe-down to dismiss.
2. **AI-curatie "deal-out" reveal.** Generate dumpt nu een lijst. In plaats daarvan: "Curated N tracks"-banner in-sliden, dan elke rij met 30ms stagger in-dealen (`.move(edge:.trailing)+.opacity`, spring), art die infade. Gouden `symbolEffect(.bounce)` op `wand.and.stars` + success-haptic. De payoff voor het LLM-wachten.
3. **Live DJ "mix radar".** Camelot-wiel als hero: huidige track in het centrum, harmonisch-compatibele suggesties orbiten op hun wielpositie, grootte = tempo-match, kleur = bestaande Camelot-hue (al in MusicMap). Compatibele keys gloeien goud & pulseren; clashes dimmen. Tap → queue-next met snap-to-center. Donkere-vilt achtergrond, neon-gouden harmonische bogen.
4. **Discovery als editorial "Listen Now".** Vervang 7 grijze stapelkaarten door een magazine: full-width hero "rediscover"-kaart (vergeten favoriet, grote art + gouden Play-overlay), dan horizontale cover-shelves met parallax, dan één Swift Charts area-chart (decade, gouden gradient). Sectiekoppen: SF Symbol + accent + chevron. Beeld doet het werk, niet tekstrijen.
5. **Sonic DNA "living fingerprint".** Radar van statische stroke → ademende identiteit: vertices spring-en uit het centrum, zachte undulatie (reduce-motion-gated), radiale goud→amber fill. Signature-tags driften één voor één in. "Personality"-headline ("High-energy, major-key, eclectic tempo"). Hele kaart deelbaar als afbeelding (Spotify-Wrapped-meets-readout).

### Toegankelijkheid (apart benoemd)
Dynamic Type genegeerd door veel vaste `Font.system(size:)` + vaste frames (`SettingsView width:440`, `statRow width:220`) die clippen; Canvas-viz (radar/curve/scatter/bars) volledig onzichtbaar voor VoiceOver — voeg `.accessibilityLabel`/`.accessibilityValue` toe ("Energy 72 procent").

---

## DEEL D — iOS-app, Widgets & Live Activity

**Verdict:** volledige *view*-pariteit (alle 14 views hergebruikt uit `RoonSageUI`), maar de iOS-eigen code is ~270 regels en bijna elke native iOS-superkracht ontbreekt.

### Top-10 iOS-gaten
1. **Geen `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`** → geen Lock Screen / Control Center / AirPods / CarPlay-bediening. *Hoogste hefboom* — bestaande `RoonClient+Transport`-API's zijn er al; alleen bedraden. (High)
2. **Geen home-screen / Lock Screen / StandBy widgets** — de bundle bevat enkel een Live Activity, geen `StaticConfiguration`/`AppIntentConfiguration`, geen `TimelineProvider`. (High)
3. **Geen App Group + geen entitlements-bestanden** (beide targets) → blokkeert gedeelde data, art-caching, interactieve bediening, push. (High)
4. **Live Activity heeft geen knoppen** — geen `Button(intent:)` play/pause/skip; iOS 17 `LiveActivityIntent` ongebruikt. (High)
5. **Geen App Intents / Shortcuts / Siri.** (High)
6. **Live Activity `staleDate: nil` + geen push-tokens** → bevroren verkeerde track op Lock Screen bij suspensie. Zet `staleDate` op trackeinde. (High)
7. **Geen APNs / push** (ook de echte fix voor #6). (Medium-high)
8. **Geen background audio session** — alleen 30s `beginBackgroundTask` tijdens sync. (Medium-high)
9. **Geen `BGTaskScheduler`** background-refresh voor cache/zone/widget-versheid. (Medium)
10. **Geen haptics, geen Handoff/`NSUserActivity`** continuïteit met macOS. (Medium/low)

### Zes iOS-flagship features
1. **Lock Screen now-playing + volledige bediening** (`MPNowPlayingInfoCenter`+`MPRemoteCommandCenter`) — hoogste leverage, gratis Lock Screen/Control Center/AirPods/CarPlay.
2. **Interactieve Live Activity / Dynamic Island** — `LiveActivityIntent`-knoppen + art via App Group-cache.
3. **"Zone Control" widgets** — `systemSmall` now-playing-per-zone + `accessoryRectangular/Circular` complicaties met interactieve play/pause; configureerbare zone.
4. **Siri/Shortcuts App Intents** — `PlayInZoneIntent`, `GeneratePlaylistIntent("chill avond mix in de woonkamer")` via `AppShortcutsProvider`.
5. **StandBy now-playing** — full-bleed art + zone + elapsed; gedockt iPhone = Roon-zonedisplay op het nachtkastje.
6. **Handoff + Live Activity push** — `NSUserActivity` voor iPhone↔Mac continuïteit + ActivityKit push-tokens.

*Goed gedaan al:* adaptieve `NavigationSplitView`/`TabView` met Create/Explore-hubs; `NSLocalNetworkUsageDescription` correct; ZeroTier auto-retry + scene-phase resume; CI naar TestFlight met `ios-v*` tag-namespace.

---

## DEEL E — Feature-pariteit & Nieuwe Features

### Pariteit met de Python-backend (samengevat)
**Aanwezig (✅):** library filter/curate, generate (2-staps native LLM — rijker dan backend), ask, recommend, sonic fingerprint, DJ sets, **Live DJ (native-only sterkte)**, playlists/Qobuz-save, scrobbling naar LB+Last.fm, on-device analyzer.
**Gedeeltelijk (⚠️):** discovery (mist smart/sonic radio, LB-aanbevelingen), taste profile (lokaal-only, geen LB/LF-merge), Music Map (scatter, geen UMAP/HDBSCAN-clustering), templates (~8 inline vs 63 built-ins).
**Afwezig (❌):** Song Paths, Song Alchemy, watchlist (new-release scanner), scheduler (cron-playlists), automations, enrichment, notifications, CLAP, semantische lyrics, scrobble-import, circadian/personas/mood/sonic-radio/queue-continuation.
**MCP-oppervlak:** native 26 tools vs backend ~113.

### Top-features om te porten (effort)
1. **Taste profile + LB/Last.fm-merge** (M) — je scrobblet al naar beide; haal de stats terug → echte cross-source profiel.
2. **Watchlist new-release scanner** (M) — met lokale notificaties (beter dan Discord op Apple).
3. **Scheduler (cron-playlists)** (M) — "verse maandag-mix" via `BGTaskScheduler` + bestaande generate-flow.
4. **Templates-pariteit** (S) — porteer de 63 JSON-templates + picker; goedkope polish.
5. **Song Paths** (M) + **Song Alchemy** (S–M) — feature-vector + `SonicSimilarity.distance` zijn er al.
6. **Sonic/Smart Radio + queue-continuation** (S–M) — `SonicEngine.nearest` bestaat; alleen een queue-feeder-loop.
7. **Vollere feature-vector** (L) — voeg danceability/valence/instrumentalness/acousticness toe aan de analyzer → ontgrendelt rijkere similarity/alchemy/mood.

### Twintig nieuwe premium-ideeën (selectie van de sterkste)
- **Gapless/crossfade DJ-transitions via `AVAudioEngine`** (L) — Roon biedt geen crossfade; native doen = echte differentiator.
- **On-device Apple Intelligence-curatie** (M) — route Generate/Ask via Apple Foundation Models (privacy/offline/geen API-key); `LLMClient` is al pluggable.
- **SharePlay luistersessies** (L) — vrienden stemmen op de volgende track.
- **Year-in-Review / "Sonic Wrapped"** (M) — geanimeerde recap uit `listening_history`; viraal.
- **Live audio-visualizer op Now Playing** (M) — Metal/Canvas gedreven door analyzer-energy.
- **ShazamKit "wat is dit?" → add to library/Qobuz** (M).
- **Apple Watch-remote + haptische BPM-tap** (M).
- **CarPlay now-playing + "speel iets zoals dit"** (M).
- **Interactieve Camelot-wiel harmonische mixer** (M) — tap een segment → filter library op compatibele tracks bij huidige BPM.
- **Hi-res signal-path badge** (S) — toon bit-depth/sample-rate/DSP uit de zone-payload; audiophile-feel.
- **Quick wins:** Templates-pariteit (S) · Sonic Radio (S–M) · Scrobble-import (S) · Hi-res badge (S) · Year-in-Review (M).

---

## ROADMAP — Gefaseerd plan

### Fase 0 — Fundering & correctheid (1 sprint, onzichtbaar maar essentieel)
- A1/B9/B5: alle DB-getters off-main (`Task.detached` / cache).
- A2: per-request timeout. A4: receive-loop guard. A5: prune-guard tegen dataverlies.
- A3: `lastActionError` → toast-infra (nodig voor alle volgende UI).
- S1: Keychain `…ThisDeviceOnly`.
- B1: FTS5 op zoeken. B4: image-cache cost-limit + downsampling.
> Resultaat: snappy, geen UI-hitches, geen stille faal, geen krimpende library.

### Fase 1 — Het paradepaardje (1–2 sprints, hoogste zichtbare impact)
- **Immersive Now Playing** (Hero #1) — grote art, ambient backdrop via bestaande `dominantColor`, custom scrubber, spring-transitions.
- Design-systeem afdwingen: `Card`-container, tokens overal, `Motion.*` overal, geforkte badges weg, **taal unificeren**.
- AI-curatie "deal-out" reveal (Hero #2) + iOS-haptics + reduce-motion.
> Resultaat: app voelt als award-kwaliteit op de twee meest-bekeken schermen.

### Fase 2 — iOS native maken (1–2 sprints)
- Entitlements + App Group toevoegen (deblokkeert de rest).
- `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` (Lock Screen/Control Center/CarPlay).
- Interactieve Live Activity-knoppen + `staleDate` + art via App Group.
- Home/Lock Screen "Zone Control"-widgets met `AppIntent`.
- App Intents/Shortcuts (PlayInZone, GeneratePlaylist).
> Resultaat: iPhone voelt als een flagship Roon-remote, niet als een shell.

### Fase 3 — Feature-diepte & differentiators (doorlopend)
- Quick wins eerst: Templates-pariteit, Sonic Radio, Scrobble-import, Hi-res badge, Taste-profile LB/LF-merge.
- Daarna premium: Song Paths/Alchemy, Year-in-Review, interactieve Camelot-wiel, Discovery-editorial-redesign (Hero #4), Live DJ mix-radar (Hero #3).
- Performance-diepte: B3 (sonic feature-vectors/bitsets), B6 (vDSP-analyzer), B7 (batch-sync).
- Tech-debt: A10 (controllers extraheren), A11 (`Codable` responses), A12 (chunkedInsert-helper).

---

## Snelle wins die je vandaag kunt doen (laag risico, direct merkbaar)
1. `ISO8601DateFormatter` → `static let` (fired elke track-wissel).
2. Goud+wit contrast-fix (`LibraryView:191`) → zwart op goud.
3. `.help()` → `.accessibilityLabel` (deblokkeert iOS-toegankelijkheid).
4. Vervang inline animatie-literals door `Motion.*`.
5. Cap de unbounded `colorCache` in `ImageCache`.
6. Verwijder dode `DiscoveredRoonCore` (`SOODMessage.swift:110-130`).
