#!/bin/bash
# Run this once from your terminal in the RoonapiApp directory
set -e

cd "$(dirname "$0")"

# Remove stale git lock if present
rm -f .git/index.lock

git add frontend/app.js \
        frontend/index.html \
        frontend/style.css \
        frontend/modules/activity.js \
        frontend/modules/events.js \
        frontend/modules/playlist.js \
        frontend/modules/playlists.js \
        frontend/modules/taste.js \
        frontend/modules/ui.js

git commit -m "frontend: Premium UI upgrade — activity bar, enrichment refactor, taste stats, full EN translation

- New module activity.js: background activity monitor polls /api/enrichment/status
  and /api/library/status every 5s; drives collapsible bg-activity-bar in header
- index.html: add bg-activity-bar HTML after <header>; replace enrichment section
  inline styles with semantic classes (enrich-stats-grid, enrich-progress-fill,
  enrich-worker-badge); full Dutch→English translation across all UI text
- style.css: ~490 new lines — activity bar, taste stats grid, enrichment section,
  discovery hover gradients, watchlist/automation cards, auto-toggle switch,
  now-playing glassmorphism, responsive breakpoints for all new components
- taste.js: add _renderTasteStats() (5-card stats grid after intel banner) and
  _renderMoodTags() (mood/skip-signal chips); fix all Dutch strings and nl-NL locales
- app.js: import + start startActivityMonitor(); fix Dutch strings in _wireArcButton
- playlist.js, playlists.js, events.js, ui.js: replace all remaining Dutch
  user-facing strings (Opslaan→Save, Valideren→Validate, Autoriseren→Authorize,
  Verbonden als→Connected as, Fout→Error, etc.)"

echo "✓ Commit created. Push with: git push"
