<div align="center">

# 🎵 RoonSage

**Native macOS & iOS apps for Roon — browse your library, control playback, curate playlists with AI, and explore your music's sonic DNA.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-F05138.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-macOS%2014%20%C2%B7%20iOS%2017-007AFF.svg)](#platforms)
[![macOS](https://img.shields.io/badge/macOS-v1.5.55-e5a00d.svg)](#platforms)
[![iOS](https://img.shields.io/badge/iOS-v1.6.26-e5a00d.svg)](#platforms)
[![ListenBrainz](https://img.shields.io/badge/ListenBrainz-integrated-eb743b.svg)](https://listenbrainz.org)
[![Last.fm](https://img.shields.io/badge/Last.fm-integrated-d51007.svg)](https://www.last.fm)

_Connects directly to your Roon Core. No server, no Docker, no Python backend required._

[Nederlands](README.nl.md) · [Overview](#what-is-roonsage) · [Platforms](#platforms) · [Features](#features) · [Architecture](#architecture) · [Build & run](#build--run) · [Claude Desktop](#claude-desktop-mcp) · [Analyzer](#audio-analyzer) · [Legacy](#legacy-docker-web-app-deprecated)

</div>

---

## What is RoonSage?

RoonSage is a pair of **native Swift/SwiftUI apps** — one for **macOS**, one for **iOS/iPadOS** — that talk to your Roon Core and turn it into a smart, AI-assisted music system. They mirror your library into a local **GRDB** (SQLite) database, then layer on AI playlist curation, taste analytics, audio-feature analysis, and harmonic DJ tools — all on top of your own library and Qobuz.

Design principles:

- **Library-first** — every suggested track exists in your Roon library or on Qobuz; nothing is hallucinated.
- **One codebase, two platforms** — macOS and iOS share `RoonSageCore` + `RoonSageUI`; the iOS app is a UI/packaging layer, not a fork.
- **Local-first** — the library, listening history, and audio features live in a local database; queries never re-hit Roon.
- **AI assists, you decide** — the LLM proposes; playback always goes through your real Roon zones.
- **UI in Dutch, code in English** — user-facing labels are Dutch; protocol/business logic and APIs are English (repo convention).

---

## Platforms

| Platform | Source | How it ships |
|----------|--------|--------------|
| **macOS** (14 Sonoma+) | [`native/RoonSage`](native/RoonSage) — `RoonSage` app target | Signed/notarized **DMG** via the `v*` tag → `Release macOS DMG` workflow (in-app updater picks it up) |
| **iOS / iPadOS** (17+) | [`native/iosapp`](native/iosapp) — xcodegen project | **TestFlight** via the `ios-v*` tag → `Release iOS TestFlight` workflow |
| **Audio Analyzer** | [`native/RoonSage`](native/RoonSage) — `RoonSageAnalyzerApp` / `roonsage-analyzer` CLI | DMG via the `analyzer-v*` tag → `Release Analyzer App` workflow |

> The three tag schemes are **separate** and never share a namespace: Mac app `vX.Y.Z`, analyzer `analyzer-vX.Y.Z`, iOS/TestFlight `ios-vX.Y.Z`. Pushing a tag triggers the matching release workflow.

---

## Features

### Library & playback
- **Browse** your full library as a track list, **albums grid**, or **artists grid**, with drill-down from album/artist into tracks. FTS5 full-text search; sort and filter by genre, decade, artist, keywords.
- **Immersive Now Playing** — full-bleed blurred album-art backdrop tinted by the art's dominant colour, large transport, scrubber, and a zone switcher.
- **Queue** view, transport, volume, shuffle/repeat, **zone transfer**, and grouping — all driven through your real Roon outputs.
- **Lock Screen / Control Center / CarPlay / AirPods** controls on iOS (`MPNowPlayingInfoCenter` + remote command center), plus **Live Activities** (lock screen + Dynamic Island) and **Siri Shortcuts**.

### AI curation & search
- **Generate** — describe a mood/genre/era; the LLM analyses it into filters, picks tracks from your library, and plays or saves the result.
- **Ask** — a lightweight vibe prompt → one LLM call → instantly-playable results (play now / queue next / play all).
- **Recommend** — album recommendations grounded in your library.
- **Save to Qobuz** — push a curated set to a real Qobuz playlist.
- LLM providers: **Anthropic**, **OpenAI**, and **Ollama** (local).

### Sonic intelligence (from audio features)
- **Sonic Fingerprint** — your musical DNA as a radar chart, computed from your most-played tracks, used to surface similar (and undiscovered) library tracks.
- **Music Map** — a native, ML-free 2D scatter of every analyzed track (X = tempo, Y = energy, colour = Camelot key); tap a point to play it.
- **Song Paths** — the smoothest sonic bridge between two tracks (nearest-neighbour walk / graph search).
- **Song Alchemy** — add/subtract vector math over the feature space to blend or steer a selection.
- **Taste Profile** — top artists, genres, tags, and listening stats combining local history with ListenBrainz/Last.fm.
- **Year in Review** — a recap of your listening.

### DJ tools
- **DJ Set** — beatmatched, Camelot-compatible sets with a BPM curve, a fixed-scale energy arc, and a harmonic-transition strip (harmonic / same-key / tempo-only), plus an "X/Y harmonic transitions" summary.
- **Live DJ** — for the now-playing track, suggests harmonically-compatible next tracks (Camelot + BPM) with one-tap play/queue.
- **Export** a set as a readable tracklist or **M3U** (with BPM/Camelot) via a share sheet.

### Scrobbling & history
- Per-zone listening monitor with a gated scrobble coordinator → **ListenBrainz** + **Last.fm** (now-playing + listen submission), local `listening_history`, and a backfill path.

### Design
- System/Light/Dark themes, an accent picker (Roon gold default), album-art-driven dynamic colour, skeleton loaders, empty states, and haptics on iOS.

---

## Architecture

```
native/
├── RoonProtocol/                 # Roon discovery + transport, pure Swift
│   └── Sources/RoonProtocol/     #   SOOD (UDP discovery), MOO frame codec, RoonServices
├── RoonSage/                     # the shared SPM package (one Package.swift, macOS + iOS)
│   └── Sources/
│       ├── RoonSageCore/         #   RoonClient, GRDB database, sync, browse, playback,
│       │                         #   LLM/Qobuz/ListenBrainz/Last.fm clients, share/proxy server
│       ├── RoonSageUI/           #   all SwiftUI views (shared by Mac + iOS), Theme, Appearance
│       ├── AudioAnalysis/        #   BPM, key→Camelot, FFT, metadata, fuzzy track matching
│       ├── AnalyzerCore/         #   analyzer library walk, feature store, HTTP /features server
│       ├── RoonSageAnalyzer/     #   roonsage-analyzer CLI (analyze / validate)
│       ├── RoonSageAnalyzerApp/  #   the standalone Analyzer macOS app
│       ├── RoonSageMCP/          #   roonsage-mcp — MCP server for Claude Desktop (stdio)
│       └── RoonSage/             #   the macOS app shell (App/MenuBar/Settings/Update)
└── iosapp/                       # iOS app target (xcodegen) → reuses RoonSageUI + RoonSageCore
    ├── Sources/                  #   @main + NowPlayingCenter (MPNowPlayingInfoCenter)
    ├── Widgets/                  #   RoonSageWidgets (Live Activity, Dynamic Island)
    └── Shared/                   #   App Intents (play/pause/next/prev) shared with the widget
```

`RoonSageCore`, `RoonSageUI`, `AudioAnalysis`, `AnalyzerCore`, and `RoonProtocol` are **platform-clean** (no AppKit) — that's what lets the iOS app reuse them. macOS-only chrome (DMG updater, menu-bar extra, `NSAlert`) is isolated behind `#if os(macOS)`.

### Server / client split

Only one device registers a Roon extension. RoonClient runs in one of two modes (`RoonControlMode`):

- **`direct`** — the **always-on server build** (typically the Mac mini next to your Roon Core): registers the Roon extension, syncs the library, runs the analyzer, and exposes a small HTTP server (`LibraryShareServer`, port `5767`):
  - `GET /library` — the synced library (so an iPhone imports it instead of an hours-long Browse walk)
  - `GET /settings` — synced settings
  - `GET /playback?zone=…` — live zones / now-playing / queue
  - `POST /command` — play / pause / volume / curate / … (the **playback proxy**)
  - `GET /health`
- **`server`** — the **Mac/iOS client apps**: no Roon extension on the device; they pull the library and settings, show live playback, and proxy every transport/curation command through the server. Playback still happens per-device-targeted Roon zones.

The analyzer is the **server of record** for sync, settings, and audio analyses; the Mac and iOS apps are thin clients that pull everything. (Discovery on iOS uses ZeroTier + a saved host, since SOOD multicast needs Apple's multicast entitlement.)

---

## Build & run

Requires Xcode 15+ (macOS 14 SDK / iOS 17 SDK) and Swift 5.9+.

```bash
# macOS app + DMG (signs/notarizes when signing env is set — see native/SIGNING.md)
cd native && ./scripts/build-release.sh 1.0.0

# Analyzer app DMG
cd native && ./scripts/build-analyzer-release.sh 1.0.0

# iOS app → generate the Xcode project, then build/run in Xcode
cd native/iosapp && xcodegen generate && open RoonSageiOS.xcodeproj

# Run the Swift test suites
cd native/RoonProtocol && swift test
cd native/RoonSage     && swift test

# Always build release before tagging (release strict-concurrency catches more than debug)
cd native/RoonSage && swift build -c release
```

Build/signing details and the GitHub release secrets: [`native/SIGNING.md`](native/SIGNING.md).
Roadmap: [`native/ROADMAP.md`](native/ROADMAP.md).
Architecture audit: [`docs/NATIVE_APP_AUDIT.md`](docs/NATIVE_APP_AUDIT.md).

---

## Claude Desktop (MCP)

The `roonsage-mcp` executable is a small **MCP server** (stdio JSON-RPC) that lets Claude Desktop control RoonSage. It talks to the RoonSage server build and exposes tools such as:

`roon_zones` · `roon_play_pause` · `roon_next` / `roon_previous` · `roon_set_volume` · `roon_adjust_volume` · `roon_mute` · `roon_set_shuffle` · `roon_set_repeat` · `roon_transfer_zone` · `roon_search_library` · `get_library_stats` · `get_albums` · `filter_tracks` → `curate_and_play` · `validate_playlist` · `play_album` · `get_listening_history` · `get_top_artists` · `get_taste_profile` · `sync_library`

Build it with `swift build` (target `roonsage-mcp`) and point your `claude_desktop_config.json` at the resulting binary.

---

## Audio Analyzer

The analyzer (CLI `roonsage-analyzer` + the `RoonSageAnalyzerApp` macOS app) walks your music files, extracts **BPM** and **musical key → Camelot**, and serves the results over HTTP (`/features`) so the Mac and iOS apps join them onto the synced library for the DJ/Sonic features. It's all native Swift (`AudioAnalysis`) — no librosa, no Python.

- **Track matching** uses a durable `TrackIdentity.matchKey` (`artist|title` with position-prefix / featured-artist / remaster-edition normalisation) plus a primary-artist reducer and a same-artist fuzzy fallback, so Roon's metadata joins onto file tags despite classical-title truncation and "feat." differences.
- **Accuracy** uses parabolic autocorrelation-peak interpolation for sub-frame BPM and per-frame chroma normalisation with silent-frame gating for key detection. A `validate <musicdir> --reference <csv>` harness reports BPM/key accuracy against a labelled sample.

---

## Legacy Docker web-app (deprecated)

> ⚠️ The original self-hosted **FastAPI web app + MCP server** is **deprecated and no longer maintained**. Its full source now lives under [`legacy-docker/`](legacy-docker/) and is kept for reference only. See [`legacy-docker/README.md`](legacy-docker/README.md).

That stack connected to a Roon Core as an Extension, mirrored the library into a SQLite cache, and exposed ~69 MCP tools so Claude Desktop could curate, discover, and control Roon via a web UI. Everything it did is being reimplemented natively. If you're running it, the legacy README has the Docker/config/API reference.

---

## Repository layout

| Path | What |
|------|------|
| [`native/`](native/) | **Primary product** — the macOS & iOS apps, shared packages, analyzer, scripts, and docs |
| [`legacy-docker/`](legacy-docker/) | Deprecated Docker/FastAPI web app + Python MCP server (reference only) |
| [`docs/`](docs/) | Native audit (`NATIVE_APP_AUDIT.md`) and other docs |
| `data/` | Runtime data (databases, caches) — git-ignored |

CI: `.github/workflows/native-tests.yml` (primary) runs the Swift suites; the `release-macos` / `release-ios` / `release-analyzer` workflows are tag-triggered. `.github/workflows/test.yml` is path-filtered to `legacy-docker/**`.

---

## License & credits

MIT — see [LICENSE](LICENSE).

- [Roon Labs](https://roon.app) for the Extension, Browse, and discovery (SOOD/MOO) APIs
- [GRDB.swift](https://github.com/groue/GRDB.swift) for the local database
- [ListenBrainz](https://listenbrainz.org) for open listening data
- [Last.fm](https://www.last.fm) for music intelligence and community tags
- [MusicBrainz](https://musicbrainz.org) for open music metadata
- [Qobuz](https://www.qobuz.com) for the lossless streaming catalogue
- [Anthropic](https://www.anthropic.com), [OpenAI](https://openai.com), and [Ollama](https://ollama.com) for the LLM backends
