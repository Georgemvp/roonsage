# RoonSage Development Guidelines

Last updated: 2026-05-15 (MCP v4.2 — 25 tools, Claude-native curation)

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
│   └── results.py       # Result history endpoints
├── config.py
├── roon_client.py
├── llm_client.py
├── analyzer.py
├── generator.py
├── library_cache.py
├── qobuz_browser.py     # Qobuz search and playback via Roon Browse API
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
- **Time-of-day context**: Day and hour are prepended to generation prompts as subtle mood hints. Dutch day names used for consistency with the UI language.

## Roon API Limitations

These are NOT bugs — they are Roon Extension API constraints:

- **No user ratings**: `user_rating` is always `None` via Browse API. The `min_rating` filter code has been removed since Roon never exposes this data.
- **No play counts**: `view_count` is hardcoded to `0`. The "familiarity" feature classifies everything as "unplayed".
- **No playlist creation**: Roon cannot save playlists via the Extension API. The frontend "Save to Playlist" concept is not available.
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

## MCP Server

`mcp_server.py` in the repo root is an MCP server that wraps the RoonSage REST API as tools for Claude Desktop. It uses `mcp[cli]` (FastMCP) and `httpx` for async HTTP calls. The server connects to the RoonSage API at `ROONSAGE_URL` (default: `http://localhost:5765`). Transport: stdio.

The MCP server contains NO own LLM logic — Claude Desktop does the thinking. When changing API endpoints in `main.py`, update the corresponding tool in `mcp_server.py` too.

The MCP server runs LOCALLY on the user's machine, not inside Docker. `pip install "mcp[cli]"` must be done locally. `scripts/install_mcp.py` configures Claude Desktop — one-time setup per machine.

### Full Tool List (24 tools)

| Tool | Backend endpoint | Purpose |
|------|-----------------|---------|
| `get_library_stats` | `GET /api/library/stats/cached` | Genre/decade/total stats from cache |
| `get_library_status` | `GET /api/library/status` | Cache freshness, needs_resync flag |
| `search_library` | `GET /api/library/search` | Search by track/artist/album name |
| `search_qobuz` | `POST /api/roon/qobuz-search` | Search Qobuz catalog via Roon |
| `filter_tracks` | `POST /api/library/filter` | Filter by genre, decade, live exclusion |
| `get_artist_albums` | `GET /api/library/artist-albums` | All albums by artist from SQLite cache |
| `sync_library` | `POST /api/library/sync` | Trigger background library sync |
| `generate_playlist` | `POST /api/generate/stream` (SSE) | AI playlist from natural language prompt; `source_mode` = library/hybrid/qobuz; `qobuz_percentage` for hybrid |
| `seed_track_playlist` | `POST /api/generate/stream` (SSE) | "More like this" playlist from seed track; `source_mode` = library/hybrid/qobuz; `qobuz_percentage` for hybrid |
| `analyze_prompt` | `POST /api/analyze/prompt` | Preview prompt → filter mapping |
| `recommend_album` | `POST /api/recommend/questions` + `generate` | Quick album recommendation; `mode="discovery"` suggests new albums, looked up on Qobuz for playback |
| `recommend_album_interactive` | `POST /api/recommend/questions` + `generate` | 2-step Q&A album recommendation; `mode="discovery"` supports Qobuz playback |
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
| `curate_and_play` | `POST /api/queue` or `/api/queue/append` | Play Claude-curated track selection from filter_tracks compact output |

### Tool Selection Guide (for Claude Desktop)

**Library playlists (primary path — Claude curates natively):**
- **User describes a mood/genre/occasion** → `get_library_stats` → `filter_tracks(output_format="compact")` → curate tracks self → `curate_and_play`
- **User mentions a SPECIFIC SONG** as inspiration → `search_library` → `filter_tracks(output_format="compact")` with matching genre/decade filters → curate tracks self → `curate_and_play`

**Qobuz / new music (requires backend pipeline):**
- **User wants to discover new music via a seed song** → `seed_track_playlist` with source_mode="hybrid" or "qobuz"
- **User wants a playlist mixing owned + new music** → `generate_playlist` with source_mode="hybrid"
- **User wants only new/unknown music** → `generate_playlist` with source_mode="qobuz"

**`generate_playlist` / `seed_track_playlist` as fallback only:**
- source_mode is "hybrid" or "qobuz" (Qobuz integration requires backend)
- Filtered pool >1000 tracks and Claude's context is running tight
- User explicitly asks for the "automatic" or "AI-generated" mode

**Other actions:**
- **User wants a specific album** → `play_album`
- **User wants an album recommendation from their library** → `recommend_album` with mode="library"
- **User wants to discover albums they don't own** → `recommend_album` with mode="discovery" (found albums are played via Qobuz)
- **User wants internet radio** → `play_radio`
- **User wants to control volume** → `volume_control`
- **User moves rooms** → `transfer_zone`
- **User wants to sync multiple rooms** → `zone_grouping`
- **User wants shuffle/repeat** → `transport_control` with action="shuffle"/"repeat"
- **Library search returns nothing** → try `search_qobuz` as fallback

### Claude-Native Playlist Flow

For all library playlist requests, Claude curates the tracks itself instead of delegating to the backend LLM pipeline:

1. **Analyse** — understand mood, genre, tempo, era from the user's request.
2. **`get_library_stats`** — check which genres and decades are available.
3. **`filter_tracks(output_format="compact", genres=[...], decades=[...], max_tracks=500)`** — retrieve a numbered list of filtered tracks + `key_map`.
4. **Curate** — select the best 15–50 tracks using musical knowledge:
   - Artist diversity: max 1 track per artist (2 only when exceptional)
   - Album diversity: max 2 tracks per album
   - Flow: alternate tempo, decades, and styles; start strong, end memorably
   - No clustering: never two tracks from the same artist consecutively
   - Aim for ≥80% unique artists (e.g. 20 unique in a 25-track playlist)
5. **`curate_and_play(track_numbers=[...], key_map={...}, zone_id="...")`** — translate numbers to item_keys and start playback.
6. **Present** — title, numbered tracklist with artist – title, brief note on why the tracks fit.

This flow is faster (no backend LLM calls), more transparent, and lets Claude apply its own musical judgment.

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
