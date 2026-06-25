# RoonSage Setup & Features Guide

**Complete installation instructions, configuration, and feature overview for macOS, iOS, the audio analyzer, and Claude Desktop.**

- [Quick Start](#quick-start)
- [System Requirements](#system-requirements)
- [RoonSage Analyzer (the server)](#roonsage-analyzer-the-server)
- [macOS App (client)](#macos-app-client)
- [iOS App (client)](#ios-app-client)
- [Architecture: Server & Clients](#architecture-server--clients)
- [Audio Analysis & Features](#audio-analysis--features)
- [Claude Desktop Integration (MCP)](#claude-desktop-integration-mcp)
- [Optional Services](#optional-services)
- [Features Deep-Dive](#features-deep-dive)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

RoonSage has two parts:

1. **RoonSage Analyzer** (the server — runs once, stays on)
   - Connects to your Roon Core as an extension
   - Syncs your library to a local database
   - Serves everything over HTTP (library, playback, audio features)
   - Must be installed on an always-on Mac (or Mac Mini near your Roon Core)

2. **RoonSage app** (the client — any Mac or iPhone)
   - Remote control for your library and playback
   - Connects to the Analyzer via HTTP
   - Cannot connect to Roon directly

**Setup in 3 minutes:**

1. Download **RoonSageAnalyzerApp-x.y.z.dmg** from [Releases](https://github.com/Georgemvp/roonsage/releases)
2. Drag to Applications, launch, point it at your music library folder
3. It syncs your Roon library and starts serving (port 5767 for library, 5766 for features)
4. Install the **RoonSage macOS app** or **iOS app** on any device
5. They auto-discover the Analyzer and you're done

---

## System Requirements

### RoonSage Analyzer (server — required)
- **macOS 14 (Sonoma)** or later
- **Always-on machine** (Mac Mini recommended, near your Roon Core for stability)
- **Roon Core** (version 1.8+) on the same network
- **Music library** on disk (FLAC, MP3, M4A; optional for audio analysis)
- ~5–15 minutes per 1000 tracks for initial audio feature extraction

### macOS App (client)
- **macOS 14 (Sonoma)** or later
- **RoonSage Analyzer running** somewhere on your network (or the same Mac)
- Internet connection (for LLM, Qobuz, scrobbling; not required for library browsing)

### iOS App (client)
- **iOS/iPadOS 17** or later
- **RoonSage Analyzer running** on your network (same WiFi, or via ZeroTier from outside)
- Optional: **ZeroTier** (free peer-to-peer VPN) for remote access

---

## RoonSage Analyzer (the server)

The **RoonSage Analyzer** is the core of RoonSage. It:

- **Registers as a Roon extension** — only one Roon extension per network, so the Analyzer owns this slot
- **Syncs your library** — walks the Roon browse hierarchy, stores everything locally
- **Serves HTTP on port 5767** — library, settings, playback state, and a playback command proxy (so clients can control Roon)
- **Extracts audio features** — analyzes BPM, musical key, and CLAP embeddings from your music files; serves via HTTP :5766
- **Scrobbles to Last.fm / ListenBrainz** — captures plays in real-time
- **Generates AI playlists** — receives LLM requests from clients

The macOS and iOS apps are **remote clients** that talk to the Analyzer over HTTP. They cannot function without it.

### Installation

1. **Download** `RoonSageAnalyzerApp-x.y.z.dmg` from [Releases](https://github.com/Georgemvp/roonsage/releases)
2. **Mount the DMG** and drag `RoonSageAnalyzerApp.app` to `/Applications`
3. **Launch** from Applications or Spotlight
4. Grant **Notifications permission** if prompted
5. The app shows a **Settings** tab — configure:
   - **Music folder path** — where your FLAC/MP3/M4A files are (e.g. `/Volumes/Music`)
   - **Other integrations** — Qobuz, Last.fm, LLM provider (optional)

If you see a security warning:
- Right-click → Open → Open
- Or System Settings → Privacy & Security → allow RoonSageAnalyzerApp

### First Run: Roon Authorization

When you first launch the Analyzer:

1. It searches for your Roon Core on the network (via UDP multicast)
2. It discovers and shows "Roon found at `192.168.1.x:9330`"
3. Click **"Authorize"** — the Roon authorization flow opens in a browser
4. In Roon, **allow RoonSage** as an extension
5. The Analyzer registers and starts syncing your library

Once synced (5–10 minutes for a typical library), the Analyzer is ready to serve clients.

**If Roon isn't discovered:**
- Verify Roon Core is running and on the same network
- Check that your network/firewall allows UDP multicast (port 23017)
- In the Analyzer's Advanced Settings, manually enter Roon Core IP + port (default `9330`)

### Audio Analysis (optional)

The Analyzer can walk your music library and extract:
- **BPM** (tempo, in beats per minute)
- **Camelot key** (musical key mapped to the DJ wheel)
- **CLAP embeddings** (512-dimensional sonic fingerprints)

This takes time (5–15 minutes per 1000 tracks) and is **optional**:
- **Without it**: library browsing, generation, and playback work fine. Sonic features (Music Map, Song Paths, Sonic Search) are disabled.
- **With it**: the Analyzer runs the audio analysis in the background or on-demand. Results are cached and served via HTTP `:5766`.

To enable analysis:
- Set **Music folder path** in the Analyzer settings
- The Analyzer automatically starts analyzing on launch if auto-start is enabled
- Or manually click **"Analyze"** to scan the folder

The Analyzer resumes from where it left off if interrupted (analysis is resumable).

---

## macOS App (client)

The **RoonSage macOS app** is a remote control for the Analyzer. It:
- Displays your full synced library (tracks, albums, artists)
- Shows live playback state and lets you control zones
- Sends all commands through the Analyzer to Roon
- Does NOT connect to Roon directly

### Installation

1. **Download** `RoonSage-x.y.z.dmg` from [Releases](https://github.com/Georgemvp/roonsage/releases)
2. **Drag to Applications**
3. **Launch** and grant Notifications permission
4. The app auto-discovers the Analyzer (via Bonjour multicast on your local network)

The app is **signed and notarized**. If you see a security warning:
- Right-click → Open → Open
- Or System Settings → Privacy & Security → allow RoonSage

### Connecting to the Analyzer

**On the same network (home WiFi):**
- The app auto-discovers the Analyzer via Bonjour
- Wait a few seconds; it should show "Connected" and list your zones

**On a different network (e.g. office, on cellular):**
- You need **ZeroTier** (free peer-to-peer VPN at [zerotier.com](https://zerotier.com))
- Install ZeroTier on both the Analyzer Mac and your Mac
- Join the same ZeroTier network on both
- In the macOS app Settings, enter the Analyzer's ZeroTier IP (e.g. `192.168.192.x`)
- The app then proxies commands through the VPN

**Manual IP entry:**
- If Bonjour doesn't work, go to Settings and manually enter the Analyzer's IP + port (default `5767`)

### Features in the macOS app

- **Library browser** — track list, albums, artists; full-text search
- **Now Playing** — large artwork, transport controls, zone switcher
- **Generate playlists** — describe a mood; LLM analyzes and picks tracks
- **Taste profile** — top artists, genres, listening heatmap
- **DJ tools** — beatmatched sets with Camelot harmony (if analyzer is running)
- **Scrobble history** — what you've played (if Last.fm/ListenBrainz is set up)
- **Auto-updates** — check for app updates via menu bar

---

## iOS App (client)

The **RoonSage iOS app** is a remote control for the Analyzer on your iPhone or iPad.

### Installation

**TestFlight beta:**
- Look for the TestFlight link in [Releases](https://github.com/Georgemvp/roonsage/releases)
- Tap the link and join the beta

**Or build from source:**
```bash
cd native/iosapp
xcodegen generate
open RoonSageiOS.xcodeproj
# Build and run in Xcode
```

### Connecting

**On your home WiFi:**
- The app auto-discovers the Analyzer via Bonjour
- You see zones and live playback

**Outside your network (cellular, different WiFi):**
1. Install **ZeroTier** on your iPhone (free app) and your Analyzer Mac
2. Join the same ZeroTier network on both
3. In iOS app Settings, enter the Analyzer's ZeroTier IP
4. Commands proxy through the VPN

### iOS Features

- **Lock Screen & Control Center** — play/pause/next from lock screen
- **Dynamic Island** (iPhone 14 Pro+) — currently playing track
- **Siri** — "Hey Siri, play next" works
- **Live Activities** — upcoming tracks and album art
- **Full library browser** — all the same features as the macOS app

---

## Architecture: Server & Clients

```
Your Network
┌──────────────────────────────────────────────────────┐
│                                                      │
│  Roon Core (9330)                                    │
│       ▼ (Roon Extension API)                         │
│  ┌─────────────────────────────────────────────────┐ │
│  │ RoonSage Analyzer App                           │ │
│  │ (always-on server — e.g. Mac Mini)              │ │
│  │                                                 │ │
│  │ ├─ Roon WebSocket connection (direct)           │ │
│  │ ├─ LibraryShareServer (:5767)                   │ │
│  │ │   └─ /library, /playback, /command, /settings │ │
│  │ └─ Audio Features Server (:5766)                │ │
│  │     └─ /features, /embeddings, /text-embed      │ │
│  └─────────────────────────────────────────────────┘ │
│                                                      │
└──────────────────────────────────────────────────────┘

┌─ Any Device ──────────────────────────────┐
│  RoonSage macOS or iOS App                │
│  HTTP client mode                         │
│                                           │
│  Talks to :5767 (library/playback proxy)  │
│  No Roon extension on this device         │
└───────────────────────────────────────────┘
```

**Why this design:**

1. **Only one Roon extension per network** — the Analyzer permanently holds this slot
2. **One source of truth** — the Analyzer syncs once, then all clients read the same data
3. **Remote clients anywhere** — any Mac or iPhone can browse your library via HTTP
4. **Always-on guarantee** — the server stays connected to Roon, so scrobbles/notifications are captured even when clients are off

**Control flow:**

1. macOS/iOS app: user taps "Play"
2. App sends HTTP POST `/command` to the Analyzer (with action="playPause", zoneID, etc.)
3. Analyzer's RoonClient receives the command and sends it to Roon via WebSocket
4. Roon plays the track; the Analyzer relays zone state updates back to the app via `/playback` polls

---

## Audio Analysis & Features

The Analyzer can extract audio features from your music files. This is **optional** and takes time.

### What gets analyzed

- **BPM** (tempo)
- **Camelot key** (musical key as a DJ wheel position)
- **CLAP embeddings** (512-dimensional vectors representing the "sound" of each track)

These power:
- **Music Map** — 2D scatter plot of your library (X/Y = sound similarity, color = key)
- **Song Paths** — find the smoothest sonic bridge between two tracks
- **Sonic Search** — "dreamy ambient" → search by sound, not metadata
- **DJ Set builder** — beatmatched sets with harmonic (Camelot) transitions
- **Sonic Fingerprint** — your musical DNA (radar chart of your taste)

### How to run analysis

**In the Analyzer app (easiest):**
1. Settings → Music folder path → choose your music directory
2. Click "Analyze" (or let auto-start do it on next launch)
3. Progress bar shows analysis status
4. Takes 5–15 minutes per 1000 tracks

**From the CLI:**
```bash
roonsage-analyzer analyze /Volumes/Music --workers 4
roonsage-analyzer serve --port 5766   # then serve the results
```

### Data storage

- **Library database**: `~/Library/Application Support/RoonSage/library.db` (GRDB)
- **Analyzer database**: `~/Library/Application Support/RoonSage/analyzer_features.db` (audio features)
- **CLAP model cache**: `~/Library/Application Support/RoonSage/.hf_cache` (Core ML embeddings model, ~600 MB)

All stays on your machine.

---

## Claude Desktop Integration (MCP)

**MCP** (Model Context Protocol) lets Claude Desktop control RoonSage via natural language.

### Setup

1. **Build the MCP server**:
   ```bash
   cd native && swift build -c release --product roonsage-mcp
   ```

2. **Install to your system**:
   ```bash
   mkdir -p ~/.local/bin
   cp .build/release/roonsage-mcp ~/.local/bin/
   chmod +x ~/.local/bin/roonsage-mcp
   ```

3. **Configure Claude Desktop**:
   - Open `~/Library/Application Support/Claude/claude_desktop_config.json`
   - Add:
     ```json
     {
       "mcpServers": {
         "roonsage": {
           "command": "~/.local/bin/roonsage-mcp",
           "env": {
             "ROONSAGE_SERVER_URL": "http://192.168.1.x:5767"
           }
         }
       }
     }
     ```
   - Replace `192.168.1.x` with your Analyzer's IP
   - Restart Claude Desktop

4. **Test**: In Claude, ask "What's in my library?" or "Generate an upbeat 80s funk playlist"

### Available tools

~30 tools for:
- **Playback**: play/pause, next/prev, volume, shuffle, zone transfer
- **Search**: library filter, Qobuz search
- **Generation**: AI playlist generation, album recommendations
- **Intelligence**: taste profile, listening history, top artists
- **Control**: list zones, now playing, queue

---

## Optional Services

These unlock extra features but RoonSage works fine without them.

### Qobuz
- **Enables**: search Qobuz when your library is missing a track; save playlists to Qobuz
- **Setup**: Qobuz email + password in Analyzer Settings

### ListenBrainz
- **Enables**: scrobble plays to the open-source ListenBrainz database
- **Setup**: create account at [listenbrainz.org](https://listenbrainz.org), copy your API token, paste in Analyzer Settings

### Last.fm
- **Enables**: scrobble to Last.fm; Last.fm tags appear in track metadata
- **Setup**: create account at [last.fm](https://last.fm), authorize RoonSage, enter your username in Analyzer Settings

### LLM Provider
- **Default**: Anthropic (Claude)
- **Alternatives**: OpenAI, Ollama (local), or any OpenAI-compatible endpoint
- **Setup**: API key in Analyzer Settings

---

## Features Deep-Dive

### Library & Playback

**Browse**
- Track list, albums, artists; drill-down from album/artist
- Full-text search (title, artist, album)
- Filter by genre, decade, keywords, live/studio
- Sort by title, artist, play count

**Now Playing**
- Full-bleed album artwork with dominant-color tinting
- Transport: play/pause, scrub, next/prev
- Zone switcher (move playback between rooms)
- Queue preview
- Lock screen / Control Center controls (iOS)

### AI Curation

**Generate**
- Describe a mood: "upbeat 80s funk", "mellow ambient"
- LLM analyzes intent, picks 15–50 tracks from your library
- Auto-generates a playlist title + description
- Save or play immediately

**Ask**
- One-liner vibe: "something to cook to"
- Instantly playable results

**Recommend**
- Album recommendations based on your taste
- Grounded in your library (not hallucinated)

### Sonic Intelligence (requires audio analysis)

**Sonic Fingerprint**
- Radar chart of your musical DNA
- Based on your top-played tracks
- Recommendations ranked by sound similarity

**Music Map**
- 2D scatter plot of every analyzed track
- X/Y = sound similarity, Color = Camelot key
- Tap to play any track

**Sonic Search**
- "Dreamy ambient piano", "funky bass grooves"
- Matches against embeddings, not metadata

**Song Paths**
- Smoothest sonic bridge between two tracks
- Nearest-neighbor walk + optional mood bias

**Song Alchemy**
- Vector math: add/subtract tracks to blend sounds
- "Like Track A but more energetic?"

**Sonic Radio**
- Endless artist-seeded stations (Roon library)
- AI artist radios (auto-refreshed Qobuz playlists)

### DJ Tools (requires audio analysis)

**DJ Set**
- Beatmatched sets with BPM curve + energy arc
- Harmonic transitions via Camelot wheel
- Export as M3U or tracklist

**Live DJ**
- For now-playing track, suggest harmonically-compatible next tracks

### Taste Profile & Scrobbling

**Taste Profile**
- Top artists, genres, tags
- Listening heatmap (when you listen)
- Combined from local history + Last.fm + ListenBrainz

**Scrobble**
- Automatic to Last.fm / ListenBrainz
- Captures plays in real-time

---

## Configuration

### Analyzer Settings

| Setting | What it does |
|---------|-------------|
| **Music folder** | Path to your music library (FLAC/MP3/M4A) for analysis |
| **Roon Core IP** | Auto-discovered; manual entry for different networks |
| **Auto-start analysis** | Start analyzing on launch |
| **LLM Provider** | Anthropic (default), OpenAI, Ollama, or custom URL |
| **Qobuz email/password** | For Qobuz search and playlist export |
| **Last.fm username** | For scrobbling + tags |
| **ListenBrainz token** | For scrobbling |
| **Analysis workers** | CPU threads for BPM/key extraction |
| **CLAP embeddings** | Enable/disable 512-dim sonic fingerprints (slower, richer features) |

### macOS/iOS Client Settings

| Setting | What it does |
|---------|-------------|
| **Analyzer IP** | Auto-discovered via Bonjour; manual entry for different networks |
| **ZeroTier IP** | For remote access via ZeroTier VPN |
| **Theme** | Dark / Light / System |
| **Accent color** | Override the default gold |

---

## Troubleshooting

### Analyzer won't connect to Roon

**Problem**: "Roon not found" in the Analyzer.

**Solutions**:
1. Verify Roon Core is running on the same network
2. Check firewall allows UDP port 23017 (Roon discovery)
3. Try wired Ethernet on the Analyzer (more reliable)
4. In Analyzer Settings, manually enter Roon Core IP + port (default `9330`)
5. Restart both Analyzer and Roon

### macOS/iOS app can't connect to Analyzer

**Problem**: App says "Analyzer not found" or "Connection failed".

**Solutions**:
1. Verify Analyzer is running and Roon is connected (check Analyzer window)
2. Both on same WiFi? → Wait a few seconds; Bonjour discovery takes time
3. Different networks? → Set up ZeroTier on both devices and enter ZeroTier IP in app Settings
4. Check firewall on Analyzer Mac: System Settings → Firewall → allow "RoonSageAnalyzerApp"
5. Find Analyzer's IP: System Preferences → Network → copy IP, enter manually in app Settings

### Audio features not working

**Problem**: Music Map, Song Paths, Sonic Search are grayed out.

**Solutions**:
1. Is Analyzer running? → Check Analyzer app window
2. Is analysis done? → Wait for progress bar to finish
3. Did you set a music folder? → Analyzer Settings → Music folder path
4. Did you click "Analyze"? → Click it, wait for progress
5. Restart both Analyzer and the client app

### Analysis is very slow

**Problem**: Analyzing 1000 tracks takes an hour+.

**Solutions**:
1. Check Activity Monitor → Disk I/O; analysis is CPU + disk intensive
2. FLAC files are slower than MP3; library format affects speed
3. Reduce workers: Analyzer Settings → Analysis workers → fewer threads
4. Let it run overnight; it's resumable and will complete eventually

### Playback timeout on large playlists

**Problem**: Curating 50+ tracks times out before playback starts.

**Solutions**:
1. This is expected for very large queues (Roon queues slowly)
2. Curate fewer tracks (25–40) per batch
3. Or increase Roon queue timeout in Analyzer Settings

### Scrobbling not working

**Problem**: Last.fm or ListenBrainz shows "not scrobbling".

**Solutions**:
1. Check API key / username is correct in Analyzer Settings
2. Verify track has both artist and title (required)
3. Check internet connection
4. Refresh credentials: clear and re-paste the token/username in Settings

---

## Need Help?

- **Docs**: [README.md](README.md), [ROADMAP.md](native/ROADMAP.md), [Architecture Audit](docs/NATIVE_APP_AUDIT.md)
- **Issues**: [GitHub Issues](https://github.com/Georgemvp/roonsage/issues)
- **Discussions**: [GitHub Discussions](https://github.com/Georgemvp/roonsage/discussions)

