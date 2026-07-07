<!-- ═══ START HIER (kopieer dit als prompt voor een nieuwe sessie) ═══
Lees docs/STATE.md en ga verder met "fix alles" uit de audit. Pak de VOLGENDE
batch uit ## Next (nu: B4/B5 performance). Werk incrementeel: per batch bewerken
→ cd native/RoonSage && swift build && swift test → commit + push + tag (vX.Y.Z
én analyzer-vX.Y.Z) → werk STATE.md bij. Constraints in ## Constraints naleven:
niet tests verzwakken, nooit de client-app op de mini deployen. Doe één batch,
niet "alles" tegelijk. Laatst geshipt: v1.10.123 / analyzer-v1.1.99.
Wil je i.p.v. de volgende batch een specifiek onderdeel? Vervang de 2e zin door
bv. "Werk feature #1 (skip = live re-steer) volledig uit" of "Doe alleen B7".
═══════════════════════════════════════════════════════════════════ -->

## Goal
Fix ALLES uit de 6-dimensie audit (2026-07-06): security, correctheid, performance, UX, architectuur én de 13 nieuwe features. Incrementeel per batch: bewerken → build/test → commit+push+tag.

## Now
B1-B6a + B7a + B8(skip-re-steer, op-deze-dag) KLAAR. Live op de mini draait nog analyzer-v1.1.101 → /on-this-day + Qobuz/discovery/filePath-perf staan in git maar NIET gedeployd. Volgende B8-features óf een deploy-ronde.

## Next
- (optioneel) analyzer redeployen op de mini → /on-this-day live + alle B4/B8-serverfixes actief (nu draait v1.1.101, git=v1.1.107)
- B8+ Features resterend (kies logica-zware/testbare eerst): loudness-normalisatie, crossfade, taste-timemachine, NL steering, scenes, share-cards, Siri-intents, Control Center, gapless, CarPlay, chat-agent
- "op deze dag" vervolg: client-fetch (RoonClient) + UI-view (hub-sectie) — nu alleen query + /on-this-day endpoint
- B7b Architectuur (groot/risico): RoonClient (900r god-object) opsplitsen in sub-coördinatoren — hoge blast radius op de live-connectieflow, niet headless verifieerbaar zonder Roon Core. Incrementeel + build-gated
- B6b (optioneel, per-verb, hoger risico): MusicMap/Ask/CustomRadio/DiscoverWeekly play-knoppen → lokale output
- B3 rest (uitgesteld, migratie-bewust): MED-2/3 matchKey-normaliser (unicode-translit + and/with/x/vs joiners) — raakt gepersisteerde keys; MED-4 dedup-key stabiliteit
- B2 rest: SEC-M2 cleartext secrets (TLS/ZeroTier-only — architectuurbeslissing), SEC-L9 DuckDNS-token roteren (user-actie) + .env verwijderen (Docker weg)
- B5 Perf client: Music Map spatial index (H7/M9), taste/embedding alloc (M1-4)
- B6 UX: Live Activity contrast, iOS deep-nav, gedeelde ZoneGate, tool-error-states, localisatie
- B7 Architectuur: RoonClient sub-coördinatoren + mock-transport testharnas
- B8+ Features (13): skip re-steer (beste ratio), Siri-intents, Control Center, NL steering, share-cards, "op deze dag", gapless, taste-timemachine, scenes, CarPlay, crossfade, loudness, chat-agent
- B3 Correctheid MED-1..8 + LOW: fuzzy version-qualifier, unicode-translit, primaryArtist joiners, dedup-key, digest re-include, bpm_confidence, LB submit
- B4 Perf serverside: analyzer hot paths H1-3 (current_match_key index, signature memoize, embeddings ETag), discovery H4-6 (MB pre-seed, studioAlbums TTL, Qobuz session cache)
- B5 Perf client: Music Map spatial index (H7/M9), taste/embedding alloc (M1-4)
- B6 UX: Live Activity contrast, iOS deep-nav, gedeelde ZoneGate, tool-error-states, localisatie
- B7 Architectuur: RoonClient sub-coördinatoren + mock-transport testharnas
- B8+ Features: skip re-steer, Siri-intents, Control Center, NL steering, share-cards, "op deze dag", gapless, taste-timemachine, scenes, CarPlay, crossfade, loudness, chat-agent

