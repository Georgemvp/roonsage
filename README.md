# RoonSage

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/downloads/)

AI-powered playlist generation and album recommendations for Roon — using only music you actually own.

![RoonSage playlist view](docs/images/screenshot-playlist.png)

RoonSage is a self-hosted web app that connects to your Roon Core as an Extension. It syncs your library to a local SQLite cache, then sends filtered track lists to an LLM of your choice. Every track it suggests already exists in your library and plays immediately. It also exposes a full MCP server so Claude Desktop can control Roon directly through conversation.

---

## Claude Desktop Integration

This is what makes RoonSage different from every other Roon add-on: a full MCP server that gives Claude Desktop 25 tools to search your library, curate and play playlists, recommend albums, and control every aspect of Roon playback — all through natural language.

You use your existing Claude Pro subscription. No separate API key, no per-token cost.

**Claude Desktop curates natively.** For library playlist requests Claude does the work itself — it checks which genres and decades are in your library, fetches a filtered track list, and picks the best tracks using its own musical judgment. No backend LLM call, no wait. Qobuz discovery and large-library generation still use the backend pipeline when needed.

```
"Make a playlist of mellow 90s electronic, nothing too aggressive, play it in the living room."
"Show me all Nick Cave albums I own."
"More like what's playing right now, but darker."
"Recommend me a jazz album I haven't listened to in a while."
"Turn shuffle on and set volume to 45%."
"Group the kitchen and living room zones."
```

### Setup

The MCP server runs locally on your Mac/PC — not inside Docker. RoonSage must already be running (Docker or bare metal) before Claude Desktop can connect to it.

```bash
# 1. Install the MCP dependency (once per machine)
pip3 install "mcp[cli]"

# 2. Auto-configure Claude Desktop
python3 scripts/install_mcp.py

# 3. Restart Claude Desktop
```

If RoonSage runs at a non-default address, set `ROONSAGE_URL` before starting Claude Desktop (default: `http://localhost:5765`).

**Manual config** — add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `~/.config/claude/claude_desktop_config.json` (Linux):

```json
{
  "mcpServers": {
    "roonsage": {
      "command": "python",
      "args": ["/full/path/to/roonsage/mcp_server.py"]
    }
  }
}
```

### Model Selection

The Claude model you pick in the conversation dropdown affects quality — all are included in Claude Pro.

| Model | Best for |
|-------|----------|
| **Claude Sonnet 4.6** | Daily use — fast, accurate, great value |
| **Claude Opus 4.6** | Abstract prompts, multi-turn refinement, deep discovery |
| **Claude Haiku 4.5** | Quick, simple requests |

Start with Sonnet. Switch to Opus when you want Claude to dig into your library for overlooked albums or handle abstract mood prompts like "something that feels like driving at night in the rain."

### Available Tools (25)

**Library**

| Tool | What it does |
|------|-------------|
| `get_library_stats` | Genre, decade, and total track counts from the cache |
| `get_library_status` | Cache freshness; surfaces `needs_resync` flag |
| `search_library` | Search by track, artist, or album name |
| `search_qobuz` | Search the Qobuz catalog via Roon |
| `filter_tracks` | Filter by genre, decade, live exclusion. Use `output_format="compact"` for a numbered token-efficient list + `key_map` (Claude-native curation). Use `"json"` for full metadata. |
| `get_artist_albums` | All albums by an artist from the SQLite cache |
| `sync_library` | Trigger a background library sync from Roon |

**Playlist Curation & Generation**

| Tool | What it does |
|------|-------------|
| `curate_and_play` | Play a track selection Claude picked from `filter_tracks` compact output — translates track numbers + `key_map` to Roon item_keys and starts playback |
| `generate_playlist` | Natural language → playlist via backend pipeline; supports library, hybrid, and Qobuz source modes. Fallback when context is large or Qobuz is needed. |
| `seed_track_playlist` | "More like this" — playlist from a specific seed track via backend pipeline |
| `analyze_prompt` | Preview how a prompt maps to genre/decade filters |
| `recommend_album` | Quick AI album recommendation (library or discovery mode) |
| `recommend_album_interactive` | 2-step Q&A for highly personalized picks |

**Playback**

| Tool | What it does |
|------|-------------|
| `play_album` | Search and play an album in one step |
| `play_radio` | Play an internet radio station by name |
| `browse_playlists` | List or play any Roon playlist |
| `list_zones` | List active Roon zones |
| `get_now_playing` | Current playback state per zone |
| `play_tracks` | Send tracks to a zone (replaces queue) |
| `queue_tracks` | Append tracks to a zone queue |

**Transport & Zone Control**

