// =============================================================================
// History Feed
// =============================================================================

import { state } from './state.js';
import { apiCall } from './api.js';
import { escapeHtml } from './utils.js';
import { loadSavedResult } from './router.js';
import { setLoading, showError } from './ui.js';

/** In-memory cache of history items + pagination metadata */
export let _historyCache = { items: [], total: 0, loaded: false, stale: true };
export let _historyFilter = 'all'; // 'all' | 'playlists' | 'albums'
export let _historyDeleteConfirm = null; // { id, el, timeout }

/** Mark history as needing re-fetch (called after a result is saved) */
export function markHistoryStale() {
    _historyCache.stale = true;
}

/** Relative timestamp for history cards */
export function relativeTime(isoString) {
    const date = new Date(isoString);
    const now = new Date();
    const diffMs = now - date;
    const diffMin = Math.floor(diffMs / 60000);
    const diffHr = Math.floor(diffMs / 3600000);
    const diffDay = Math.floor(diffMs / 86400000);

    if (diffMin < 1) return 'Just now';
    if (diffMin < 60) return `${diffMin}m ago`;
    if (diffHr < 24) return `${diffHr}h ago`;
    if (diffDay === 1) return 'Yesterday';
    if (diffDay < 7) {
        return date.toLocaleDateString(undefined, { weekday: 'long' });
    }
    // Same year → "Feb 12"; different year → "Feb 2025"
    if (date.getFullYear() === now.getFullYear()) {
        return date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
    }
    return date.toLocaleDateString(undefined, { month: 'short', year: 'numeric' });
}

/** Date group label for a given ISO timestamp */
export function dateGroupLabel(isoString) {
    const date = new Date(isoString);
    const now = new Date();

    // Today
    const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    if (date >= todayStart) return 'Today';

    // Yesterday
    const yesterdayStart = new Date(todayStart);
    yesterdayStart.setDate(yesterdayStart.getDate() - 1);
    if (date >= yesterdayStart) return 'Yesterday';

    // Earlier this week (same ISO week)
    const dayOfWeek = now.getDay() || 7; // Monday = 1
    const weekStart = new Date(todayStart);
    weekStart.setDate(weekStart.getDate() - dayOfWeek + 1);
    if (date >= weekStart) return 'Earlier this week';

    // Same year → "Month Day"; different year → "Month Year"
    if (date.getFullYear() === now.getFullYear()) {
        return date.toLocaleDateString(undefined, { month: 'long', day: 'numeric' });
    }
    return date.toLocaleDateString(undefined, { month: 'long', year: 'numeric' });
}

/** Icon for result type (inline SVGs at 16x16, matching Lucide home-card icons) */
export function historyIcon(type) {
    const attrs = 'xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
    if (type === 'album_recommendation') return `<svg ${attrs}><circle cx="12" cy="12" r="10"/><circle cx="12" cy="12" r="2"/></svg>`;
    if (type === 'seed_playlist') return `<svg ${attrs}><path d="M14 9.536V7a4 4 0 0 1 4-4h1.5a.5.5 0 0 1 .5.5V5a4 4 0 0 1-4 4 4 4 0 0 0-4 4c0 2 1 3 1 5a5 5 0 0 1-1 3"/><path d="M4 9a5 5 0 0 1 8 4 5 5 0 0 1-8-4"/><path d="M5 21h14"/></svg>`;
    if (type === 'mcp_playlist') return `<svg ${attrs}><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M9 9h6M9 12h6M9 15h4"/></svg>`;
    if (type === 'song_path') return `<svg ${attrs}><circle cx="5" cy="12" r="2"/><circle cx="19" cy="12" r="2"/><path d="M5 12c0-4 4-7 7-7"/><path d="M19 12c0 4-4 7-7 7"/><path d="M9 9l3-3 3 3"/><path d="M15 15l-3 3-3-3"/></svg>`;
    return `<svg ${attrs}><path d="M12 18V5"/><path d="M15 13a4.17 4.17 0 0 1-3-4 4.17 4.17 0 0 1-3 4"/><path d="M17.598 6.5A3 3 0 1 0 12 5a3 3 0 1 0-5.598 1.5"/><path d="M17.997 5.125a4 4 0 0 1 2.526 5.77"/><path d="M18 18a4 4 0 0 0 2-7.464"/><path d="M19.967 17.483A4 4 0 1 1 12 18a4 4 0 1 1-7.967-.517"/><path d="M6 18a4 4 0 0 1-2-7.464"/><path d="M6.003 5.125a4 4 0 0 0-2.526 5.77"/></svg>`;
}

/** Icon title for result type */
export function historyIconTitle(type) {
    if (type === 'album_recommendation') return 'Album aanbeveling';
    if (type === 'seed_playlist') return 'Playlist van seed-track';
    if (type === 'mcp_playlist') return 'MCP playlist (Claude Desktop)';
    if (type === 'song_path') return 'Song Pad';
    return 'Playlist van prompt';
}

