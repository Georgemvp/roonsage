# RoonSage

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/downloads/)

AI-powered playlist curation and album recommendations for Roon — using music you own, music on Qobuz, or both.

![RoonSage playlist view](docs/images/screenshot-playlist.png)

RoonSage is a self-hosted web app that connects to your Roon Core as an Extension. It syncs your library to a local SQLite cache and exposes a full MCP server so Claude Desktop can search your library, curate playlists, recommend albums, and control every aspect of Roon playback — all through natural conversation.

---

## Claude Desktop Integration

This is the primary way to use RoonSage. A full MCP server gives Claude Desktop **42 tools** to interact with your library and Roon — and Claude does all the curation work itself, using its own musical judgment. No separate API key, no per-token costs — just your existing Claude Pro subscription.

```
"Make a playlist for a late Friday evening, something melancholic but not depressing."
"More like what's playing now, but a bit more energetic."
"Find a jazz album I don't know yet and play it."
"Give me everything by Nick Cave that I own."
"Turn on shuffle and set volume to 40%."
"Group the living room and kitchen."
"Save this playlist to Qobuz so I can listen on the go in Arc."
"What's new on Qobuz this week in jazz?"
"What does my taste profile look like right now?"
"Save this playlist as 'Sunday Morning Jazz' so I can replay it."
"I hated that last one — note that in my profile."

(Dutch / "Maak een playlist voor een late vrijdagavond, iets melancholisch maar niet depressief.")
(Dutch / "Meer zoals wat er nu speelt, maar wat energieker.")
(Dutch / "Sla deze playlist op als 'Zondagochtend jazz'.")
```

### How Claude curates

Claude handles **all** playlist, seed, and recommendation flows itself. The backend provides data and Roon connectivity; Claude does the thinking.

**Three flows:**

| Flow | What the user says | How Claude handles it |
|------|--------------------|-----------------------|
| **Prompt playlist** | "Make a playlist of mellow 90s electronic" | `get_library_stats` → `filter_tracks(compact)` → curate → `curate_and_play` |
| **Seed playlist** | "More like Portishead – Glory Box" | `search_library` → analysis → `filter_tracks(compact)` → curate → `curate_and_play` |
| **Album recommendation** | "Recommend me an album for Sunday morning" | `filter_tracks` or `get_artist_albums` → pick album → editorial pitch → `play_album` |

**Three source modes — Claude detects or asks:**

| Source | When | Approach |
|--------|------|----------|
| **Library** | "from my collection", "what I own" | `filter_tracks(compact)` → curate → `curate_and_play` |
| **Hybrid** | "mix of mine + new", "supplemented with discoveries" | `filter_tracks(compact)` + `search_qobuz` → blend → `play_tracks` |
| **Qobuz** | "something new", "surprise me", "I don't know yet" | multiple `search_qobuz` calls → curate → `play_tracks` |

When in doubt, Claude asks which source you want.

### Intelligence layer — taste profile & history

RoonSage tracks your listening and remembers what you like. Claude reads your profile at the start of each session and adjusts its recommendations accordingly.

**What is tracked automatically:**
- Every track you play is logged to a listening history table — artist, title, album, genre, how long you listened, and whether you skipped it.
- After each playlist, Claude can update your taste profile (genres, decades, artists, moods) using a weighted merge with 30% recency bias, so your profile evolves without losing long-term preferences.
- Explicit feedback ("I hated that one", "add jazz to my dislikes") is applied immediately.

**Taste profile structure:**

```json
{
  "genres":   {"Jazz": 0.8, "Electronic": 0.6},
  "decades":  {"1990s": 0.7, "2000s": 0.5},
  "artists":  {"Radiohead": 0.9, "Miles Davis": 0.85},
  "moods":    {"melancholic": 0.7, "energetic": 0.4},
  "dislikes": ["christmas", "karaoke"],
  "notes":    ["prefers album-oriented listening", "no live versions"],
  "stats":    {"total_playlists": 42, "avg_rating": 4.2}
}
```

**Saved playlists** — any curated playlist can be saved by name. Claude can replay it later (via `replay_saved_playlist`) or use it as inspiration for a new session.

