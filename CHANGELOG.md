# Changelog

All notable changes to RoonSage are documented here.

## [12.0] - 2026-05-22

### Added
- **63 MCP tools** — expanded template engine with category tabs in the UI
- **PWA support** — installable on mobile and desktop (manifest + service worker + SVG icons)
- **Taste profile everywhere** — `use_taste_profile` toggle applied across all generation flows
- **125 new tests** — covering 7 previously untested subsystems (coverage gate ≥ 40 %)
- **Enrichment speed options** — `ENRICHMENT_SKIP_MB=true` for Last.fm-only mode (~50× faster on large libraries); persistent dedup cache across batches; MB tag-fetch skipped when Last.fm is active

### Fixed
- `closeBottomSheet` moved to `window`; raw `fetch` calls migrated to `apiCall`
- Track number prefix stripping and navigation-item filtering in album browse
- Exact title match instead of `LOWER()` for album enrichment
- Track→album matching on `(title, artist)` instead of `item_key`
- Discovery deep-cuts + forgotten-favorites capped at 2 tracks/artist, randomised

---

## [11.0]

### Added
- Discovery engine uses ListenBrainz `top_releases` + loved tracks with 1-per-artist diversity
- Filter sessions (server-side `key_map`) — saves 10–20 k tokens per curation flow
- AcoustID fingerprint verification for Qobuz tracks
- Automation engine (trigger-action workflows)
- Scheduled playlist regeneration (cron-based, 60 s tick)
- Enrichment worker — MusicBrainz + Last.fm background metadata pipeline
- Watchlist scanner — monitors Qobuz for new releases from favourite artists
- Notifications — Discord / Telegram / webhook event bus

---

## [10.0]

### Added
- Scrobble import (one-time backfill from ListenBrainz and Last.fm)
- Taste profile — unified profile combining local listening history, LB stats, and Last.fm stats
- MusicBrainz client + AcoustID client
- Qobuz direct API for playlist save (`app_id` auto-detected)
- HTTP Basic Auth (`ROONSAGE_PASSWORD`)
- slowapi rate-limiter on LLM endpoints (30 req/h/IP)

---

## [9.0] and earlier

Early development — Roon library sync, SQLite cache, initial MCP server (FastMCP), web UI, ListenBrainz and Last.fm scrobbling.
