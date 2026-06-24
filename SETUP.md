# RoonSage Setup & Features Guide

**Complete installation instructions, configuration, and feature overview for macOS, iOS, and the audio analyzer.**

- [Quick Start](#quick-start)
- [System Requirements](#system-requirements)
- [macOS App](#macos-app)
- [iOS App](#ios-app)
- [Audio Analyzer](#audio-analyzer)
- [Server & Client Architecture](#server--client-architecture)
- [Claude Desktop Integration (MCP)](#claude-desktop-integration-mcp)
- [Optional Services](#optional-services)
- [Features Deep-Dive](#features-deep-dive)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

**If you just want to get started quickly:**

1. **Download the macOS app** from [Releases](https://github.com/Georgemvp/roonsage/releases) (look for `RoonSage-x.y.z.dmg`)
2. **Run the app** — it will discover your Roon Core on the network
3. **Authorize** when the Roon authorization dialog appears
4. **Browse your library, generate playlists, and play**

For **iOS**, join the TestFlight beta (link in releases) or build from source.

For **Sonic features** (Music Map, Song Paths, Sonic Search), [download the Analyzer](#audio-analyzer) and run it alongside the macOS app.

---

## System Requirements

### macOS App
- **macOS 14 (Sonoma)** or later
- **Roon Core** (version 1.8+) running on your network
- Internet connection (for Qobuz search, LLM, scrobbling, metadata enrichment)

### iOS App
- **iOS/iPadOS 17** or later
- **Roon Core** on your network (or a macOS RoonSage server if behind NAT)
- Optional: **ZeroTier** (free peer-to-peer VPN) for access outside your home network

### Audio Analyzer (optional, for sonic features)
- **macOS 14+** or **roonsage-analyzer** CLI on any OS
- **Music library** accessible on disk (FLAC, MP3, M4A with tags)
- ~5–15 minutes per 1000 tracks (depends on format; FLAC faster)

### Roon Core
- Your own instance running on your network
- Not part of RoonSage — you manage it separately
- See [roon.app](https://roon.app) to install

---

## macOS App

### Installation

1. **Download** the latest `RoonSage-x.y.z.dmg` from [Releases](https://github.com/Georgemvp/roonsage/releases)
2. **Open the DMG** and drag `RoonSage.app` to `Applications`
3. **Launch** from Applications or Spotlight
4. On first launch, **grant Notifications permission** if prompted (for live playback updates)

The app is **signed and notarized** (gatekeeper approved). If you see a security warning:
- Right-click the app → "Open" → "Open"
- Or allow it in System Settings → Privacy & Security

### First Run: Roon Authorization

When you first open the app:

1. It scans your network for Roon Core (via UDP multicast)
2. If found, displays "Roon found at `192.168.1.x:9330`"
3. Click **"Authorize"** — the Roon authorization flow opens
4. **Allow** the RoonSage extension in Roon
5. You see "✓ Connected" when authorization completes

The app automatically **saves your Roon Core ID and token** in the local database (not synced anywhere).

**If Roon isn't discovered:**
- Verify Roon Core is running and on the same network
- Check that your Wi-Fi/firewall allows multicast (UDP 5353 + 23017)
- Or manually enter the IP + port in Settings

### Upgrading

The app checks for updates and can **auto-install** them overnight or on-demand from the menu bar.

---

## iOS App

### Installation

1. **Join the TestFlight beta**: Look for the TestFlight link in [Releases](https://github.com/Georgemvp/roonsage/releases)
2. **Or build from source** (requires Xcode 15+, see [Build & Run](README.md#build--run))
3. Install `Xcode` + run `cd native/iosapp && xcodegen generate && open RoonSageiOS.xcodeproj` in Xcode, then build on your device

### Setup

On first launch, the app looks for a **RoonSage server** (the macOS app):

- **On your home network**: If the macOS app is running, it auto-discovers via Bonjour
- **Outside your network** (iPhone/iPad on cellular): You need to:
  1. Set up a **ZeroTier** peer-to-peer VPN (free, at [zerotier.com](https://zerotier.com))
  2. In RoonSage Settings, enter the ZeroTier IP of your Mac (e.g. `192.168.192.x`)
  3. The app then proxies all Roon commands through the secure tunnel

If you **don't have a server** (running the macOS app), the iOS app can't connect — it's a **thin client** that requires a server build of the macOS app to be always-on.

### Lock Screen, Control Center & Siri

Once paired, you get:

- **Lock Screen** — see what's playing (artwork + title/artist)
- **Control Center** — quick play/pause/next/prev with a swipe from the top-right
- **Dynamic Island** (iPhone 14 Pro+) — Live Activity shows currently-playing track
- **Siri** — "Hey Siri, play next" → works with RoonSage

These rely on `MPNowPlayingInfoCenter` and remote command handling.

---

## Audio Analyzer

The **Audio Analyzer** walks your music files, extracts BPM, musical key (Camelot), and a 512-dimensional **CLAP sonic embedding** per track. These power Sonic Search, Music Map, Song Paths, DJ tools, and Sonic Radio.

### Why it exists

- Roon has no way to query "all tracks in the key of G" or "fast-tempo funk"
- The analyzer fills this gap by indexing your actual audio files
- It runs locally (all analysis stays on your machine)
- Results are served via a simple HTTP server that the macOS and iOS apps pull from

### Installation & Running

#### Option A: Analyzer macOS app (easiest)

1. Download `RoonSageAnalyzerApp-x.y.z.dmg` from [Releases](https://github.com/Georgemvp/roonsage/releases)
2. Drag to Applications and launch
3. The app shows a progress bar + task count
4. When done, it stays running as a background server on port `5766`

#### Option B: CLI (`roonsage-analyzer`)

1. Build from source: `cd native && swift build -c release --product roonsage-analyzer`
2. Find the binary at `.build/release/roonsage-analyzer`
3. Run `roonsage-analyzer analyze /path/to/music` (e.g. `/Volumes/MyMusicDrive/Music`)
4. Or `roonsage-analyzer serve --port 5766` to start the HTTP server

#### Option C: Docker (if running on a server)

The analyzer is a **pure Swift app** — there's no Dockerfile currently, but you can build and run the binary anywhere Swift runs (macOS, Linux via Swift toolchain).

### Supported Formats

- **FLAC** (fastest — reads uncompressed metadata)
- **MP3** (ID3v2 tags)
- **M4A** (iTunes metadata)
- **WAV** (basic ID3)

The analyzer reads **embedded tags only** — it doesn't call out to online services.

### How it works

1. **First run**: walks your music library directory, reads file tags, extracts BPM and key via DSP + Core ML CLAP embedding
2. **Stores results** in a local SQLite database (`data/analyzer_features.db`)
3. **Serves HTTP**: exposes `/features`, `/embeddings`, `/text-embed?q=...` endpoints
4. **Updates incrementally**: on subsequent runs, only new/modified files are analyzed
5. **Tracks versions**: if you upgrade the CLAP model version, it re-analyzes just the embeddings (not the BPM/key)

### Performance

- **BPM + key**: ~3–5 seconds per track
- **CLAP embedding**: ~5–10 seconds per track (depends on file size and format)
- Typically **5–15 minutes per 1000 tracks** end-to-end
- Runs in the background; you can use the macOS app while analysis is in progress

### Data Storage

Results live in:
- **Feature/embedding database**: `data/analyzer_features.db`
- **Model cache**: `data/.hf_cache` (CLAP Core ML model downloaded once)

All of this stays on your machine — nothing leaves.

---

## Server & Client Architecture

RoonSage uses a **server/client split**:

```
┌─ Your Network ─────────────────────────────────────┐
│                                                     │
│  Roon Core (extension-capable device)              │
│    ▼                                               │
│  RoonSage Server (always-on, macOS Mini recommended)
│    ├─ Registers as Roon extension                  │
│    ├─ Syncs library → local GRDB database          │
│    ├─ Listens for zone playback changes            │
│    ├─ Exposes HTTP:5767 library share              │
│    ├─ Exposes HTTP:5767 playback proxy             │
│    └─ Runs analyzer (optional, separate process)   │
│         └─ HTTP:5766 audio features                │
│                                                    │
└─ Thin Clients (iPhone, iPad, or 2nd Mac) ────────┘
    RoonSage app (client mode)
    ├─ Pulls library from server (HTTP:5767)
    ├─ Shows live playback from server
    └─ Proxies all commands back to server
    
    Analyzer app (optional)
    └─ Pulls features from analyzer (HTTP:5766)
```

### Why split?

- **Roon only allows one extension per network** → one device must register with Roon
- **Thin clients everywhere** — any Mac or iOS device can browse and control once the server is set up
- **Offline-first** — library and playback are cached locally; thin clients still work if they can reach the server

### Server setup

Run the **macOS app in server mode**:

1. Place your Mac near your Roon Core (same network, ideally wired Ethernet for reliability)
2. Open RoonSage Settings → **"Server mode"** toggle → enabled
3. The app registers as a Roon extension and starts syncing
4. Other devices can now connect (see [Client setup](#client-setup) below)

The server syncs your library once (5–10 minutes for 100k tracks) and then keeps playback live. It's safe to put it on a Mac Mini and forget about it.

### Client setup (iOS, or secondary Mac)

1. Install RoonSage on your device
2. It auto-discovers the server on the same network (via Bonjour)
3. If outside your network, manually enter the server IP in Settings
4. Once connected, you see a live mirror of the library and can control playback

---

## Claude Desktop Integration (MCP)

**MCP** (Model Context Protocol) lets Claude Desktop control RoonSage via natural language.

### Installation

1. **Build the MCP server**:
   ```bash
   cd native && swift build -c release --product roonsage-mcp
   ```
   The binary is at `.build/release/roonsage-mcp`

2. **Install it to your system** (so Claude can find it):
   ```bash
   mkdir -p ~/.local/bin
   cp .build/release/roonsage-mcp ~/.local/bin/
   chmod +x ~/.local/bin/roonsage-mcp
   ```

3. **Configure Claude Desktop**:
   - Open `~/Library/Application Support/Claude/claude_desktop_config.json`
   - Add this block:
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
   - Replace `192.168.1.x` with your RoonSage server's IP
   - Restart Claude Desktop

4. **Test it** — in Claude, type "What's in my library?" or "Generate a playlist"

### Available tools

~30 MCP tools for:
- **Playback**: play/pause, next/prev, volume, shuffle, zone transfer
- **Search**: library search, Qobuz search
- **Curation**: filter tracks, curate playlists, album recommendations
- **Intelligence**: listening history, taste profile, top artists
- **Control**: zone listing, now-playing status

See the full list in [README.md](README.md#claude-desktop-mcp).

---

## Optional Services

These are **optional** — RoonSage works fine without them, but they unlock features like scrobbling, web search for albums, and playlist export.

### Qobuz

**Enables:**
- Search Qobuz when your library doesn't have a track
- Save curated playlists to Qobuz (so Roon can play them)

**Setup:**
1. Sign up at [qobuz.com](https://www.qobuz.com)
2. In RoonSage Settings, paste your email and password
3. Done — search now falls back to Qobuz automatically

### ListenBrainz

**Enables:**
- Scrobble your plays to ListenBrainz (open-source Spotify/Last.fm alternative)
- Track listening history across devices

**Setup:**
1. Create an account at [listenbrainz.org](https://listenbrainz.org)
2. Get your API token from Settings → "Tools" → "Database preferences" → token
3. In RoonSage Settings, paste the token
4. The app automatically scrobbles plays

### Last.fm

**Enables:**
- Scrobble to Last.fm + Last.fm tags on tracks
- Last.fm stats in taste profiles

**Setup:**
1. Create an account at [last.fm](https://last.fm)
2. Authorize RoonSage in Last.fm Settings → "Applications" → "Authorised applications"
3. In RoonSage, paste your Last.fm username
4. Scrobbling starts automatically

### Metadata Services

**MusicBrainz** (enabled by default) provides:
- Genre / style tags
- Release dates + edition info
- Composer info for classical

No auth needed — the app calls the open API automatically.

---

## Features Deep-Dive

### Library & Playback

#### Browse
- **Track list** — all tracks, sorted/searchable by title, artist, album
- **Albums grid** — visual album covers, tap to drill into tracks
- **Artists grid** — sort by play count, alphabetical, or recent
- **Full-text search** (FTS5) across titles, artists, album names
- **Filters** — genre, decade, keywords, artist cap (no "too many" albums by one artist)

#### Now Playing
- **Full-bleed album art** with smart tinting from art's dominant color
- **Transport** — play/pause, scrub timeline, next/prev
- **Zone switcher** — move playback to any zone (not just the current one)
- **Queue preview** — peek at what's coming next
- **Lock screen / Control Center** (iOS) — control from lock screen, Dynamic Island shows artwork

### AI Curation

#### Generate
- Describe a mood, genre, or era ("upbeat 80s funk", "mellow ambient", "lo-fi chill beats")
- The LLM **analyzes intent** → converts to Roon genre filters
- Picks 15–50 tracks from your library (preferring unique artists, fresh sounds)
- **Auto-generates a title + description** (you can edit before saving)
- Save locally and play anytime, or play now

#### Ask
- One-liner vibe prompt ("something to cook to")
- Instant results — playlist auto-plays (no extra confirmation)
- Faster than Generate

#### Recommend (Albums)
- Based on your listening history, get album recommendations
- Grounded in your library (not hallucinated)

#### Save to Qobuz
- Curate a playlist, then save it to Qobuz
- Roon automatically picks it up as a custom playlist

### Sonic Intelligence

The **analyzer** extracts a 512-dim CLAP embedding from each track, unlocking:

#### Sonic Fingerprint
- Your **musical DNA** — a radar chart showing:
  - Energy level (quiet ↔ loud)
  - Tempo (slow ↔ fast)
  - Major-key ratio (how much in major vs minor)
  - Tempo spread (how much variance)
  - Tag richness (variety of genres/styles)
- Based on your top-played tracks
- **Recommendations ranked by cosine similarity** — finds tracks "like your taste"

#### Sonic Search
- Free-text query: "dreamy ambient piano", "energetic funk with horns", "lo-fi laptop beats"
- Embedded via CLAP text encoder
- Matched against your library's embeddings
- No metadata needed — finds by *sound*

#### Music Map
- **2D scatter plot** of every analyzed track
- X/Y = PCA-2D projection of embeddings (or tempo × energy before analysis)
- **Color = Camelot key** (musical key as a circle/wheel)
- Tap any point to play it
- Zoom, pan, filter by Camelot key

#### Song Paths
- **Smoothest sonic bridge** between two tracks
- Nearest-neighbor walk through the embedding space (greedy) or Dijkstra over a k-NN graph
- Results are a short playlist of sonically-coherent tracks connecting them
- Optional **mood bias** — prefer tracks biased toward one of 8 mood centroids (energetic, melancholic, etc.)

#### Song Alchemy
- Vector arithmetic: `mean(add) − 0.5 × mean(subtract)`
- "What sounds like [Track A] but more energetic?" → add energetic tracks, subtract current picks
- Find the "sweet spot" in taste space

#### Sonic Radio
- **Endless artist-seeded stations** — pick an artist, station refills as it drains (greedy nearest-neighbor walk)
- **AI artist radios** — stable, auto-refreshing Qobuz playlists with AI-generated titles, genre-coherent ordering

### DJ Tools

#### DJ Set
- **Beatmatched, Camelot-compatible sets** with:
  - Automatic BPM curve (starts slow, peaks, ends cool-down)
  - Energy arc (quiet → energetic → cool-down)
  - **Harmonic transitions** — seamlessly move between keys using the Camelot wheel
  - `X/Y harmonic transitions` summary (how many tracks can mix with next via key matching)
- Tap any transition to see what makes it work (BPM, energy, key)
- **Live DJ** — for the now-playing track, one-tap suggestion of compatible next tracks

#### Export
- **Readable tracklist** with BPM, Camelot key, artist, title
- **M3U file** (so other apps/controllers can read it)
- Share via AirDrop or email

#### Camelot Wheel
- Musical keys mapped to wheel positions
- C major = 1B, D major = 3B, etc. (visible in the DJ Set view)

### Taste Profile

Combines:
- **Local listening history** (what you've actually played in RoonSage)
- **ListenBrainz** (if scrobbled; sees plays from all sources)
- **Last.fm** (if scrobbled; includes historical plays)

Shows:
- Top artists (last 3 months, 6 months, all-time)
- Genre distribution (pie chart)
- Tags / styles (word cloud)
- Listening heatmap (when you listen: day of week + time of day)
- Stats: total plays, unique artists, average plays/artist

### Year in Review

Automatic end-of-year recap:
- Top albums, artists, genres
- Playlist recommendations based on the year's listening
- Share-friendly summary
- Works on thin clients (pulled from the server)

### Scrobbling & History

#### Automatic Scrobbling
- Every track play is logged to `listening_history` (local)
- If **ListenBrainz** or **Last.fm** enabled, plays are scrobbled automatically
- Now-playing updates in real-time (within 1 second of play)

#### Listening History
- See what you've played, when
- Filter by date range
- Sorted by most recent

### Design & Themes

- **Dark** (default — soft blacks + Roon gold `#e5a00d`)
- **Light** (bright UI for daytime use)
- **System** (matches macOS/iOS system setting)
- **Accent picker** — choose a color to replace the default gold
- **Album art colors** — if an album has a strong color, the app tints text/UI to match (so it never clashes with the artwork)
- **Skeleton loaders** — while data is loading, animated placeholders appear (not blank, not frozen)
- **Haptics** (iOS) — tactile feedback on interactions

---

## Configuration

### macOS App

**Settings** (menu bar → gear icon or `Cmd + ,`):

| Setting | What it does | Default |
|---------|-------------|---------|
| **Roon Core IP** | IP:port of your Roon Core (auto-detected but can be manual) | auto (SOOD discovery) |
| **Server mode** | Register as a Roon extension; expose HTTP server for thin clients | off |
| **LLM Provider** | Anthropic, OpenAI, Ollama, or custom endpoint | Anthropic |
| **LLM Model** | Which model to use for generation (per provider) | sonnet-4-5 (Anthropic) |
| **Theme** | Dark / Light / System | System |
| **Accent color** | Override Roon gold | off |
| **Qobuz email/password** | For Qobuz search + playlist save | (blank) |
| **ListenBrainz token** | For scrobbling | (blank) |
| **Last.fm username** | For Last.fm scrobbling + tags | (blank) |
| **Analyzer URL** | HTTP URL of analyzer server (auto-detected on local network) | `http://localhost:5766` |
| **Database** | Option to reset/backup your local database | (buttons) |

### iOS App

Same settings as macOS, plus:

| Setting | What it does |
|---------|-------------|
| **Server IP** | Manual IP of RoonSage macOS server (if not auto-discovered) |
| **ZeroTier IP** | Manual ZeroTier IP of server (for remote access) |
| **App lock** | Optionally lock the app with Face ID / Touch ID |

### Analyzer

**Command-line options**:

```bash
roonsage-analyzer analyze /path/to/music
  --skip-bpm              # skip BPM analysis (faster; use if only want embeddings)
  --skip-embeddings       # skip CLAP (faster; use if only want BPM/key)
  --only-new              # only analyze new/modified files
  --db /path/to/db.sqlite # custom database location (default: data/analyzer_features.db)

roonsage-analyzer serve
  --port 5766             # HTTP server port (default 5766)
  --db /path/to/db.sqlite # custom database location

roonsage-analyzer validate /music/dir --reference /labels.csv
  # Compare BPM/key against a labeled sample; reports accuracy
```

---

## Troubleshooting

### Roon not found

**Problem**: The app doesn't see your Roon Core.

**Solutions**:
1. Verify Roon is running and on the same network
2. Check that your Wi-Fi allows UDP multicast (some corporate networks don't)
3. In Settings, manually enter the Roon Core IP + port (default `9330`)
4. Try wired Ethernet (more reliable than Wi-Fi)
5. Restart the app and Roon

### App crashes on launch

**Problem**: RoonSage crashes immediately or on load.

**Solutions**:
1. Check System Preferences → Security & Privacy → allow RoonSage (if notarization fails)
2. Try deleting the app cache: `rm -rf ~/Library/Caches/com.roonsage.RoonSage`
3. Try resetting the local database (Settings → Database → Reset)
4. Reinstall the app fresh

### Thin client can't connect to server

**Problem**: The iOS/secondary Mac app can't see the server.

**Solutions**:
1. Verify the server is running in server mode (Settings → Server mode is ON)
2. Both devices on the same Wi-Fi network? → Try Bonjour discovery again
3. Different networks? → Set up [ZeroTier](#ios-app) and enter the server's ZeroTier IP
4. Verify firewall isn't blocking port `5767` (Settings → Firewall & Network)
5. On the server, check: System Preferences → Network → see the actual IP, then manually enter it on the client

### Sonic features not working

**Problem**: Music Map, Song Paths, Sonic Search are grayed out or don't show results.

**Solutions**:
1. Is the analyzer running? → Launch `RoonSageAnalyzerApp` or `roonsage-analyzer serve`
2. Analyzer still analyzing? → Wait (you'll see progress in the analyzer app)
3. Analyzer finished but still no results? → Check analyzer was pointed at the right music directory
4. In RoonSage Settings, verify **Analyzer URL** is correct (usually `http://localhost:5766` or the analyzer's IP:port)
5. Try restarting both apps

### Analyzer slow or hangs

**Problem**: Audio analysis takes forever or seems stuck.

**Solutions**:
1. Is the disk busy? → Check Activity Monitor (Disk I/O). Analysis is CPU + disk-intensive.
2. Large FLAC files? → FLAC is slower but complete; MP3 is faster. Your library determines speed.
3. Is it actually running? → Check the analyzer app window (does it show a progress bar?)
4. Try restarting the analyzer; it will resume from where it left off
5. On very slow Macs (older Mini), 15 min/1000 tracks is expected

### Playback proxy timeouts

**Problem**: When curating a large playlist (50+ tracks), the app says "timeout" before playback starts.

**Solutions**:
1. This is expected for very large playlists (Roon queues them slowly)
2. Try curating fewer tracks (25–40) and playing those first
3. Or cue them in smaller batches

### Qobuz login fails

**Problem**: Qobuz search doesn't work or login error appears.

**Solutions**:
1. Verify your Qobuz email + password are correct (Settings)
2. Some Qobuz accounts have locale restrictions — search may fail in that region
3. Try without Qobuz (library-only search still works)

### Scrobbling not working

**Problem**: ListenBrainz or Last.fm says "not scrobbling".

**Solutions**:
1. Check your token/username is pasted correctly in Settings
2. Verify the track has both an artist and title (scrobble services require both)
3. Check your internet connection
4. Try logging in again (tokens may expire)
5. In Settings → Database → see "scrobble queue"; it's queued locally and retries

---

## Need Help?

- **Docs**: [README.md](README.md), [ROADMAP.md](native/ROADMAP.md), [NATIVE_APP_AUDIT.md](docs/NATIVE_APP_AUDIT.md)
- **Issues**: [GitHub Issues](https://github.com/Georgemvp/roonsage/issues) — check existing first, then open a new one with:
  - macOS/iOS version
  - Roon Core version
  - Steps to reproduce
  - Crash log (if applicable)
- **Discussions**: [GitHub Discussions](https://github.com/Georgemvp/roonsage/discussions)