**Session-start workflow (Claude Desktop):**

```
1. get_taste_profile          → Claude knows your current preferences
2. (optional) get_listening_history  → Claude sees what you've been playing lately
3. [curate playlist]          → guided by profile
4. rate_playlist              → 1–5 stars + optional note
5. update_taste_profile       → profile evolves based on feedback
```

### Setup

The MCP server runs locally on your Mac/PC — not in Docker. RoonSage itself (Docker or bare metal) must already be running before Claude Desktop connects to it.

```bash
# 1. Install the MCP dependency (once per machine)
pip3 install "mcp[cli]"

# 2. Configure Claude Desktop automatically
python3 scripts/install_mcp.py

# 3. Restart Claude Desktop
```

If RoonSage runs at a different address, set `ROONSAGE_URL` before starting Claude Desktop (default: `http://localhost:5765`).

**Manual configuration** — add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `~/.config/claude/claude_desktop_config.json` (Linux):

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

### Which Claude model to use?

| Model | Best for |
|-------|----------|
| **Claude Sonnet 4.6** | Daily use — fast, accurate |
| **Claude Opus 4.6** | Abstract prompts, deep discovery, multi-turn refinement |
| **Claude Haiku 4.5** | Quick, simple requests |

Start with Sonnet. Switch to Opus for prompts like "something that feels like driving in the rain at night."

### Available tools (42)

**Library**

| Tool | What it does |
|------|-------------|
| `get_library_stats` | Genre, decade, and total overview from the cache |
| `get_library_status` | Cache freshness; `needs_resync` flag |
| `search_library` | Search by track, artist, or album name |
| `search_qobuz` | Search the Qobuz catalogue via Roon; results are directly playable |
| `filter_tracks` | Filter by genre, decade, live exclusion. `output_format="compact"` returns a numbered list + `session_id`. `"ultra"` returns only artist — title per line. `"json"` returns full metadata. Supports `artist_limit` and `exclude_keywords`. |
| `get_artist_albums` | All albums by an artist from the SQLite cache |
| `sync_library` | Trigger a background library sync from Roon |

**Playlist curation & generation**

| Tool | What it does |
|------|-------------|
| `curate_and_play` | Plays a selection Claude chose from `filter_tracks` compact output — translates track numbers via `session_id` to Roon item_keys and starts playback |
| `validate_playlist` | Check a track selection for duplicates, clustering, and overrepresentation before playing |
| `generate_playlist` | Natural language → playlist via backend pipeline (library/hybrid/qobuz). Fallback when context is too large or explicitly requested. |
| `seed_track_playlist` | "More like this" — playlist from a seed track via backend pipeline (fallback) |
| `analyze_prompt` | Preview how a prompt is translated into genre/decade filters |
| `recommend_album` | Quick AI album recommendation (library or discovery mode) — fallback |
| `recommend_album_interactive` | 2-step Q&A for personalised picks — fallback |

**Playback**

| Tool | What it does |
|------|-------------|
| `play_album` | Search and play an album in one step |
| `play_radio` | Play an internet radio station by name |
| `browse_playlists` | List or play all Roon playlists |
| `list_zones` | List active Roon zones |
| `get_now_playing` | Current playback state per zone |
| `play_tracks` | Send tracks to a zone (replaces queue) |
| `queue_tracks` | Append tracks to the zone queue |

**Transport & zone management**

| Tool | What it does |
|------|-------------|
| `transport_control` | Play, pause, stop, next, previous, shuffle, repeat, seek |
| `volume_control` | Set, adjust, mute, or query volume per zone |
| `transfer_zone` | Move playback from one zone to another |
| `zone_grouping` | Group or ungroup zones for synchronised playback |
| `get_result_history` | Previously generated playlists and recommendations |

**Intelligence & taste profile**

