# RoonSage Development Guidelines

Last updated: 2026-05-19 (MCP v4.8 — Qobuz global-search fallback)

## Project Overview

RoonSage is a self-hosted web application that generates Roon music playlists using LLMs with library awareness. It uses a filter-first approach to ensure 100% of suggested tracks are playable. It connects to Roon as an Extension via the Python `roonapi` package and uses the Browse API (`browse_browse`/`browse_load`) for all library access.

## Active Technologies

- **Backend**: Python 3.11+, FastAPI, python-roonapi, anthropic SDK, openai SDK, google-genai SDK, pydantic, uvicorn, rapidfuzz, unidecode, httpx
- **Frontend**: Vanilla HTML/CSS/JS (no build step)
- **Config**: YAML + environment variables
- **Database**: SQLite at `data/library_cache.db` (library cache + results history)
- **Deployment**: Docker

## Project Structure

```text
backend/
├── main.py              # FastAPI app, lifespan, router registration, static files
├── dependencies.py      # Shared helpers, auth, rate limiting
├── routes/
│   ├── setup.py         # Setup/onboarding endpoints
│   ├── library.py       # Library cache, sync, search, filter endpoints
│   ├── generate.py      # Playlist generation + analysis endpoints
│   ├── recommend.py     # Album recommendation pipeline endpoints
│   ├── roon.py          # Roon zones, queue, transport control, art proxy endpoints
│   ├── config_routes.py # Config, health, Ollama endpoints
│   ├── results.py       # Result history endpoints
│   └── qobuz_playlist.py # Qobuz playlist save endpoints
├── config.py
├── roon_client.py
├── llm_client.py
├── analyzer.py
├── generator.py
├── library_cache.py
├── qobuz_browser.py     # Qobuz search and playback via Roon Browse API
├── qobuz_api.py         # Direct Qobuz API client for playlist save (independent of Roon)
├── recommender.py
├── music_research.py
└── models.py

frontend/
├── index.html           # Single page app
├── style.css            # Dark theme
└── app.js               # UI logic

tests/
└── test_*.py            # pytest tests
```

## Commands

```bash
# Development
pip install -r requirements.txt
uvicorn backend.main:app --reload --port 5765

# Testing
pytest

# Linting
ruff check .

# Docker
docker-compose up -d
```

## Code Style

- **Python**: PEP 8, type hints, Pydantic models for all API contracts
- **JavaScript**: ES6+, no framework, simple state object
- **CSS**: BEM-style naming, CSS custom properties for theming

## Constitution Principles