## Constraints
- Commit + push + tag per geverifieerde batch (user, 2026-07-06)
- "iOS moet je ook taggen he" — tag ook ios-vX.Y.Z per batch, naast vX.Y.Z + analyzer-vX.Y.Z (user, 2026-07-06)
- NIET tests verzwakken om ze groen te krijgen (hard stop)
- Nooit client-app op de mini deployen (alleen analyzer-server); zie memory

## Decisions
- B6 ZoneGate grondig (user-keuze 2026-07-07): oudere play-acties die een lokaal equivalent hebben routeren via playToActiveOutput + gate hasActiveOutput; Roon-only acties (sonic radio, DJ-set, album/artist-bulk mét eigen lokale knop) blijven selectedZone-gated. Waarom: veel play-knoppen negeerden lokale output (selectedZone==nil disablede ze terwijl "dit apparaat" gekozen was). playToActiveOutput==curateTracks(zoneID) als zone geselecteerd → Roon-pad bewijsbaar ongewijzigd
- getJSON: één status-bewuste GET-helper in QobuzClient, retry 429/5xx met backoff, nil=echte fout — waarom: root-cause van terugkerende stille Qobuz-storingen is fout==leeg conflatie
- findPlaylist → enum PlaylistLookup {found/absent/failed} — waarom: read-fout mag geen duplicaat-playlist maken

## Facts
- Test: cd native/RoonSage && swift test ; build: swift build ; release: swift build -c release --product RoonSage
- Tag-namespaces: app vX.Y.Z · iOS ios-vX.Y.Z · analyzer analyzer-vX.Y.Z
- Baseline build (2026-07-06): PASS (exit 0). Test-baseline vóór B1: 463 tests, 0 failures (prior task Done).
- Kern-audit files: QobuzClient.swift, LibraryShareServer.swift (:91 enforceToken), RoonClient+DiscoverWeekly.swift (:355 searchQobuz-gate), AnalyzerCore/HTTPServer.swift (5766)