| Tool | What it does |
|------|-------------|
| `get_taste_profile` | Retrieve your full taste profile (genres, decades, artists, moods, dislikes, notes, stats) |
| `update_taste_profile` | Merge new preferences into your profile — genres, moods, dislikes, freeform notes |
| `rate_playlist` | Rate a saved playlist 1–5 stars with an optional comment |
| `get_listening_history` | Recent listening history — artist, title, play duration, skip flag |
| `save_playlist` | Save a curated playlist by name for future replay |
| `list_saved_playlists` | List all saved playlists with metadata and ratings |
| `replay_saved_playlist` | Play a previously saved playlist by name or ID |
| `browse_tags` | List all Roon Tags from your library for tag-based filtering |
| `modify_playlist` | Adjust a playing or proposed playlist — remove tracks, change mood, swap artists |

**Qobuz & Roon Arc**

| Tool | What it does |
|------|-------------|
| `save_to_qobuz` | Save a curated playlist to your Qobuz account by artist + title search |
| `prepare_for_arc` | Save a playlist to Qobuz **and** add albums to favorites in one step — the playlist and favorites automatically appear in Roon Arc |
| `add_to_qobuz_favorites` | Add albums, tracks, or artists to Qobuz favorites (appears instantly in Roon Arc) |
| `list_qobuz_playlists` | List all playlists in your Qobuz account with track counts and dates |
| `update_qobuz_playlist` | Rename a playlist, add tracks, or remove tracks by position |
| `delete_qobuz_playlist` | Permanently delete a Qobuz playlist |
| `browse_qobuz_new_releases` | Browse new/featured album releases on Qobuz, optionally filtered by genre |

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

Open **http://localhost:5765** — a setup wizard guides you through connecting to Roon, choosing an AI provider, and syncing your library.

**Authorise in Roon:** Settings → Extensions → find **RoonSage** → Enable.

> **Free option:** Google Gemini has a free API tier that is sufficient for personal use. No credit card required. See [`docs/gemini-free-credit-guide.md`](docs/gemini-free-credit-guide.md).

---

## Web UI

The web interface works without Claude Desktop and offers the same playlist and recommendation features through a standard browser form.

![Home screen](docs/images/screenshot-home.png)

**Playlist from prompt** — describe a mood in natural language. RoonSage analyses your prompt, translates it into genre/decade filters, sends the filtered tracks to the LLM, and returns a playable playlist. Works with libraries of 50,000+ tracks.

**Playlist from seed** — choose a track, select musical dimensions (mood, era, instrumentation, production style), and get a playlist that explores those qualities.

**Refine & iterate** — use the Refine button on any result to adjust without starting over. "Darker", "more 80s", "less jazz" — the LLM sees the original prompt plus your notes.

**Album recommendations** — describe a moment or mood, answer two quick questions, and get one album recommendation with an editorial pitch. Library mode recommends albums you own; Discovery mode finds albums you don't have yet (searched on Qobuz).

**Qobuz integration** — three source modes: Library only, Mix (library + Qobuz discoveries), and Qobuz Discovery (new music only). Automatically detected when Qobuz is configured in Roon.

**Save to Qobuz** — save any generated playlist directly to your Qobuz account. Configure your Qobuz email and password in Settings — the app auto-detects the required API credentials. Each track is looked up in the Qobuz catalogue by artist + title; matched tracks are added to a new Qobuz playlist. Unmatched tracks are reported. Via Claude Desktop you can additionally manage playlists, handle favorites, and prepare Arc-ready collections.

**Roon Arc integration** — everything you save to Qobuz (playlists and favorites) automatically appears in Roon Arc. Via Claude Desktop, say _"Save this for Arc"_ and `prepare_for_arc` creates the Qobuz playlist and adds the albums to your favorites in one call. Claude can also browse new Qobuz releases by genre, manage existing Qobuz playlists, and add individual albums to favorites after a discovery recommendation.

**Smart filtering** — filter by genre, decade, and live exclusion before the LLM sees anything. Real-time track counts show exactly how your choices narrow the pool. Estimated token costs are shown before you generate.

**Time-aware context** — the current day and hour are sent as subtle mood hints in generation prompts. Friday evening picks differ from Tuesday morning.

![Album recommendation](docs/images/screenshot-album.png)

---

## How it works

RoonSage uses a filter-first architecture for large libraries. The LLM never sees your entire library — only a filtered, manageable subset.

There are two paths depending on how you use RoonSage:

### Path A — Claude Desktop (native curation, fast)