/** Scrub date suffix from playlist titles (e.g., "Title - Feb 2026") */
export function scrubDateSuffix(title) {
    return title.replace(/ - (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4}$/, '');
}

/** Check if item passes the current filter */
export function passesHistoryFilter(item) {
    if (_historyFilter === 'all') return true;
    if (_historyFilter === 'playlists') return item.type !== 'album_recommendation' && item.type !== 'song_path';
    if (_historyFilter === 'albums') return item.type === 'album_recommendation';
    if (_historyFilter === 'paths') return item.type === 'song_path';
    return true;
}

/** Render the history feed from cached data */
export function renderHistoryFeedFromCache() {
    const container = document.getElementById('history-feed');
    if (!container) return;

    const items = _historyCache.items;

    // Empty state
    if (items.length === 0) {
        container.innerHTML = `
            <div class="rs-empty-state">
                <div class="rs-empty-icon" style="background:rgba(0,212,170,0.10);color:var(--teal,#00d4aa);">🕐</div>
                <div class="rs-empty-title">Nog geen geschiedenis</div>
                <div class="rs-empty-desc">Luistergeschiedenis verschijnt zodra je begint met afspelen via Roon.</div>
                <button class="rs-empty-cta" style="background:rgba(0,212,170,0.10);color:var(--teal,#00d4aa);border-color:var(--teal,#00d4aa);"
                    onclick="window.location.hash='nowplaying'">Open Now Playing</button>
            </div>`;
        return;
    }

    // Count by type for filter chips
    const playlistCount = items.filter(i => i.type !== 'album_recommendation' && i.type !== 'song_path').length;
    const albumCount = items.filter(i => i.type === 'album_recommendation').length;
    const pathCount = items.filter(i => i.type === 'song_path').length;

    // Build HTML
    let html = '';

    // Filter chips
    html += '<div class="history-filters" role="group" aria-label="Filter history by type">';
    html += `<button class="filter-chip${_historyFilter === 'all' ? ' selected' : ''}" data-hfilter="all">Alles <span class="filter-chip-count">${items.length}</span></button>`;
    html += `<button class="filter-chip${_historyFilter === 'playlists' ? ' selected' : ''}" data-hfilter="playlists">Playlists <span class="filter-chip-count">${playlistCount}</span></button>`;
    html += `<button class="filter-chip${_historyFilter === 'albums' ? ' selected' : ''}" data-hfilter="albums">Albums <span class="filter-chip-count">${albumCount}</span></button>`;
    if (pathCount > 0) {
        html += `<button class="filter-chip${_historyFilter === 'paths' ? ' selected' : ''}" data-hfilter="paths">Paden <span class="filter-chip-count">${pathCount}</span></button>`;
    }
    html += '</div>';

    // Group by date
    let lastGroup = null;
    let idx = 0;
    for (const item of items) {
        const visible = passesHistoryFilter(item);
        const display = visible ? '' : ' style="display:none"';
        const group = dateGroupLabel(item.created_at);

        if (group !== lastGroup) {
            // Check if this group has any visible items
            const groupHasVisible = items.some(
                i => dateGroupLabel(i.created_at) === group && passesHistoryFilter(i)
            );
            const headerStyle = groupHasVisible
                ? `animation-delay:${idx * 30}ms`
                : `display:none;animation-delay:${idx * 30}ms`;
            html += `<div class="date-group-header" style="${headerStyle}">${escapeHtml(group)}</div>`;
            lastGroup = group;
        }

        const title = item.type === 'album_recommendation'
            ? escapeHtml(item.title)
            : escapeHtml(scrubDateSuffix(item.title));

        const artistSpan = item.artist && item.type !== 'album_recommendation'
            ? ` <span class="history-card-artist">${escapeHtml(item.artist)}</span>`
            : '';

        const subtitle = item.subtitle
            ? escapeHtml(item.subtitle)
            : (item.prompt ? escapeHtml(item.prompt) : '');

        html += `<div class="history-card" data-result-id="${escapeHtml(item.id)}" data-type="${escapeHtml(item.type)}"${display} style="animation-delay:${idx * 30}ms">`;
        html += `  <div class="history-card-icon" title="${historyIconTitle(item.type)}">${historyIcon(item.type)}</div>`;
        html += `  <div class="history-card-body">`;
        html += `    <div class="history-card-title">${title}${artistSpan}</div>`;
        html += `    <div class="history-card-subtitle">${subtitle}</div>`;
        html += `  </div>`;
        html += `  <span class="history-card-time">${relativeTime(item.created_at)}</span>`;
        html += `  <button class="history-card-delete" aria-label="Delete" title="Delete">&times;</button>`;
        html += '</div>';
        idx++;
    }

    // Load more button
    if (_historyCache.items.length < _historyCache.total) {
        html += '<div class="history-load-more"><button class="load-more-btn">Load more</button></div>';
    }

    container.innerHTML = html;
}

