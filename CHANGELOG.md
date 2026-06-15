# Changelog

All notable changes to RoonSage are documented here.

## Native era (macOS / iOS / Analyzer)

RoonSage is now a native Swift/SwiftUI product. Per-release notes are published
on **[GitHub Releases](https://github.com/Georgemvp/roonsage/releases)** (the
in-app updater consumes the same feed), across three independent tag tracks:

- **macOS** — `vX.Y.Z`
- **iOS** — `ios-vX.Y.Z`
- **Analyzer** — `analyzer-vX.Y.Z`

The entries below document the **deprecated** Docker/Python web app
(`legacy-docker/`), kept for historical reference only.

---

## [13.2.0] - 2026-06-01 _(legacy Docker/Python)_

### Added

- **Background AI enrichment system** — unified AI enrichment pipeline for free/local providers (Ollama, custom). Six independent tasks running continuously in trickle mode:
  - **Vibe & Context Tagging** — LLM assigns 2–4 listening contexts ("late night coding", "Sunday cleaning") and 1–2 mood labels ("melancholic", "euphoric") to every library track. Stored in `track_vibes`.
  - **Lyrics Theme Extraction** — extracts themes, emotional arc, language and abstraction level from embedded lyrics. Stored in `track_lyrics_themes`.
  - **Discovery AI Descriptions** — proactively generates tagline + description for Deep Cuts, Forgotten Favorites and Genre Explorer sections. Cached in `discovery_descriptions`, refreshed every 24 h. Displayed immediately on the Discovery tab without a page reload.
  - **Cluster AI Labels** — generates vivid names, descriptions and color hints for each sonic cluster after clustering runs. Stored in `cluster_ai_labels`.
  - **Song Path Narratives** — writes a short narrative about the sonic journey for each Song Path. Generated on-demand after a path is computed; cached by MD5 of the path parameters in `song_path_narratives`.
  - **Template Suggestions** — proposes 3 new playlist templates weekly based on listening patterns. Cached in `template_suggestions_cache`.

- **Trickle mode scheduling** — batches run continuously (not just at night). Pause between batches is time-of-day aware: 8 s / 15 s at night (01:00–07:00), 90 s / 120 s during the day, so Gemma 4 is never overwhelmed during active hours.

- **Global LLM semaphore** — `asyncio.Semaphore(1)` across all background AI tasks guarantees no concurrent Ollama calls regardless of which tasks are triggered simultaneously.

- **Background AI settings dashboard** (`/settings` → Background AI section) — unified control panel with:
  - Toggle to enable/disable background AI (persisted to `config.user.yaml`; disabled automatically for paid providers)
  - Provider badge showing the active LLM provider
  - Active task widget with live progress bar and `done / total` counter
  - Per-task cards showing schedule, state badge (running / queued / failed / complete / partial / idle), and progress bar derived from DB counts
  - Manual "Nu starten" / "Genereren" trigger buttons per task

- **Notification enrichment** — the event bus optionally personalises notification messages with an AI-written summary + emoji when the notification type is `playlist_generated`, `new_release_found` or `listening_milestone`. Uses a 5 s timeout so it never blocks a notification.

- **AI playlist descriptions** — after a playlist is saved to history (`/api/generate` or refine), a fire-and-forget call generates a short AI description + tags and persists them in the `results` table (`ai_description`, `ai_tags` columns). Shown as the subtitle in the Playlists view.

- **Background task tracker** (`backend/background_tasks.py`) — thread-safe in-memory tracker that records status, progress percentage, elapsed time and error for every background AI task. Exposed via `/api/background-ai/status`.

- **New API endpoints** (`/api/background-ai/`):
  - `GET /config` — current enabled state + provider
  - `POST /config` — persist enabled toggle
  - `GET /status` — unified status for all 6 tasks (DB progress + task_tracker state)
  - `POST /start-vibes` / `POST /start-lyrics-themes` — manual triggers
  - `POST /generate-cluster-labels` / `POST /generate-template-suggestions` — manual triggers
  - `GET /song-path-narrative/{cache_key}` — cached narrative lookup
  - `GET /template-suggestions` — cached suggestions
  - `POST /describe-playlist` — on-demand playlist description

- **New DB tables**: `cluster_ai_labels`, `song_path_narratives`, `template_suggestions_cache`.

- **`results` table extended** with `ai_description TEXT` and `ai_tags TEXT` (JSON) columns for AI-generated playlist metadata.

### Changed

- **Vibe & lyrics loops** replaced from nightly one-shot (`_sleep_until_night()` → run all → sleep 24 h) to continuous trickle (`max_batches=1` per tick, time-of-day pause). Tasks always make progress; full speed at night, gentle pace during the day.
- **Clustering** (`/api/clustering/run`) now automatically fires `generate_cluster_labels()` after a successful cluster run.
- **Song Paths** (`/api/song-path`) now generates and caches a narrative for every computed path when background AI is enabled.
- **Scheduler + Automation Engine** now respect `is_background_ai_enabled()` — generation tasks are skipped (not errored) when background AI is disabled for paid providers.
- **Playlists view** shows `ai_description` as subtitle when available, falling back to the stored subtitle.
- **Taste profile stat cards** improved: hours now estimated from LB scrobble count (avg 4 min/track) when more complete than local Roon-logged hours; unique tracks and artist count use best available source across profile, LB and stats objects; top genre and peak hour chips populated.
- **Analysis Tasks panel** extended with vibe tagging and lyrics themes status + trigger controls (in addition to the unified Background AI section).

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