Claude curates the playlist itself using its own musical knowledge. No backend LLM call.

```
┌─────────────────────────────────────────────────────────────────┐
│  1. ANALYSE (Claude)                                             │
│     Claude interprets your prompt — mood, genre, era, tempo      │
│     Also detects desired source: library / hybrid / qobuz        │
├─────────────────────────────────────────────────────────────────┤
│  2. STATS (optional, for library/hybrid)                         │
│     get_library_stats → Claude sees which genres/decades exist   │
├─────────────────────────────────────────────────────────────────┤
│  3. FILTER & SEARCH                                              │
│     Library/hybrid: filter_tracks(compact) → numbered list       │
│     + key_map with up to 500 tracks                              │
│     Hybrid/qobuz: search_qobuz for Qobuz tracks                 │
├─────────────────────────────────────────────────────────────────┤
│  4. CURATE (Claude)                                              │
│     Claude picks the best 15–50 tracks using musical             │
│     knowledge: diversity, flow, no clustering, right mood        │
│     For hybrid: library and Qobuz tracks blended through list    │
├─────────────────────────────────────────────────────────────────┤
│  5. PLAY                                                         │
│     curate_and_play or play_tracks → item_keys to Roon zone      │
│     Direct playback in any Roon client                           │
└─────────────────────────────────────────────────────────────────┘
```

### Path B — Web UI and fallback (backend pipeline)

Used by the web interface and by Claude Desktop when the filtered pool is too large or the user explicitly asks for "automatic".

```
┌─────────────────────────────────────────────────────────────────┐
│  1. ANALYSE                                                      │
│     LLM interprets prompt → suggests genre/decade filters        │
├─────────────────────────────────────────────────────────────────┤
│  2. FILTER                                                       │
│     Library narrowed via SQLite                                  │
│     "90s Alternative" → 2,000 tracks                             │
├─────────────────────────────────────────────────────────────────┤
│  3. SAMPLE (large libraries only)                                │
│     Too large for context window → random sample                 │
├─────────────────────────────────────────────────────────────────┤
│  4. GENERATE                                                     │
│     Filtered list + prompt sent to LLM                           │
│     LLM selects best tracks by track number                      │
├─────────────────────────────────────────────────────────────────┤
│  5. MATCH                                                        │
│     Track number → O(1) lookup in SQLite cache                   │
│     Fallback to fuzzy matching (rapidfuzz) if needed             │
├─────────────────────────────────────────────────────────────────┤
│  6. PLAY                                                         │
│     Tracks sent to Roon zone via Browse API                      │
└─────────────────────────────────────────────────────────────────┘
```

Library data is synced once to SQLite via the Roon Browse API (`browse_browse` / `browse_load`). All subsequent queries read from the local cache — no Roon API calls needed during generation.

### Intelligence layer (background)

A passive listening monitor runs alongside Roon. Every 10 seconds it checks which tracks are playing across all zones. When a track plays for at least 5 seconds, it is logged to `listening_history` with artist, title, album, genre, play duration, and a skip flag (skipped = played less than 30 s). This data is used to recompute genre and artist preference scores and to evolve the taste profile over time — entirely locally, with no cloud dependency.

---

## Installation

### Docker Compose

```bash
mkdir roonsage && cd roonsage
curl -O https://raw.githubusercontent.com/Georgemvp/roonsage/main/docker-compose.yml
# edit docker-compose.yml: set ROON_HOST and an API key
docker compose up -d
```

### NAS platforms

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

