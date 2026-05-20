#!/usr/bin/env bash
# Run this script from your terminal to commit the taste profile bug fixes.
# Usage: bash commit_taste_bugfixes.sh
set -e

cd "$(dirname "$0")"

# Remove stale git lock files if present
rm -f .git/HEAD.lock .git/index.lock

git add \
  backend/enrichment_worker.py \
  backend/roon_browse.py \
  backend/routes/intelligence.py \
  backend/taste_profile.py \
  frontend/modules/taste.js

git commit -m "fix: 6 taste profile bugs — genres, era/decade, Last.fm, caching

BUG 1 (routes/intelligence.py): Add top_genres array [{name, score}] to
/taste/profile response so taste.js no longer falls back to library stats.
Also add lb_era_distribution fallback when decades is empty.

BUG 2 (enrichment_worker.py + taste_profile.py): Backfill year from
mb_release_date to tracks table after each enrichment. Add fallback decade
query from track_metadata_ext when listening_history has no decade data.

BUG 3 (enrichment_worker.py): Deprioritise orchestral/classical tracks in
enrichment queue. Skip Last.fm lookups for classical performers. Clean Roon
title noise (' : ' separators, leading track numbers, Unicode prefixes)
before querying Last.fm. Fall back to artist.getTopTags when track lookup
fails completely.

BUG 4 (enrichment_worker.py): Auto-enrich listening_history genre/year/decade
via fuzzy match after every enrichment batch (100 rows, threshold 80).

BUG 5 (taste.js + roon_browse.py): Replace live /library/stats call with
/library/stats/cached in taste.js fallback — stops 4-5x redundant Roon
Browse scans per page load. Add 5-minute in-memory cache for
get_all_albums_metadata() in roon_browse.py.

BUG 6 (taste_profile.py): When listening_history yields < 5 genres, seed
genre_scores from library track_genres table at 0.5x weight so the taste
banner and radar chart are never blank."

echo ""
echo "Commit gemaakt. Push naar GitHub met:"
echo "  git push origin main"
