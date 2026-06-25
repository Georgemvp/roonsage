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

**The Analyzer is the core of RoonSage.** It connects to Roon, syncs your library, and acts as the server. The macOS and iOS apps are remote apps that connect to it.

1. **Download and install the Analyzer** from [Releases](https://github.com/Georgemvp/roonsage/releases) (look for `RoonSageAnalyzerApp-x.y.z.dmg`)
2. **Point it at your music library folder** and let it scan
3. **Authorize with Roon** when the Roon dialog appears
4. **Download the macOS or iOS app** — it connects to the Analyzer as a remote and gives you a full library browser + player UI

The Analyzer should stay running at all times (Mac Mini next to your Roon Core is ideal). The macOS/iOS apps can come and go.

---

## System Requirements

### Audio Analyzer (the server — required)
- **macOS 14 (Sonoma)** or later (runs on the always-on machine, e.g. Mac Mini)
- **Roon Core** (version 1.8+) running on your network
- **Music library** accessible on disk (FLAC, MP3, M4A)
- ~5–15 minutes per 1000 tracks for the initial analysis

### macOS App (remote)
- **macOS 14 (Sonoma)** or later
- **Analyzer running** somewhere on your network (or on the same machine)
- Internet connection (for Qobuz search, LLM features, scrobbling)

### iOS App (remote)
- **iOS/iPadOS 17** or later
- **Analyzer running** somewhere reachable (same network, or via ZeroTier from outside)
- Optional: **ZeroTier** (free peer-to-peer VPN) for access outside your home network

### Roon Core
- Your own instance running on your network
- Not part of RoonSage — you manage it separately
- See [roon.app](https://roon.app) to install

---

## macOS App

The macOS app is a **remote app** — it connects to a running Analyzer and gives you a full library browser + player UI. It does not connect to Roon directly.

### Installation

1. **Download** the latest `RoonSage-x.y.z.dmg` from [Releases](https://github.com/Georgemvp/roonsage/releases)
2. **Open the DMG** and drag `RoonSage.app` to `Applications`
3. **Launch** from Applications or Spotlight
4. On first launch, **grant Notifications permission** if prompted (for live playback updates)

The app is **signed and notarized** (gatekeeper approved). If you see a security warning:
- Right-click the app → "Open" → "Open"
- Or allow it in System Settings → Privacy & Security

### First Run: Connect to the Analyzer

1. Make sure the **Analyzer** is running (on this machine or another on the network)
2. The macOS app auto-discovers the Analyzer via Bonjour
3. If not auto-discovered, go to Settings and enter the Analyzer's IP address + port (`5767`)
4. Once connected you see "✓ Connected" and the library loads

The macOS app has **no Roon connection of its own** — all library data and playback go through the Analyzer.

### Upgrading

The app checks for updates and can **auto-install** them overnight or on-demand from the menu bar.

---

## iOS App

### Installation

1. **Join the TestFlight beta**: Look for the TestFlight link in [Releases](https://github.com/Georgemvp/roonsage/releases)
2. **Or build from source** (requires Xcode 15+, see [Build & Run](README.md#build--run))
3. Install `Xcode` + run `cd native/iosapp && xcodegen generate && open RoonSageiOS.xcodeproj` in Xcode, then build on your device

### Setup

On first launch, the app looks for a **running Analyzer**:

- **On your home network**: The Analyzer is auto-discovered via Bonjour
- **Outside your network** (iPhone/iPad on cellular): You need to:
  1. Set up a **ZeroTier** peer-to-peer VPN (free, at [zerotier.com](https://zerotier.com))
  2. In RoonSage Settings, enter the ZeroTier IP of the machine running the Analyzer (e.g. `192.168.192.x`)
  3. All Roon commands then proxy through the Analyzer over the secure tunnel

If the **Analyzer is not running**, the iOS app can't connect — it's a remote app that requires the Analyzer to be always-on (e.g. on a Mac Mini).

### Lock Screen, Control Center & Siri

Once paired, you get:

- **Lock Screen** — see what's playing (artwork + title/artist)
- **Control Center** — quick play/pause/next/prev with a swipe from the top-right
- **Dynamic Island** (iPhone 14 Pro+) — Live Activity shows currently-playing track
- **Siri** — "Hey Siri, play next" → works with RoonSage

These rely on `MPNowPlayingInfoCenter` and remote command handling.

---

## Audio Analyzer

The **Audio Analyzer** is the heart of RoonSage. It is the **always-on server** that:

- Registers with your Roon Core as an extension
- Syncs your full library into a local database
- Walks your music files and extracts BPM, musical key (Camelot), and a 512-dimensional **CLAP sonic embedding** per track
- Serves everything to the macOS and iOS remote apps over HTTP (port `5767` for library/playback, port `5766` for audio features)

The macOS and iOS apps are remotes — they cannot function without the Analyzer running somewhere.

**Best setup**: run the Analyzer on a Mac Mini or always-on Mac that is near your Roon Core.

### Installation & Running

#### Option A: Analyzer macOS app (easiest)

1. Download `RoonSageAnalyzerApp-x.y.z.dmg` from [Releases](https://github.com/Georgemvp/roonsage/releases)
2. Drag to Applications and launch
3. **Point it at your music library folder** (e.g. `/Volumes/MyMusic`)
4. It shows a progress bar while analyzing; once done it stays running as a server
5. **Authorize with Roon** when the Roon authorization dialog appears — the Analyzer registers as a Roon extension and starts syncing your library

#### Option B: CLI (`roonsage-analyzer`)

1. Build from source: `cd native && swift build -c release --product roonsage-analyzer`
2. Find the binary at `.build/release/roonsage-analyzer`
3. Run `roonsage-analyzer analyze /path/to/music` (e.g. `/Volumes/MyMusicDrive/Music`)
4. Or `roonsage-analyzer serve --port 5766` to start only the HTTP server (if already analyzed)

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

RoonSage uses an **Analyzer-as-server** design:

```
┌─ Your Network ────────────────────────────────────────────┐
│                                                           │
│  Roon Core                                                │
│    ▼  (Roon Extension API)                                │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  RoonSage Analyzer  (always-on, Mac Mini ideal)    │  │
│  │    ├─ Registers as Roon extension                  │  │
│  │    ├─ Syncs library → local GRDB database          │  │
│  │    ├─ Analyzes music files (BPM, key, embeddings)  │  │
│  │    ├─ HTTP :5767  library / playback proxy         │  │
│  │    └─ HTTP :5766  audio features (BPM, CLAP, …)   │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                           │
└─ Remote Apps ─────────────────────────────────────────────┘
    macOS App  ──┐
                 ├──▶  pulls library, settings, playback
    iOS App    ──┘     proxies all commands back to Analyzer
```

### Why this design?

- **Roon only allows one extension per network** — the Analyzer holds that slot permanently
- **Remote apps are lightweight** — any Mac or iOS device instantly has your full library
- **Always-on means always in sync** — new albums, plays, and scrobbles are captured even when remotes are closed
- **Audio analysis lives with the data** — the Analyzer stores features next to the library, so features are always available

### Analyzer setup (do this first)

1. Install the Analyzer on your always-on Mac (see [Audio Analyzer](#audio-analyzer) above)
2. Point it at your music directory and let the initial analysis finish
3. Authorize the Roon extension when prompted
4. Note the Analyzer's IP address (visible in the Analyzer app, or check System Settings → Network)

### Remote app setup (macOS or iOS)

1. Install RoonSage on your Mac or iPhone/iPad
2. It auto-discovers the Analyzer on the same network (via Bonjour)
3. If on a different network, manually enter the Analyzer's IP + port `5767` in Settings
4. Once connected, you see a live mirror of the library and can control all Roon zones

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
   - Replace `192.168.1.x` with your **Analyzer's** IP
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
| **Analyzer URL** | IP:port of the Analyzer (auto-discovered via Bonjour, or enter manually) | auto |
| **LLM Provider** | Anthropic, OpenAI, Ollama, or custom endpoint | Anthropic |
| **LLM Model** | Which model to use for generation (per provider) | sonnet-4-5 (Anthropic) |
| **Theme** | Dark / Light / System | System |
| **Accent color** | Override Roon gold | off |
| **Qobuz email/password** | For Qobuz search + playlist save | (blank) |
| **ListenBrainz token** | For scrobbling | (blank) |
| **Last.fm username** | For Last.fm scrobbling + tags | (blank) |
| **Database** | Option to reset/backup your local database | (buttons) |

### iOS App

Same settings as macOS, plus:

| Setting | What it does |
|---------|-------------|
| **Analyzer IP** | Manual IP of the Analyzer machine (if not auto-discovered) |
| **ZeroTier IP** | Manual ZeroTier IP of the Analyzer machine (for remote access) |
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

### Roon not found / Analyzer can't connect to Roon

**Problem**: The Analyzer shows "Roon not found" or can't authorize.

**Solutions**:
1. Verify Roon Core is running and on the same network as the Analyzer
2. Check that your network allows UDP multicast (some corporate/mesh networks block it)
3. In the Analyzer's Settings, manually enter the Roon Core IP + port (default `9330`)
4. Try wired Ethernet on the Analyzer machine (more reliable than Wi-Fi)
5. Restart the Analyzer and Roon

### App crashes on launch

**Problem**: RoonSage (macOS or iOS remote app) crashes immediately.

**Solutions**:
1. Check System Preferences → Security & Privacy → allow RoonSage (if notarization fails)
2. Try deleting the app cache: `rm -rf ~/Library/Caches/com.roonsage.RoonSage`
3. Try resetting the local database in Settings → Database → Reset
4. Reinstall the app fresh

### Remote app can't connect to the Analyzer

**Problem**: The iOS or macOS remote app can't find the Analyzer.

**Solutions**:
1. Verify the Analyzer is running (check the Analyzer app window or `roonsage-analyzer serve`)
2. Both devices on the same Wi-Fi? → Bonjour should auto-discover; wait 10 seconds and retry
3. Different networks? → Set up [ZeroTier](#ios-app) and enter the Analyzer machine's ZeroTier IP
4. Verify firewall isn't blocking port `5767` on the Analyzer machine (System Settings → Firewall)
5. Find the Analyzer's IP in System Preferences → Network, then manually enter it in the remote app Settings

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

