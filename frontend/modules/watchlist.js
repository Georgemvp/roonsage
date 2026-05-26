// =============================================================================
// Watchlist — artist new-release monitoring
// =============================================================================

import { apiCall } from './api.js';

let _initialized = false;

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

export async function initWatchlistView() {
    if (!_initialized) {
        _bindEvents();
        _initialized = true;
    }
    await Promise.all([_loadArtists(), _loadNewReleases(), _loadAutocomplete()]);
}

// ---------------------------------------------------------------------------
// Data loading
// ---------------------------------------------------------------------------

async function _loadArtists() {
    const container = document.getElementById('watchlist-artists-list');
    if (!container) return;
    container.innerHTML = '<div class="rs-loading"><div class="rs-spinner"></div><span class="rs-loading-text">Loading…</span></div>';
    try {
        const artists = await apiCall('/watchlist');
        _renderArtists(artists);
    } catch (e) {
        container.innerHTML = '<p class="rs-empty">Could not load watchlist.</p>';
    }
}

async function _loadNewReleases() {
    try {
        const releases = await apiCall('/watchlist/new-releases');
        _renderNewReleases(releases);
    } catch (e) {
        // Non-critical — just hide the section
        _renderNewReleases([]);
    }
}

async function _loadAutocomplete() {
    try {
        const data = await apiCall('/library/search?q=&limit=500');
        const artists = [...new Set((data.tracks || []).map(t => t.artist).filter(Boolean))].sort();
        const dl = document.getElementById('watchlist-artist-suggestions');
        if (!dl) return;
        dl.innerHTML = artists.map(a => `<option value="${_esc(a)}">`).join('');
    } catch (_) { /* best effort */ }
}

// ---------------------------------------------------------------------------
// Renderers
// ---------------------------------------------------------------------------

function _renderArtists(artists) {
    const container = document.getElementById('watchlist-artists-list');
    if (!container) return;
    if (!artists || !artists.length) {
        container.innerHTML = '<p class="rs-empty">No artists watched yet. Add artists above or use Auto-populate.</p>';
        return;
    }
    container.innerHTML = artists.map(a => _artistRow(a)).join('');
    // Bind remove buttons
    container.querySelectorAll('.watchlist-remove-btn').forEach(btn => {
        btn.addEventListener('click', async () => {
            const name = btn.dataset.artist;
            if (!name) return;
            btn.disabled = true;
            try {
                await apiCall(`/watchlist/${encodeURIComponent(name)}`, { method: 'DELETE' });
                await _loadArtists();
            } catch (e) {
                btn.disabled = false;
                alert('Could not remove artist: ' + (e.message || e));
            }
        });
    });
    // Bind toggle switches
    container.querySelectorAll('.watchlist-toggle').forEach(toggle => {
        toggle.addEventListener('change', async () => {
            const name = toggle.dataset.artist;
            const flag = toggle.dataset.flag;
            const value = toggle.checked;
            try {
                await apiCall(`/watchlist/${encodeURIComponent(name)}`, {
                    method: 'PATCH',
                    body: JSON.stringify({ [flag]: value }),
                    headers: { 'Content-Type': 'application/json' },
                });
            } catch (e) {
                // Revert on failure
                toggle.checked = !value;
            }
        });
    });
}