| Tool | What it does |
|------|-------------|
| `transport_control` | Play, pause, stop, next, previous, shuffle, repeat, seek |
| `volume_control` | Set, adjust, mute, or get volume by zone name |
| `transfer_zone` | Move playback from one zone to another |
| `zone_grouping` | Group or ungroup zones for synchronized playback |
| `get_result_history` | Previously generated playlists and recommendations |

---

## Quick Start

```bash
docker run -d \
  --name roonsage \
  -p 5765:5765 \
  -v roonsage-data:/app/data \
  --restart unless-stopped \
  -e ROON_HOST=192.168.1.x \
  -e GEMINI_API_KEY=your-key \
  ghcr.io/Georgemvp/roonsage:latest
```

Open **http://localhost:5765** — a setup wizard walks you through connecting to Roon, choosing an AI provider, and syncing your library.

Then **authorize in Roon**: Settings → Extensions → find **RoonSage** → Enable.

> **Free option:** Google Gemini has a free API tier that covers typical personal use. No credit card required. See [`docs/gemini-free-credit-guide.md`](docs/gemini-free-credit-guide.md).

---

## Web UI

The web interface covers everything without Claude Desktop.

![Home screen](docs/images/screenshot-home.png)

**Playlist from Prompt** — describe a vibe in natural language. RoonSage analyzes your prompt, maps it to genre/decade filters, narrows your library, sends the filtered tracks to the LLM, and returns a playable playlist. Works with libraries of 50,000+ tracks.

**Playlist from Seed** — pick a track you love, choose musical dimensions (mood, era, instrumentation, production style), and get a playlist that explores those qualities.

**Refine & Iterate** — use the Refine button on any result to adjust without starting over. "Darker", "more 80s", "less jazz" — the LLM sees the original prompt and your notes.

**Album Recommendations** — describe a moment or mood, answer two quick questions, get a single album recommendation with an editorial pitch. Library mode recommends albums you own; Discovery mode surfaces albums you don't have yet.

**Qobuz Integration** — three source modes: My Library only, Mix (library + Qobuz discoveries), and Qobuz Discovery (new music only). Detected automatically if Qobuz is configured in Roon.

**Smart Filtering** — filter by genre, decade, and live version exclusion before the LLM sees anything. Real-time track counts show exactly how your choices narrow the pool. Estimated token cost displays before you generate.

**Time-Aware Context** — the current day and hour are included in generation prompts as subtle mood hints. Friday evening picks naturally differ from Tuesday morning.

![Album recommendation](docs/images/screenshot-album.png)

---

## Installation

### Docker Compose

```bash
mkdir roonsage && cd roonsage
curl -O https://raw.githubusercontent.com/Georgemvp/roonsage/main/docker-compose.yml
# edit docker-compose.yml to set ROON_HOST and an API key
docker compose up -d
```

### NAS Platforms

<details>
<summary><strong>Synology (Container Manager)</strong></summary>

**GUI:** Container Manager → Registry → search `ghcr.io/Georgemvp/roonsage` → Download `latest` → Create container → Port 5765:5765 → add `ROON_HOST` and API key.

**Docker Compose:**
```bash
mkdir -p /volume1/docker/roonsage && cd /volume1/docker/roonsage
curl -O https://raw.githubusercontent.com/Georgemvp/roonsage/main/docker-compose.yml
nano docker-compose.yml  # set ROON_HOST and API key
```
Then Container Manager → Project → Create, point to `/volume1/docker/roonsage`.