## Done
- Audit 6 dimensies afgerond — RESULT: rapport met SEC-H1 (default-open server), COR-H1..4 (Qobuz fail-closed + DiscoverWeekly), PERF-H1..7, UX-M1..4, Code-H1..3, 13 features
- B1 Kritiek GESHIPT — RESULT: commit d8b912e, v1.10.118 + analyzer-v1.1.94. QobuzClient getJSON+fail-closed (count→Int?, ids→[String]?, findPlaylist→PlaylistLookup, searchTracks retry), DiscoverWeekly matchKey-gate, LibraryShareServer non-GET+/settings altijd token + auto-enforce na 1e pairing. 463 tests 0 failures
- B2 Security GESHIPT — RESULT: commit 5778071, v1.10.119 + analyzer-v1.1.95. Analyzer-server ACAO:* weg (M4), share-server POST vereist application/json (CSRF M5), pending-cap 50 (L6). 463 tests
- B3a Correctheid GESHIPT — RESULT: commit 8486494, v1.10.120 + analyzer-v1.1.96. FuzzyMatch version-qualifier-guard +regressietest (MED-1), LB submit status-check + loved partial-log (MED-7), bpm_confidence NULL conditioneel (MED-8). 464 tests
- B3b Correctheid GESHIPT — RESULT: commit 000b02b, v1.10.121 + analyzer-v1.1.97. Digest sluit accepted albums uit op dedup_key+artiest|album (MED-5), Chillen/Lounge vereisen echt bpm (zero-is-data LOW). 464 tests
- B4a Perf GESHIPT — RESULT: commit b44a9f2, v1.10.122 + analyzer-v1.1.98. Qobuz session-cache 10-min TTL (PERF-H6). 464 tests
- B4b Perf GESHIPT — RESULT: commit 0703238, v1.10.124 + analyzer-v1.1.100. Discovery filter-reorder (PERF-M5): identity-drop (in-library/listened/blocked/cooldown) verplaatst naar 3a-ter, vóór álle album/cover-resolutie (MB studioAlbums/coverArt + Qobuz resolveAlbums/artistCovers) i.p.v. erna; final Score/Filter blijft autoriteit → correctheid ongewijzigd. Bounded concurrency (PERF-M6): QobuzClient.resolveAlbums + resolveArtistCovers nu ≤5 in flight via withTaskGroup (was volledig sequentieel over ~dozijnen wants); artistCover-helper geëxtraheerd. swift build+test exit 0, 464 tests 0 failures
- B4c Perf GESHIPT — RESULT: v1.10.125 + analyzer-v1.1.101 + ios-v1.7.90. PERF-H1: FeatureStore.filePath deed per /audio-request een FULL TABLE SCAN (matchKey per rij herberekend) als de client-key ≠ stored PK (oud-schema rijen); nu O(1)-lookup in gememoiseerde current-scheme [matchKey→file_path]-map, herbouwd alleen als contentSignature wijzigt (proces-scoped → normaliser-wijziging = nieuwe binary = restart = herbouw, dus nooit stale). playableMatchKeys deelt dezelfde map. **H2 (signature memoize) + H3 (embeddings ETag) NIET gedaan — REDUNDANT**: client gate't de hele /features+/embeddings pull al op featuresRevision (RoonClient+Features.swift:186-187 → geen HTTP-request bij ongewijzigde revisie), dus ETag heeft geen caller en contentSignature draait op de 30s revision-timer i.p.v. per poll. swift build+test exit 0, 464 tests. GEEN schema-migratie (in-memory map i.p.v. current_match_key kolom → geen stale-key 404-risico bij schemawissel)
- LAUNCH-CRASH GEFIXT + GESHIPT — RESULT: commit fccf37d, v1.10.123 + analyzer-v1.1.99. v1.10.117 crashte bij opstarten (SIGTRAP): LS→Bundle.module fatalError want release-packaging kopieerde RoonSage_RoonSageUI.bundle niet in .app. Fix: beide release-scripts kopiëren *.bundle → Contents/Resources; LS/LT defensieve uiBundle-lookup (fallback .main ipv fatal). GEVERIFIEERD: .app mét bundle start (ALIVE 5s), .app zónder bundle start óók (fallback). 464 tests
- B8 "op deze dag" GESHIPT — RESULT: v1.10.131 + analyzer-v1.1.107 + ios-v1.7.96. DatabaseManager.onThisDay(now:limit:): plays uit dezelfde maand-dag (MM-DD, UTC via strftime) in eerdere jaren, huidig jaar uitgesloten, nieuwste eerst; OnThisDayEntry (Codable). /on-this-day thin-client-endpoint in LibraryShareServer (naast /year-review). 3 unit-tests (temp-DB via appendImportedListens): MM-DD-match+prior-years+DESC, huidig-jaar-excl+limit, leeg. 481 tests, build+test exit 0. Endpoint NIET live tot analyzer-redeploy; client-fetch+UI = follow-up
- B8 skip re-steer GESHIPT — RESULT: v1.10.130 + analyzer-v1.1.106 + ios-v1.7.95. "Skip = live re-steer" (best-ratio feature): RadioEngine.rank kreeg skippedKeys → zachte negatieve query-push (skipPush 0.20 < dislikePush 0.40), sessie-scoped. RadioRunState.skippedKeys accumuleert; regenerateRadioPool geeft ze door aan buildRadioCandidates→rank; recordRadioSkip(matchKey:) voegt toe + triggert resteerActiveRadio (single-flight). Hook in next(zoneID:): skip op de actieve-station-zone → nowPlaying-matchKey geregistreerd (server routeert remote "next" óók via next(), dus thin-client-skips tellen mee). Engine UNIT-GETEST (symmetrisch: skip +y⇒−y wint, skip −y⇒+y wint); 478 tests, build+test exit 0. Live-gedrag EDITED-UNVERIFIED (headless, geen live Roon-zone)
- B7a Architectuur GESHIPT — RESULT: v1.10.129 + analyzer-v1.1.105 + ios-v1.7.94. Mock-transport testharnas: TransportDispatching-protocol (1 methode: dispatch(endpoint,body)) geëxtraheerd; RoonTransport conformeert (additief), TransportService hangt nu aan het protocol i.p.v. de concrete actor → MockTransport in tests. 5 nieuwe TransportServiceTests pinnen elke command-payload vast (control/volume/mute-bool→how/repeat-enum→loop_one|disabled/shuffle/seek/group/transfer). Enige caller RoonClient:630 ongewijzigd (RoonTransport conformeert). Eerste unit-dekking van de transport-commandolaag. build+test exit 0, 477 tests
- B6a UX GESHIPT — RESULT: v1.10.128 + analyzer-v1.1.104 + ios-v1.7.93. ZoneGate: library "speel nu"-oppervlak (LibraryView selectie+rijen, LibraryDetailViews album-rijen+meest-gespeeld) routeert nu via playToActiveOutput + gate hasActiveOutput i.p.v. curateTracks(zoneID)+selectedZone==nil → honoreert lokale output ("dit apparaat"). Roon-pad bewijsbaar identiek (playToActiveOutput==curateTracks als zone gekozen). Wachtrij + sonic radio + album/artist-bulk (heeft eigen lokale knop) blijven zone-gated. Help-tekst "Kies eerst een zone of apparaat". build+test exit 0, 472 tests. Lokaal on-device pad EDITED-UNVERIFIED (headless mini, geen GUI) — Casper test op toestel
- B5b Perf client GESHIPT — RESULT: v1.10.127 + analyzer-v1.1.103 + ios-v1.7.92. Taste/embedding alloc (PERF-M1-4): TasteVector.compute kopieerde ELKE library-embedding in een dict (1 [Float]-alloc per rij, ~50k) om er ~honderden op te zoeken → nu idByKey (goedkope strings) + embedding-lookup enkel voor gespeelde+geliked keys (M1). vDSP-accumulaties (TasteVector.add, VectorIndex.centroid, nnSimilarityStats) gebruiken in-place vsma / hergebruikte buffer i.p.v. per-iteratie temp-array (M2-4): centroid geen scaled-temp per seed, nnStats één scores-buffer + query wijst direct in de matrix (was per-sample alloc+kopie). Numeriek identiek: 5 nieuwe tests (gewogen centroid, nnStats finite/in-range, taste lean/like/nil). 472 tests, build+test exit 0
- B5a Perf client GESHIPT — RESULT: v1.10.126 + analyzer-v1.1.102 + ios-v1.7.91. Music Map spatial index (PERF-H7/M9): MusicMapView.selectNearest deed O(n) over álle ~50k tracks per tap (position per track herberekend); nu SpatialGrid (nieuw, RoonSageCore, uniform 64×64 grid over genormaliseerde [0,1]²-coords) → O(1)-amortized cell-query. norm[] + grid 1× gebouwd in load(); render scaalt goedkoop i.p.v. bounds-math per punt. Selectie bewijsbaar identiek (±20pt candidate-box ⊇ 14pt hit-radius, exacte afstandstest + 196-drempel ongewijzigd). 467 tests (3 nieuw: SpatialGridTests, nearest==brute-force). swift build+test exit 0
- Alle batches gepusht. ANALYZER-SERVER GEDEPLOYD op de mini 2026-07-06 — RESULT: analyzer-v1.1.101 (build-analyzer-release.sh 1.1.101, Developer-ID signed, *.bundle mee), /Applications/RoonSage Analyzer.app vervangen + herstart (PID 98941). Geverifieerd op loopback: /health 5766=58839 features + 5767=76571 library, /features 200 51MB 0.57s (warm), /audio 206 audio/flac (H1-pad live). GEEN launch-crash. Client-app NIET gedeployd (constraint). Gotcha: /features cold-cache + herhaalde 120s-probes = GRDB reader-pileup (opstart-piek) → meet één keer na settle

## Open items
- SEC-M2 cleartext secrets: TLS of ZeroTier-only transport — architectuurbeslissing, in B2 afwegen
- searchTracks conflateert nog hard-fail vs leeg naar caller (resolveTrackID); retry dekt transient, diepere abort-op-hardfail = mogelijke follow-up
- Skip re-steer: alleen skips via de app-next() (lokaal + thin-client) worden gevangen; Roon-zijde skips (fysieke afstandsbediening / andere Roon-controllers) NIET — zou een zone-update-heuristiek vereisen (nowPlaying-wissel + played-fraction uit liveSeek). Follow-up indien gewenst
- PERF-H2/H3 GESLOTEN als redundant (zie B4c) — als /features ooit ZONDER revision-gate gepolld wordt, heropenen: contentSignature memoize vereist write-generatie-invalidatie over ~12 write-sites (data_version werkt niet bij single-connection GRDB) + botst met MusicBrainzGenreTests:59 (write moet signature direct wijzigen)

## Failed attempts
(none)
