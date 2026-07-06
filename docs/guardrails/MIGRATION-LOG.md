<!-- guardrails-kit migration log -->
# MIGRATION-LOG.md — guardrails-kit v1.0 install

Mode: FULL MIGRATION (Phase 0: no sentinel, no prior log, CLAUDE.md exists @ 249 lines).
Snapshot: CLAUDE.md.pre-migration-20260706-1444 (hash 20e6384ca111fada13f04d0d135a36cca8faabb1, committed 9a6b20f).
User decisions (M5): (1) drop legacy-docker content — native kept; (2) commit snapshot allowed, no push;
(3) rescue product principles: library-first (L31 clause) + Roon-API constraints (L110-119).

## Surfaces
- ./CLAUDE.md (249 lines) — MIGRATE (primary target).
- ./.claude/worktrees/agent-a8978658f823d6703/CLAUDE.md — LEAVE (ephemeral agent-worktree scratch; never edited).
- .claude/settings.local.json — LEAVE (contains only a "permissions" allowlist; no hooks).
- No .claude/commands, .claude/agents, .claude/skills directories.
- No @import lines in CLAUDE.md.
- No existing docs/guardrails/*.md name collisions (dir freshly created).

## Disposition table
Counts: MOVED 29, DROPPED 161, KEPT/MERGED/SUPERSEDED/UNSORTED/CONFLICT-PENDING 0. Non-blank lines 190 == rows 190.
| # | original text (verbatim) | disposition | destination | note |
|---|---|---|---|---|
| 001 | # CLAUDE.md | DROPPED | — | decoration: label-only title heading |
| 002 | This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. | DROPPED | — | boilerplate: content-free intro sentence |
| 003 | ## Repository structure (READ FIRST) | MOVED | docs/guardrails/PROJECT.md | heading -> anchor ## Repository structure ('(READ FIRST)' kept as body emphasis) |
| 004 | The repository now has two tracks: | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 005 | - **`native/`** — the **primary product**: native macOS & iOS apps (Swift/SwiftUI). | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 006 |   Shared SPM package (`native/RoonSage` — RoonSageCore/UI/MCP/AudioAnalysis/Analyzer), | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 007 |   the protocol package (`native/RoonProtocol`), the iOS app (`native/iosapp`, xcodegen), | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 008 |   the analyzer, build scripts (`native/scripts/`) and docs (`native/ROADMAP.md`, | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 009 |   `native/SIGNING.md`). These apps use their own **GRDB** database and do **not** | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 010 |   need the Python backend. CI: `.github/workflows/native-tests.yml` (primary) + | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 011 |   the `release-macos`/`release-ios`/`release-analyzer` tag-triggered workflows. | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 012 | - **`legacy-docker/`** — the **deprecated** Docker/FastAPI web app + MCP server, | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 013 |   being decommissioned and kept for reference only. CI: `.github/workflows/test.yml` | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 014 |   (path-filtered to `legacy-docker/**`). | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 015 | > ⚠️ The "Project Overview", "Commands", "Architecture", and convention sections | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 016 | > **below describe the legacy Docker/Python stack**, whose source now lives under | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 017 | > `legacy-docker/`. Every relative path mentioned below (`backend/`, `frontend/`, | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 018 | > `mcp_server.py`, `tests/`, `requirements*.txt`, `pyproject.toml`, | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 019 | > `system_prompt.md`, `scripts/`, `config.example.yaml`, the `Dockerfile` and | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 020 | > `docker-compose*.yml`) is now under `legacy-docker/`. Runtime `data/` stays at | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 021 | > the repo root. Prefer working in `native/` unless a legacy reference fix is | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 022 | > explicitly requested. | MOVED | docs/guardrails/PROJECT.md | native-relevant repo orientation (verbatim) |
| 023 | ## Project Overview | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 024 | RoonSage is a self-hosted FastAPI web app + MCP server that connects to a Roon Core as an Extension, mirrors the library into a local SQLite cache, and exposes ~69 tools so Claude Desktop can curate playlists, discover music, monitor releases, automate workflows, analyse audio features, build DJ sets, and control Roon through natural language. The constitution principle is **library-first**: every suggested track must exist either in the user's Roon library or on Qobuz — nothing is hallucinated. | DROPPED | CLAUDE.md ## Project | legacy sentence DROPPED; 'library-first' clause preserved verbatim as a zone-2 project constraint (user rescue) |
| 025 | Current version: **v13.1** (see `pyproject.toml`, `backend/version.py` auto-detects via `git describe`). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 026 | v13.1 highlights: Sonic Fingerprint (musical DNA from listening history, radar chart, 2 MCP tools), | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 027 | mood-aware Song Paths (8 mood centroids bias the greedy walk / Dijkstra graph), | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 028 | Docker build split into core (`requirements.txt`) + ML (`requirements-ml.txt`) layers. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 029 | v13.0 highlights: sonic clustering (UMAP+HDBSCAN), Music Map 2D visualization, | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 030 | Song Paths (bridge playlists), Song Alchemy (ADD/SUBTRACT vector mixing), | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 031 | CLAP text-to-audio search, semantic lyrics search. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 032 | ## Commands | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 033 | ```bash | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 034 | # Install | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 035 | pip install -r requirements.txt -r requirements-dev.txt | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 036 | # Development server (with auto-reload; use --workers 1 to avoid file-handle races on the SQLite cache) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 037 | uvicorn backend.main:app --reload --port 5765 | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 038 | # Tests | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 039 | pytest                              # full suite | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 040 | pytest tests/test_library_cache.py  # single file | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 041 | pytest -k "test_filter"             # by name | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 042 | pytest --cov=backend --cov-report=term-missing --cov-fail-under=40   # what CI runs | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 043 | # Lint (CI gate — must be clean) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 044 | ruff check . | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 045 | # Docker | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 046 | docker-compose up -d --build | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 047 | # MCP server setup (runs LOCALLY on the user's machine, not in Docker) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 048 | pip install "mcp[cli]" httpx | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 049 | python3 scripts/install_mcp.py   # writes claude_desktop_config.json | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 050 | ``` | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 051 | CI (`.github/workflows/test.yml`) runs ruff + pytest with coverage gate ≥40% on Python 3.11 and 3.12. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 052 | ## Architecture | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 053 | ### Backend layout (`backend/`) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 054 | - **`main.py`** — FastAPI app, lifespan, JSON-line logging, optional HTTP Basic Auth middleware, CORS, slowapi rate-limiter wiring, static file serving. Lifespan logic is split out to **`startup.py`** (`init_clients`, `start_background_tasks`, `shutdown`). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 055 | - **`routes/`** — every feature has its own router (library, generate, recommend, roon, intelligence, qobuz_playlist, discovery, templates, watchlist, scheduler, automations, enrichment, verify, notifications, results, setup, config_routes, **audio_features**). New endpoints go into the matching router; don't add to `main.py`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 056 | - **`db.py`** — SQLite schema, WAL-mode connections, migration flag, `needs_resync()`. All other cache modules use `get_db_connection()` or the `get_connection()` context manager from here. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 057 | - **`library_cache.py`** — orchestrates library sync into SQLite and exposes the read queries used by filters/discovery. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 058 | - **`roon_client.py`** — thin re-export. The real implementation is the **mixin pattern** across `roon_connection.py`, `roon_browse.py`, `roon_playback.py`, `roon_search.py`, `roon_intelligence.py`. `RoonClient` inherits all of them. Browse calls are serialized via `_browse_lock` (single-session API constraint, see below). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 059 | - **LLM/AI**: `llm_client.py` (multi-provider — anthropic, openai, gemini, ollama, custom), `analyzer.py` (prompt → genre/decade filter), `generator.py` (filtered track list → playlist), `recommender.py` (album recommendations), `music_research.py` (web research helper for albums). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 060 | - **Intelligence**: `roon_intelligence.py` (zone monitor + listening history + scrobble dispatch to LB/LF), `taste_profile.py` (combines local + LB + Last.fm into a unified profile with `lb_` / `lf_` prefixed keys), `scrobble_import.py` (one-time backfill from LB/LF). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 061 | - **External services**: `listenbrainz_client.py` + `listenbrainz_sync.py`, `lastfm_client.py` + `lastfm_sync.py`, `musicbrainz_client.py`, `acoustid_client.py`, `qobuz_browser.py` (search/playback via Roon), `qobuz_api.py` (direct Qobuz JSON API for playlist save). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 062 | - **Workflow subsystems**: `discovery.py` (4 cache-only discovery sections), `watchlist.py` (artist new-release scanner), `scheduler.py` (cron-based playlist regeneration), `automation_engine.py` (trigger-action workflows), `enrichment_worker.py` (background MusicBrainz + Last.fm enrichment — `ENRICHMENT_SKIP_MB=true` switches to Last.fm-only for ~50× speed), `templates.py` (playlist template engine, 63 built-ins with category tabs), `notifications.py` (event bus → Discord/Telegram/webhook). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 063 | - **Sonic clustering + Music Map** (`backend/audio_features/clustering.py` + `backend/routes/clustering.py`): UMAP→HDBSCAN over the audio-features matrix; persists `cluster_id`/`x_2d`/`y_2d` columns onto `track_audio_features` plus a `cluster_runs` single-row metadata table. Powers the canvas Music Map view in `frontend/modules/music-map.js`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 064 | - **Song Paths** (`backend/audio_features/song_path.py` + `backend/routes/song_path.py`): smoothest sonic bridge between two tracks — greedy nearest-neighbor walk biased toward the target *or* Dijkstra over a k-NN graph (`method="graph"`). Optional `mood` parameter biases the walk toward one of 8 mood centroids defined in `data/mood_centroids.json`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 065 | - **Sonic Fingerprint** (`backend/audio_features/sonic_fingerprint.py` + `backend/routes/sonic_fingerprint.py`): computes the user's musical DNA by averaging the normalised feature vector of their top-played tracks and cosine-ranking the full library. Unplayed tracks are boosted for discovery. REST: `GET /api/sonic-fingerprint/profile`, `GET /api/sonic-fingerprint/recommendations`, `POST /api/sonic-fingerprint/play`. MCP tools: `get_sonic_fingerprint`, `play_sonic_fingerprint`. Frontend: radar chart + results list in `frontend/modules/sonic-fingerprint.js`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 066 | - **Song Alchemy** (`backend/audio_features/alchemy.py` + `backend/routes/alchemy.py`): vector arithmetic over the feature matrix — `mean(add) − 0.5 × mean(subtract)` → cosine-rank the library. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 067 | - **CLAP text-to-audio search** (`backend/audio_features/clap_search.py` + `backend/routes/clap_search.py`): laion-clap embeds the audio itself; queries are matched directly against those embeddings. Disabled unless `CLAP_ENABLED=true`. Storage: `clap_embeddings` + `clap_runs`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 068 | - **Semantic lyrics search** (`backend/lyrics/` + `backend/routes/lyrics.py`): `extractor.py` pulls embedded lyrics from MP3/FLAC/M4A tags via mutagen; `embedder.py` runs GTE-multilingual via `transformers` (lazy-loaded). Disabled unless `LYRICS_SEARCH_ENABLED=true`. Storage: `lyrics_data` + `lyrics_embeddings` + `lyrics_runs`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 069 | - **Audio features** (`backend/audio_features/`): `analyzer.py` runs librosa to extract BPM, Camelot key, energy, danceability, valence, instrumentalness, acousticness; `worker.py` is a managed asyncio worker (CONCURRENCY=4, CPU-bound) that drains `audio_features_queue`; `path_resolver.py` walks `MUSIC_LIBRARY_PATH` once to map library tracks → on-disk files (single-flight via thread lock, exposes live progress via `get_scan_progress()`); `dj_generator.py` builds beatmatched, Camelot-compatible DJ sets with configurable BPM curves; `camelot.py` maps musical keys to wheel positions. Routes in `routes/audio_features.py`. Tables: `track_audio_features`, `audio_features_queue`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 070 | - **`filter_sessions.py`** — server-side `session_id` → `key_map` storage so the MCP client doesn't have to hold the full track list in context (saves 10–20k tokens per curation flow). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 071 | - **`models.py`** — Pydantic models for all API contracts. Every request/response uses these. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 072 | ### Frontend (`frontend/`) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 073 | Vanilla HTML/CSS/JS, no build step. Single-page app shell `index.html` + `app.js` bootstrap; per-view modules live in `frontend/modules/` (one file per view: playlist, library, discovery, taste, watchlist, automations, scheduler, history, playlists, nowplaying, recommend, templates, setup-wizard, plus shared `api.js`/`state.js`/`router.js`/`ui.js`/`events.js`). Chart.js is loaded via CDN for taste-profile charts. The frontend is a PWA (`manifest.json` + SVG icons). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 074 | ### Data flow | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 075 | 1. **Sync** — `library_cache.sync_library()` walks Roon Browse hierarchy (Root → Library → Albums → tracks per album) and writes into `tracks` + `track_genres` + `albums` tables. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 076 | 2. **Query** — `filter_tracks` runs SQL against the local cache (genre IN (...), decade, keywords, optional artist-cap, live-version exclusion); never re-hits Roon. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 077 | 3. **Curate** — Claude Desktop (or the backend LLM for the web UI) picks track numbers from the numbered list; `curate_and_play` translates them back to Roon item keys via the stored session and calls Play Now. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 078 | 4. **Background** — listening monitor, LB/LF sync (every 6h), watchlist scan (every 12h), scheduler (60s tick), enrichment worker, audio-features worker, automation engine, periodic DB backup (every 4h) all run as managed asyncio tasks; cancelled cleanly in `shutdown()`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 079 | 5. **Self-heal at startup** — `repair_corrupt_indexes()` runs `PRAGMA integrity_check` and rebuilds any corrupt indexes (caused by uvicorn-reload mid-write or container kills). Orphaned `processing` / `analyzing` rows in `enrichment_queue` + `audio_features_queue` are reset to `pending` so workers don't leave items stuck. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 080 | ### MCP Server (`mcp_server.py`, single file at repo root) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 081 | Wraps the RoonSage REST API as **~67 tools** for Claude Desktop using `mcp[cli]` (FastMCP) + httpx over stdio. Contains **no LLM logic** — Claude Desktop does the thinking. When you change a backend endpoint in `routes/`, update the corresponding tool here too. It runs locally on the user's machine (not in Docker); `scripts/install_mcp.py` configures `claude_desktop_config.json`. The system prompt that ships to Claude Desktop is `system_prompt.md` at repo root. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 082 | ## Key Conventions and Gotchas | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 083 | ### Roon API constraints (NOT bugs — work around them) | MOVED | docs/guardrails/PROJECT.md | Roon-API product constraints, verbatim -> ## Roon API constraints (user rescue) |
| 084 | - **No user ratings**: `user_rating` is always `None`. Any `min_rating` filter code has been removed. | MOVED | docs/guardrails/PROJECT.md | Roon-API product constraints, verbatim -> ## Roon API constraints (user rescue) |
| 085 | - **No play counts via Roon**: `view_count` is hardcoded to `0`. Play counts come from the local `listening_history` table (logged by `roon_intelligence._log_listen`) + LB/LF stats. | MOVED | docs/guardrails/PROJECT.md | Roon-API product constraints, verbatim -> ## Roon API constraints (user rescue) |
| 086 | - **No playlist creation via Roon Extension API**: use `qobuz_api.py` (direct Qobuz JSON API) for playlist save. `app_id` is auto-detected — never hardcode. | MOVED | docs/guardrails/PROJECT.md | Roon-API product constraints, verbatim -> ## Roon API constraints (user rescue) |
| 087 | - **No direct track queries**: every library access goes through Browse hierarchy (Root → Library → Albums → tracks per album). | MOVED | docs/guardrails/PROJECT.md | Roon-API product constraints, verbatim -> ## Roon API constraints (user rescue) |
| 088 | - **Metadata parsed from subtitle strings**: `"Artist • Year • Genre"` split on `•`. Fragile — defend against missing fields. | MOVED | docs/guardrails/PROJECT.md | Roon-API product constraints, verbatim -> ## Roon API constraints (user rescue) |
| 089 | - **ARC zones invisible**: Roon ARC playback is not observable from the Extension API. | MOVED | docs/guardrails/PROJECT.md | Roon-API product constraints, verbatim -> ## Roon API constraints (user rescue) |
| 090 | - **Single-session Browse API**: concurrent browse calls on the same hierarchy interfere. All Roon Browse sequences must be serialized — `_browse_lock` (and the album/genre variants) on `RoonClient` exists for this reason. Don't bypass it. | MOVED | docs/guardrails/PROJECT.md | Roon-API product constraints, verbatim -> ## Roon API constraints (user rescue) |
| 091 | - **`hierarchy: "search"` (global search) returns ephemeral item keys**. They expire as soon as another browse/search call mutates session state. For Qobuz global-search fallback, `qobuz_browser.py` generates a synthetic key `qobuz_search::{url-encoded artist}::{url-encoded title}`; `roon_playback.play_tracks` detects this prefix and re-issues a fresh search at playback time. Don't try to "fix" this by storing the real key. | MOVED | docs/guardrails/PROJECT.md | Roon-API product constraints, verbatim -> ## Roon API constraints (user rescue) |
| 092 | ### Playback / queue | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 093 | - **`play_tracks` tries direct key browse first**, then falls back to search. This was deliberate — for classical/long titles Roon search often returns the wrong track when given a key that's still valid. Don't reorder. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 094 | - **`curate_and_play` uses a 180s timeout** (not 30s) because 30+ track queues can take that long. The response includes `playback_started` and a "do not retry" flag for Claude Desktop. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 095 | - **`/api/library/filter/curate` always returns a `resolved_tracks` list** (`{number, title, artist}`) sourced from SQLite. The MCP system prompt instructs Claude to render this verbatim — never reconstruct the tracklist from memory. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 096 | ### Track matching | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 097 | - Generation LLM is told to return **track numbers** from the numbered list (O(1) lookup). Falls back to rapidfuzz fuzzy match (threshold ~60) if a model ignores the instruction. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 098 | - **Live versions**: filter out by keywords (`live`, `concert`, `unplugged`) and date patterns in title/album. `is_live` is a stored column for SQL-native filtering. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 099 | - **Genre filtering**: SQL via the `track_genres` junction table, not JSON parsing in Python. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 100 | ### Filter sessions (server-side key_map) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 101 | `filter_tracks(output_format="compact" \| "ultra")` returns a `session_id`. The key_map (number → item_key) is stored server-side in `filter_sessions.py`. The client (web UI or Claude Desktop) only sees the numbered list. `curate_and_play` looks the session back up by `session_id`. This saves ~10–20k tokens per flow and is required for `max_tracks` ≥ 500. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 102 | ### Time-of-day context | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 103 | Generation/recommendation prompts get the current day + hour prepended (Dutch day names — kept for UI-language consistency). This subtly shapes mood without explicit prompting. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 104 | ### Auth / rate limiting | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 105 | - HTTP Basic Auth is enabled only when `ROONSAGE_PASSWORD` is set. Exempt paths: `/api/health`, `/api/art/*`, `/api/external-art` (otherwise Docker health checks and post-login art loading break). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 106 | - LLM endpoints are rate-limited (30 req/h/IP) via slowapi. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 107 | ### LLM models (per provider) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 108 | \| Provider \| Analysis \| Generation \| Context \| | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 109 | \|----------\|----------\|------------\|---------\| | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 110 | \| Gemini (default) \| `gemini-2.5-flash` \| `gemini-2.5-flash-lite` \| 1M tokens (~18k tracks) \| | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 111 | \| Anthropic \| `claude-sonnet-4-5` \| `claude-haiku-4-5` \| 200K (~3.5k tracks) \| | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 112 | \| OpenAI \| `gpt-4.1` \| `gpt-4.1-mini` \| 128K (~2.3k tracks) \| | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 113 | \| Ollama \| auto-detect via `/api/show` \| same \| auto-detect \| | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 114 | \| Custom \| OpenAI-compatible base_url \| same \| user-set \| | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 115 | `smart_generation: true` uses the analysis model for both stages (higher quality, ~3–5× cost). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 116 | ## Environment Variables (essentials) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 117 | ```bash | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 118 | ROON_HOST=192.168.1.x            # required | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 119 | ROON_PORT=9330 | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 120 | ROON_CORE_ID=                    # auto-saved after Roon authorization | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 121 | ROON_TOKEN=                      # auto-saved after Roon authorization | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 122 | LLM_PROVIDER=gemini              # anthropic \| openai \| gemini \| ollama \| custom | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 123 | ANTHROPIC_API_KEY= / OPENAI_API_KEY= / GEMINI_API_KEY= | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 124 | OLLAMA_URL=http://localhost:11434 | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 125 | CUSTOM_LLM_URL= / CUSTOM_CONTEXT_WINDOW= | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 126 | ROONSAGE_PASSWORD=               # enables HTTP Basic Auth | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 127 | CORS_ORIGINS=http://localhost:5765 | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 128 | # Optional services | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 129 | QOBUZ_EMAIL= / QOBUZ_PASSWORD=                       # playlist save (app_id auto-detected) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 130 | LISTENBRAINZ_TOKEN= / LISTENBRAINZ_USERNAME= | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 131 | LASTFM_API_KEY= / LASTFM_API_SECRET= / LASTFM_SESSION_KEY= / LASTFM_USERNAME= | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 132 | ACOUSTID_API_KEY= / ACOUSTID_ENABLED=false / ACOUSTID_AUTO_VERIFY_QOBUZ=false | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 133 | DISCORD_WEBHOOK_URL= / TELEGRAM_BOT_TOKEN= / TELEGRAM_CHAT_ID= / WEBHOOK_URL= | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 134 | WATCHLIST_SCAN_INTERVAL_HOURS=12 | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 135 | # Enrichment | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 136 | ENRICHMENT_SKIP_MB=true          # Last.fm-only mode (~50× faster than MB+LF) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 137 | # Audio features | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 138 | AUDIO_FEATURES_ENABLED=true      # toggles the analyzer worker + DJ-set endpoints | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 139 | # v13.0 feature toggles | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 140 | CLAP_ENABLED=false               # CLAP text-to-audio search (~600 MB model) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 141 | CLAP_MODEL=laion/larger_clap_music_and_speech | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 142 | CLAP_BATCH_SIZE=4 | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 143 | CLAP_CACHE_DIR=/app/data/.clap_cache | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 144 | LYRICS_SEARCH_ENABLED=false      # semantic lyrics search | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 145 | LYRICS_MODEL=Alibaba-NLP/gte-multilingual-base | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 146 | HF_HOME=/app/data/.hf_cache      # transformers download cache | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 147 | AUDIO_FEATURES_FULL=true         # false = BPM + key only (faster); true = full Spotify-style vector | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 148 | MUSIC_LIBRARY_PATH=/music        # filesystem root for audio analysis (must be readable) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 149 | MUSIC_PATH_MAP_FROM= / MUSIC_PATH_MAP_TO=   # remap Roon-reported paths to container paths | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 150 | NUMBA_CACHE_DIR=/app/data/.numba_cache   # required for librosa's JIT inside Docker | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 151 | MPLCONFIGDIR=/app/data/.mpl_cache | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 152 | APP_VERSION=                     # injected by Docker build; falls back to git describe | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 153 | ``` | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 154 | Config priority: env > `data/config.user.yaml` (UI-saved) > `config.yaml` (file) > defaults. UI writes go to `config.user.yaml` with `chmod 600`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 155 | ## Code Style | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 156 | - **Python**: PEP 8, type hints everywhere, Pydantic models for every API contract. `ruff` config in `pyproject.toml` (line length 100, selected rules `E,F,W,I,UP,B,SIM,TCH`; `E501`, `SIM117` ignored). CI fails on lint errors. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 157 | - **JavaScript**: ES6+, no framework, module pattern with a single shared `state` object in `frontend/modules/state.js`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 158 | - **CSS**: BEM-style naming, CSS custom properties for theming (`--color-bg #1a1a1a`, `--color-accent #e5a00d`). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 159 | - **Logging**: structured JSON lines via `JSONFormatter` in `main.py`. Use module-level `logger = logging.getLogger(__name__)`; don't replace `except Exception: pass` with bare suppression — log a warning. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 160 | - **Background tasks**: register through `_add_task(coro, name)` in `startup.start_background_tasks` so they're cancelled cleanly on shutdown and surface exceptions via the done-callback. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 161 | ## MCP Tool Selection (for Claude Desktop) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 162 | The MCP system prompt (`system_prompt.md`) instructs Claude Desktop to **curate natively** for playlists, seeds, and albums. Native curation is the primary flow; backend LLM tools (`generate_playlist`, `seed_track_playlist`, `recommend_album`) are fallback-only and are mainly used by the web UI. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 163 | ### Native curation flow (library) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 164 | 1. Analyse the user request (mood, genre, era). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 165 | 2. `get_library_stats` → see what's available. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 166 | 3. `filter_tracks(output_format="compact", genres=[...], decades=[...], max_tracks=500)` → numbered list + `session_id`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 167 | 4. Curate 15–50 tracks: ≥80% unique artists, max 2 tracks/album, no consecutive same-artist, alternate tempo/era. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 168 | 5. (Optional) `validate_playlist(session_id, track_numbers)` to catch duplicates/clustering. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 169 | 6. `curate_and_play(track_numbers, session_id, zone_id)`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 170 | 7. Present the `resolved_tracks` list from the response verbatim. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 171 | ### Source modes | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 172 | - **library**: `filter_tracks` → `curate_and_play` | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 173 | - **hybrid**: `filter_tracks` + multiple `search_qobuz` → mix → `play_tracks` (combined keys) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 174 | - **qobuz**: multiple `search_qobuz` → `play_tracks` (Qobuz keys only) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 175 | ### Common direct actions | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 176 | - **Specific album** → `play_album` | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 177 | - **Internet radio** → `play_radio` | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 178 | - **Volume / transport / shuffle / repeat** → `volume_control` / `transport_control` | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 179 | - **Move playback between rooms** → `transfer_zone` | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 180 | - **Group zones** → `zone_grouping` | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 181 | - **Library search misses** → fall back to `search_qobuz` | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 182 | - **Save curated playlist to Qobuz** → `save_to_qobuz` (after `curate_and_play` or `play_tracks`) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 183 | ### Tool categories (~67 total) | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 184 | Library & search · Discovery · Playlist generation · Claude-native curation · Album recommendations · Roon playback & control · Intelligence & taste · ListenBrainz · Last.fm · Qobuz · Watchlist · Scheduled playlists · Metadata enrichment · Automation · AcoustID verification · **Audio features & DJ sets** (`get_audio_features_status`, `get_track_audio_features`, `filter_tracks_by_audio`, `build_dj_set`). | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 185 | The full per-tool table is maintained in **README.md** under "Full MCP Tool List". | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 186 | ## When Editing | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 187 | - **Adding a backend endpoint**: add to the correct `routes/*.py`, add the Pydantic request/response models to `models.py`, expose to MCP by adding a tool in `mcp_server.py`, and update `system_prompt.md` if the tool affects Claude Desktop's flows. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 188 | - **Changing the DB schema**: edit `backend/db.py` — `init_schema` handles incremental `ALTER TABLE` migrations and flips `_migration_applied`, which triggers auto-resync in `startup.start_background_tasks`. Tables: `tracks`, `track_genres`, `albums`, `listening_history`, `lb_stats_cache`, `lf_stats_cache`, `track_metadata_ext`, `enrichment_queue`, `track_audio_features`, `audio_features_queue`, `artist_watchlist`, `artist_releases_cache`, `scheduled_playlists`, `automations`, `automation_log`, `scrobble_import_state`, plus the results history. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 189 | - **Touching Roon Browse code**: respect `_browse_lock` and the synthetic-key convention for Qobuz global-search results. Test that browse → search → browse sequences don't corrupt session state. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |
| 190 | - **Working on the frontend**: changes are picked up live without a rebuild (Docker mounts `frontend/` as a volume); HTML asset URLs are cache-busted with `?v={version}` in `serve_index`. | DROPPED | — | legacy Docker/Python stack (per user decision + file ⚠️ L20-27) |

## CONFLICTS
none found — no old PROCESS rule contradicts a kit rule (M4(c)). Every modal-keyword line is either a
kept repo-structure fact (L13, L17), a rescued Roon constraint (L110-119, now MOVED), or a DROPPED
legacy domain rule. The two product principles (L31 library-first, L110-119 Roon constraints) were
rescued at M5 per user decision, not conflicts.

## Kit-doc collisions
- _FORMAT.md: installed (no prior file; hash == kit source)
- PLAN.md: installed (no prior file; hash == kit source)
- CODE.md: installed (no prior file; hash == kit source)
- DEBUG.md: installed (no prior file; hash == kit source)
- VERIFY.md: installed (no prior file; hash == kit source)
- EFFICIENCY.md: installed (no prior file; hash == kit source)
- SESSION.md: installed (no prior file; hash == kit source)
- TRAPS.md: installed (no prior file; hash == kit source)
