# MediaSage Development Guidelines

Last updated: 2026-05-12 (Roon conversion)

## Project Overview

MediaSage is a self-hosted web application that generates Roon music playlists using LLMs with library awareness. It uses a filter-first approach to ensure 100% of suggested tracks are playable. It connects to Roon as an Extension via the Python `roonapi` package and uses the Browse API (`browse_browse`/`browse_load`) for all library access.

## Active Technologies

- **Backend**: Python 3.11+, FastAPI, python-roonapi, anthropic SDK, openai SDK, google-genai SDK, pydantic, uvicorn, rapidfuzz, unidecode, httpx
- **Frontend**: Vanilla HTML/CSS/JS (no build step)
- **Config**: YAML + environment variables
- **Database**: SQLite at `data/library_cache.db` (library cache + results history)
- **Deployment**: Docker

## Project Structure

```text
backend/
├── main.py              # FastAPI app, routes, static file serving
├── config.py            # Config loading (YAML + env vars)
├── roon_client.py       # Roon Core connection, library browsing via Browse API, zone/transport management
├── llm_client.py        # Claude/OpenAI/Gemini/Ollama abstraction
├── analyzer.py          # Prompt analysis + seed track dimensions
├── generator.py         # Playlist generation
├── library_cache.py     # SQLite cache for Roon library track metadata
├── recommender.py       # Album recommendation pipeline
├── music_research.py    # MusicBrainz/Wikipedia research client
└── models.py            # Pydantic models

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
- **No auth**: Rely on network security (home LAN, VPN, reverse proxy)
- **Album art proxy**: Backend proxies art from Roon's image URL to avoid exposing the Roon token to the browser
- **Two-model strategy**: Smart model for analysis, cheap model for generation
- **Fuzzy track matching**: Use rapidfuzz (threshold ~60) to match LLM responses to library
- **Live version filtering**: Exclude tracks with "live", "concert", dates in title/album
- **Browse hierarchy**: All Roon library access follows: Root → Library → Albums → tracks per album

## Roon API Limitations

These are NOT bugs — they are Roon Extension API constraints:

- **No user ratings**: `user_rating` is always `None` via Browse API. The min_rating filter in the UI does nothing.
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

## MCP Server

- `mcp_server.py` in de repo root is een MCP server die de MediaSage REST API wrapt als tools voor Claude Desktop
- Het gebruikt `mcp[cli]` (FastMCP) en `httpx` voor async HTTP calls
- De server praat met de MediaSage API op `MEDIASAGE_URL` (default: `http://localhost:5765`)
- Transport: stdio
- Tools: `get_library_stats`, `search_library`, `filter_tracks`, `list_zones`, `play_tracks`, `queue_tracks`, `sync_library`
- De MCP server bevat GEEN eigen LLM logica — Claude Desktop doet het denkwerk
- Bij wijzigingen aan de API endpoints in `main.py`, update ook de corresponderende tool in `mcp_server.py`
- The MCP server runs LOCALLY on the user's machine, not inside Docker
- `pip install "mcp[cli]"` must be done locally, not in the Docker container
- `scripts/install_mcp.py` configures Claude Desktop — it's a one-time local setup per machine
- The MCP server connects to MediaSage via HTTP, so MediaSage must be running (Docker or bare metal)