function _artistRow(a) {
    const checked = a.last_checked ? _formatDate(a.last_checked) : 'never';
    const badge = a.unnotified_count > 0
        ? `<span class="badge badge--amber">${a.unnotified_count} new</span>`
        : '';
    const autoTag = a.auto_added ? '<span class="watchlist-tag">auto</span>' : '';
    return `
    <div class="watchlist-artist-row" data-artist="${_esc(a.artist_name)}">
        <div class="watchlist-artist-info">
            <span class="watchlist-artist-name">${_esc(a.artist_name)}${autoTag}</span>
            ${badge}
            <span class="watchlist-artist-meta">checked: ${checked}</span>
        </div>
        <div class="watchlist-artist-controls">
            <label class="watchlist-toggle-label" title="Albums">
                <input type="checkbox" class="watchlist-toggle" data-artist="${_esc(a.artist_name)}" data-flag="monitor_albums" ${a.monitor_albums ? 'checked' : ''}>
                <span>Albums</span>
            </label>
            <label class="watchlist-toggle-label" title="EPs">
                <input type="checkbox" class="watchlist-toggle" data-artist="${_esc(a.artist_name)}" data-flag="monitor_eps" ${a.monitor_eps ? 'checked' : ''}>
                <span>EPs</span>
            </label>
            <label class="watchlist-toggle-label" title="Singles">
                <input type="checkbox" class="watchlist-toggle" data-artist="${_esc(a.artist_name)}" data-flag="monitor_singles" ${a.monitor_singles ? 'checked' : ''}>
                <span>Singles</span>
            </label>
            <button class="watchlist-remove-btn rs-btn rs-btn--secondary" data-artist="${_esc(a.artist_name)}" aria-label="Remove ${_esc(a.artist_name)}">
                &times;
            </button>
        </div>
    </div>`.trim();
}

function _renderNewReleases(releases) {
    const section = document.getElementById('watchlist-releases-section');
    const grid = document.getElementById('watchlist-releases-list');
    const badge = document.getElementById('watchlist-releases-badge');
    if (!section || !grid) return;
    if (!releases || !releases.length) {
        section.classList.add('hidden');
        return;
    }
    section.classList.remove('hidden');
    if (badge) badge.textContent = releases.length;
    grid.innerHTML = releases.map(r => _releaseCard(r)).join('');
    // Bind play buttons
    grid.querySelectorAll('.watchlist-play-btn').forEach(btn => {
        btn.addEventListener('click', async () => {
            const id = btn.dataset.releaseId;
            const itemKey = btn.dataset.itemKey;
            btn.disabled = true;
            btn.textContent = '▶ Playing…';
            try {
                if (itemKey) {
                    // Direct play via /api/queue
                    await apiCall('/queue', {
                        method: 'POST',
                        body: JSON.stringify({ item_keys: [itemKey] }),
                        headers: { 'Content-Type': 'application/json' },
                    });
                }
                // Mark as dismissed
                if (id) {
                    await apiCall(`/watchlist/new-releases/${id}/dismiss`, { method: 'POST' });
                }
                btn.textContent = '✓ Playing';
                await _loadNewReleases();
            } catch (e) {
                btn.disabled = false;
                btn.textContent = '▶ Play';
                alert('Playback failed: ' + (e.message || e));
            }
        });
    });
    // Bind dismiss buttons
    grid.querySelectorAll('.watchlist-dismiss-btn').forEach(btn => {
        btn.addEventListener('click', async () => {
            const id = btn.dataset.releaseId;
            if (!id) return;
            btn.disabled = true;
            try {
                await apiCall(`/watchlist/new-releases/${id}/dismiss`, { method: 'POST' });
                await _loadNewReleases();
            } catch (e) {
                btn.disabled = false;
            }
        });
    });
}

function _releaseCard(r) {
    const date = r.release_date ? `<span class="release-date">${r.release_date}</span>` : '';
    const typeBadge = `<span class="release-type release-type--${r.release_type || 'album'}">${r.release_type || 'album'}</span>`;
    const artKey = r.item_key;
    const artHtml = artKey
        ? `<img class="rs-album-art" src="/api/art/${encodeURIComponent(artKey)}" alt="${_esc(r.album_title)}" loading="lazy" onerror="this.style.display='none'">`
        : `<div class="rs-album-art rs-album-art--placeholder" aria-hidden="true"></div>`;
    const playBtn = r.item_key
        ? `<button class="watchlist-play-btn rs-btn rs-btn--primary" data-release-id="${r.id}" data-item-key="${_esc(r.item_key || '')}">▶ Play</button>`
        : '';
    return `
    <div class="rs-album-card">
        ${artHtml}
        <div class="release-card-body">
            <div class="rs-album-title">${_esc(r.album_title)}</div>
            <div class="rs-album-artist">${_esc(r.artist_name)}</div>
            <div class="release-card-meta">${typeBadge}${date}</div>
            <div class="release-card-actions">
                ${playBtn}
                <button class="watchlist-dismiss-btn rs-btn rs-btn--secondary" data-release-id="${r.id}">Dismiss</button>
            </div>
        </div>
    </div>`.trim();
}