ARM-based Synology units without Docker: use [Bare Metal](#bare-metal) below.
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

### Environment variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `ROON_HOST` | Yes | — | IP or hostname of your Roon Core |
| `ROON_PORT` | No | `9330` | Roon Core port |
| `ROON_CORE_ID` | No | auto | Saved after first authorisation |
| `ROON_TOKEN` | No | auto | Saved after first authorisation |
| `GEMINI_API_KEY` | One of three | — | Google Gemini (has free tier) |
| `ANTHROPIC_API_KEY` | One of three | — | Anthropic Claude |
| `OPENAI_API_KEY` | One of three | — | OpenAI GPT |
| `LLM_PROVIDER` | No | auto-detect | Force: `gemini`, `anthropic`, `openai`, `ollama`, `custom` |
| `OLLAMA_URL` | No | `http://localhost:11434` | Ollama server URL |
| `CUSTOM_LLM_URL` | No | — | OpenAI-compatible API base URL |
| `CUSTOM_CONTEXT_WINDOW` | No | `32768` | Context window for custom provider |
| `ROONSAGE_PASSWORD` | No | — | Enable HTTP Basic Auth on all endpoints |
| `ROONSAGE_URL` | No | `http://localhost:5765` | Address at which the MCP server reaches RoonSage |
| `QOBUZ_EMAIL` | No | — | Qobuz account email (voor playlist-opslag in Qobuz) |
| `QOBUZ_PASSWORD` | No | — | Qobuz account wachtwoord (voor playlist-opslag) |

Settings can also be adjusted via the web UI (Settings page). UI-saved settings go to `data/config.user.yaml`. Environment variables always take precedence.

### config.yaml

```yaml
roon:
  host: "192.168.1.x"
  port: 9330

llm:
  provider: "gemini"
  model_analysis: "gemini-2.5-flash"
  model_generation: "gemini-2.5-flash"
  smart_generation: false  # true = use analysis model for generation too (higher quality, ~3–5× cost)

defaults:
  track_count: 25
```

### Model choice for the Web UI

The Web UI uses a two-model strategy: a smarter model for prompt analysis, a cheaper model for track selection.

| Role | Anthropic | OpenAI | Gemini |
|------|-----------|--------|--------|
| Analysis | `claude-sonnet-4-5` | `gpt-4.1` | `gemini-2.5-flash` |
| Generation | `claude-haiku-4-5` | `gpt-4.1-mini` | `gemini-2.5-flash` |
| Max tracks to AI | ~3,500 | ~2,300 | **~18,000** |

Gemini's 1M token context window allows sending far more tracks to the model, improving variety with large libraries.

### Local LLM (experimental)

<details>
<summary><strong>Ollama</strong></summary>

```bash
ollama pull llama3:8b
```

```bash
LLM_PROVIDER=ollama
OLLAMA_URL=http://localhost:11434
```

Select your model in Settings — the context window is detected automatically. Models with 8K+ context work best (`llama3:8b`, `qwen3:8b`, `mistral`).
</details>

<details>
<summary><strong>Custom OpenAI-compatible API</strong></summary>

For LM Studio, text-generation-webui, vLLM, or similar:

```bash
LLM_PROVIDER=custom
CUSTOM_LLM_URL=http://localhost:5000/v1
CUSTOM_CONTEXT_WINDOW=32768
```

Set the model name and API key (if required) via Settings.
</details>

---

## Security

RoonSage is designed for home network use. Without `ROONSAGE_PASSWORD`, anyone on your network has access to the web UI.

`ROONSAGE_PASSWORD` enables HTTP Basic Auth on all endpoints. The health check (`/api/health`) and the art proxy are exempt, so Docker health checks and album art continue to work without credentials.

LLM-powered endpoints are rate-limited to 30 requests per hour per IP. API keys are stored in `data/config.user.yaml` (permissions 600) and are never exposed via the API.

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
ruff check .       # linting
```

**Stack:** Python 3.11+, FastAPI, python-roonapi, anthropic / openai / google-genai SDKs, rapidfuzz, SQLite, vanilla HTML/CSS/JS.

---

## API Reference

Interactive docs at `/docs` when the server is running.

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/health` | GET | Health check |
| `/api/config` | GET/POST | Retrieve or update configuration |
| `/api/setup/status` | GET | Onboarding checklist status |
| `/api/setup/validate-roon` | POST | Validate Roon Core connection |
| `/api/setup/validate-ai` | POST | Validate AI provider credentials |
| `/api/library/stats/cached` | GET | Genre/decade/total from SQLite |
| `/api/library/status` | GET | Cache status, track count, needs_resync |
| `/api/library/sync` | POST | Trigger background library sync |
| `/api/library/search` | GET | Search by track/artist/album |
| `/api/library/artist-albums` | GET | All albums by artist from cache |
| `/api/library/filter` | POST | Filter by genre/decade/live exclusion |
| `/api/library/filter/session` | POST | Store server-side key_map for curate_and_play |
| `/api/library/filter/curate` | POST | Play curated track selection via session_id + track numbers |
| `/api/library/filter/validate` | POST | Validate track selection for quality issues |
| `/api/analyze/prompt` | POST | Analyse prompt → filter mapping |
| `/api/generate/stream` | POST | Stream playlist generation (SSE) |
| `/api/roon/zones` | GET | Get active Roon zones |
| `/api/roon/transport` | POST | play/pause/stop/next/previous/shuffle/repeat/seek |
| `/api/roon/volume` | POST | Set/adjust/mute/query volume |
| `/api/roon/transfer` | POST | Move playback to another zone |
| `/api/roon/group` | POST | Group or ungroup zones |
| `/api/roon/radio` | POST | Play an internet radio station |
| `/api/roon/playlists` | POST | List or play Roon playlists |
| `/api/roon/qobuz-search` | POST | Search Qobuz catalogue via Roon |
| `/api/qobuz/playlist/save` | POST | Save a playlist to the user's Qobuz account |
| `/api/qobuz/save-status` | GET | Check whether Qobuz save is configured |
| `/api/qobuz/validate` | POST | Validate Qobuz credentials |
| `/api/qobuz/favorite/add` | POST | Add tracks, albums, or artists to Qobuz favorites |
| `/api/qobuz/favorite/remove` | POST | Remove items from Qobuz favorites |
| `/api/qobuz/favorites` | GET | List user's Qobuz favorites (tracks/albums/artists) |
| `/api/qobuz/playlists` | GET | List all Qobuz playlists in user's account |
| `/api/qobuz/playlist/{id}` | GET | Get Qobuz playlist details with tracks |
| `/api/qobuz/playlist/{id}` | PUT | Update playlist — rename, add or remove tracks |
| `/api/qobuz/playlist/{id}` | DELETE | Delete a Qobuz playlist |
| `/api/qobuz/new-releases` | GET | Browse new/featured Qobuz albums, optional `genre_id` filter |
| `/api/qobuz/prepare-for-arc` | POST | Resolve tracks → create Qobuz playlist → add to favorites (Arc workflow) |
| `/api/intelligence/taste-profile` | GET | Retrieve the user's taste profile |
| `/api/intelligence/taste-profile` | PUT | Merge updates into the taste profile |
| `/api/intelligence/taste-events` | GET | Recent taste events (plays, ratings, feedback) |
| `/api/intelligence/listening-history` | GET | Paginated listening history with skip/duration data |
| `/api/intelligence/listening-history/recompute` | POST | Recompute the taste profile from listening history |
| `/api/playlists/saved` | GET | List all saved playlists |
| `/api/playlists/saved` | POST | Save a new playlist by name |
| `/api/playlists/saved/from-session` | POST | Save the current filter session as a named playlist |
| `/api/playlists/saved/{id}` | GET | Retrieve a saved playlist with its tracks |
| `/api/playlists/saved/{id}` | PUT | Update rating or notes on a saved playlist |
| `/api/playlists/saved/{id}` | DELETE | Delete a saved playlist |
| `/api/playlists/saved/{id}/play` | POST | Play a saved playlist in a Roon zone |
| `/api/roon/tags` | GET | List all Roon Tags from the library |
| `/api/queue` | POST | Send tracks to a Roon zone |
| `/api/queue/append` | POST | Append tracks to a zone queue |
| `/api/recommend/questions` | POST | Generate clarifying questions |
| `/api/recommend/generate` | POST | Generate album recommendations |
| `/api/results` | GET | Retrieve result history |
| `/api/art/{item_key}` | GET | Proxy album art from Roon |

---

## Credits

RoonSage is based on [MediaSage](https://github.com/ecwilsonaz/mediasage) by Eric Wilson, originally built for Plex. RoonSage has been independently developed for Roon with significant new functionality, including MCP integration, Qobuz support, zone management, time-aware context, and a full library cache layer.

---

## License

MIT