1. **Library-First**: All playlist tracks MUST exist in user's Roon library
2. **Simplicity**: No build steps, no frameworks, single container
3. **User Agency**: Users control filters and can remove/regenerate
4. **Cost Transparency**: Display token counts and estimated costs
5. **Dark Theme**: Dark UI (#1a1a1a background), amber accent (#e5a00d)

## Environment Variables

```bash
ROON_HOST=192.168.1.x          # IP address of your Roon Core
ROON_PORT=9330                  # Default Roon Extension port
ROON_CORE_ID=                   # Roon Core unique ID (saved after first auth)
ROON_TOKEN=                     # Roon Extension token (saved after authorization)
LLM_PROVIDER=anthropic          # anthropic, openai, gemini, ollama, or custom
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=...
# For local providers
OLLAMA_URL=http://localhost:11434
CUSTOM_LLM_URL=http://localhost:5000/v1
CUSTOM_CONTEXT_WINDOW=4096
# Qobuz playlist save (optional)
QOBUZ_EMAIL=                # Qobuz account email (for playlist save)
QOBUZ_PASSWORD=             # Qobuz account password (for playlist save)
# app_id is auto-detected — no manual configuration needed
```

## Key Design Decisions

- **Filter-first**: Apply genre/decade filters before sending to LLM (handles 50k+ track libraries)
- **SQLite cache + Browse API**: Library data is synced once into SQLite via `library_cache.sync_library()`; all subsequent queries read from the local cache for instant response. The Roon Browse API is used for the initial sync and for playback.
- **Optional auth**: Password protection via `ROONSAGE_PASSWORD` env var. Rate limiting on LLM endpoints (30/hour/IP).
- **Album art proxy**: Backend proxies art from Roon's image URL to avoid exposing the Roon token to the browser
- **Two-model strategy**: Smart model for analysis, cheap model for generation
- **Track number matching**: LLM returns track numbers from the numbered list for O(1) lookup. Falls back to fuzzy matching (rapidfuzz, threshold ~60) for models that don't follow number instructions.
- **Genre junction table**: `track_genres` table enables SQL-native genre filtering instead of Python-side JSON parsing.
- **Live version filtering**: Exclude tracks with "live", "concert", dates in title/album
- **Browse hierarchy**: All Roon library access follows: Root → Library → Albums → tracks per album
- **Qobuz via Roon Browse API**: No separate Qobuz API key needed. RoonSage navigates Roon's Browse hierarchy (Root → Qobuz → Search) to find and play Qobuz tracks. Detected automatically at startup.
- **Qobuz playlist save via direct API**: Roon's Extension API cannot create playlists. RoonSage connects directly to the Qobuz JSON API (`https://www.qobuz.com/api.json/0.2/`) for playlist creation. The app_id is obtained automatically by trying known working app_ids (from LMS plugin, QobuzDL, streamrip) with fallback to web player extraction. Track resolution uses search + fuzzy matching (rapidfuzz) to translate artist+title to Qobuz track IDs. Rate limited at 150ms between searches.
- **Time-of-day context**: Day and hour are prepended to generation prompts as subtle mood hints. Dutch day names used for consistency with the UI language.

## Roon API Limitations

These are NOT bugs — they are Roon Extension API constraints:

- **No user ratings**: `user_rating` is always `None` via Browse API. The `min_rating` filter code has been removed since Roon never exposes this data.
- **No play counts**: `view_count` is hardcoded to `0`. The "familiarity" feature classifies everything as "unplayed".
- **No playlist creation**: Roon cannot save playlists via the Extension API. RoonSage uses the Qobuz API directly for playlist save (requires `QOBUZ_EMAIL` + `QOBUZ_PASSWORD`; app_id is auto-detected).
- **No direct track queries**: All library access goes through Browse hierarchy (Root → Library → Albums → tracks per album).
- **Metadata parsed from subtitle strings**: Genre, year, and artist are parsed from `"Artist • Year • Genre"` format using `•` separator. This is fragile.
- **ARC zones invisible**: Roon ARC playback is not visible to the Extension API.
- **Single-session Browse API**: Concurrent browse operations on the same hierarchy interfere. All browse sequences are serialized via `_browse_lock`.

## LLM Models

| Task | Anthropic | OpenAI | Gemini |
|------|-----------|--------|--------|
| Analysis | `claude-sonnet-4-5` | `gpt-4.1` | `gemini-2.5-flash` |
| Generation | `claude-haiku-4-5` | `gpt-4.1-mini` | `gemini-2.5-flash` |
| Context Limit | 200K tokens | 128K tokens | **1M tokens** |

Gemini's 1M context allows sending ~18,000 tracks to the AI, vs ~3,500 for Anthropic/OpenAI.

Option: `smart_generation: true` uses analysis model for both (higher quality, ~3-5x cost)

### Local LLM Providers

**Ollama** (`LLM_PROVIDER=ollama`):
- Auto-discovers installed models via `/api/tags`
- Auto-detects context window via `/api/show`
- Uses native `/api/generate` endpoint for completions
- 10-minute timeout for slow hardware
- Zero cost (local inference)

**Custom** (`LLM_PROVIDER=custom`):
- Any OpenAI-compatible endpoint (LM Studio, text-generation-webui, etc.)
- Manual configuration: URL, model name, context window
- Uses openai SDK with custom `base_url`
- Zero cost (local inference)

## Recent Changes

- roon-support: Converted from Plex to Roon Labs Extension API. All library access via Browse API. SQLite cache for fast queries. Playlist creation not available (Roon API limitation).
- Refactored `main.py` into FastAPI routers (`routes/` directory)
- Track matching by number (with fuzzy fallback)
- Genre junction table (`track_genres`) for SQL-native filtering
- Optional password auth (`ROONSAGE_PASSWORD`)
- Rate limiting on LLM endpoints (30 requests/hour/IP)
- Renamed `plex_server_id` → `roon_core_id` in `sync_state`
- MCP server: added `generate_playlist`, `get_now_playing`, `recommend_album` tools
- All backend error messages standardized to English
- MCP server expanded with 8 new tools: `get_library_status`, `get_artist_albums`, `seed_track_playlist`, `analyze_prompt`, `recommend_album_interactive`, `play_album`, `transport_control`, `get_result_history`
- Backend: added `transport_control()` to `roon_client.py` via `roonapi.playback_control()`
- Backend: added `POST /api/roon/transport` endpoint + `TransportControlRequest/Response` models
- Backend: added `get_albums_by_artist()` to `library_cache.py` + `GET /api/library/artist-albums` endpoint
- MCP v3 (2026-05-15): 7 new tools + playlist/generation improvements
- **MCP v4 (2026-05-15):** Qobuz integration, playlist refinement, time-aware context, and code cleanup:
  - Qobuz integration: source mode selection (library/hybrid/qobuz) for playlist generation, Qobuz search via Roon Browse API, discovery album playback via Qobuz
  - Playlist refinement: "Refine" button in web UI for iterative playlist generation using `additional_notes` parameter
  - Time-of-day context: playlist and album recommendation prompts now include day/time for mood-appropriate suggestions
  - MCP server refactored: centralized `_api_call()` helper, persistent httpx client, shared SSE parser — reduced ~400 lines of duplication
  - Removed dead `min_rating` code path (Roon API doesn't expose user ratings)
  - Removed `commit_fix.sh` and `commit_prompt5.sh` from repo tracking
  - New MCP tool: `search_qobuz` for Qobuz catalog search via Roon Browse API
  - `generate_playlist` MCP tool now accepts `source_mode` and `qobuz_percentage` parameters
- **MCP v4.1 (2026-05-15):** Qobuz source mode voor seed_track_playlist:
  - `seed_track_playlist` accepts `source_mode` and `qobuz_percentage` parameters (same as `generate_playlist`)
  - Discovery album Qobuz lookup was already implemented in `recommend.py`; frontend already handles `source="qobuz"` and `playable=False` display
- **MCP v4.2 (2026-05-15):** Claude-native curation for ALL flows (playlists, seeds, albums, Qobuz):
  - `filter_tracks` now has `output_format` parameter: "json" (default) or "compact" (numbered list + key_map, token-efficient, max_tracks auto-raised to 500)
  - New tool `curate_and_play`: translates track numbers from key_map to item_keys and starts playback; handles missing numbers gracefully
  - `system_prompt.md` fully rewritten: 3 native flows (prompt/seed/album) × 3 source modes (library/hybrid/qobuz)
  - `CLAUDE.md` Tool Selection Guide updated: native curation is now primary for all flows; backend LLM tools demoted to fallback
  - Web UI flow unchanged — backend LLM tools (`generate_playlist`, `seed_track_playlist`, `recommend_album`) still used by the web interface
- **MCP v4.3 (2026-05-15):** 5 token-optimalisaties:
  - `filter_tracks` output_format="ultra": minimale "nr. Artist — Title" output (~50% minder tokens dan compact)
  - `filter_tracks` artist_limit parameter voor stratified sampling per artiest
  - `filter_tracks` exclude_keywords parameter voor keyword-based uitsluiting
  - Server-side key_map opslag: session_id in plaats van key_map in context (~10-20K tokens bespaard)
  - `validate_playlist` tool: controleer duplicaten, clustering en overrepresentatie vóór afspelen
- **MCP v4.6 (2026-05-16):** Queue mismatch fix:
  - Fix: `/api/library/filter/curate` now returns `resolved_tracks` list (`{number, title, artist}`) for every queued track, sourced from SQLite — eliminates Claude hallucinating the wrong tracklist
  - Fix: `curate_and_play` MCP tool passes `resolved_tracks` through to Claude's response
  - Fix: `system_prompt.md` instructs Claude to always show `resolved_tracks` from the response, never reconstruct from memory
  - Fix: `play_tracks` now tries direct key browse first (most reliable), falls back to search only on failure — fixes classical track mismatches where Roon search returned unrelated tracks
- **MCP v4.5 (2026-05-16):** Reliability improvements:
  - Fix: curate_and_play uses 180s timeout instead of 30s (prevents false timeout during 30+ track playback)
  - Fix: Classical track search query shortened (primary artist + short title, with fallback to title-only and direct key)
  - Fix: play_tracks checks Roon connection per-track with 30s reconnect wait (prevents silent failures during websocket drops)
  - Fix: curate_and_play response includes `playback_started` flag and explicit "do not retry" note
  - Fix: system_prompt.md includes retry prevention rules (Claude must never re-send after curate_and_play)
- **MCP v4.4 (2026-05-15):** Qobuz playlist save:
  - New module `backend/qobuz_api.py`: direct Qobuz API client with auto-detected app_id (tries known working app_ids from LMS plugin/QobuzDL/streamrip, falls back to web player extraction), email/password login with MD5 fallback, track search, playlist create, playlist addTracks, fuzzy track resolution
  - New endpoint `POST /api/qobuz/playlist/save`: full pipeline — resolve tracks to Qobuz IDs → create playlist → add tracks
  - New endpoint `POST /api/qobuz/validate`: test credentials with live login attempt
  - New endpoint `GET /api/qobuz/save-status`: check if Qobuz save is configured
  - New MCP tool `save_to_qobuz`: save curated playlists to Qobuz from Claude Desktop
  - Frontend: Qobuz settings section (email + password only, app_id auto-detected) with validate button
  - Frontend: "Opslaan in Qobuz" button on playlist results (visible when Qobuz is configured)
  - Config: `QOBUZ_EMAIL`, `QOBUZ_PASSWORD` environment variables (no app_id needed)
- **MCP v4.8 (2026-05-19):** Qobuz search global-search fallback:
  - Fix: `search_qobuz_tracks_sync` in `backend/qobuz_browser.py` no longer returns `[]` when the Qobuz Browse hierarchy has no search entry point (Paths A/B/C all fail). It now falls back to Roon's `hierarchy: "search"` global search, which searches all configured services simultaneously and is present on all Roon versions.
  - `result_items` is initialised to `None` before Path A/B/C; both Path C failure branches populate it via global search; Step 4 only runs when `result_items is None` (i.e. a browse-hierarchy entry was found). No existing paths were changed.
  - `hierarchy: "search"` is independent from `hierarchy: "browse"` — switching does not corrupt browse state; `input` + `pop_all` can be combined in one call.
  - Debug endpoint `GET /api/roon/qobuz-browse-test` now always appends `fallback_global_search` + `global_search_results` steps so the global-search output is visible regardless of which path succeeded.
- **MCP v4.7 (2026-05-18):** recommend_album_interactive parameter fix:
  - `recommend_album_interactive` now accepts `session_id: Optional[str] = None` as a proper parameter
  - Removed fragile `"SESSION:<id>|<prompt>"` prompt-prefix encoding (broke when prompt contained `|`)
  - Step 2 passes `session_id` directly; step 1 response instructions updated accordingly
  - `filter_tracks` helpers extracted: `_build_key_map`, `_store_session`, `_format_compact_line`, `_format_ultra_line` — eliminates duplication between compact/ultra branches; `except Exception: pass` replaced with `logger.warning()`

## MCP Server

`mcp_server.py` in the repo root is an MCP server that wraps the RoonSage REST API as tools for Claude Desktop. It uses `mcp[cli]` (FastMCP) and `httpx` for async HTTP calls. The server connects to the RoonSage API at `ROONSAGE_URL` (default: `http://localhost:5765`). Transport: stdio.

The MCP server contains NO own LLM logic — Claude Desktop does the thinking. When changing API endpoints in `main.py`, update the corresponding tool in `mcp_server.py` too.

The MCP server runs LOCALLY on the user's machine, not inside Docker. `pip install "mcp[cli]"` must be done locally. `scripts/install_mcp.py` configures Claude Desktop — one-time setup per machine.

### Full Tool List (27 tools)

| Tool | Backend endpoint | Purpose |
|------|-----------------|---------|
| `get_library_stats` | `GET /api/library/stats/cached` | Genre/decade/total stats from cache |
| `get_library_status` | `GET /api/library/status` | Cache freshness, needs_resync flag |
| `search_library` | `GET /api/library/search` | Search by track/artist/album name |
| `search_qobuz` | `POST /api/roon/qobuz-search` | Search Qobuz catalog via Roon |
| `filter_tracks` | `POST /api/library/filter` | Filter by genre, decade, live exclusion; `output_format` = json/compact/ultra; supports `artist_limit` and `exclude_keywords` |
| `get_artist_albums` | `GET /api/library/artist-albums` | All albums by artist from SQLite cache |
| `sync_library` | `POST /api/library/sync` | Trigger background library sync |
| `generate_playlist` | `POST /api/generate/stream` (SSE) | AI playlist from natural language prompt; `source_mode` = library/hybrid/qobuz; `qobuz_percentage` for hybrid |
| `seed_track_playlist` | `POST /api/generate/stream` (SSE) | "More like this" playlist from seed track; `source_mode` = library/hybrid/qobuz; `qobuz_percentage` for hybrid |
| `analyze_prompt` | `POST /api/analyze/prompt` | Preview prompt → filter mapping |
| `recommend_album` | `POST /api/recommend/questions` + `generate` | Quick album recommendation; `mode="discovery"` suggests new albums, looked up on Qobuz for playback |
| `recommend_album_interactive` | `POST /api/recommend/questions` + `generate` | 2-step Q&A album recommendation; step 2 passes `session_id` from step 1 as a separate parameter; `mode="discovery"` supports Qobuz playback |
| `play_album` | `GET /api/library/search` + `POST /api/queue` | Search + play album in one step |
| `list_zones` | `GET /api/roon/zones` | List active Roon zones |
| `get_now_playing` | `GET /api/roon/zones` | Current playback state per zone |
| `play_tracks` | `POST /api/queue` | Send tracks to zone (replaces queue) |
| `queue_tracks` | `POST /api/queue/append` | Append tracks to zone queue |
| `transport_control` | `POST /api/roon/transport` | play/pause/stop/next/previous/shuffle/repeat/seek |
| `get_result_history` | `GET /api/results` | Previously generated playlists/recs |
| `volume_control` | `POST /api/roon/volume` | Set/adjust/get/mute volume by zone name |
| `transfer_zone` | `POST /api/roon/transfer` | Transfer playback between zones |
| `zone_grouping` | `POST /api/roon/group` | Group/ungroup/list zone groups |
| `play_radio` | `POST /api/roon/radio` | Play internet radio station (fuzzy match) |
| `browse_playlists` | `POST /api/roon/playlists` | List/play Roon playlists (all playlists, not just RoonSage) |
| `curate_and_play` | `POST /api/library/filter/curate` | Play Claude-curated track selection using session_id from filter_tracks; translates track numbers to item_keys server-side |
| `validate_playlist` | `POST /api/library/filter/validate` | Check curated selection for duplicates, clustering, overrepresentation |
| `save_to_qobuz` | `POST /api/qobuz/playlist/save` | Save curated playlist to user's Qobuz account |

### Tool Selection Guide (for Claude Desktop)

**Playlist curatie (primaire flow — Claude curates natively):**
- **Mood/genre/occasion → library** → `get_library_stats` → `filter_tracks(output_format="compact")` → curate zelf → valideer → `curate_and_play`
- **Na selectie: validatie** → `validate_playlist(session_id, track_numbers)` → fix waarschuwingen → `curate_and_play`
- **Mood/genre/occasion → hybrid** → `filter_tracks(output_format="compact")` + `search_qobuz` → meng en curate → `play_tracks`
- **Mood/genre/occasion → qobuz only** → meerdere `search_qobuz` calls → curate → `play_tracks`

**Seed playlist (primaire flow — Claude curates natively):**
- **"Meer zoals X" → library** → `search_library` → `filter_tracks(output_format="compact")` → curate → `curate_and_play`
- **"Meer zoals X" → hybrid** → `search_library` (analyse) → `filter_tracks(output_format="compact")` + `search_qobuz` → meng → `play_tracks`
- **"Meer zoals X" → qobuz only** → `search_library` (analyse) → meerdere `search_qobuz` calls → curate → `play_tracks`

**Album aanbeveling (primaire flow — Claude curates natively):**
- **Album uit library** → `filter_tracks(output_format="compact")` of `get_artist_albums` → kies album → editorial pitch → `play_album`
- **Album ontdekken (nieuw)** → eigen muziekkennis → `search_qobuz` per album → editorial pitch → `play_tracks` met Qobuz item_keys

**Overige acties (ongewijzigd):**
- **Specifiek album afspelen** → `play_album`
- **Internet radio** → `play_radio`
- **Volume** → `volume_control`
- **Verplaatsen naar andere kamer** → `transfer_zone`
- **Zones groeperen** → `zone_grouping`
- **Shuffle/repeat** → `transport_control` with action="shuffle"/"repeat"
- **Library search levert niets op** → `search_qobuz` als fallback
- **Playlist opslaan in Qobuz** → `save_to_qobuz` (na curate_and_play of play_tracks)

**Fallback tools (alleen bij problemen of op expliciet verzoek):**
- `generate_playlist` — backend-LLM generatie (bij context-overflow of op verzoek)
- `seed_track_playlist` — backend seed-generatie (fallback)
- `recommend_album` / `recommend_album_interactive` — backend aanbeveling (fallback)

### Claude-Native Curatie Flow

Claude Desktop doet zelf het curatie-werk voor playlists, seed-playlists en albumaanbevelingen.
De backend levert alleen data (`filter_tracks`, `search_library`, `search_qobuz`) en connectiviteit
(`play_tracks`, `queue_tracks`). Geen backend LLM-calls nodig voor de MCP-flow.

**Voordelen:**
- Betere kwaliteit bij abstracte/mood-based verzoeken (Claude > goedkope generation models)
- Multi-turn verfijning ("iets minder jazz, meer post-rock") zonder nieuwe generatie
- Geen aparte API-key of per-token kosten (Claude Pro dekt alles)
- Qobuz-integratie via `search_qobuz` voor hybrid/discovery modes

De backend tools (`generate_playlist`, `seed_track_playlist`, `recommend_album`) blijven beschikbaar als fallback en worden nog steeds gebruikt door de Web UI.

**Stap-voor-stap voor library playlist:**

1. **Analyse** — understand mood, genre, tempo, era from the user's request.
2. **`get_library_stats`** — check which genres and decades are available.
3. **`filter_tracks(output_format="compact", genres=[...], decades=[...], max_tracks=500)`** — retrieve a numbered list of filtered tracks; returns a `session_id` (key_map stored server-side, ~10-20K tokens saved).
4. **Curate** — select the best 15–50 tracks using musical knowledge:
   - Artist diversity: max 1 track per artist (2 only when exceptional)
   - Album diversity: max 2 tracks per album
   - Flow: alternate tempo, decades, and styles; start strong, end memorably
   - No clustering: never two tracks from the same artist consecutively
   - Aim for ≥80% unique artists (e.g. 20 unique in a 25-track playlist)
5. **`curate_and_play(track_numbers=[...], session_id="...", zone_id="...")`** — server translates numbers to item_keys via stored key_map and starts playback.
6. **Present** — title, numbered tracklist with artist – title, brief note on why the tracks fit.

**Voor hybrid playlists:** combineer stap 1–4 met `search_qobuz` calls voor Qobuz-tracks; meng gelijkmatig door de library-selectie; gebruik `play_tracks` met gecombineerde item_keys.

**Voor discovery albums:** gebruik eigen muziekkennis → `search_qobuz` per album → `play_tracks` met Qobuz item_keys.

### Playlist Generation Output Format (v2)

Both `generate_playlist` and `seed_track_playlist` now return:
- `track_count` — exact number of tracks matching the request
- `tracks[].year` — year from SQLite cache
- `tracks[].album` — album name (falls back to "Unknown Album")
- `genre_breakdown` — e.g. `"Jazz: 12 | Blues: 8 | Pop/Rock: 5"`
- `note_live` — confirms live track exclusion status
- `extra_item_keys` — if AI generated more than requested, surplus keys for `queue_tracks`
- `live_excluded` — boolean flag

Qobuz tracks have `source="qobuz"` on the Track model; library tracks have `source="library"`.

### Album Recommendation Output (discovery mode)

In `mode="discovery"`, recommended albums are searched on Qobuz after selection:
- `playable=True` + `source="qobuz"` — album found on Qobuz; `track_rating_keys` contains Qobuz item keys usable with `play_tracks` / `queue_tracks`
- `playable=False` — album not found on Qobuz; display only, cannot be played