// ---------------------------------------------------------------------------
// Event binding
// ---------------------------------------------------------------------------

function _bindEvents() {
    // Add artist
    const addBtn = document.getElementById('watchlist-add-btn');
    const addInput = document.getElementById('watchlist-artist-input');
    if (addBtn && addInput) {
        addBtn.addEventListener('click', () => _addArtist(addInput));
        addInput.addEventListener('keydown', e => {
            if (e.key === 'Enter') _addArtist(addInput);
        });
    }

    // Auto-populate
    const autoBtn = document.getElementById('watchlist-auto-btn');
    if (autoBtn) {
        autoBtn.addEventListener('click', async () => {
            autoBtn.disabled = true;
            autoBtn.textContent = 'Populating…';
            try {
                const res = await apiCall('/watchlist/auto-populate', { method: 'POST' });
                const n = res.count || 0;
                autoBtn.textContent = n > 0 ? `Added ${n} artist${n !== 1 ? 's' : ''}` : 'Already up to date';
                await _loadArtists();
            } catch (e) {
                autoBtn.textContent = 'Auto-populate from taste';
                alert('Auto-populate failed: ' + (e.message || e));
            } finally {
                autoBtn.disabled = false;
                setTimeout(() => { autoBtn.textContent = 'Auto-populate from taste'; }, 3000);
            }
        });
    }

    // Scan now
    const scanBtn = document.getElementById('watchlist-scan-btn');
    if (scanBtn) {
        scanBtn.addEventListener('click', async () => {
            const label = document.getElementById('watchlist-scan-label');
            const spinner = document.getElementById('watchlist-scan-spinner');
            scanBtn.disabled = true;
            if (label) label.textContent = 'Scanning…';
            if (spinner) spinner.classList.remove('hidden');
            try {
                const res = await apiCall('/watchlist/scan', { method: 'POST' });
                const n = res.new_releases_found || 0;
                if (label) label.textContent = n > 0 ? `Found ${n} new!` : 'No new releases';
                await Promise.all([_loadArtists(), _loadNewReleases()]);
            } catch (e) {
                if (label) label.textContent = 'Scan failed';
            } finally {
                scanBtn.disabled = false;
                if (spinner) spinner.classList.add('hidden');
                setTimeout(() => { if (label) label.textContent = 'Scan Now'; }, 4000);
            }
        });
    }
}

async function _addArtist(input) {
    const name = (input.value || '').trim();
    if (!name) return;
    const addBtn = document.getElementById('watchlist-add-btn');
    if (addBtn) addBtn.disabled = true;
    try {
        await apiCall('/watchlist', {
            method: 'POST',
            body: JSON.stringify({ artist_name: name }),
            headers: { 'Content-Type': 'application/json' },
        });
        input.value = '';
        await _loadArtists();
    } catch (e) {
        alert('Could not add artist: ' + (e.message || e));
    } finally {
        if (addBtn) addBtn.disabled = false;
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function _esc(str) {
    return String(str ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function _formatDate(iso) {
    try {
        const d = new Date(iso + 'Z');
        const now = new Date();
        const diffMs = now - d;
        const diffH = diffMs / 3600000;
        if (diffH < 1) return 'just now';
        if (diffH < 24) return `${Math.floor(diffH)}h ago`;
        const diffD = Math.floor(diffH / 24);
        if (diffD < 7) return `${diffD}d ago`;
        return d.toLocaleDateString();
    } catch (_) {
        return iso;
    }
}
