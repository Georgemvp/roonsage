<div align="center">

# 🎵 RoonSage

**Native macOS- & iOS-apps voor Roon — blader door je bibliotheek, bedien afspelen, stel playlists samen met AI, en verken het sonische DNA van je muziek.**

[![Native Tests](https://github.com/Georgemvp/roonsage/actions/workflows/native-tests.yml/badge.svg?branch=main)](https://github.com/Georgemvp/roonsage/actions/workflows/native-tests.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-F05138.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2014%20%C2%B7%20iOS%2017-007AFF.svg)](#platforms)
[![macOS](https://img.shields.io/github/v/tag/Georgemvp/roonsage?filter=v*&label=macOS&color=e5a00d)](https://github.com/Georgemvp/roonsage/releases)
[![iOS](https://img.shields.io/github/v/tag/Georgemvp/roonsage?filter=ios-v*&label=iOS&color=e5a00d)](https://github.com/Georgemvp/roonsage/releases)
[![Analyzer](https://img.shields.io/github/v/tag/Georgemvp/roonsage?filter=analyzer-v*&label=Analyzer&color=e5a00d)](https://github.com/Georgemvp/roonsage/releases)
[![ListenBrainz](https://img.shields.io/badge/ListenBrainz-integrated-eb743b.svg)](https://listenbrainz.org)
[![Last.fm](https://img.shields.io/badge/Last.fm-integrated-d51007.svg)](https://www.last.fm)

_Verbindt rechtstreeks met je Roon Core. Geen server, geen Docker, geen Python-backend nodig._

[Engelse README](README.md) · [Overzicht](#wat-is-roonsage) · [Platforms](#platforms) · [Functies](#functies) · [Architectuur](#architectuur) · [Bouwen & draaien](#bouwen--draaien) · [Claude Desktop](#claude-desktop-mcp) · [Analyzer](#audio-analyzer) · [Legacy](#legacy-docker-webapp-gedeprecieerd)

</div>

---

## Wat is RoonSage?

RoonSage bestaat uit twee **native Swift/SwiftUI-apps** — één voor **macOS**, één voor **iOS/iPadOS** — die met je Roon Core praten en die omtoveren tot een slim, AI-ondersteund muzieksysteem. Ze spiegelen je bibliotheek naar een lokale **GRDB**-database (SQLite) en bouwen daarbovenop AI-playlistsamenstelling, smaakanalyse, audio-featureanalyse en harmonische DJ-tools — allemaal op basis van je eigen bibliotheek en Qobuz.

Ontwerpprincipes:

- **Bibliotheek-eerst** — elke voorgestelde track bestaat in je Roon-bibliotheek of op Qobuz; er wordt niets gehallucineerd.
- **Eén codebase, twee platforms** — macOS en iOS delen `RoonSageCore` + `RoonSageUI`; de iOS-app is een UI-/packaginglaag, geen fork.
- **Lokaal-eerst** — de bibliotheek, luistergeschiedenis en audio-features staan in een lokale database; query's raken Roon niet opnieuw.
- **AI helpt, jij beslist** — de LLM stelt voor; afspelen gaat altijd via je echte Roon-zones.
- **UI in het Nederlands, code in het Engels** — gebruikerslabels zijn Nederlands; protocol-/businesslogica en API's zijn Engels (repo-conventie).

---

## Platforms

| Platform | Bron | Hoe het uitkomt |
|----------|------|-----------------|
| **macOS** (14 Sonoma+) | [`native/RoonSage`](native/RoonSage) — `RoonSage`-apptarget | Ondertekend/genotariseerd **DMG** via de `v*`-tag → workflow `Release macOS DMG` (de in-app updater pikt 'm op) |
| **iOS / iPadOS** (17+) | [`native/iosapp`](native/iosapp) — xcodegen-project | **TestFlight** via de `ios-v*`-tag → workflow `Release iOS TestFlight` |
| **Audio Analyzer** | [`native/RoonSage`](native/RoonSage) — `RoonSageAnalyzerApp` / CLI `roonsage-analyzer` | DMG via de `analyzer-v*`-tag → workflow `Release Analyzer App` |

> De drie tag-schema's zijn **gescheiden** en delen nooit een namespace: Mac-app `vX.Y.Z`, analyzer `analyzer-vX.Y.Z`, iOS/TestFlight `ios-vX.Y.Z`. Een tag pushen triggert de bijbehorende release-workflow.

---

## Functies

### Bibliotheek & afspelen
- **Bladeren** door je volledige bibliotheek als tracklijst, **albums-grid** of **artiesten-grid**, met drill-down van album/artiest naar tracks. FTS5 full-text-zoeken; sorteren en filteren op genre, decennium, artiest en trefwoorden.
- **Immersive Now Playing** — full-bleed vervaagde albumhoes-achtergrond getint door de dominante kleur van de hoes, grote transportknoppen, scrubber en een zone-wisselaar.
- **Wachtrij**-weergave, transport, volume, shuffle/herhalen, **zone-overdracht** en groeperen — allemaal aangestuurd via je echte Roon-outputs.
- **Lock Screen / Bedieningspaneel / CarPlay / AirPods**-bediening op iOS (`MPNowPlayingInfoCenter` + remote command center), plus **Live Activities** (lockscreen + Dynamic Island) en **Siri Shortcuts**.

### AI-samenstelling & zoeken
- **Generate** — beschrijf een sfeer/genre/tijdperk; de LLM vertaalt dat naar filters (sub-stijlen worden op Roons grove genres gemapt), kiest tracks uit je bibliotheek en stopt bij een afgeronde playlist met een **AI-titel + beschrijving**, lokaal automatisch opgeslagen — daarna kies je een zone en speel je af. Waarschuwt wanneer een genre-intentie niet door de bibliotheek kon worden ingevuld.
- **Ask** — een lichte vibe-prompt → één LLM-call → direct afspeelbare resultaten (nu afspelen / als volgende in wachtrij / alles afspelen).
- **Recommend** — albumaanbevelingen geworteld in je bibliotheek.
- **Opslaan naar Qobuz** — push een samengestelde set naar een echte Qobuz-playlist.
- LLM-providers: **Anthropic**, **OpenAI**, **Ollama** (lokaal) en elk **OpenAI-compatibel** custom endpoint.

### Sonische intelligentie (CLAP-embeddings)
De sonische functies draaien over **CLAP-embeddings** (512-dim vectoren die de analyzer per track berekent via Core ML), met een rule-based fallback op BPM/Camelot/energie/tags zolang een track nog niet is geanalyseerd.
- **Sonic Fingerprint** — je muzikale DNA als radardiagram (energie, tempo, aandeel majeur, tempo-spreiding, tag-rijkdom) berekend uit je meest gespeelde tracks; aanbevelingen worden gerangschikt op cosine-gelijkenis in de embeddingruimte.
- **Sonic Search** — vrije-tekstquery ("dromerige ambient piano", "energieke funk met blazers") → CLAP-tekstencoder → cosine-match tegen de embeddings van je bibliotheek.
- **Music Map** — een 2D-scatter van elke geanalyseerde track: X/Y zijn een **PCA-2D-projectie van de CLAP-embeddings** (valt terug op tempo × energie vóór analyse), kleur = Camelot-toonsoort; tik op een punt om af te spelen.
- **Song Paths** — de soepelste sonische brug tussen twee tracks (nearest-neighbour-wandeling / graafzoektocht over de embeddingruimte).
- **Song Alchemy** — optellen/aftrekken met vectorrekenen over de embeddingruimte om een selectie te mengen of te sturen.
- **Sonic Radio** — dagelijkse, eindeloze artiest-gezaaide stations die zichzelf bijvullen, plus enkele **AI-artiesten-radio's** opgeslagen als stabiele, automatisch ververste Qobuz-playlists (AI-gegenereerde titels, genre-coherente volgorde).
- **Taste Profile** — top-artiesten, -genres, -tags en luisterstatistieken die lokale historie combineren met ListenBrainz/Last.fm.
- **Year in Review** — een terugblik op je luistergedrag (werkt ook op thin clients — opgehaald van de server).

### DJ-tools
- **DJ Set** — beatgematchte, Camelot-compatibele sets met een BPM-curve, een energie-boog op vaste schaal en een harmonische-overgangenstrip (harmonisch / zelfde toonsoort / alleen tempo), plus een "X/Y harmonische overgangen"-samenvatting.
- **Live DJ** — voor de nu spelende track suggereert het harmonisch-compatibele volgende tracks (Camelot + BPM) met één tik afspelen/in wachtrij.
- **Exporteren** van een set als leesbare tracklijst of **M3U** (met BPM/Camelot) via een deelvenster.

### Scrobbelen & historie
- Per-zone luistermonitor met een gegate scrobble-coördinator → **ListenBrainz** + **Last.fm** (now-playing + listen-inzending), lokale `listening_history` en een backfill-pad.
- **Automatische Last.fm-sync** — de serverbuild haalt elke 15 minuten nieuwe scrobbles op en vangt zo plays op van ARC en andere bronnen die de Roon Extension-API niet kan waarnemen.

### Ontwerp
- Systeem-/licht-/donkerthema's, een accentkiezer (Roon-goud als standaard), albumhoes-gedreven dynamische kleur, skeleton-loaders, lege toestanden en haptics op iOS.

---

## Architectuur

```
native/
├── RoonProtocol/                 # Roon-discovery + transport, pure Swift
│   └── Sources/RoonProtocol/     #   SOOD (UDP-discovery), MOO-framecodec, RoonServices
├── RoonSage/                     # het gedeelde SPM-pakket (één Package.swift, macOS + iOS)
│   └── Sources/
│       ├── RoonSageCore/         #   RoonClient, GRDB-database, sync, browse, afspelen,
│       │                         #   LLM/Qobuz/ListenBrainz/Last.fm-clients, share-/proxyserver
│       ├── RoonSageUI/           #   alle SwiftUI-views (gedeeld door Mac + iOS), Theme, Appearance
│       ├── AudioAnalysis/        #   BPM, toonsoort→Camelot, FFT, metadata, fuzzy matching, CLAP (Core ML)
│       ├── AnalyzerCore/         #   analyzer library-walk, feature-/embedding-store, HTTP-server
│       ├── RoonSageAnalyzer/     #   CLI roonsage-analyzer (analyze / validate)
│       ├── RoonSageAnalyzerApp/  #   de losse Analyzer macOS-app
│       ├── RoonSageMCP/          #   roonsage-mcp — MCP-server voor Claude Desktop (stdio)
│       └── RoonSage/             #   de macOS-app-shell (App/MenuBar/Settings/Update)
└── iosapp/                       # iOS-apptarget (xcodegen) → hergebruikt RoonSageUI + RoonSageCore
    ├── Sources/                  #   @main + NowPlayingCenter (MPNowPlayingInfoCenter)
    ├── Widgets/                  #   RoonSageWidgets (Live Activity, Dynamic Island)
    └── Shared/                   #   App Intents (play/pause/next/prev) gedeeld met de widget
```

`RoonSageCore`, `RoonSageUI`, `AudioAnalysis`, `AnalyzerCore` en `RoonProtocol` zijn **platform-schoon** (geen AppKit) — dat is wat de iOS-app in staat stelt ze te hergebruiken. macOS-specifieke chrome (DMG-updater, menubalk-extra, `NSAlert`) staat geïsoleerd achter `#if os(macOS)`.

### Server/client-splitsing

Slechts één apparaat registreert een Roon-extensie. RoonClient draait in één van twee modi (`RoonControlMode`):

- **`direct`** — de **altijd-aan-serverbuild** (meestal de Mac mini naast je Roon Core): registreert de Roon-extensie, synchroniseert de bibliotheek, draait de analyzer en biedt een kleine HTTP-server (`LibraryShareServer`, poort `5767`):
  - `GET /library` — de gesynchroniseerde bibliotheek (zodat een iPhone die importeert i.p.v. een urenlange Browse-walk)
  - `GET /settings` — gesynchroniseerde instellingen
  - `GET /playback?zone=…` — live zones / now-playing / wachtrij
  - `POST /command` — play / pause / volume / curate / … (de **playback-proxy**)
  - `GET /history` — luistergeschiedenis (zodat thin clients historie, radio's en smaak tonen)
  - `GET /year-review?year=…` — Year in Review-statistieken
  - `GET /health`
- **`server`** — de **Mac-/iOS-client-apps**: geen Roon-extensie op het apparaat; ze halen de bibliotheek en instellingen op, tonen live afspelen en proxyen elk transport-/curatiecommando via de server. Afspelen gebeurt nog steeds op de per-apparaat-gerichte Roon-zones.

De **analyzer** draait een eigen HTTP-server (`AnalyzerCore`, poort `5766`) waar de apps audio-analyses vandaan halen: `GET /features` (BPM/toonsoort/scalairen), `GET /embeddings` (binaire CLAP-vectoren), `GET /text-embed?q=…` (CLAP-tekstencoder voor Sonic Search) en `GET /health`.

De analyzer is de **server of record** voor sync, instellingen en audio-analyses; de Mac- en iOS-apps zijn thin clients die alles ophalen (bibliotheek, instellingen, historie, features en embeddings). (Discovery op iOS gebruikt ZeroTier + een opgeslagen host, omdat SOOD-multicast Apple's multicast-entitlement vereist.)

---

## Bouwen & draaien

Vereist Xcode 15+ (macOS 14-SDK / iOS 17-SDK) en Swift 5.9+.

```bash
# macOS-app + DMG (ondertekent/notariseert als de signing-env is gezet — zie native/SIGNING.md)
cd native && ./scripts/build-release.sh 1.0.0

# Analyzer-app-DMG
cd native && ./scripts/build-analyzer-release.sh 1.0.0

# iOS-app → genereer het Xcode-project, bouw/draai daarna in Xcode
cd native/iosapp && xcodegen generate && open RoonSageiOS.xcodeproj

# Draai de Swift-testsuites
cd native/RoonProtocol && swift test
cd native/RoonSage     && swift test

# Bouw altijd release vóór het taggen (release strict-concurrency vangt meer dan debug)
cd native/RoonSage && swift build -c release
```

Build-/signing-details en de GitHub-release-secrets: [`native/SIGNING.md`](native/SIGNING.md).
Roadmap: [`native/ROADMAP.md`](native/ROADMAP.md).
Architectuur-audit: [`docs/NATIVE_APP_AUDIT.md`](docs/NATIVE_APP_AUDIT.md).

---

## Claude Desktop (MCP)

Het `roonsage-mcp`-executable is een kleine **MCP-server** (stdio JSON-RPC) waarmee Claude Desktop RoonSage kan bedienen. Het praat met de RoonSage-serverbuild en biedt tools zoals:

`roon_zones` · `roon_play_pause` · `roon_next` / `roon_previous` · `roon_set_volume` · `roon_adjust_volume` · `roon_mute` · `roon_set_shuffle` · `roon_set_repeat` · `roon_transfer_zone` · `roon_search_library` · `search_qobuz` · `get_library_stats` · `get_albums` · `filter_tracks` → `curate_and_play` · `validate_playlist` · `play_album` · `save_playlist` / `list_playlists` / `play_playlist` / `delete_playlist` · `get_listening_history` · `get_top_artists` · `get_taste_profile` · `sync_library`

Bouw het met `swift build` (target `roonsage-mcp`) en wijs je `claude_desktop_config.json` naar het resulterende binary.

---

## Audio Analyzer

De analyzer (CLI `roonsage-analyzer` + de macOS-app `RoonSageAnalyzerApp`) doorloopt je muziekbestanden, extraheert **BPM**, **muzikale toonsoort → Camelot** en een **512-dim CLAP-embedding** per track, en serveert ze over HTTP (poort `5766`: `/features`, `/embeddings`, `/text-embed`) zodat de Mac- en iOS-apps ze koppelen aan de gesynchroniseerde bibliotheek voor de DJ- en Sonic-functies. Volledig native Swift — DSP in `AudioAnalysis`, CLAP-inferentie via **Core ML** — geen librosa, geen Python tijdens runtime.

- **CLAP-embeddings** voeden Sonic Search, Music Map, Similar, Song Paths, Song Alchemy en Sonic Radio. De Core ML-conversie gebruikt een exacte bicubische mel-resize die overeenkomt met de PyTorch-referentie (cosine-pariteit 1.0000) en middelt meerdere vensters over het tracklichaam zodat de vector de hele song weergeeft. De versie van het embeddingmodel wordt bijgehouden zodat een bump opnieuw embeddet zonder de scalairen te herberekenen.
- **Track-matching** gebruikt een duurzame `TrackIdentity.matchKey` (`artist|title` met normalisatie van positieprefix / featured-artiest / remaster-editie) plus een primary-artist-reductie en een fuzzy fallback binnen dezelfde artiest, zodat Roons metadata koppelt aan bestandstags ondanks afgekapte klassieke titels en "feat."-verschillen.
- **Nauwkeurigheid** gebruikt parabolische autocorrelatie-piekinterpolatie voor sub-frame-BPM en per-frame chroma-normalisatie met silent-frame-gating voor toonsoortdetectie. Een `validate <muziekmap> --reference <csv>`-harnas rapporteert BPM-/toonsoortnauwkeurigheid tegen een gelabelde steekproef.

---

## Legacy Docker-webapp (gedeprecieerd)

> ⚠️ De oorspronkelijke zelf-gehoste **FastAPI-webapp + MCP-server** is **gedeprecieerd en wordt niet meer onderhouden**. De volledige broncode staat nu onder [`legacy-docker/`](legacy-docker/) en wordt enkel als referentie bewaard. Zie [`legacy-docker/README.md`](legacy-docker/README.md).

Die stack verbond met een Roon Core als extensie, spiegelde de bibliotheek naar een SQLite-cache en bood ~69 MCP-tools zodat Claude Desktop via een web-UI kon samenstellen, ontdekken en Roon bedienen. Alles wat het deed wordt native heropgebouwd. Draai je het nog, dan staat in de legacy-README de Docker-/config-/API-referentie.

---

## Repo-indeling

| Pad | Wat |
|-----|-----|
| [`native/`](native/) | **Primaire product** — de macOS- & iOS-apps, gedeelde pakketten, analyzer, scripts en docs |
| [`legacy-docker/`](legacy-docker/) | Gedeprecieerde Docker-/FastAPI-webapp + Python-MCP-server (enkel referentie) |
| [`docs/`](docs/) | Native audit (`NATIVE_APP_AUDIT.md`) en overige docs |
| `data/` | Runtime-data (databases, caches) — git-ignored |

CI: `.github/workflows/native-tests.yml` (primair) draait de Swift-suites; de workflows `release-macos` / `release-ios` / `release-analyzer` zijn tag-getriggerd. `.github/workflows/test.yml` is path-gefilterd op `legacy-docker/**`.

---

## Licentie & credits

MIT — zie [LICENSE](LICENSE).

- [Roon Labs](https://roon.app) voor de Extension-, Browse- en discovery-API's (SOOD/MOO)
- [GRDB.swift](https://github.com/groue/GRDB.swift) voor de lokale database
- [ListenBrainz](https://listenbrainz.org) voor open luisterdata
- [Last.fm](https://www.last.fm) voor muziekintelligentie en community-tags
- [MusicBrainz](https://musicbrainz.org) voor open muziekmetadata
- [Qobuz](https://www.qobuz.com) voor de lossless streamingcatalogus
- [Anthropic](https://www.anthropic.com), [OpenAI](https://openai.com) en [Ollama](https://ollama.com) voor de LLM-backends
