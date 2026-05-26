# Changelog

All notable changes to RoonSage are documented here.

## [13.1.0] - 2026-05-26

### Added
- **Sonic Fingerprint** — computes the user's musical DNA from listening history: averages the audio-feature profile of their top-played tracks and ranks the full library by cosine similarity. Unplayed tracks are boosted for discovery. Radar chart visualisation (Chart.js). REST endpoints: `GET /api/sonic-fingerprint/profile`, `GET /api/sonic-fingerprint/recommendations`, `POST /api/sonic-fingerprint/play`. Two new MCP tools: `get_sonic_fingerprint`, `play_sonic_fingerprint`.
- **Mood-aware Song Paths** — optional `mood` parameter for `/api/song-path` biases the greedy walk and Dijkstra graph toward mood centroids. Eight moods defined in `data/mood_centroids.json`: calm, energetic, happy, melancholic, aggressive, dreamy, groovy, dark. Mood dropdown added to the Song Paths frontend view and `find_song_path` MCP tool.

### Fixed
- Docker build: split requirements into `requirements.txt` (core, compiled by uv) and `requirements-ml.txt` (torch/torchaudio CPU wheels + umap-learn, hdbscan, laion-clap, transformers). The builder stage now installs them in two separate layers so Docker can cache the large ML layer independently.
- `sqlite3.Row` does not support `.get()` — fixed `AttributeError` in `backend/discovery.py` (`get_lb_top_releases_in_library`).

## [12.0] - 2026-05-22

### Added
- **Audio feature analysis** — new `backend/audio_features/` subsystem (analyzer, worker, camelot mapper, DJ set generator, path resolver). Background worker extracts BPM, musical key (Camelot wheel), energy, danceability, valence, instrumentalness, acousticness, tempo confidence per track using librosa. Stored in `track_audio_features` table; queue table `audio_features_queue` drives processing
- **DJ set builder** — beatmatched, harmonically mixed playlist generator with configurable BPM curve (flat / ramp_up / ramp_down / peak / valley), Camelot-compatible transitions, and optional seed track. Frontend "DJ Set" view + MCP tool `build_dj_set`
- **Audio-feature filters** — `filter_tracks_by_audio` MCP tool (BPM range, Camelot keys, energy/valence/danceability/instrumentalness windows) returns same session-based shape as `filter_tracks`
- **Live scan progress in UI** — Audio Features view shows a phase banner (walking / matching / complete) with file-count, throughput, and ETA while the filesystem walk runs
- **67 MCP tools** (up from 62) — adds `get_audio_features_status`, `get_track_audio_features`, `filter_tracks_by_audio`, `build_dj_set`, plus expanded template engine with category tabs in the UI
- **63 playlist templates** with category tabs in the UI
- **PWA support** — installable on mobile and desktop (manifest + service worker + SVG icons)
- **Taste profile everywhere** — `use_taste_profile` toggle applied across all generation flows
- **125 new tests** — covering 7 previously untested subsystems (coverage gate ≥ 40 %)
- **Enrichment speed options** — `ENRICHMENT_SKIP_MB=true` for Last.fm-only mode (~50× faster on large libraries); persistent dedup cache across batches; MB tag-fetch skipped when Last.fm is active
- **Self-healing SQLite** — `repair_corrupt_indexes()` runs `PRAGMA integrity_check` on every startup and rebuilds affected tables when uvicorn-reload or container kills leave broken indexes; orphaned `processing` / `analyzing` rows in the enrichment + audio-features queues are reset to `pending`
- **`NUMBA_CACHE_DIR` + `MPLCONFIGDIR`** mapped to `/app/data/.numba_cache` / `.mpl_cache` so librosa's numba JIT can cache inside the container

### Changed
- **Discovery / polling / retries / watchlist** — discovery queries refactored (caching + smaller fan-out), polling intervals tuned, retry/back-off normalized in `lastfm_client` + `listenbrainz_client`, watchlist scan made more conservative
- **Audio-features worker concurrency** raised from 2 → 4 (analysis is CPU-bound; tune down if the host saturates)
- **Path resolver** is now single-flight (thread lock) and non-blocking from the REST API; concurrent scan attempts back off

### Fixed
- `closeBottomSheet` moved to `window`; raw `fetch` calls migrated to `apiCall`
- Track number prefix stripping and navigation-item filtering in album browse
- Exact title match instead of `LOWER()` for album enrichment
- Track→album matching on `(title, artist)` instead of `item_key` (Phase 4 sync); subsequent fix narrows the match to title-only when the artist column has been normalised differently
- Discovery deep-cuts + forgotten-favorites capped at 2 tracks/artist, randomised

---

## [11.0]

### Added
- Discovery engine uses ListenBrainz `top_releases` + loved tracks with 1-per-artist diversity
- Filter sessions (server-side `key_map`) — saves 10–20 k tokens per curation flow
- AcoustID fingerprint verification for Qobuz tracks
- Automation engine (trigger-action workflows)
- Scheduled playlist regeneration (cron-based, 60 s tick)
- Enrichment worker — MusicBrainz + Last.fm background metadata pipeline
- Watchlist scanner — monitors Qobuz for new releases from favourite artists
- Notifications — Discord / Telegram / webhook event bus

---

## [10.0]

### Added
- Scrobble import (one-time backfill from ListenBrainz and Last.fm)
- Taste profile — unified profile combining local listening history, LB stats, and Last.fm stats
- MusicBrainz client + AcoustID client
- Qobuz direct API for playlist save (`app_id` auto-detected)
- HTTP Basic Auth (`ROONSAGE_PASSWORD`)
- slowapi rate-limiter on LLM endpoints (30 req/h/IP)

---

## [9.0] and earlier

Early development — Roon library sync, SQLite cache, initial MCP server (FastMCP), web UI, ListenBrainz and Last.fm scrobbling.