ARM-based Synology units without Docker support: use [Bare Metal](#bare-metal) below.
</details>

<details>
<summary><strong>Unraid</strong></summary>

Docker → Add Container → Repository: `ghcr.io/Georgemvp/roonsage:latest` → Port 5765:5765 → add `ROON_HOST` and API key.
</details>

<details>
<summary><strong>TrueNAS SCALE</strong></summary>

Apps → Discover Apps → Custom App → Image `ghcr.io/Georgemvp/roonsage`, tag `latest` → Port 5765 → add environment variables.
</details>

<details>
<summary><strong>Portainer</strong></summary>

Stacks → Add Stack:
```yaml
services:
  roonsage:
    image: ghcr.io/Georgemvp/roonsage:latest
    ports:
      - "5765:5765"
    environment:
      - ROON_HOST=192.168.1.x
      - ROON_PORT=9330
      - GEMINI_API_KEY=your-key
    volumes:
      - ./data:/app/data
    restart: unless-stopped
```
</details>

### Bare Metal

```bash
git clone https://github.com/Georgemvp/roonsage.git
cd roonsage
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
export ROON_HOST=192.168.1.x ROON_PORT=9330 GEMINI_API_KEY=your-key
uvicorn backend.main:app --host 0.0.0.0 --port 5765
```

<details>
<summary><strong>systemd service</strong></summary>

```ini
# /etc/systemd/system/roonsage.service
[Unit]
Description=RoonSage
After=network.target

[Service]
Type=simple
User=your-user
WorkingDirectory=/path/to/roonsage
EnvironmentFile=/path/to/roonsage/.env
ExecStart=/path/to/roonsage/venv/bin/uvicorn backend.main:app --host 0.0.0.0 --port 5765
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable roonsage && sudo systemctl start roonsage
```
</details>

---

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ROON_HOST` | Yes | — | IP or hostname of your Roon Core |
| `ROON_PORT` | No | `9330` | Roon Core port |
| `ROON_CORE_ID` | No | auto | Saved after first authorization |
| `ROON_TOKEN` | No | auto | Saved after first authorization |
| `GEMINI_API_KEY` | One of three | — | Google Gemini |
| `ANTHROPIC_API_KEY` | One of three | — | Anthropic Claude |
| `OPENAI_API_KEY` | One of three | — | OpenAI GPT |
| `LLM_PROVIDER` | No | auto-detect | Force: `gemini`, `anthropic`, `openai`, `ollama`, `custom` |
| `OLLAMA_URL` | No | `http://localhost:11434` | Ollama server URL |
| `CUSTOM_LLM_URL` | No | — | OpenAI-compatible API base URL |
| `CUSTOM_CONTEXT_WINDOW` | No | `32768` | Context window for custom provider |
| `ROONSAGE_PASSWORD` | No | — | Enable HTTP Basic Auth on all endpoints |
| `ROONSAGE_URL` | No | `http://localhost:5765` | MCP server → RoonSage address |

Settings can also be configured through the web UI (Settings page). UI-saved settings go to `data/config.user.yaml`. Environment variables always take priority.

### config.yaml

```yaml
roon:
  host: "192.168.1.x"
  port: 9330

llm:
  provider: "gemini"
  model_analysis: "gemini-2.5-flash"
  model_generation: "gemini-2.5-flash"
  smart_generation: false  # true = use analysis model for both (higher quality, ~3–5× cost)

defaults:
  track_count: 25
```

### Model Selection

RoonSage uses a two-model strategy by default — a smarter model to interpret prompts and a cheaper one to select tracks from the filtered list.

| Role | Anthropic | OpenAI | Gemini |
|------|-----------|--------|--------|
| Analysis | `claude-sonnet-4-5` | `gpt-4.1` | `gemini-2.5-flash` |
| Generation | `claude-haiku-4-5` | `gpt-4.1-mini` | `gemini-2.5-flash` |
| Max tracks to AI | ~3,500 | ~2,300 | **~18,000** |

Gemini's 1M context window allows sending far more tracks to the model, which improves variety for large libraries.

### Local LLM (Experimental)

<details>
<summary><strong>Ollama</strong></summary>

```bash
ollama pull llama3:8b
```

```bash
LLM_PROVIDER=ollama
OLLAMA_URL=http://localhost:11434
```

Select your model in Settings — context window is auto-detected. Models with 8K+ context work best (`llama3:8b`, `qwen3:8b`, `mistral`).
</details>

<details>
<summary><strong>Custom OpenAI-compatible API</strong></summary>

For LM Studio, text-generation-webui, vLLM, or similar:

```bash
LLM_PROVIDER=custom
CUSTOM_LLM_URL=http://localhost:5000/v1
CUSTOM_CONTEXT_WINDOW=32768
```

Configure model name and API key (if required) in Settings.
</details>

---

## How It Works

RoonSage uses a filter-first architecture designed for large libraries. The LLM never sees your entire library — only a filtered, manageable slice of it.

There are two playlist paths depending on how you use RoonSage:

### Path A — Claude Desktop (native curation, fast)

Claude itself curates the playlist using its own musical knowledge. No backend LLM call.

```
┌─────────────────────────────────────────────────────────────────┐
│  1. ANALYSE (Claude)                                             │
│     Claude interprets your prompt — mood, genre, era, tempo      │
├─────────────────────────────────────────────────────────────────┤
│  2. STATS                                                        │
│     get_library_stats → Claude sees which genres/decades exist   │
├─────────────────────────────────────────────────────────────────┤
│  3. FILTER                                                       │
│     filter_tracks(compact) → numbered list of up to 500 tracks   │
│     + key_map to translate numbers back to Roon item_keys        │
├─────────────────────────────────────────────────────────────────┤
│  4. CURATE (Claude)                                              │
│     Claude picks the best 15–50 tracks using musical judgment    │
│     Artist diversity, flow, no clustering — all done by Claude   │
├─────────────────────────────────────────────────────────────────┤
│  5. PLAY                                                         │
│     curate_and_play → item_keys sent to Roon zone                │
│     Immediate playback in any Roon client                        │
└─────────────────────────────────────────────────────────────────┘
```

### Path B — Web UI / Qobuz / large libraries (backend pipeline)

Used by the web interface and by Claude Desktop when Qobuz is involved or the filtered pool is very large.

```
┌─────────────────────────────────────────────────────────────────┐
│  1. ANALYZE                                                      │
│     LLM interprets your prompt → suggests genre/decade filters   │
├─────────────────────────────────────────────────────────────────┤
│  2. FILTER                                                       │
│     Library narrowed to matching tracks via SQLite               │
│     "90s Alternative" → 2,000 tracks                             │
├─────────────────────────────────────────────────────────────────┤
│  3. SAMPLE                                                       │
│     If too large for context window, randomly sample             │
│     Fits within model's token budget                             │
├─────────────────────────────────────────────────────────────────┤
│  4. GENERATE                                                     │
│     Filtered list + prompt sent to LLM                           │
│     LLM selects best matches by track number                     │
├─────────────────────────────────────────────────────────────────┤
│  5. MATCH                                                        │
│     Track number lookup → O(1) lookup in SQLite cache            │
│     Falls back to fuzzy matching (rapidfuzz) if needed           │
├─────────────────────────────────────────────────────────────────┤
│  6. PLAY                                                         │
│     Tracks sent to Roon zone via Browse API                      │
│     Immediate playback in any Roon client                        │
└─────────────────────────────────────────────────────────────────┘
```

Library data is synced once to SQLite via the Roon Browse API (`browse_browse` / `browse_load`). All subsequent queries read from the local cache — no Roon API calls needed during generation.

---

## Security

RoonSage is designed for home network use. Without `ROONSAGE_PASSWORD`, anyone on your network can access the web UI.

`ROONSAGE_PASSWORD` enables HTTP Basic Auth on all endpoints. Health check (`/api/health`) and the art proxy remain exempt so Docker health checks and album art continue to work without credentials.

LLM-powered endpoints are rate-limited to 30 requests per hour per IP. API keys are stored in `data/config.user.yaml` (permissions 600) and are never exposed through the API.

---

## Development

```bash
git clone https://github.com/Georgemvp/roonsage.git
cd roonsage
python -m venv venv && source venv/bin/activate
pip install -r requirements.txt
export ROON_HOST=192.168.1.x ROON_PORT=9330 GEMINI_API_KEY=your-key
uvicorn backend.main:app --reload --port 5765
```

```bash
pytest tests/ -v   # run tests
ruff check .       # lint
```

**Stack:** Python 3.11+, FastAPI, python-roonapi, anthropic / openai / google-genai SDKs, rapidfuzz, SQLite, vanilla HTML/CSS/JS.

---

## API Reference

Interactive docs at `/docs` when the server is running.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/health` | GET | Health check |
| `/api/config` | GET/POST | Get or update configuration |
| `/api/setup/status` | GET | Onboarding checklist state |
| `/api/setup/validate-roon` | POST | Validate Roon Core connection |
| `/api/setup/validate-ai` | POST | Validate AI provider credentials |
| `/api/library/stats/cached` | GET | Genre/decade/total counts from SQLite |
| `/api/library/status` | GET | Cache state, track count, needs_resync |
| `/api/library/sync` | POST | Trigger background library sync |
| `/api/library/search` | GET | Search library by track/artist/album |
| `/api/library/artist-albums` | GET | All albums by artist from cache |
| `/api/library/filter` | POST | Filter by genre/decade/live exclusion |
| `/api/analyze/prompt` | POST | Analyze prompt → filter mapping |
| `/api/generate/stream` | POST | Stream playlist generation (SSE) |
| `/api/roon/zones` | GET | List active Roon zones |
| `/api/roon/transport` | POST | play/pause/stop/next/previous/shuffle/repeat/seek |
| `/api/roon/volume` | POST | Set/adjust/mute/get volume |
| `/api/roon/transfer` | POST | Transfer playback between zones |
| `/api/roon/group` | POST | Group/ungroup zones |
| `/api/roon/radio` | POST | Play internet radio station |
| `/api/roon/playlists` | POST | List/play Roon playlists |
| `/api/roon/qobuz-search` | POST | Search Qobuz catalog via Roon |
| `/api/queue` | POST | Send tracks to a Roon zone |
| `/api/queue/append` | POST | Append tracks to a zone queue |
| `/api/recommend/questions` | POST | Generate clarifying questions |
| `/api/recommend/generate` | POST | Generate album recommendations |
| `/api/results` | GET | List result history |
| `/api/art/{item_key}` | GET | Proxy album art from Roon |

---

## Credits

RoonSage is based on [MediaSage](https://github.com/ecwilsonaz/mediasage) by Eric Wilson, originally built for Plex. RoonSage has been independently developed for Roon with significant new functionality including MCP integration, Qobuz support, zone control, time-aware context, and a full library cache layer.

---

## License

MIT
