<div align="center">

# 🎵 RoonSage

**AI-powered playlist curation, music intelligence, automated discovery, and smart library management for Roon**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Python 3.11+](https://img.shields.io/badge/Python-3.11+-blue.svg)](https://www.python.org/downloads/)
[![FastAPI](https://img.shields.io/badge/FastAPI-0.128+-009688.svg)](https://fastapi.tiangolo.com)
[![Version](https://img.shields.io/badge/Version-13.2-e5a00d.svg)](#changelog)
[![ListenBrainz](https://img.shields.io/badge/ListenBrainz-integrated-eb743b.svg)](https://listenbrainz.org)
[![Last.fm](https://img.shields.io/badge/Last.fm-integrated-d51007.svg)](https://www.last.fm)

_Curate playlists from your library, discover hidden gems, monitor artist releases on Qobuz,_
_automate your listening, and let Claude Desktop control every aspect of Roon — all in natural language._

[Features](#features) · [Claude Desktop](#claude-desktop-integration) · [Discovery](#discovery-engine) · [Automation](#automation-engine) · [ListenBrainz](#listenbrainz-integration) · [Last.fm](#lastfm-integration) · [Setup](#deployment) · [API](#api-reference) · [Changelog](#changelog)

</div>

---

## Screenshots

| Home (Insight Selection + bento) | Generate Playlist |
|---|---|
| ![Home](docs/images/screenshot-home.png) | ![Generate Playlist](docs/images/screenshot-playlist.png) |

| From Seed Song | Recommend Album |
|---|---|
| ![From Seed Song](docs/images/screenshot-seed.png) | ![Recommend Album](docs/images/screenshot-recommend.png) |

| Discovery (cache-powered rails) | My Taste (intelligence profile) |
|---|---|
| ![Discovery](docs/images/screenshot-discovery.png) | ![My Taste](docs/images/screenshot-taste.png) |

| DJ Set (Camelot + energy curve) | Automations |
|---|---|
| ![DJ Set](docs/images/screenshot-dj.png) | ![Automations](docs/images/screenshot-automations.png) |

| Watchlist | Settings |
|---|---|
| ![Watchlist](docs/images/screenshot-watchlist.png) | ![Settings](docs/images/screenshot-settings.png) |

| Playlists library | Enrichment |
|---|---|
| ![Playlists](docs/images/screenshot-playlists.png) | ![Enrichment](docs/images/screenshot-enrichment.png) |

### v13 — Audio AI features

| Sonic Fingerprint (musical DNA radar) | Song Paths (sonic bridge builder) |
|---|---|
| ![Sonic Fingerprint](docs/images/screenshot-sonic-fingerprint.png) | ![Song Paths](docs/images/screenshot-song-paths.png) |

| Song Alchemy (add / subtract vector mix) | Music Map (UMAP + HDBSCAN clusters) |
|---|---|
| ![Song Alchemy](docs/images/screenshot-alchemy.png) | ![Music Map](docs/images/screenshot-music-map.png) |

| Circadian Rhythm (24h audio profile) | Sonic Match (CLAP text-to-audio search) |
|---|---|
| ![Circadian](docs/images/screenshot-circadian.png) | ![Sonic Match](docs/images/screenshot-sonic-match.png) |

| Meaning Match (semantic lyrics search) | |
|---|---|
| ![Meaning Match](docs/images/screenshot-meaning-match.png) | |

---

## What is RoonSage?

RoonSage is a **self-hosted web app** that connects to your Roon Core as an Extension. It syncs your library into a local SQLite cache and wraps everything in a full **MCP server** (69 tools) so Claude Desktop can search, curate, discover, build DJ sets, and control Roon through natural conversation.

Key design principles:

- **Library-first** — 100% of suggested tracks exist in your library or on Qobuz; nothing is hallucinated
- **Claude curates** — Claude Desktop does the musical thinking; the backend provides data and Roon connectivity
- **Smart discovery** — cache-powered discovery surfaces hidden gems with zero LLM calls and zero external API requests
- **Automation-ready** — trigger-action workflows run on schedule, zone events, library syncs, and more
- **No build step** — vanilla HTML/CSS/JS frontend, single Docker container
- **Optional everything** — Qobuz, ListenBrainz, Last.fm, AcoustID, notifications, and password auth are all optional add-ons

---

## System Architecture

```mermaid
graph TB
    subgraph home["🏠 Your Home Network"]
        RC("🎵 Roon Core")
        RS("⚙️ RoonSage Backend\nFastAPI · Python 3.11")
        DB[("🗄️ SQLite\nlibrary_cache.db")]
        FE("🖥️ Web UI\nPWA · Chart.js")
        AE("🤖 Automation Engine\ntrigger-action workflows")
        DE("🔍 Discovery Engine\ncache-powered SQL")
        EW("🏷️ Enrichment Worker\nMusicBrainz · Last.fm")
    end

    subgraph cloud["☁️ External Services"]
        LB("🎧 ListenBrainz\nscrobbling · stats")
        LF("🎵 Last.fm\nscrobbling · tags · similar")
        QB("🎶 Qobuz\ncatalog · playlists")
        MB("🗃️ MusicBrainz\ntrack metadata")
        AI("🤖 LLM Provider\nGemini · Anthropic · OpenAI · Ollama")
        AID("🔊 AcoustID\nfingerprint verification")
        NOTIF("📣 Notifications\nDiscord · Telegram · Webhook")
    end

    CD("💬 Claude Desktop\n67 MCP tools")

    RC  <-->|"WebSocket\nExtension API"| RS
    RS  <-->|"Browse API\nsync + playback"| RC
    RS  <-->|read / write| DB
    RS  -->|serve| FE
    RS  <-->|"scrobble + stats"| LB
    RS  <-->|"scrobble + tags"| LF
    RS  <-->|"catalog · playlist save"| QB
    RS  <-->|"track metadata"| MB
    RS  <-->|"prompt analysis\ntrack selection"| AI
    RS  <-->|"fingerprint verify"| AID
    RS  -->|"events"| NOTIF
    AE  -->|triggers| RS
    DE  -->|SQL queries| DB
    EW  -->|enriches| DB
    CD  <-->|"MCP stdio"| RS
```

---

## How Data Flows

```mermaid
flowchart LR
    subgraph sync["🔄 Library Sync (one-time + on demand)"]
        direction TB
        A("Roon Core\nBrowse API")
        B("roon_browse.py")
        C[("tracks\ntrack_genres")]
        A -->|"Root → Library\n→ Albums → Tracks"| B
        B -->|"INSERT artist, title,\ngenre, year"| C
    end

    subgraph query["⚡ Query (from SQLite — instant)"]
        direction TB
        D("filter_tracks")
        E[("SQLite cache")]
        F("Claude Desktop\nor Web UI")
        D -->|"SQL: genre IN (...)\ndecade = '1990s'"| E
        E -->|"numbered list\n+ session_id"| F
    end

    subgraph play["▶️ Playback"]
        direction TB
        G("curate_and_play")
        H("roon_playback.py")
        I("Roon Zone")
        G -->|"session_id +\ntrack numbers"| H
        H -->|"Browse API\nPlay Now"| I
    end

    sync --> query --> play
```

---

## Claude Desktop Integration

Add the MCP server to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "roonsage": {
      "command": "python3",
      "args": ["/FULL/PATH/TO/roonsage/mcp_server.py"],
      "env": {
        "ROONSAGE_URL": "http://localhost:5765"
      }
    }
  }
}
```

### Example prompts

```
"Play some melancholic post-rock for a rainy Sunday afternoon."
"Give me 30 tracks of 90s underground hip-hop, focus on obscure stuff."
"What's currently playing and what zone is it in?"
"Show me albums I own by my favorite artists that I've never played."
"Add Radiohead to my watchlist and scan for new Qobuz releases."
"Create an automation that generates a chill playlist every Friday at 6pm."
"What's my enrichment progress?"
"Play something I haven't heard in over two months."
"Set up a scheduled playlist — jazz every weekday morning at 8am."
"Give me an album recommendation for a dinner party with guests who like Nils Frahm."
"More like this track, but from my library only."
"Search Qobuz for the new Thom Yorke album and play it."
"Transfer playback from the living room to the office and lower the volume."
"Show me the deep cuts from my top 20 artists."
"Save this playlist to Qobuz."
"What genres do I have in my library and how many tracks each?"
```

### Three curation flows

```mermaid
flowchart TD
    U("User request") --> A{Source mode?}

    A -->|library| B["filter_tracks(compact)\n→ session_id"]
    B --> C["Claude curates\n(15–50 tracks)"]
    C --> D["validate_playlist\n(optional check)"]
    D --> E["curate_and_play\n→ Roon zone"]

    A -->|hybrid| F["filter_tracks\n+ search_qobuz"]
    F --> G["Claude mixes\nlibrary + Qobuz"]
    G --> H["play_tracks\n(combined keys)"]

    A -->|qobuz only| I["search_qobuz\n(multiple queries)"]
    I --> J["Claude selects\nfrom Qobuz results"]
    J --> K["play_tracks\n(Qobuz keys)"]
```

### Source modes

| Mode | Source | Use when |
|------|--------|----------|
| `library` | Your Roon library only | Best quality control, everything you own |
| `hybrid` | Library + Qobuz catalog | Mix familiar and new discoveries |
| `qobuz` | Qobuz catalog only | Pure discovery, nothing in library needed |

---

## Full MCP Tool List

RoonSage exposes **69 tools** to Claude Desktop, grouped by function.

### Library & Search

| Tool | Description |
|------|-------------|
| `get_library_stats` | Genre/decade/total track counts from cache |
| `get_library_status` | Cache freshness, track count, needs-resync flag |
| `search_library` | Full-text search by track, artist, or album name |
| `filter_tracks` | Filter by genre, decade, keywords; output as `json`/`compact`/`ultra` |
| `get_artist_albums` | All albums by an artist from the SQLite cache |
| `sync_library` | Trigger a background library re-sync from Roon |
| `browse_tags` | List all Roon tags available in the library |

### Discovery

| Tool | Description |
|------|-------------|
| `get_discovery_sections` | All 4 cache-powered sections: undiscovered albums, deep cuts, forgotten favorites, genre explorer |

### Playlist Generation

| Tool | Description |
|------|-------------|
| `generate_playlist` | Backend LLM playlist from natural language (web UI flow; fallback for MCP) |
| `seed_track_playlist` | "More like this" playlist from a seed track |
| `analyze_prompt` | Preview how a prompt maps to genre/decade filters |
| `list_playlist_templates` | List all built-in and user-created playlist templates |
| `generate_from_template` | Generate a playlist from a named template |

### Claude-Native Curation

| Tool | Description |
|------|-------------|
| `curate_and_play` | Translate track numbers from `filter_tracks` compact list to Roon item keys and start playback |
| `validate_playlist` | Check a curated selection for duplicates, artist clustering, and overrepresentation |

### Album Recommendations

| Tool | Description |
|------|-------------|
| `recommend_album` | Quick single-step album recommendation |
| `recommend_album_interactive` | 2-step Q&A recommendation with `session_id` handoff |
| `play_album` | Search library + play album in one step |

### Roon Playback & Control

| Tool | Description |
|------|-------------|
| `list_zones` | List all active Roon playback zones |
| `get_now_playing` | Current track, zone, and playback state |
| `play_tracks` | Send item keys to a zone (replaces queue) |
| `queue_tracks` | Append tracks to a zone's queue |
| `transport_control` | play/pause/stop/next/prev/shuffle/repeat/seek |
| `volume_control` | Set, adjust, get, or mute volume by zone name |
| `transfer_zone` | Move playback from one zone to another |
| `zone_grouping` | Group or ungroup Roon zones |
| `play_radio` | Play an internet radio station by name (fuzzy match) |
| `browse_playlists` | List and play Roon playlists |

### Intelligence & Taste

| Tool | Description |
|------|-------------|
| `get_taste_profile` | Detailed taste profile with genre scores, era data, LB + Last.fm stats |
| `update_taste_profile` | Manually adjust genre/era weights |
| `rate_playlist` | Rate a generated playlist (thumbs up/down) |
| `get_listening_history` | Recent listening history from the local database |
| `get_listening_stats` | Play counts, genre breakdown, listening patterns |
| `save_playlist` | Save a curated playlist to the local database |
| `list_saved_playlists` | List previously saved playlists with optional tag filter |
| `replay_saved_playlist` | Re-send a saved playlist to a Roon zone |
| `modify_playlist` | Add, remove, or reorder tracks in a saved playlist |
| `get_result_history` | Previously generated playlists and recommendations |

### ListenBrainz

| Tool | Description |
|------|-------------|
| `get_listenbrainz_recommendations` | Personal recommendations from ListenBrainz |
| `submit_listen_feedback` | Submit love/hate feedback for a track to ListenBrainz |
| `sync_listenbrainz` | Force an immediate ListenBrainz stats sync (bypasses 6h TTL) |

### Qobuz

| Tool | Description |
|------|-------------|
| `search_qobuz` | Search Qobuz catalog via Roon Browse API |
| `save_to_qobuz` | Save a curated playlist to your Qobuz account |
| `add_to_qobuz_favorites` | Add a track or album to Qobuz favorites |
| `list_qobuz_playlists` | List your Qobuz playlists |
| `update_qobuz_playlist` | Rename or update a Qobuz playlist |
| `delete_qobuz_playlist` | Delete a Qobuz playlist |
| `browse_qobuz_new_releases` | Browse Qobuz new releases by genre |
| `prepare_for_arc` | Prepare a playlist for Roon ARC offline listening |

### Watchlist

| Tool | Description |
|------|-------------|
| `get_watchlist` | List all watched artists and their latest release status |
| `add_to_watchlist` | Add an artist to the release watchlist |
| `scan_watchlist` | Immediately scan all watched artists for new Qobuz releases |
| `play_new_release` | Play a newly detected release from the watchlist |

### Scheduled Playlists

| Tool | Description |
|------|-------------|
| `list_scheduled_playlists` | List all configured scheduled playlists |
| `create_scheduled_playlist` | Create a cron-based auto-regenerating playlist |
| `run_scheduled_playlist` | Manually trigger a scheduled playlist immediately |

### Metadata Enrichment

| Tool | Description |
|------|-------------|
| `get_enrichment_status` | Enrichment queue progress, completion %, source breakdown |
| `start_enrichment` | Start or resume background MusicBrainz + Last.fm enrichment |

### Automation

| Tool | Description |
|------|-------------|
| `list_automations` | List all automations with status and run history |
| `create_automation` | Create a new trigger-action automation |
| `toggle_automation` | Enable or disable an automation by ID |

### AcoustID Verification

| Tool | Description |
|------|-------------|
| `verify_track_match` | Fingerprint-verify that a Qobuz search result matches the intended track |

### Audio Features & DJ Sets

| Tool | Description |
|------|-------------|
| `get_audio_features_status` | Queue counts, worker state, scan progress, analyser availability |
| `get_track_audio_features` | BPM / key / energy / valence / danceability for a single track |
| `filter_tracks_by_audio` | Filter by BPM range, Camelot keys, energy / valence / danceability / instrumentalness — returns the same numbered list + `session_id` as `filter_tracks` |
| `build_dj_set` | Beatmatched, Camelot-compatible DJ set with a configurable BPM curve (flat / ramp_up / ramp_down / peak / valley) and optional seed track |

---

## Features

### Web UI Views

![Home](docs/images/screenshot-home.png)

| View | Description |
|------|-------------|
| **Generate** | Natural language playlist generation with genre/decade filters, track count, source mode (library/hybrid/qobuz), and one-click playlist templates |
| **Filter** | Direct library filtering by genre, decade, and keywords with live track count preview |
| **Discover** | Cache-powered discovery: Undiscovered Albums, Deep Cuts, Forgotten Favorites, Genre Explorer |
| **My Taste** | Chart.js visualizations of genre scores, era distribution, listening heatmap, ListenBrainz + Last.fm stats with time range filters |
| **Watchlist** | Artist monitoring with Qobuz new-release detection and dismiss/play controls |
| **Automations** | Trigger-action workflow builder with presets, activity log, and enable/disable toggles |
| **Audio Features** | Worker status, queue counts, and live scan progress (walking → matching → complete) for the librosa-based BPM/key/energy analysis |
| **DJ Set** | Beatmatched playlist builder — pick duration, BPM curve, and energy shape; sends a Camelot-compatible queue straight to a Roon zone |
| **Settings** | Roon, LLM, Qobuz, ListenBrainz, Last.fm, Notifications, Scheduled Playlists, Enrichment status, AcoustID |

### Discovery Engine

![Discovery](docs/images/screenshot-discovery.png)

Four sections powered entirely by SQL queries against the local SQLite cache — zero LLM calls, zero external API calls, instant response:

- **Undiscovered Albums** — Albums by the user's most-played artists with zero play count. Great for "what else do they have?"
- **Deep Cuts** — Under-played tracks from the top-20 most-listened artists. Side-B tracks you keep skipping.
- **Forgotten Favorites** — Tracks with 5+ total plays but no play in the last 60 days. Perfect for "Rediscover" playlists.
- **Genre Explorer** — All library genres with artist count and track count, sorted by artist diversity.

### Playlist Templates

![Generate Playlist](docs/images/screenshot-playlist.png)

One-click playlist presets eliminate the need to type prompts for common listening occasions:

- **Built-in templates** stored in `data/playlist_templates.yaml` — Morning commute, Late-night focus, Weekend dinner, etc.
- **User templates** stored in `data/user_templates.yaml` — create your own via the Settings UI or `create_automation`
- Templates support genre/decade filters, track count, source mode, and a free-text prompt
- The `generate_from_template` MCP tool and the web UI Generate view both support one-click generation

### Artist Watchlist

![Watchlist](docs/images/screenshot-watchlist.png)

Monitor artists for new releases on Qobuz without leaving Roon:

- Add artists manually or auto-populate from your top ListenBrainz/Last.fm artists
- Background scan every 12 hours (configurable via `WATCHLIST_SCAN_INTERVAL_HOURS`)
- Detects albums, EPs, and optionally singles per artist
- Sends a notification (Discord/Telegram/webhook) when a new release is found
- Play a new release directly with `play_new_release` or from the Watchlist view

### Scheduled Playlists

Cron-based automatic playlist regeneration that keeps your Roon queue fresh:

- Define a prompt + filters + cron expression (e.g. `0 8 * * 1-5` for weekday mornings)
- Generated playlists are sent directly to a Roon zone and/or saved to Qobuz
- Double-run protection: a schedule is skipped if it ran within the last 55 seconds
- Manually trigger any schedule immediately via `run_scheduled_playlist` or the Settings UI

### Automation Engine

![Automations](docs/images/screenshot-automations.png)

A trigger-action workflow system that connects Roon events to RoonSage actions:

**Triggers:**

| Trigger | Fires when… |
|---------|-------------|
| `schedule` | A cron expression matches |
| `track_played` | A track completes in a Roon zone |
| `zone_started` | A Roon zone begins playback |
| `library_synced` | A library sync completes |
| `lb_synced` | A ListenBrainz sync completes |
| `watchlist_match` | A new release is detected on the watchlist |

**Actions:**

| Action | Does… |
|--------|-------|
| `generate_playlist` | Generate and queue a playlist |
| `play_template` | Trigger a named playlist template |
| `sync_library` | Run a library sync |
| `sync_listenbrainz` | Run a ListenBrainz sync |
| `scan_watchlist` | Scan watchlist for new releases |
| `send_notification` | Send a message via Discord/Telegram/webhook |
| `run_maintenance` | Run enrichment or other maintenance tasks |
| `volume_set` | Set zone volume |

Automations have a configurable cooldown (default 5 minutes) to prevent double-firing. Activity is logged to `automation_log` for auditing.

### Metadata Enrichment

Background pipeline that enriches every track in the library with additional metadata from MusicBrainz and Last.fm:

- **MusicBrainz**: MBID, release date, country of origin, genre tags
- **Last.fm**: listener count, global play count, community tags (e.g. "late night", "atmospheric")
- Enrichment data is stored in `track_metadata_ext` and can inform playlist generation prompts
- Worker runs automatically at startup and can be paused/resumed
- Progress tracked per-track: `pending → processing → complete / failed`
- Check status with `get_enrichment_status` or the Settings UI

### AcoustID Verification

Audio fingerprint verification for Qobuz search results using the free [AcoustID](https://acoustid.org) service:

- Detects wrong versions before playback: live vs. studio, remix vs. original, wrong decade remaster
- `verify_track_match` fingerprints the local library file and compares against the Qobuz result's MBID
- Optional `auto_verify_qobuz` mode verifies every Qobuz search result automatically (adds minor latency)
- Requires `libchromaprint-tools` (included in the Docker image) and a free AcoustID API key

### Audio Features & DJ Set Builder

![DJ Set](docs/images/screenshot-dj.png)

Per-track audio analysis with [librosa](https://librosa.org) + a beatmatched DJ set generator:

- **What's extracted** — BPM, musical key + Camelot wheel code, energy, danceability, valence, instrumentalness, acousticness, tempo confidence
- **Background worker** — drains `audio_features_queue` (4 concurrent analyses, CPU-bound). Pause/resume from the Audio Features view
- **Path resolver** — walks `MUSIC_LIBRARY_PATH` once, builds a `(artist, album, title)` → file path index from mutagen tags, then matches it back to Roon tracks. Single-flight: only one scan runs at a time
- **Live scan progress** — UI shows phase (walking / matching / complete), files seen, throughput, and ETA while the multi-minute walk runs
- **DJ Set view + `build_dj_set` tool** — pick a duration, start/end BPM, and an energy curve (`flat`, `ramp_up`, `ramp_down`, `peak`, `valley`) and RoonSage emits a Camelot-compatible playlist with smooth tempo transitions
- **Filter by feature** — `filter_tracks_by_audio` slices by BPM window, Camelot keys, energy/valence/danceability/instrumentalness, with the same `session_id` shape as `filter_tracks`
- Config: `AUDIO_FEATURES_ENABLED`, `AUDIO_FEATURES_FULL`, `MUSIC_LIBRARY_PATH`, optional `MUSIC_PATH_MAP_FROM` / `MUSIC_PATH_MAP_TO` for Roon-path → container-path remapping. The Docker image ships `librosa` + `libchromaprint-tools` and mounts `NUMBA_CACHE_DIR=/app/data/.numba_cache` for the JIT cache

### Notifications

Event-driven notifications sent to Discord, Telegram, and/or a custom webhook:

- **Discord** — POST to a webhook URL (Server Settings → Integrations → Webhooks)
- **Telegram** — Bot token + chat ID via @BotFather
- **Generic webhook** — any HTTP endpoint accepting POST JSON

Configurable `enabled_events`:

| Event | Fires when… |
|-------|-------------|
| `playlist_generated` | A playlist is generated via the web UI or scheduler |
| `library_sync_complete` | Library sync finishes |
| `library_sync_failed` | Library sync fails |
| `lb_sync_complete` | ListenBrainz sync completes |
| `new_release_found` | Watchlist scan finds a new release |
| `listening_milestone` | Listening milestone reached |

### Mobile & PWA

- Fully responsive layout for phones and tablets
- `frontend/manifest.json` enables "Add to Home Screen" on iOS and Android
- SVG app icons at 192 × 192 and 512 × 512

### Qobuz Integration

Two independent Qobuz connection methods — no manual app_id configuration required:

1. **Qobuz via Roon Browse API** — Used for search and playback. RoonSage navigates Roon's Browse hierarchy (Root → Qobuz → Search) to find and play Qobuz tracks. Requires Qobuz subscription in Roon. Detected automatically at startup.

2. **Qobuz direct API** — Used for playlist save and management. Connects directly to `https://www.qobuz.com/api.json/0.2/`. The `app_id` is auto-detected by trying known working IDs (LMS plugin, QobuzDL, streamrip) with a fallback to web player extraction. Requires `QOBUZ_EMAIL` + `QOBUZ_PASSWORD`.

**Synthetic key fix (v4.9):** Qobuz global-search item keys are ephemeral session keys that expire after any subsequent browse call. RoonSage generates a stable synthetic key `qobuz_search::{artist}::{title}` for global-search results, then re-issues a fresh search at playback time — ensuring Qobuz tracks always play correctly regardless of time elapsed.

### LLM Providers

| Provider | Analysis model | Generation model | Context |
|----------|---------------|-----------------|---------|
| **Gemini** | `gemini-2.5-flash` | `gemini-2.5-flash-lite` | 1M tokens (~18k tracks) |
| **Anthropic** | `claude-sonnet-4-5` | `claude-haiku-4-5` | 200K tokens (~3.5k tracks) |
| **OpenAI** | `gpt-4.1` | `gpt-4.1-mini` | 128K tokens (~2.3k tracks) |
| **Ollama** | auto-detected | auto-detected | auto-detected |
| **Custom** | user-specified | user-specified | user-specified |

Gemini's 1M context allows sending ~18,000 filtered tracks to the AI in a single call — the largest supported context window. `smart_generation: true` uses the analysis model for both steps (higher quality, ~3–5× cost).

---

## Intelligence Layer

![My Taste](docs/images/screenshot-taste.png)

RoonSage builds a detailed taste profile from multiple data sources:

```mermaid
graph LR
    subgraph local["Local (Roon)"]
        L1("Listening history\nzone callbacks")
        L2("Genre junction table\nSQL-native")
        L3("Track metadata\nMusicBrainz / Last.fm")
    end

    subgraph lb["ListenBrainz"]
        B1("Top artists/recordings")
        B2("Genre heatmap by hour")
        B3("Era distribution")
        B4("Artist countries")
        B5("Similar users")
        B6("Loved / hated tracks")
    end

    subgraph lf["Last.fm"]
        F1("Top artists / tracks")
        F2("Community tags")
        F3("Similar artists")
        F4("Scrobble history")
    end

    TP[("Taste Profile\ntaste_profile.py")]

    local --> TP
    lb    --> TP
    lf    --> TP
```

### Taste profile structure (selected keys)

```python
{
  # Local Roon listening
  "genre_scores":         {"Jazz": 0.82, "Post-Rock": 0.71, ...},
  "decade_scores":        {"1990s": 0.68, "2000s": 0.55, ...},
  "top_artists":          ["Radiohead", "Miles Davis", ...],
  "top_albums":           [{"title": "...", "artist": "...", "plays": 12}, ...],
  "total_hours":          142.5,
  "peak_hour":            22,           # 10pm is peak listening hour
  "peak_day":             "friday",
  "recently_active":      ["Portishead", "Floating Points"],
  "artist_streaks":       {"Nick Cave": 7},
  "moods":                ["melancholic", "instrumental", "late-night"],
  "skip_signals":         ["upbeat pop", "christmas"],

  # ListenBrainz (lb_ prefix)
  "lb_genre_by_hour":     {"22": {"Jazz": 12, "Ambient": 8}},
  "lb_era_distribution":  {"1990s": 0.35, "2000s": 0.28},
  "lb_daily_heatmap":     {"mon": [0,0,2,...], "fri": [0,0,0,...,8,12]},
  "lb_artist_countries":  {"UK": 0.42, "US": 0.31},
  "lb_loved_recordings":  [{"artist": "...", "title": "..."}],
  "lb_similar_users":     ["user1", "user2"],
  "lb_top_artists":       [{"name": "Radiohead", "listen_count": 312}],

  # Last.fm (lf_ prefix)
  "lf_top_artists":       [{"name": "Portishead", "playcount": 187}],
  "lf_top_tracks":        [{"artist": "...", "title": "...", "playcount": 44}],
  "lf_tags":              ["trip-hop", "alternative", "post-rock"],
  "lf_similar_artists":   ["Massive Attack", "Tricky"],
}
```

Scrobbling is **dual** — every completed track is sent to both ListenBrainz and Last.fm simultaneously (when both are configured).

---

## ListenBrainz Integration

ListenBrainz provides community-sourced music intelligence that enriches the taste profile with listening patterns, track feedback, and similar-user discovery.

### Setup

1. Create a free account at [listenbrainz.org](https://listenbrainz.org)
2. Get your user token from [listenbrainz.org/profile](https://listenbrainz.org/profile)
3. Add to your config (or via the Settings UI):

```yaml
listenbrainz:
  token: "your-token-here"
  username: "your-username"
```

### What it provides

- **Scrobbling** — every completed Roon track is scrobbled in real time
- **Now playing** — current track sent on zone start
- **Stats sync** (every 6h) — genre heatmap, era distribution, daily listening patterns, artist countries, loved/hated tracks, similar users, top artists/recordings/releases
- **Recommendations** — `get_listenbrainz_recommendations` returns personalized suggestions from the LB recommendation engine
- **Feedback** — `submit_listen_feedback` lets Claude mark tracks as loved or hated

---

## Last.fm Integration

Last.fm adds a second scrobbling channel and provides community tags, similar artists, and listening stats that complement ListenBrainz.

### Setup

1. Create an API application at [last.fm/api/account/create](https://www.last.fm/api/account/create)
2. Add the API key and secret to your config (or via the Settings UI):

```yaml
lastfm:
  api_key: "your-api-key"
  api_secret: "your-api-secret"
  username: "your-username"
  # session_key is auto-saved after you complete auth in the Settings UI
  session_key: ""
```

3. Complete the OAuth flow in **Settings → Last.fm → Authenticate** — this generates and saves the session key.

### Auth flow

Last.fm uses a token-based OAuth-like flow:

1. `POST /api/intelligence/lastfm/auth/token` — requests an auth token and returns a Last.fm authorization URL
2. User opens the URL and grants access in their browser
3. `POST /api/intelligence/lastfm/auth/session` — exchanges the token for a persistent session key, saved to `config.user.yaml`

### What it provides

- **Scrobbling** — dual-scrobbles every completed Roon track alongside ListenBrainz
- **Now playing** — current track sent at zone start
- **Stats sync** (every 6h) — top artists, top tracks, community tags per artist/track, similar artists
- **Taste profile keys** — `lf_top_artists`, `lf_top_tracks`, `lf_tags`, `lf_similar_artists`

---

## Deployment

![Settings](docs/images/screenshot-settings.png)

### Docker (recommended)

```bash
git clone https://github.com/Georgemvp/roon-mediasage.git
cd roonsage
cp config.example.yaml config.yaml
# Edit config.yaml with your Roon host, LLM API key, etc.
docker-compose up -d
```

`docker-compose.yml` mounts `./data` for the SQLite database and user config so they persist across container restarts.

> **Note:** The Docker image includes `libchromaprint-tools` for AcoustID fingerprint verification. No extra install needed.

### Bare metal

```bash
git clone https://github.com/Georgemvp/roon-mediasage.git
cd roonsage
pip install -r requirements.txt
cp config.example.yaml config.yaml
uvicorn backend.main:app --reload --port 5765
```

### MCP server (local — not in Docker)

```bash
pip install "mcp[cli]" httpx
python3 scripts/install_mcp.py   # writes claude_desktop_config.json entry
```

The MCP server runs locally on your machine and connects to the RoonSage API over HTTP. Set `ROONSAGE_URL` if RoonSage is running on a different host (e.g. Synology NAS).

### First run

1. Open `http://localhost:5765` and follow the setup wizard
2. In Roon: **Settings → Extensions → Enable RoonSage**
3. Trigger **Library Sync** (takes 2–10 min for large libraries)
4. Start generating playlists

---

## Configuration

### Environment variables

| Variable | Description | Default |
|----------|-------------|---------|
| `ROON_HOST` | IP address of your Roon Core | _(required)_ |
| `ROON_PORT` | Roon Extension port | `9330` |
| `ROON_CORE_ID` | Roon Core unique ID (auto-saved after first auth) | — |
| `ROON_TOKEN` | Roon Extension token (auto-saved after auth) | — |
| `LLM_PROVIDER` | `anthropic`, `openai`, `gemini`, `ollama`, or `custom` | `gemini` |
| `ANTHROPIC_API_KEY` | Anthropic API key | — |
| `OPENAI_API_KEY` | OpenAI API key | — |
| `GEMINI_API_KEY` | Google Gemini API key | — |
| `OLLAMA_URL` | Ollama base URL | `http://localhost:11434` |
| `CUSTOM_LLM_URL` | Custom OpenAI-compatible endpoint URL | — |
| `CUSTOM_CONTEXT_WINDOW` | Context window size for custom provider | `32768` |
| `ROONSAGE_PASSWORD` | Optional HTTP Basic Auth password | _(disabled)_ |
| `QOBUZ_EMAIL` | Qobuz account email (for playlist save) | — |
| `QOBUZ_PASSWORD` | Qobuz account password (for playlist save) | — |
| `LISTENBRAINZ_TOKEN` | ListenBrainz user token | — |
| `LISTENBRAINZ_USERNAME` | ListenBrainz username | — |
| `LASTFM_API_KEY` | Last.fm API key | — |
| `LASTFM_API_SECRET` | Last.fm API secret | — |
| `LASTFM_SESSION_KEY` | Last.fm session key (auto-saved after OAuth) | — |
| `LASTFM_USERNAME` | Last.fm username | — |
| `DISCORD_WEBHOOK_URL` | Discord notification webhook URL | — |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token | — |
| `TELEGRAM_CHAT_ID` | Telegram chat ID | — |
| `WEBHOOK_URL` | Generic webhook URL (POST JSON) | — |
| `ACOUSTID_API_KEY` | AcoustID API key (free at acoustid.org) | — |
| `ACOUSTID_ENABLED` | Enable AcoustID verification | `false` |
| `ACOUSTID_AUTO_VERIFY_QOBUZ` | Auto-verify every Qobuz search result | `false` |
| `WATCHLIST_SCAN_INTERVAL_HOURS` | Watchlist background scan interval | `12` |

### config.yaml example

```yaml
roon:
  host: "192.168.1.x"
  port: 9330
  # core_id and token are auto-saved after first Roon authorization
  core_id: ""
  token: ""
  extension_id: "com.roonsage.roon"
  display_name: "RoonSage"

llm:
  provider: "gemini"
  # api_key can also be set via GEMINI_API_KEY / ANTHROPIC_API_KEY / OPENAI_API_KEY env var
  api_key: ""
  model_analysis: "gemini-2.5-flash"
  model_generation: "gemini-2.5-flash-lite"
  smart_generation: false

defaults:
  track_count: 25

listenbrainz:
  token: ""
  username: ""

lastfm:
  api_key: ""
  api_secret: ""
  session_key: ""       # auto-saved after OAuth — do not set manually
  username: ""

notifications:
  discord_webhook_url: ""
  telegram_bot_token: ""
  telegram_chat_id: ""
  webhook_url: ""
  enabled_events:
    - playlist_generated
    - library_sync_complete
    - new_release_found

acoustid:
  api_key: ""           # free key at https://acoustid.org/api-key
  enabled: false
  auto_verify_qobuz: false
```

---

## Project Structure

```
roonsage/
├── backend/
│   ├── main.py                  # FastAPI app, lifespan, router registration
│   ├── config.py                # Config loading (env > user YAML > base YAML)
│   ├── db.py                    # SQLite schema, migrations, connection helpers
│   ├── models.py                # Pydantic models for all API contracts
│   ├── dependencies.py          # Auth, rate limiting shared helpers
│   ├── version.py               # Git-tag based version detection
│   ├── roon_client.py           # Roon Extension client (roonapi wrapper)
│   ├── roon_connection.py       # WebSocket connection management
│   ├── roon_browse.py           # Browse API — sync, search, navigate hierarchy
│   ├── roon_playback.py         # Play Now / queue logic, synthetic key handling
│   ├── roon_intelligence.py     # Zone monitor, listening history, scrobble dispatch
│   ├── roon_search.py           # Library search helpers
│   ├── roon_utils.py            # Shared Roon Browse utilities
│   ├── library_cache.py         # SQLite cache queries and sync orchestration
│   ├── sync.py                  # Library sync worker
│   ├── tracks.py                # Track model helpers
│   ├── filter_sessions.py       # Server-side key_map session storage
│   ├── taste_profile.py         # Taste profile computation (local + LB + LF)
│   ├── analyzer.py              # Prompt → genre/decade filter analysis
│   ├── generator.py             # Track list → LLM → playlist generation
│   ├── recommender.py           # Album recommendation pipeline
│   ├── llm_client.py            # Multi-provider LLM client
│   ├── music_research.py        # Web research for album recommendations
│   ├── results.py               # Result history persistence
│   ├── qobuz_browser.py         # Qobuz search + playback via Roon Browse API
│   ├── qobuz_api.py             # Direct Qobuz API client (playlist save)
│   ├── discovery.py             # ★ Cache-powered discovery (zero LLM / API)
│   ├── templates.py             # ★ Playlist template engine
│   ├── watchlist.py             # ★ Artist watchlist + Qobuz release detection
│   ├── scheduler.py             # ★ Cron-based scheduled playlist runner
│   ├── automation_engine.py     # ★ Trigger-action workflow engine
│   ├── enrichment_worker.py     # ★ Background MusicBrainz + Last.fm enrichment
│   ├── musicbrainz_client.py    # ★ MusicBrainz API client
│   ├── acoustid_client.py       # ★ AcoustID fingerprint verification
│   ├── notifications.py         # ★ Event bus + Discord/Telegram/webhook dispatch
│   ├── listenbrainz_client.py   # ListenBrainz API client
│   ├── listenbrainz_sync.py     # ListenBrainz stats sync service
│   ├── lastfm_client.py         # ★ Last.fm API client
│   ├── lastfm_sync.py           # ★ Last.fm stats sync service
│   ├── audio_features/          # ★ Audio analysis subsystem
│   │   ├── analyzer.py          #    librosa-based BPM/key/energy extraction
│   │   ├── worker.py            #    Background asyncio worker (CONCURRENCY=4)
│   │   ├── path_resolver.py     #    Roon track → on-disk file index (single-flight)
│   │   ├── camelot.py           #    Musical key → Camelot wheel mapping
│   │   └── dj_generator.py      #    Beatmatched, harmonic DJ set builder
│   └── routes/
│       ├── library.py           # Library cache, sync, search, filter endpoints
│       ├── generate.py          # Playlist generation + analysis endpoints
│       ├── recommend.py         # Album recommendation pipeline endpoints
│       ├── roon.py              # Zones, queue, transport, art proxy, Qobuz search
│       ├── intelligence.py      # Taste profile, listening history, LB/LF endpoints
│       ├── setup.py             # Setup wizard + provider validation endpoints
│       ├── config_routes.py     # Config, health, Ollama endpoints
│       ├── results.py           # Result history endpoints
│       ├── qobuz_playlist.py    # Qobuz playlist save + favorites endpoints
│       ├── discovery.py         # ★ Discovery sections endpoints
│       ├── templates.py         # ★ Playlist template CRUD + generate endpoints
│       ├── watchlist.py         # ★ Artist watchlist endpoints
│       ├── scheduler.py         # ★ Scheduled playlist endpoints
│       ├── automations.py       # ★ Automation CRUD + run endpoints
│       ├── enrichment.py        # ★ Enrichment status + control endpoints
│       ├── verify.py            # ★ AcoustID verification endpoints
│       ├── audio_features.py    # ★ Audio features + DJ set endpoints
│       └── notifications.py     # ★ Notification config + history endpoints
├── frontend/
│   ├── index.html               # Single-page app shell
│   ├── style.css                # Dark theme (background #1a1a1a, amber #e5a00d)
│   ├── app.js                   # App bootstrap
│   ├── manifest.json            # ★ PWA manifest
│   ├── icon-192.svg             # ★ PWA icon 192×192
│   ├── icon-512.svg             # ★ PWA icon 512×512
│   └── modules/
│       ├── api.js               # HTTP client helpers
│       ├── state.js             # Global app state
│       ├── router.js            # Hash-based client routing
│       ├── ui.js                # Shared UI primitives
│       ├── utils.js             # Utility functions
│       ├── playlist.js          # Generate view
│       ├── templates.js         # Template picker
│       ├── recommend.js         # Album recommendation view
│       ├── library.js           # Filter view
│       ├── discovery.js         # ★ Discover view
│       ├── taste.js             # My Taste view (Chart.js)
│       ├── history.js           # Listening history view
│       ├── playlists.js         # Saved playlists view
│       ├── watchlist.js         # ★ Watchlist view
│       ├── automations.js       # ★ Automations view
│       ├── scheduler.js         # ★ Scheduled playlists view
│       ├── audio-features.js    # ★ Audio Features view (status + scan progress)
│       ├── dj-set.js            # ★ DJ Set builder view
│       ├── pwa.js               # ★ PWA install + service worker glue
│       ├── nowplaying.js        # Now Playing view
│       ├── instant-queue.js     # Instant queue controls
│       ├── focus.js             # Focus mode
│       ├── events.js            # Event bus (frontend)
│       ├── loading.js           # Loading states
│       └── setup-wizard.js      # Setup wizard
├── data/
│   ├── library_cache.db         # SQLite database (runtime — not in git)
│   ├── playlist_templates.yaml  # ★ Built-in playlist templates
│   └── user_templates.yaml      # ★ User-created templates
├── docs/
│   └── images/                  # Screenshots for README
├── tests/
│   └── test_*.py                # pytest tests
├── scripts/
│   └── install_mcp.py           # One-time MCP server setup script
├── mcp_server.py                # MCP server (62 tools, runs locally)
├── config.example.yaml          # Config template — copy to config.yaml
├── docker-compose.yml
├── Dockerfile
├── requirements.txt
└── system_prompt.md             # MCP system prompt (Claude Desktop context)
```

★ = Added in v7.0 or later

---

## API Reference

<details>
<summary><strong>Library</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/library/status` | Cache freshness, track count, needs-resync flag |
| `POST` | `/api/library/sync` | Trigger background library sync |
| `GET` | `/api/library/stats` | Live genre/decade stats |
| `GET` | `/api/library/stats/cached` | Cached genre/decade stats (instant) |
| `GET` | `/api/library/artist-albums` | Albums by artist from SQLite |
| `GET` | `/api/library/search` | Search tracks by name/artist/album |
| `POST` | `/api/library/filter` | Filter tracks by genre/decade/keywords |
| `POST` | `/api/filter/preview` | Preview filter results without returning tracks |
| `POST` | `/api/library/filter/session` | Store a key_map server-side, get session_id |
| `POST` | `/api/library/filter/curate` | Translate track numbers → item keys → play |
| `POST` | `/api/library/filter/validate` | Validate curated selection for quality |

</details>

<details>
<summary><strong>Discovery</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/discovery/sections` | All 4 discovery sections |
| `GET` | `/api/discovery/undiscovered-albums` | Albums by top artists with zero plays |
| `GET` | `/api/discovery/genre-explorer` | Genre breakdown with counts |

</details>

<details>
<summary><strong>Templates</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/templates` | List all templates |
| `GET` | `/api/templates/{template_id}` | Get a single template |
| `POST` | `/api/templates` | Create a user template |
| `DELETE` | `/api/templates/{template_id}` | Delete a user template |
| `POST` | `/api/templates/{template_id}/generate` | Generate playlist from template (SSE) |

</details>

<details>
<summary><strong>Generation & Recommendations</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/generate/stream` | AI playlist generation (SSE stream) |
| `POST` | `/api/analyze/prompt` | Prompt → filter mapping preview |
| `POST` | `/api/analyze/track` | Analyze a track for seed playlist |
| `GET` | `/api/albums/preview` | Preview album candidates for recommendation |
| `POST` | `/api/recommend/questions` | Recommendation Q&A — generate questions |
| `POST` | `/api/recommend/switch-mode` | Switch recommendation mode |
| `POST` | `/api/recommend/generate` | Generate recommendation answer |

</details>

<details>
<summary><strong>Roon Playback & Control</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/roon/zones` | List active Roon zones |
| `POST` | `/api/queue` | Play tracks (replaces queue) |
| `POST` | `/api/queue/append` | Append tracks to queue |
| `GET` | `/api/art/{item_key}` | Proxied album art from Roon |
| `GET` | `/api/external-art` | Proxied external cover art |
| `POST` | `/api/roon/transport` | Transport control (play/pause/next/etc.) |
| `POST` | `/api/roon/volume` | Volume control |
| `POST` | `/api/roon/transfer` | Transfer zone |
| `POST` | `/api/roon/group` | Zone grouping |
| `POST` | `/api/roon/radio` | Play radio station |
| `POST` | `/api/roon/playlists` | Browse and play Roon playlists |
| `POST` | `/api/roon/qobuz-search` | Qobuz catalog search via Roon Browse |
| `GET` | `/api/roon/tags` | List Roon library tags |
| `GET` | `/api/roon/browse-root` | Browse Roon root hierarchy |
| `GET` | `/api/roon/qobuz-browse-test` | Debug endpoint for Qobuz Browse path |

</details>

<details>
<summary><strong>Intelligence & Taste</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/taste/profile` | Taste profile |
| `POST` | `/api/taste/profile` | Update taste profile weights |
| `POST` | `/api/taste/event` | Record a taste event |
| `GET` | `/api/taste/events` | List taste events |
| `GET` | `/api/listening/history` | Recent listening history |
| `GET` | `/api/listening/stats` | Listening stats (play counts, genres) |
| `GET` | `/api/playlists/saved` | List saved playlists |
| `POST` | `/api/playlists/saved` | Save a playlist |
| `POST` | `/api/playlists/saved/from-session` | Save from a filter session |
| `PUT` | `/api/playlists/saved/{id}` | Update a saved playlist |
| `DELETE` | `/api/playlists/saved/{id}` | Delete a saved playlist |
| `GET` | `/api/playlists/saved/{id}/tracks` | Get tracks of a saved playlist |
| `POST` | `/api/playlists/modify` | Modify a saved playlist (add/remove/reorder) |
| `GET` | `/api/intelligence/listening-stats` | Extended listening stats |
| `GET` | `/api/intelligence/taste-profile/detailed` | Full taste profile incl. LB + LF data |
| `POST` | `/api/intelligence/listening-history/enrich` | Enrich history with genre/year data |

</details>

<details>
<summary><strong>ListenBrainz</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/intelligence/listenbrainz/sync` | Force LB stats sync |
| `GET` | `/api/intelligence/listenbrainz/status` | LB connection + last sync status |
| `GET` | `/api/intelligence/listenbrainz/recommendations` | LB personalized recommendations |

</details>

<details>
<summary><strong>Last.fm</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/intelligence/lastfm/status` | Last.fm connection + sync status |
| `POST` | `/api/intelligence/lastfm/auth/token` | Request auth token, returns authorization URL |
| `POST` | `/api/intelligence/lastfm/auth/session` | Exchange token for persistent session key |
| `POST` | `/api/intelligence/lastfm/sync` | Force Last.fm stats sync |

</details>

<details>
<summary><strong>Watchlist</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/watchlist` | List watched artists |
| `POST` | `/api/watchlist` | Add artist to watchlist |
| `PATCH` | `/api/watchlist/{artist_name}` | Update watchlist settings for an artist |
| `DELETE` | `/api/watchlist/{artist_name}` | Remove artist from watchlist |
| `POST` | `/api/watchlist/auto-populate` | Auto-populate from top LB/LF artists |
| `POST` | `/api/watchlist/scan` | Trigger immediate watchlist scan |
| `GET` | `/api/watchlist/new-releases` | List detected new releases |
| `POST` | `/api/watchlist/new-releases/{release_id}/dismiss` | Dismiss a new release |

</details>

<details>
<summary><strong>Scheduled Playlists</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/schedules` | List all scheduled playlists |
| `POST` | `/api/schedules` | Create a scheduled playlist |
| `GET` | `/api/schedules/{id}` | Get a single schedule |
| `PUT` | `/api/schedules/{id}` | Update a schedule |
| `DELETE` | `/api/schedules/{id}` | Delete a schedule |
| `POST` | `/api/schedules/{id}/run` | Run a schedule immediately |
| `PATCH` | `/api/schedules/{id}/toggle` | Enable or disable a schedule |

</details>

<details>
<summary><strong>Automations</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/automations/presets` | List automation presets |
| `GET` | `/api/automations/log` | Automation activity log |
| `GET` | `/api/automations` | List all automations |
| `POST` | `/api/automations` | Create an automation |
| `PUT` | `/api/automations/{id}` | Update an automation |
| `DELETE` | `/api/automations/{id}` | Delete an automation |
| `PATCH` | `/api/automations/{id}/toggle` | Enable or disable an automation |
| `POST` | `/api/automations/{id}/run` | Run an automation immediately |

</details>

<details>
<summary><strong>Metadata Enrichment</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/enrichment/status` | Queue size, completion %, source breakdown |
| `POST` | `/api/enrichment/start` | Start or resume enrichment worker |
| `POST` | `/api/enrichment/pause` | Pause the enrichment worker |
| `POST` | `/api/enrichment/resume` | Resume a paused worker |
| `GET` | `/api/enrichment/queue` | Show enrichment queue entries |

</details>

<details>
<summary><strong>AcoustID Verification</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/verify/track` | Fingerprint-verify a Qobuz track match |
| `GET` | `/api/verify/status` | AcoustID configuration status |

</details>

<details>
<summary><strong>Notifications</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/notifications/config` | Get notification channel config |
| `POST` | `/api/notifications/config` | Update notification config |
| `POST` | `/api/notifications/test` | Send a test notification |
| `GET` | `/api/notifications/history` | Notification delivery log |

</details>

<details>
<summary><strong>Qobuz</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/api/qobuz/playlist/save` | Save playlist to Qobuz account |
| `GET` | `/api/qobuz/save-status` | Check if Qobuz save is configured |
| `POST` | `/api/qobuz/validate` | Test Qobuz credentials |
| `POST` | `/api/qobuz/favorite/add` | Add track/album to Qobuz favorites |
| `POST` | `/api/qobuz/favorite/remove` | Remove from Qobuz favorites |
| `GET` | `/api/qobuz/favorites` | List Qobuz favorites |
| `GET` | `/api/qobuz/playlists` | List Qobuz playlists |
| `GET` | `/api/qobuz/playlist/{id}` | Get a Qobuz playlist |
| `PUT` | `/api/qobuz/playlist/{id}` | Update a Qobuz playlist |
| `DELETE` | `/api/qobuz/playlist/{id}` | Delete a Qobuz playlist |
| `GET` | `/api/qobuz/new-releases` | Browse Qobuz new releases |
| `POST` | `/api/qobuz/prepare-for-arc` | Prepare playlist for Roon ARC |

</details>

<details>
<summary><strong>Saved Playlists, Config & Health</strong></summary>

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/results` | Previously generated playlists/recs |
| `GET` | `/api/results/{id}` | Single result detail |
| `DELETE` | `/api/results/{id}` | Delete a result |
| `GET` | `/api/health` | Health check (used by Docker) |
| `GET` | `/api/config` | Current configuration |
| `POST` | `/api/config` | Update configuration |
| `GET` | `/api/ollama/status` | Ollama connection status |
| `GET` | `/api/ollama/models` | Available Ollama models |
| `GET` | `/api/ollama/model-info` | Current Ollama model context size |
| `GET` | `/api/setup/status` | Setup completion status |
| `POST` | `/api/setup/validate-roon` | Test Roon connection |
| `POST` | `/api/setup/validate-ai` | Test LLM API key |
| `POST` | `/api/setup/validate-listenbrainz` | Test ListenBrainz token |
| `POST` | `/api/setup/validate-lastfm` | Test Last.fm credentials |
| `POST` | `/api/setup/complete` | Mark setup as complete |

</details>

---

## Security

- **Optional HTTP Basic Auth** — set `ROONSAGE_PASSWORD` to enable. Exempt paths: `/api/health`, `/api/art/*`, `/api/external-art`.
- **Rate limiting** — LLM endpoints are limited to 30 requests/hour/IP to prevent abuse.
- **Local-only by default** — the backend binds to `0.0.0.0:5765`. Place behind a reverse proxy (nginx, Traefik) with TLS for remote access.
- **Non-root Docker user** — the container runs as UID 1000 (`roonsageappuser`).
- **Notification webhook URLs** are stored in `data/config.user.yaml` with `chmod 600` permissions.
- **Qobuz credentials** are stored in `config.user.yaml` (chmod 600), not in the Roon Extension token.

---

## Development

### Stack

- **Backend**: Python 3.11+, FastAPI, roonapi, anthropic, openai, google-genai, httpx, pydantic, uvicorn, rapidfuzz, unidecode, pyacoustid
- **Frontend**: Vanilla HTML/CSS/JS (no build step), Chart.js (CDN)
- **Config**: YAML + environment variables
- **Database**: SQLite (WAL mode) at `data/library_cache.db`

### Commands

```bash
# Install
pip install -r requirements.txt

# Development server
uvicorn backend.main:app --reload --port 5765

# Tests
pytest

# Lint
ruff check .

# Docker build
docker-compose up -d --build
```

### Code style

- **Python**: PEP 8, type hints throughout, Pydantic models for all API contracts
- **JavaScript**: ES6+, no framework, simple module pattern with a shared `state` object
- **CSS**: BEM-style naming, CSS custom properties for theming (`--color-bg`, `--color-accent`)

---

## Changelog

### v13.2 — Background AI enrichment system, trickle-mode scheduling, AI playlist descriptions

- **Background AI enrichment** — six continuous enrichment tasks powered by your local LLM (Ollama / custom). All tasks share a global `asyncio.Semaphore(1)` so Gemma 4 is never overloaded:
  - **Vibe & Context Tagging** — assigns 2–4 listening contexts + 1–2 mood labels to every library track (`track_vibes` table). Runs in trickle mode: one batch of 20 tracks every 90 s during the day, every 8 s at night.
  - **Lyrics Theme Extraction** — extracts themes, emotional arc and language from embedded lyrics (`track_lyrics_themes`). One batch of 5 tracks every 2 min / 15 s.
  - **Discovery AI Descriptions** — proactively generates taglines and descriptions for Deep Cuts, Forgotten Favorites and Genre Explorer. Cached in `discovery_descriptions`, refreshed every 24 h, shown immediately on the Discovery tab.
  - **Cluster AI Labels** — names and describes each sonic cluster automatically after a cluster run (`cluster_ai_labels`).
  - **Song Path Narratives** — writes a narrative about each computed Song Path on-demand, cached by path fingerprint (`song_path_narratives`).
  - **Template Suggestions** — proposes 3 new playlist templates weekly from listening patterns (`template_suggestions_cache`).
- **Background AI settings dashboard** — new unified control panel in Settings with an enable/disable toggle (persisted to `config.user.yaml`), live active-task widget with progress bar, and per-task status cards showing schedule, state badge and DB progress. Manual trigger buttons per task.
- **Notification enrichment** — background AI personalises notification messages with an AI-written summary + emoji for playlist, release and milestone events (5 s timeout; graceful fallback).
- **AI playlist descriptions** — after a playlist is saved, a fire-and-forget call generates a short description + tags stored in the `results` table (`ai_description`, `ai_tags`) and shown as the subtitle in the Playlists view.
- **Taste profile stat cards** improved: hours derived from LB scrobble count when more complete than local Roon-logged hours; top genre and peak hour chips populated from best available source.

### v13.1 — Sonic Fingerprint, Mood-aware Song Paths, Docker build fix

- **Sonic Fingerprint** — computes the user's musical DNA by averaging the normalised audio-feature profile of their top-played tracks and cosine-ranking the full library. Unplayed tracks are boosted for discovery. Radar chart visualisation (Chart.js). REST: `GET /api/sonic-fingerprint/profile`, `GET /api/sonic-fingerprint/recommendations`, `POST /api/sonic-fingerprint/play`. MCP tools: `get_sonic_fingerprint`, `play_sonic_fingerprint`. Frontend view with nav entry under "Library".
- **Mood-aware Song Paths** — optional `mood` parameter for `/api/song-path` and the `find_song_path` MCP tool. Eight moods defined in `data/mood_centroids.json` (calm, energetic, happy, melancholic, aggressive, dreamy, groovy, dark) bias the greedy walk and Dijkstra graph toward a mood centroid. Mood dropdown added to the Song Paths frontend.
- **Docker build** — split requirements into `requirements.txt` (core deps, compiled by uv) and `requirements-ml.txt` (torch/torchaudio CPU wheels + umap-learn, hdbscan, laion-clap, transformers). The builder stage installs them in two separate layers so Docker can cache the large ML layer independently.
- **Fix** — `sqlite3.Row` does not support `.get()`; fixed `AttributeError` in `backend/discovery.py` (`get_lb_top_releases_in_library`).

### v13.0 — Sonic Clustering, Music Map, Song Paths, Alchemy, CLAP, Lyrics Search

- **Sonic clustering** — UMAP + HDBSCAN over the audio-feature matrix. New `backend/audio_features/clustering.py`, single-row `cluster_runs` metadata table, and three columns added to `track_audio_features`: `cluster_id`, `x_2d`, `y_2d`. REST routes under `/api/clustering/*`.
- **Music Map** — canvas-based 2D scatter plot of the entire library, colored by cluster or genre, with pan/zoom/hover/click-to-play. Embeds the clustering panel as a side dock so triggering re-clustering refreshes the map. `frontend/modules/music-map.js` + `css/music-map.css`.
- **Song Paths** — find the smoothest sonic bridge between two tracks. Greedy nearest-neighbor walk biased toward the target *or* Dijkstra over a k-NN graph (`method="graph"`). `backend/audio_features/song_path.py`, `/api/song-path` + `/api/song-path/play`.
- **Song Alchemy** — vector arithmetic over audio features: `mean(add) − 0.5 × mean(subtract)`, then cosine-rank the library. UI shows a Chart.js radar comparing target vs. realized profile. `backend/audio_features/alchemy.py`, `/api/alchemy/mix` + `/api/alchemy/play`.
- **CLAP text-to-audio search** — laion-clap embeds the actual audio; natural-language queries are matched directly against those embeddings (no metadata involved). Disabled by default; opt-in via `CLAP_ENABLED=true`. Storage: `clap_embeddings` + `clap_runs`. `backend/audio_features/clap_search.py`, `/api/clap/*`.
- **Semantic lyrics search** — pulls embedded lyrics from MP3/FLAC/M4A tags via mutagen, embeds them with GTE-multilingual via `transformers`, and ranks queries by cosine similarity over the lyrics index. Disabled by default; opt-in via `LYRICS_SEARCH_ENABLED=true`. Storage: `lyrics_data` + `lyrics_embeddings` + `lyrics_runs`. `backend/lyrics/`, `/api/lyrics/*`.
- **12+ new MCP tools** — `run_clustering`, `get_clustering_summary`, `get_cluster_tracks`, `find_song_path`, `play_song_path`, `song_alchemy`, `play_alchemy`, `clap_search`, `clap_status`, `start_clap_analysis`, `lyrics_search`, `lyrics_status`, `start_lyrics_analysis`, `get_track_lyrics`.
- **5 new frontend views** — Music Map, Song Paths, Alchemy, CLAP Search, Lyrics Search — with nav entries under the "Library" sidebar section.
- **New dependencies** — `scikit-learn`, `umap-learn`, `hdbscan` (clustering); `laion-clap`, `transformers` (CLAP); `onnxruntime`, `tokenizers` (lyrics embedding stack). All are lazy-imported so the app still boots cleanly with the heavy models disabled.
- **Dockerfile** — pre-creates `/app/data/.clap_cache` and `/app/data/.hf_cache` with the right ownership, and exports `CLAP_CACHE_DIR` / `HF_HOME` / `TRANSFORMERS_CACHE` so the model downloads land on a persistent volume.
- **Tests** — `test_clustering.py`, `test_song_path.py`, `test_alchemy.py`, `test_clap_search.py`, `test_lyrics.py`; the ML-heavy ones use `pytest.importorskip` so they're inert when deps aren't installed.

### v12.0 — Audio Features, DJ Set Builder, PWA, 67 Tools (2026-05-22)

- **Audio feature analysis** — new `backend/audio_features/` subsystem extracts BPM, Camelot key, energy, danceability, valence, instrumentalness, acousticness per track via librosa. Worker drains `audio_features_queue` with `CONCURRENCY=4` (CPU-bound).
- **DJ set builder** — `build_dj_set` MCP tool + frontend view generate beatmatched, Camelot-compatible playlists with configurable BPM curves (`flat`, `ramp_up`, `ramp_down`, `peak`, `valley`).
- **Audio-feature filter** — `filter_tracks_by_audio` slices the library by BPM window, Camelot keys, energy/valence/danceability/instrumentalness; returns the same `session_id` shape as `filter_tracks`.
- **Path resolver** — single-flight scan of `MUSIC_LIBRARY_PATH`, maps Roon tracks → on-disk files via mutagen tags. UI shows live scan progress (phase + file count + ETA).
- **5 new MCP tools** for a total of **67** (was 62).
- **63 playlist templates** with category tabs in the UI (was ~30).
- **PWA** — installable on iOS / Android / desktop (manifest + service worker + SVG icons).
- **Taste profile everywhere** — `use_taste_profile` toggle wired into generate / recommend / templates / scheduler flows.
- **125 new tests** covering 7 previously untested subsystems; coverage gate ≥ 40 %.
- **Enrichment ~50× faster** via `ENRICHMENT_SKIP_MB=true` (Last.fm-only mode) + persistent dedup cache across batches.
- **Self-healing SQLite** — `repair_corrupt_indexes()` at startup runs `PRAGMA integrity_check` and REINDEXes affected tables (fixes uvicorn-reload corruption). Orphaned `processing` / `analyzing` rows are reset to `pending`.
- **`NUMBA_CACHE_DIR` + `MPLCONFIGDIR`** mapped inside the container so librosa's JIT can cache.
- **Sync fixes** — track→album matching uses `(title, artist)` (then title-only) instead of fragile `item_key`; exact title match (not `LOWER()`) for album enrichment; track-number prefix stripped + navigation items filtered in album browse.
- **Discovery / polling / retries / watchlist** tuned — smaller fan-out, normalized back-off, lighter watchlist scan.
- **Frontend cleanup** — `closeBottomSheet` on `window`; raw `fetch` calls migrated to `apiCall`.
- New `.env.example`, `CONTRIBUTING.md`, and `CHANGELOG.md` at repo root; GitHub issue templates added.

### v11.5 — AcoustID Verification (2026-05-20)

- New module `backend/acoustid_client.py`: audio fingerprinting via the free AcoustID service and `pyacoustid`/`libchromaprint`.
- New endpoint `POST /api/verify/track`: fingerprint a local library track, resolve its MusicBrainz recording ID, and compare against a Qobuz search result's MBID — catches wrong versions (live vs. studio, remix vs. original, wrong-decade remaster) before playback.
- New endpoint `GET /api/verify/status`: check AcoustID configuration.
- Optional `auto_verify_qobuz` mode automatically verifies every Qobuz search result.
- New MCP tool `verify_track_match`.
- Docker image now includes `libchromaprint-tools`.
- Config: `ACOUSTID_API_KEY`, `ACOUSTID_ENABLED`, `ACOUSTID_AUTO_VERIFY_QOBUZ`.

### v11.0 — Automation Engine (2026-05-20)

- New module `backend/automation_engine.py`: trigger-action workflow system with `TriggerType` and `ActionType` enums.
- **Triggers**: `schedule`, `track_played`, `zone_started`, `library_synced`, `lb_synced`, `watchlist_match`.
- **Actions**: `generate_playlist`, `play_template`, `sync_library`, `sync_listenbrainz`, `scan_watchlist`, `send_notification`, `run_maintenance`, `volume_set`.
- New SQLite tables: `automations`, `automation_log`.
- New routes `backend/routes/automations.py`: full CRUD + toggle + manual run + presets + activity log.
- Frontend Automations view with preset picker and live activity log.
- New MCP tools: `list_automations`, `create_automation`, `toggle_automation`.
- Cooldown protection (configurable, default 300s) prevents double-firing.

### v10.0 — Metadata Enrichment Pipeline (2026-05-20)

- New modules: `backend/enrichment_worker.py`, `backend/musicbrainz_client.py`.
- Background worker enriches every library track with MusicBrainz (MBID, release date, country, genre tags) and Last.fm (listener count, play count, community tags).
- New SQLite tables: `track_metadata_ext`, `enrichment_queue`.
- New routes `backend/routes/enrichment.py`: status, start, pause, resume, queue.
- Worker auto-starts at startup, processes pending tracks from the enrichment queue.
- New MCP tools: `get_enrichment_status`, `start_enrichment`.

### v9.0 — Scheduled Playlist Regeneration (2026-05-20)

- New module `backend/scheduler.py`: cron-expression-based playlist scheduler (checks every 60 seconds, double-run protection within 55s).
- Scheduled playlists can queue directly to a Roon zone and/or save to a Qobuz playlist.
- New SQLite table: `scheduled_playlists`.
- New routes `backend/routes/scheduler.py`: full CRUD + manual run + toggle.
- New MCP tools: `list_scheduled_playlists`, `create_scheduled_playlist`, `run_scheduled_playlist`.
- Frontend Settings view extended with Scheduled Playlists management.

### v8.0 — Artist Watchlist + Qobuz Release Detection (2026-05-19)

- New module `backend/watchlist.py`: monitors watched artists for new Qobuz releases via the Roon Browse API.
- New SQLite tables: `artist_watchlist`, `artist_releases_cache`.
- Background scan every 12 hours (configurable via `WATCHLIST_SCAN_INTERVAL_HOURS`).
- Auto-populate watchlist from top ListenBrainz/Last.fm artists.
- Notifications fired on `watchlist_match` events (Discord/Telegram/webhook).
- New routes `backend/routes/watchlist.py`: list, add, update, delete, auto-populate, scan, new-releases, dismiss.
- New MCP tools: `get_watchlist`, `add_to_watchlist`, `scan_watchlist`, `play_new_release`.
- Frontend Watchlist view.

### v7.0 — Discovery · Last.fm · Notifications · Templates · PWA · Chart.js (2026-05-19/20)

**Cache-Powered Discovery:**
- New module `backend/discovery.py`: four SQL-only discovery sections (undiscovered albums, deep cuts, forgotten favorites, genre explorer).
- New MCP tool `get_discovery_sections`. Frontend Discover view.

**Last.fm Integration:**
- New modules: `backend/lastfm_client.py`, `backend/lastfm_sync.py`.
- Dual-scrobbling: every completed Roon track sent to both ListenBrainz and Last.fm simultaneously.
- OAuth token-based auth flow with auto-saved session key.
- Stats sync every 6h: top artists, top tracks, community tags, similar artists.
- Taste profile extended with `lf_` keys.
- New endpoints: Last.fm auth token, auth session, sync, status.
- Config: `LASTFM_API_KEY`, `LASTFM_API_SECRET`, `LASTFM_SESSION_KEY`, `LASTFM_USERNAME`.

**Notifications:**
- New module `backend/notifications.py`: event bus dispatching to Discord webhook, Telegram bot, and generic webhook.
- New routes `backend/routes/notifications.py`: config, test, history.
- Config: `DISCORD_WEBHOOK_URL`, `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, `WEBHOOK_URL`.

**Playlist Templates:**
- New module `backend/templates.py`: template engine with built-in (`data/playlist_templates.yaml`) and user templates (`data/user_templates.yaml`).
- New routes `backend/routes/templates.py`.
- New MCP tools: `list_playlist_templates`, `generate_from_template`.
- Frontend Generate view extended with one-click template picker.

**Chart.js My Taste + Mobile PWA:**
- My Taste view rebuilt with Chart.js bar charts, era charts, and 7×24 listening heatmap; time range filters.
- `frontend/manifest.json` + SVG icons — installable PWA on iOS and Android.
- Fully responsive layout for mobile browsers.

### v6.0 — ListenBrainz Integration (2026-05-19)

- New modules: `backend/listenbrainz_client.py`, `backend/listenbrainz_sync.py`.
- Real-time scrobbling and now-playing notifications.
- Stats sync every 6h: genre heatmap, era distribution, daily heatmap, artist countries, loved/hated tracks, similar users, top artists/recordings/releases.
- New SQLite table: `lb_stats_cache`.
- `taste_profile.py` extended with decade scores, listening patterns, full LB data integration.
- New endpoints: `/api/intelligence/listening-stats`, `/api/intelligence/taste-profile/detailed`, `/api/intelligence/listenbrainz/*`.
- New MCP tools: `get_listening_stats`, `get_listenbrainz_recommendations`, `submit_listen_feedback`, `sync_listenbrainz`.
- Frontend My Taste view: LB status card, bar charts, heatmap, loved tracks.
- Config: `LISTENBRAINZ_TOKEN`, `LISTENBRAINZ_USERNAME`.

### Earlier versions

For changes prior to v6.0 (Qobuz integration, Claude-native curation, filter-first approach, track-number matching, genre junction table, MCP server, Docker support), see the [git log](https://github.com/Georgemvp/roon-mediasage/commits/main).

---

## Credits

- [Roon Labs](https://roon.app) for the Extension API and Browse API
- [roonapi](https://github.com/pavoni/pyroon) Python binding by pavoni
- [ListenBrainz](https://listenbrainz.org) for open music listening data
- [Last.fm](https://www.last.fm) for music intelligence and community tags
- [MusicBrainz](https://musicbrainz.org) for open music metadata
- [AcoustID](https://acoustid.org) for audio fingerprinting
- [Qobuz](https://www.qobuz.com) for lossless streaming catalog
- [FastAPI](https://fastapi.tiangolo.com), [Pydantic](https://pydantic.dev), [httpx](https://www.python-httpx.org)
- [Chart.js](https://www.chartjs.org) for My Taste visualizations