/** Fetch and render the history feed */
export async function renderHistoryFeed() {
    const container = document.getElementById('history-feed');
    if (!container) return;

    // Use cache if fresh
    if (_historyCache.loaded && !_historyCache.stale) {
        renderHistoryFeedFromCache();
        return;
    }

    try {
        const data = await apiCall('/results?limit=20');
        _historyCache.items = data.results || [];
        _historyCache.total = data.total || 0;
        _historyCache.loaded = true;
        _historyCache.stale = false;
        _historyFilter = 'all';

        renderHistoryFeedFromCache();
    } catch (e) {
        console.warn('Failed to load history:', e);
        container.innerHTML = `
            <div class="rs-empty-state">
                <div class="rs-empty-icon" style="background:rgba(233,92,89,0.10);color:var(--error);">!</div>
                <div class="rs-empty-title">Kon geschiedenis niet laden</div>
                <div class="rs-empty-desc">Controleer de verbinding met de RoonSage backend en probeer opnieuw.</div>
            </div>`;
    }
}

/** Load more history items */
export async function loadMoreHistory() {
    try {
        const offset = _historyCache.items.length;
        const data = await apiCall(`/results?limit=20&offset=${offset}`);
        const newItems = data.results || [];
        _historyCache.items.push(...newItems);
        _historyCache.total = data.total || _historyCache.total;
        renderHistoryFeedFromCache();
    } catch (e) {
        console.warn('Failed to load more history:', e);
    }
}

/** Handle filter chip clicks */
export function handleHistoryFilterClick(filter) {
    _historyFilter = filter;
    renderHistoryFeedFromCache();
}

/** Reset a delete button from confirming state back to × */
export function resetDeleteConfirm() {
    if (!_historyDeleteConfirm) return;
    clearTimeout(_historyDeleteConfirm.timeout);
    const btn = _historyDeleteConfirm.el;
    btn.classList.remove('confirming');
    btn.textContent = '×';
    btn.setAttribute('aria-label', 'Delete');
    _historyDeleteConfirm = null;
}

/** Handle two-step inline delete confirmation */
export function handleHistoryDelete(resultId, deleteBtn) {
    // If this button is already confirming → execute the delete
    if (_historyDeleteConfirm && _historyDeleteConfirm.id === resultId) {
        resetDeleteConfirm();
        finalizeHistoryDelete(resultId);
        return;
    }

    // Reset any other card's confirming state
    resetDeleteConfirm();

    // Enter confirming state on this button
    deleteBtn.classList.add('confirming');
    deleteBtn.textContent = 'Delete?';
    deleteBtn.setAttribute('aria-label', 'Confirm delete');

    const timeout = setTimeout(() => {
        if (_historyDeleteConfirm && _historyDeleteConfirm.id === resultId) {
            resetDeleteConfirm();
        }
    }, 3000);

    _historyDeleteConfirm = { id: resultId, el: deleteBtn, timeout };
}

/** Actually delete the result via API and remove from cache */
export function finalizeHistoryDelete(resultId) {
    // Optimistically remove from cache and re-render
    _historyCache.items = _historyCache.items.filter(i => i.id !== resultId);
    _historyCache.total = Math.max(0, _historyCache.total - 1);
    _historyDeleteConfirm = null;
    renderHistoryFeedFromCache();

    // Fire the server delete; restore cache on failure.
    // Raw fetch (not apiCall) because we need to tolerate 404 — the item may
    // already be gone server-side, in which case the optimistic cache update
    // is the correct end state.
    fetch(`/api/results/${encodeURIComponent(resultId)}`, { method: 'DELETE' })
        .then(resp => {
            if (!resp.ok && resp.status !== 404) {
                showError('Failed to delete item');
                _historyCache.stale = true;
                _historyCache.items = [];
                renderHistoryFeed();
            }
        })
        .catch(() => {
            showError('Failed to delete item');
            _historyCache.stale = true;
            _historyCache.items = [];
            renderHistoryFeed();
        });
}


/** Set up event delegation for history feed clicks */
export function setupHistoryEventListeners() {
    const container = document.getElementById('history-feed');
    if (!container) return;

    container.addEventListener('click', (e) => {
        // Filter chip
        const chip = e.target.closest('.filter-chip');
        if (chip) {
            handleHistoryFilterClick(chip.dataset.hfilter);
            return;
        }

        // Delete button (two-step confirm)
        const deleteBtn = e.target.closest('.history-card-delete');
        if (deleteBtn) {
            e.stopPropagation();
            const card = deleteBtn.closest('.history-card');
            if (card) handleHistoryDelete(card.dataset.resultId, deleteBtn);
            return;
        }

        // Load more
        const loadMore = e.target.closest('.load-more-btn');
        if (loadMore) {
            loadMoreHistory();
            return;
        }

        // Card click → navigate to result
        const card = e.target.closest('.history-card');
        if (card && card.dataset.resultId) {
            location.hash = `#result/${card.dataset.resultId}`;
        }
    });
}
