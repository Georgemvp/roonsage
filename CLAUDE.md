# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RoonSage is a self-hosted FastAPI web app + MCP server that connects to a Roon Core as an Extension, mirrors the library into a local SQLite cache, and exposes ~67 tools so Claude Desktop can curate playlists, discover music, monitor releases, automate workflows, analyse audio features, build DJ sets, and control Roon through natural language. The constitution principle is **library-first**: every suggested track must exist either in the user's Roon library or on Qobuz — nothing is hallucinated.

Current version: **v12.0** (see `pyproject.toml`, `backend/version.py` auto-detects via `git describe`).

## Commands

```bash
# Install
pip install -r requirements.txt -r requirements-dev.txt

# Development server (with auto-reload; use --workers 1 to avoid file-handle races on the SQLite cache)
uvicorn backend.main:app --reload --port 5765

# Tests
pytest                              # full suite
pytest tests/test_library_cache.py  # single file
pytest -k "test_filter"             # by name
pytest --cov=backend --cov-report=term-missing --cov-fail-under=40   # what CI runs

# Lint (CI gate — must be clean)
ruff check .

# Docker
docker-compose up -d --build

# MCP server setup (runs LOCALLY on the user's machine, not in Docker)
pip install "mcp[cli]" httpx
python3 scripts/install_mcp.py   # writes claude_desktop_config.json
```

CI (`.github/workflows/test.yml`) runs ruff + pytest with coverage gate ≥40% on Python 3.11 and 3.12.

## Architecture

### Backend layout (`backend/`)

- **`main.py`** — FastAPI app, lifespan, JSON-line logging, optional HTTP Basic Auth middleware, CORS, slowapi rate-limiter wiring, static file serving. Lifespan logic is split out to **`startup.py`** (`init_clients`, `start_background_tasks`, `shutdown`).
- **`routes/`** — every feature has its own router (library, generate, recommend, roon, intelligence, qobuz_playlist, discovery, templates, watchlist, scheduler, automations, enrichment, verify, notifications, results, setup, config_routes, **audio_features**). New endpoints go into the matching router; don't add to `main.py`.
- **`db.py`** — SQLite schema, WAL-mode connections, migration flag, `needs_resync()`. All other cache modules use `get_db_connection()` or the `get_connection()` context manager from here.
- **`library_cache.py`** — orchestrates library sync into SQLite and exposes the read queries used by filters/discovery.
- **`roon_client.py`** — thin re-export. The real implementation is the **mixin pattern** across `roon_connection.py`, `roon_browse.py`, `roon_playback.py`, `roon_search.py`, `roon_intelligence.py`. `RoonClient` inherits all of them. Browse calls are serialized via `_browse_lock` (single-session API constraint, see below).
- **LLM/AI**: `llm_client.py` (multi-provider — anthropic, openai, gemini, ollama, custom), `analyzer.py` (prompt → genre/decade filter), `generator.py` (filtered track list → playlist), `recommender.py` (album recommendations), `music_research.py` (web research helper for albums).
- **Intelligence**: `roon_intelligence.py` (zone monitor + listening history + scrobble dispatch to LB/LF), `taste_profile.py` (combines local + LB + Last.fm into a unified profile with `lb_` / `lf_` prefixed keys), `scrobble_import.py` (one-time backfill from LB/LF).
- **External services**: `listenbrainz_client.py` + `listenbrainz_sync.py`, `lastfm_client.py` + `lastfm_sync.py`, `musicbrainz_client.py`, `acoustid_client.py`, `qobuz_browser.py` (search/playback via Roon), `qobuz_api.py` (direct Qobuz JSON API for playlist save).
- **Workflow subsystems**: `discovery.py` (4 cache-only discovery sections), `watchlist.py` (artist new-release scanner), `scheduler.py` (cron-based playlist regeneration), `automation_engine.py` (trigger-action workflows), `enrichment_worker.py` (background MusicBrainz + Last.fm enrichment — `ENRICHMENT_SKIP_MB=true` switches to Last.fm-only for ~50× speed), `templates.py` (playlist template engine, 63 built-ins with category tabs), `notifications.py` (event bus → Discord/Telegram/webhook).
- **Audio features** (`backend/audio_features/`): `analyzer.py` runs librosa to extract BPM, Camelot key, energy, danceability, valence, instrumentalness, acousticness; `worker.py` is a managed asyncio worker (CONCURRENCY=4, CPU-bound) that drains `audio_features_queue`; `path_resolver.py` walks `MUSIC_LIBRARY_PATH` once to map library tracks → on-disk files (single-flight via thread lock, exposes live progress via `get_scan_progress()`); `dj_generator.py` builds beatmatched, Camelot-compatible DJ sets with configurable BPM curves; `camelot.py` maps musical keys to wheel positions. Routes in `routes/audio_features.py`. Tables: `track_audio_features`, `audio_features_queue`.
- **`filter_sessions.py`** — server-side `session_id` → `key_map` storage so the MCP client doesn't have to hold the full track list in context (saves 10–20k tokens per curation flow).
- **`models.py`** — Pydantic models for all API contracts. Every request/response uses these.

