# RoonSage — Feature-audit & consolidatieplan

> Gegenereerd: 2026-07-12. Methode: 3 parallelle code-verkenners (sidebar-inventaris +
> Create-cluster + Explore-cluster), elke bevinding gegrond op file:line in de echte
> broncode. Doel: "veel features, weinig assen" — de ~23 menu-items terugbrengen naar
> een IA die naar *intentie* is geordend i.p.v. naar *motor*.

---

## 1. Het oordeel

De app toont **±23 menu-items + 2 verweesde** (DJ Modes, Sonic Journeys — die stonden
op macOS in géén enkele sidebar-sectie, alleen bereikbaar via ⌘K/losse links). Daaronder
draaien in werkelijkheid **vier motoren**. Het menu was geordend naar hoe iets technisch
werkt, niet naar wat de gebruiker wil doen — dat is de kern van de wildgroei.

De vier substraten:

| Motor | Wat het is | Features |
|---|---|---|
| **A. Discovery-pijplijn** | muziek die je *niet* bezit → Qobuz | New Discoveries |
| **B. History/metadata-rollups** | eigen bibliotheek + luistergeschiedenis | Discover, Recent, Taste Profile, Year in Review, Multitag, Library |
| **C. CLAP-embeddings (VectorIndex)** | sonische ruimte, "klinkt als" | Sonic DNA, Sonic search, Song Alchemy, The Bridge, Radios, + rerank-stap in Ask/Generate |
| **D. Rauwe analyzer-features** (bpm/energy/Camelot) | regelgebaseerd, geen ML | Music Map, DJ Set, Live DJ |

## 2. De concrete overlappen (met bewijs)

1. **Naamomkering "New Discoveries" ⟷ "Discover"** — `.discover` (unowned, `DiscoverFeedView`)
   vs `.discovery` (owned/verwaarloosd, `DiscoveryView`). Labels waren feitelijk omgedraaid
   t.o.v. de enum-namen. Grootste verwarringsrisico. *(Batch 1: opgelost → "Nieuw voor jou" / "Herontdek".)*
2. **Ask ≈ Generate-lite** — beide `analyzeForFilters` → kandidatenpool; Ask stopt na sonische
   rerank, Generate voegt LLM-curatie + flow + titel toe. Broncode van Ask zegt dit letterlijk.
3. **Recommend = dezelfde analyzer op albumniveau** (`candidateAlbums` i.p.v. tracks).
4. **The Bridge + Song Alchemy + Sonic search = bijna identiek plumbing** — alle drie
   `sonicLibrary()` + `sonicVectorIndex()` → `[SonicEngine.Scored]`. Verschillen enkel in de
   vector-operatie (tekst-kNN / add−subtract / interpoleren). Sterkste overlap.
5. **The Bridge staat dubbel** — top-level `.songPaths` én ingebed in Sonic Journeys.
6. **Taste Profile + Year in Review + Recent = drie sneden op `listening_history`.**
7. **Sonic DNA + Music Map** — twee vensters op de geanalyseerde bibliotheek (embeddings vs 3 scalars),
   delen geen code → onverklaarbaar verschil voor de gebruiker.
8. **Radios ≈ DJ Modes** — beide volledig op `RadioEngine`; persona = dial-preset.
9. **DJ Set ≈ Live DJ** — beide `db.djCandidates` + Camelot, batch vs incrementeel.
10. **macOS- en iOS-navigatie zijn twee losse, handmatig onderhouden structuren** → driften.
    *(Batch 1: beide uit intentie-groepen gehaald.)*

## 3. Doel-IA (van ~23 losse items → intentie-groepen)

| Groep | Items | Later te consolideren tot |
|---|---|---|
| **Play** | Now Playing, Queue, Library, Saved | — |
| **Create** | Ask, Generate, Recommend, Playlists | Generate absorbeert Ask (Snel-modus) + Recommend (Albums-scope) |
| **Stations** | Radios, DJ Modes, Sonic Journeys, DJ Set, Live DJ | Radios-hub (Radios+DJ Modes+Journeys, één RadioEngine); DJ (Set+Live) |
| **Explore** | New Discoveries, Discover, Sonic search, Song Alchemy, The Bridge, Music Map, Multitag | Discover-2-banen (nieuw/herontdek); Sonic Lab (search+mix+bridge, Music Map als lens); Multitag → Library-filter |
| **You** | Sonic DNA, Taste Profile, Recent, Year in Review | Eén Taste-hub met tabs (DNA / Genres&Artiesten / Historie / Jaaroverzicht) |

## 4. Slimmer maken (naast minder)

1. **Eén feedback-bus** — laat Ask/Generate/Sonic search óók `track_feedback` schrijven zodat
   elke surface de taste-vector scherpt (nu alleen Radio/Discovery).
2. **Ask → Generate-doorgeef** — Ask ís Generate-stap-1; geef Ask-resultaten "verfijn tot
   playlist" die de al-berekende analyze doorgeeft (geen 2e LLM-call).
3. **Music Map als generator** — lasso een regio (tempo×energie) → start daar een station/zoekopdracht
   i.p.v. tik→speel-één-track (verbindt motor D met C).
4. **"Herontdek" smaak-gestuurd** — rangschik verwaarloosd bezit op de CLAP-taste-centroid
   (die `TasteSeeds` al gebruikt), niet op rauwe play-counts.
