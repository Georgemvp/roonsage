#!/bin/bash
# Run this from the repo root to commit the Last.fm integration
cd "$(dirname "$0")"

git add \
  backend/lastfm_client.py \
  backend/lastfm_sync.py \
  backend/config.py \
  backend/db.py \
  backend/main.py \
  backend/roon_intelligence.py \
  backend/taste_profile.py \
  backend/routes/intelligence.py \
  backend/routes/setup.py \
  config.example.yaml \
  frontend/index.html \
  frontend/modules/events.js \
  frontend/modules/playlist.js

git commit -m "feat: Last.fm integration — dual-scrobbling + enhanced music intelligence (MCP v7.0)

New modules:
- backend/lastfm_client.py: async Last.fm API client (auth flow, scrobbling,
  similar artists, top tags, top artists/tracks). MD5-signed API calls.
  Module-level singleton (init_lf_client / get_lf_client).
- backend/lastfm_sync.py: background sync service — pulls top_artists,
  top_tracks, similar_artists (per-artist), artist_tags (per-artist) every 6h.
  Caches in new SQLite table lastfm_stats_cache. Module-level singleton.

Backend changes:
- backend/db.py: new lastfm_stats_cache table (stat_type PK, data_json, synced_at).
- backend/config.py: get_lastfm_config() reads LASTFM_API_KEY / LASTFM_API_SECRET /
  LASTFM_SESSION_KEY / LASTFM_USERNAME from env + config.user.yaml.
- backend/main.py: init_lf_client + init_lf_sync_instance in lifespan; Last.fm
  background sync task (every 6h, 45s startup delay).
- backend/roon_intelligence.py: fire-and-forget Last.fm update_now_playing() on
  track start; fire-and-forget scrobble() on completion alongside ListenBrainz.
- backend/taste_profile.py: merges lf_top_artists, lf_similar_artists,
  lf_artist_tags (with 0.3-weight mood blend), lf_last_synced into profile.
  _empty_profile() and _merge_profiles() updated with lf_* overwrite keys.
- backend/routes/intelligence.py: new endpoints:
    GET  /api/intelligence/lastfm/status
    POST /api/intelligence/lastfm/auth/token
    POST /api/intelligence/lastfm/auth/session
    POST /api/intelligence/lastfm/sync
- backend/routes/setup.py: POST /api/setup/validate-lastfm (validates
  api_key + api_secret + username, saves to config.user.yaml, re-inits client).
- config.example.yaml: lastfm section with api_key, api_secret, session_key,
  username and env var comments.

Frontend changes:
- frontend/index.html: Last.fm settings section (API key, secret, username,
  Validate + Authorise buttons, 2-step OAuth UI for session completion).
- frontend/modules/events.js: validate-lastfm handler, auth token request,
  session completion handler (_lastfmPendingToken state).
- frontend/modules/playlist.js: loadSettings() fetches lastfm/status on nav
  to populate status dot (green=scrobbling, amber=api-only, grey=unconfigured)."