### Frontend (`frontend/`)

Vanilla HTML/CSS/JS, no build step. Single-page app shell `index.html` + `app.js` bootstrap; per-view modules live in `frontend/modules/` (one file per view: playlist, library, discovery, taste, watchlist, automations, scheduler, history, playlists, nowplaying, recommend, templates, setup-wizard, plus shared `api.js`/`state.js`/`router.js`/`ui.js`/`events.js`). Chart.js is loaded via CDN for taste-profile charts. The frontend is a PWA (`manifest.json` + SVG icons).

### Data flow

1. **Sync** — `library_cache.sync_library()` walks Roon Browse hierarchy (Root → Library → Albums → tracks per album) and writes into `tracks` + `track_genres` + `albums` tables.
2. **Query** — `filter_tracks` runs SQL against the local cache (genre IN (...), decade, keywords, optional artist-cap, live-version exclusion); never re-hits Roon.
3. **Curate** — Claude Desktop (or the backend LLM for the web UI) picks track numbers from the numbered list; `curate_and_play` translates them back to Roon item keys via the stored session and calls Play Now.
4. **Background** — listening monitor, LB/LF sync (every 6h), watchlist scan (every 12h), scheduler (60s tick), enrichment worker, audio-features worker, automation engine, periodic DB backup (every 4h) all run as managed asyncio tasks; cancelled cleanly in `shutdown()`.
5. **Self-heal at startup** — `repair_corrupt_indexes()` runs `PRAGMA integrity_check` and rebuilds any corrupt indexes (caused by uvicorn-reload mid-write or container kills). Orphaned `processing` / `analyzing` rows in `enrichment_queue` + `audio_features_queue` are reset to `pending` so workers don't leave items stuck.

### MCP Server (`mcp_server.py`, single file at repo root)

Wraps the RoonSage REST API as **~67 tools** for Claude Desktop using `mcp[cli]` (FastMCP) + httpx over stdio. Contains **no LLM logic** — Claude Desktop does the thinking. When you change a backend endpoint in `routes/`, update the corresponding tool here too. It runs locally on the user's machine (not in Docker); `scripts/install_mcp.py` configures `claude_desktop_config.json`. The system prompt that ships to Claude Desktop is `system_prompt.md` at repo root.

## Key Conventions and Gotchas

### Roon API constraints (NOT bugs — work around them)

- **No user ratings**: `user_rating` is always `None`. Any `min_rating` filter code has been removed.
- **No play counts via Roon**: `view_count` is hardcoded to `0`. Play counts come from the local `listening_history` table (logged by `roon_intelligence._log_listen`) + LB/LF stats.
- **No playlist creation via Roon Extension API**: use `qobuz_api.py` (direct Qobuz JSON API) for playlist save. `app_id` is auto-detected — never hardcode.
- **No direct track queries**: every library access goes through Browse hierarchy (Root → Library → Albums → tracks per album).
- **Metadata parsed from subtitle strings**: `"Artist • Year • Genre"` split on `•`. Fragile — defend against missing fields.
- **ARC zones invisible**: Roon ARC playback is not observable from the Extension API.
- **Single-session Browse API**: concurrent browse calls on the same hierarchy interfere. All Roon Browse sequences must be serialized — `_browse_lock` (and the album/genre variants) on `RoonClient` exists for this reason. Don't bypass it.
- **`hierarchy: "search"` (global search) returns ephemeral item keys**. They expire as soon as another browse/search call mutates session state. For Qobuz global-search fallback, `qobuz_browser.py` generates a synthetic key `qobuz_search::{url-encoded artist}::{url-encoded title}`; `roon_playback.play_tracks` detects this prefix and re-issues a fresh search at playback time. Don't try to "fix" this by storing the real key.

### Playback / queue