5. **Stations die zichzelf kiezen** — auto-persona op tijdstip/recente luister (Guest-DJ-autoplay-haak
   bestaat al); dial laat leren van skips.

## 5. Batch-roadmap

- **Batch 1 — IA-reorg (nav-only) — ✅ GESHIPT.** macOS-sidebar + iOS-hubs herordend naar
  6 intentie-groepen (Play/Create/Stations/Explore/You/System); 2 wezen (DJ Modes, Sonic Journeys)
  op macOS zichtbaar in Stations; naamomkering opgelost ("Nieuw voor jou"/"Herontdek"); macOS↔iOS
  uit dezelfde groepen. Alleen `RootView.swift` + en/nl strings, geen engines. 577 tests groen.
- **Batch 2 — Sonic Lab (3→1) — ✅ GESHIPT.** Nieuwe `SonicLabView` = dunne container met segmented
  modus-schakelaar Zoek/Mix/Brug die `SonicSearchView` / `SongAlchemyView` / `SongPathsView` embed
  (engines ongewijzigd). Sidebar-item `.sonicLab` vervangt de 3 losse items in Explore; iOS "Sonic-tools"
  idem. The Bridge blijft los bereikbaar vanuit Sonic Journeys. 577 tests groen.
  *Vervolgverfijning (later): resultatenlijst + seed-picker écht delen i.p.v. per modus; Music Map als 4e (visuele) modus.*
- **Batch 3 — Taste-hub (4→1) — ✅ GESHIPT.** Nieuwe `TasteHubView` = container met segmented
  modi DNA/Smaak/Historie/Jaar die `SonicFingerprintView` / `TasteProfileView` / `RecentView` /
  `YearInReviewView` embed. Sidebar-item `.tasteHub` vervangt de 4 losse items in de You-groep;
  iOS "Jouw smaak" idem. Engines ongewijzigd. 577 tests groen.
  *Vervolg (later): de listening_history-overlap tussen profiel/historie/jaar écht dedupliceren.*
- **Batch 4 — Stations-hub — ✅ GESHIPT.** Twee containers: `StationsHubView` (segmented
  Radio's/DJ-modi/Journeys — delen RadioEngine) embed `SonicRadioView`/`DJModesView`/`SonicJourneysView`;
  `DJView` (segmented Set/Live — harmonische mixer) embed `DJSetView`/`LiveDJView`. Stations-groep
  gaat van 5 losse items → 2 (`.stationsHub`, `.dj`); iOS idem. Engines ongewijzigd. 577 tests groen.
- **Batch 5 — Create-consolidatie — ✅ GESHIPT.** Nieuwe `CreateHubView` = segmented
  Genereer/Snel/Albums die `GenerateView`/`AskView`/`RecommendView` embed. `.generate` wijst nu
  naar de hub (geen nieuw enum-case); Create-groep 4 → 2 items (Generate-hub + Playlists); iOS
  "AI-curatie" idem. Engines ongewijzigd. 577 tests groen.
  *Resultaat IA-consolidatie (Batch 1–5): sidebar ~23 → 15 items, intentie-gegroepeerd, geen wezen,
  geen naamcollisie. Vervolg (later): de hubs écht 1 pipeline laten delen i.p.v. losse views embedden.*
- **Batch 6 — Slimmer (engine-werk).**
  - **#1 smaak-gestuurde Herontdek — ✅ GESHIPT.** `undiscoveredAlbums` rangschikt nu een random
    kandidatenpool op cosine(album-embeddingcentroid, taste-centroid) i.p.v. `ORDER BY RANDOM()`.
    Nieuwe DB-query `undiscoveredAlbumCandidates` (album + match_keys); ranking + veilige fallback
    naar random in `RoonClient.undiscoveredAlbums` (signatuur ongewijzigd → geen callers geraakt).
    Client-side (lokale db + /play-stats), geen mini-deploy. 577 tests groen; live-ranking alleen
    in-app met embeddings observeerbaar.
  - #2 feedback-bus (Ask/Generate/Sonic Lab → track_feedback) — server-of-record, deploy-implicatie.
  - **#3 Ask→Generate-doorgeef — ✅ GESHIPT.** In de Create-hub geeft Snel (Ask) nu een
    "Verfijn tot playlist →"-knop die de query doorgeeft aan Genereer (`GenerateView(initialPrompt:)`
    seedt de prompt als die leeg is). Client-side UI-wiring, geen engine-wijziging. 577 tests groen.
  - **#5 auto-persona — ✅ GESHIPT.** Nieuwe pure `DJMode.forTimeOfDay(hour:)` (getest); toggle
    "Kies persona automatisch op tijdstip" in DJModesView + pref `djAutoplayAutoPersona`; Guest-DJ-autoplay
    kiest de persona nu op het lokale uur i.p.v. de vaste `selectedDJMode`. Client-side. 579 tests groen.
  - **#4 Music Map-generator — ✅ GESHIPT.** De selectie-kaart op de Music Map krijgt naast "Speel nu"
    een "Start station hier" (`startTrackRadio` vanaf de gekozen stip) — de kaart wordt een station-launcher
    i.p.v. tik→speel-één-track, en verbindt zo motor D (scatter) met de RadioEngine. Client-side. 579 tests groen.
    *(Volledige regio/lasso-selectie = latere verfijning; deze tap-seed dekt de kernwaarde met minimale interactie.)*
