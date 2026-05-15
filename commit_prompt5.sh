#!/bin/bash
# Run this from your terminal to commit the Prompt 5 changes
cd "$(dirname "$0")"
rm -f .git/index.lock
git add backend/models.py backend/routes/config_routes.py backend/library_cache.py tests/test_library_cache.py tests/test_api.py README.md
git commit -m "ops: health check 503, fix Python version badge, rename plex_server_id to roon_core_id

- GET /api/health now returns HTTP 503 when any critical dependency
  (Roon, LLM, SQLite) is down; adds database_ok field to HealthResponse
- README badge and Tech Stack section corrected from Python 3.14+ to 3.11+
- Renamed legacy plex_server_id column to roon_core_id in sync_state table;
  added ALTER TABLE RENAME migration for existing databases so no data is lost
- Updated all library_cache.py references and matching test assertions"