- **`play_tracks` tries direct key browse first**, then falls back to search. This was deliberate — for classical/long titles Roon search often returns the wrong track when given a key that's still valid. Don't reorder.
- **`curate_and_play` uses a 180s timeout** (not 30s) because 30+ track queues can take that long. The response includes `playback_started` and a "do not retry" flag for Claude Desktop.
- **`/api/library/filter/curate` always returns a `resolved_tracks` list** (`{number, title, artist}`) sourced from SQLite. The MCP system prompt instructs Claude to render this verbatim — never reconstruct the tracklist from memory.

### Track matching

- Generation LLM is told to return **track numbers** from the numbered list (O(1) lookup). Falls back to rapidfuzz fuzzy match (threshold ~60) if a model ignores the instruction.
- **Live versions**: filter out by keywords (`live`, `concert`, `unplugged`) and date patterns in title/album. `is_live` is a stored column for SQL-native filtering.
- **Genre filtering**: SQL via the `track_genres` junction table, not JSON parsing in Python.

### Filter sessions (server-side key_map)

`filter_tracks(output_format="compact" | "ultra")` returns a `session_id`. The key_map (number → item_key) is stored server-side in `filter_sessions.py`. The client (web UI or Claude Desktop) only sees the numbered list. `curate_and_play` looks the session back up by `session_id`. This saves ~10–20k tokens per flow and is required for `max_tracks` ≥ 500.

### Time-of-day context

Generation/recommendation prompts get the current day + hour prepended (Dutch day names — kept for UI-language consistency). This subtly shapes mood without explicit prompting.

### Auth / rate limiting

- HTTP Basic Auth is enabled only when `ROONSAGE_PASSWORD` is set. Exempt paths: `/api/health`, `/api/art/*`, `/api/external-art` (otherwise Docker health checks and post-login art loading break).
- LLM endpoints are rate-limited (30 req/h/IP) via slowapi.

### LLM models (per provider)

| Provider | Analysis | Generation | Context |
|----------|----------|------------|---------|
| Gemini (default) | `gemini-2.5-flash` | `gemini-2.5-flash-lite` | 1M tokens (~18k tracks) |
| Anthropic | `claude-sonnet-4-5` | `claude-haiku-4-5` | 200K (~3.5k tracks) |
| OpenAI | `gpt-4.1` | `gpt-4.1-mini` | 128K (~2.3k tracks) |
| Ollama | auto-detect via `/api/show` | same | auto-detect |
| Custom | OpenAI-compatible base_url | same | user-set |

`smart_generation: true` uses the analysis model for both stages (higher quality, ~3–5× cost).

## Environment Variables (essentials)

```bash
ROON_HOST=192.168.1.x            # required
ROON_PORT=9330
ROON_CORE_ID=                    # auto-saved after Roon authorization
ROON_TOKEN=                      # auto-saved after Roon authorization
LLM_PROVIDER=gemini              # anthropic | openai | gemini | ollama | custom
ANTHROPIC_API_KEY= / OPENAI_API_KEY= / GEMINI_API_KEY=
OLLAMA_URL=http://localhost:11434
CUSTOM_LLM_URL= / CUSTOM_CONTEXT_WINDOW=
ROONSAGE_PASSWORD=               # enables HTTP Basic Auth
CORS_ORIGINS=http://localhost:5765
# Optional services
QOBUZ_EMAIL= / QOBUZ_PASSWORD=                       # playlist save (app_id auto-detected)
LISTENBRAINZ_TOKEN= / LISTENBRAINZ_USERNAME=
LASTFM_API_KEY= / LASTFM_API_SECRET= / LASTFM_SESSION_KEY= / LASTFM_USERNAME=
ACOUSTID_API_KEY= / ACOUSTID_ENABLED=false / ACOUSTID_AUTO_VERIFY_QOBUZ=false
DISCORD_WEBHOOK_URL= / TELEGRAM_BOT_TOKEN= / TELEGRAM_CHAT_ID= / WEBHOOK_URL=
WATCHLIST_SCAN_INTERVAL_HOURS=12
# Enrichment
ENRICHMENT_SKIP_MB=true          # Last.fm-only mode (~50× faster than MB+LF)
# Audio features
AUDIO_FEATURES_ENABLED=true      # toggles the analyzer worker + DJ-set endpoints
AUDIO_FEATURES_FULL=true         # false = BPM + key only (faster); true = full Spotify-style vector
MUSIC_LIBRARY_PATH=/music        # filesystem root for audio analysis (must be readable)
MUSIC_PATH_MAP_FROM= / MUSIC_PATH_MAP_TO=   # remap Roon-reported paths to container paths
NUMBA_CACHE_DIR=/app/data/.numba_cache   # required for librosa's JIT inside Docker
MPLCONFIGDIR=/app/data/.mpl_cache
APP_VERSION=                     # injected by Docker build; falls back to git describe
```

