#!/bin/bash
# Commit the stale-track full-replace fix.
# Run once from your terminal: bash commit_fix.sh

set -e
cd "$(dirname "$0")"

rm -f .git/HEAD.lock .git/index.lock .git/objects/maintenance.lock 2>/dev/null || true

git add backend/library_cache.py tests/test_library_cache.py
git commit -m "fix: replace stale-track timestamp deletion with full-replace strategy

Roon's Browse API returns different item_key values for the same tracks
across browse sessions. This caused INSERT OR REPLACE to always create
new rows (never updating existing ones), and the stale-track cleanup
(DELETE WHERE updated_at < sync_start) then deleted every row on each
sync — the log showed 'Removed 67984 stale tracks' on every run.

Fix: clear tracks + track_genres AFTER the Roon data fetch succeeds but
BEFORE the insertion loop. This mirrors the existing albums full-replace
pattern (DELETE FROM albums at the top of the sync).

Placement rationale: deleting after a successful Phase 2 fetch means a
network failure in Phase 1/2 leaves the previous cache intact, so
has_cached_tracks() stays True and the UI can keep serving from it.

Changes:
- Delete track_genres (FK child) then tracks just before Phase 3 loop
- Remove sync_start_iso, stale-track DELETE block, and stale logging
- Remove now-redundant DELETE FROM track_genres from end of sync
- Update test_sync_removes_deleted_tracks: drop misleading updated_at
  timestamp hint in INSERT — full-replace makes it unnecessary

All 41 library_cache tests pass."

echo "Done. Run: git push"