Config priority: env > `data/config.user.yaml` (UI-saved) > `config.yaml` (file) > defaults. UI writes go to `config.user.yaml` with `chmod 600`.

## Code Style

- **Python**: PEP 8, type hints everywhere, Pydantic models for every API contract. `ruff` config in `pyproject.toml` (line length 100, selected rules `E,F,W,I,UP,B,SIM,TCH`; `E501`, `SIM117` ignored). CI fails on lint errors.
- **JavaScript**: ES6+, no framework, module pattern with a single shared `state` object in `frontend/modules/state.js`.
- **CSS**: BEM-style naming, CSS custom properties for theming (`--color-bg #1a1a1a`, `--color-accent #e5a00d`).
- **Logging**: structured JSON lines via `JSONFormatter` in `main.py`. Use module-level `logger = logging.getLogger(__name__)`; don't replace `except Exception: pass` with bare suppression — log a warning.
- **Background tasks**: register through `_add_task(coro, name)` in `startup.start_background_tasks` so they're cancelled cleanly on shutdown and surface exceptions via the done-callback.

## MCP Tool Selection (for Claude Desktop)

The MCP system prompt (`system_prompt.md`) instructs Claude Desktop to **curate natively** for playlists, seeds, and albums. Native curation is the primary flow; backend LLM tools (`generate_playlist`, `seed_track_playlist`, `recommend_album`) are fallback-only and are mainly used by the web UI.

### Native curation flow (library)

1. Analyse the user request (mood, genre, era).
2. `get_library_stats` → see what's available.
3. `filter_tracks(output_format="compact", genres=[...], decades=[...], max_tracks=500)` → numbered list + `session_id`.
4. Curate 15–50 tracks: ≥80% unique artists, max 2 tracks/album, no consecutive same-artist, alternate tempo/era.
5. (Optional) `validate_playlist(session_id, track_numbers)` to catch duplicates/clustering.
6. `curate_and_play(track_numbers, session_id, zone_id)`.
7. Present the `resolved_tracks` list from the response verbatim.

### Source modes

- **library**: `filter_tracks` → `curate_and_play`
- **hybrid**: `filter_tracks` + multiple `search_qobuz` → mix → `play_tracks` (combined keys)
- **qobuz**: multiple `search_qobuz` → `play_tracks` (Qobuz keys only)

### Common direct actions

- **Specific album** → `play_album`
- **Internet radio** → `play_radio`
- **Volume / transport / shuffle / repeat** → `volume_control` / `transport_control`
- **Move playback between rooms** → `transfer_zone`
- **Group zones** → `zone_grouping`
- **Library search misses** → fall back to `search_qobuz`
- **Save curated playlist to Qobuz** → `save_to_qobuz` (after `curate_and_play` or `play_tracks`)

### Tool categories (~67 total)

Library & search · Discovery · Playlist generation · Claude-native curation · Album recommendations · Roon playback & control · Intelligence & taste · ListenBrainz · Last.fm · Qobuz · Watchlist · Scheduled playlists · Metadata enrichment · Automation · AcoustID verification · **Audio features & DJ sets** (`get_audio_features_status`, `get_track_audio_features`, `filter_tracks_by_audio`, `build_dj_set`).

The full per-tool table is maintained in **README.md** under "Full MCP Tool List".

## When Editing

- **Adding a backend endpoint**: add to the correct `routes/*.py`, add the Pydantic request/response models to `models.py`, expose to MCP by adding a tool in `mcp_server.py`, and update `system_prompt.md` if the tool affects Claude Desktop's flows.
- **Changing the DB schema**: edit `backend/db.py` — `init_schema` handles incremental `ALTER TABLE` migrations and flips `_migration_applied`, which triggers auto-resync in `startup.start_background_tasks`. Tables: `tracks`, `track_genres`, `albums`, `listening_history`, `lb_stats_cache`, `lf_stats_cache`, `track_metadata_ext`, `enrichment_queue`, `track_audio_features`, `audio_features_queue`, `artist_watchlist`, `artist_releases_cache`, `scheduled_playlists`, `automations`, `automation_log`, `scrobble_import_state`, plus the results history.
- **Touching Roon Browse code**: respect `_browse_lock` and the synthetic-key convention for Qobuz global-search results. Test that browse → search → browse sequences don't corrupt session state.
- **Working on the frontend**: changes are picked up live without a rebuild (Docker mounts `frontend/` as a volume); HTML asset URLs are cache-busted with `?v={version}` in `serve_index`.
