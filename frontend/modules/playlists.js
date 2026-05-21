// =============================================================================
// Playlist Library Module
// =============================================================================

import { apiCall } from './api.js';
import { escapeHtml } from './utils.js';
import { state } from './state.js';

// ── Local state ──────────────────────────────────────────────────────────────
let _playlists = [];
let _filter = { source: 'all', tag: null, sort: 'newest', query: '' };

// ── Public init ──────────────────────────────────────────────────────────────
export function initPlaylistsView() {
    renderFilters();
    loadPlaylists();
    bindSearch();
}

// ── API helpers ──────────────────────────────────────────────────────────────
async function loadPlaylists() {
    const container = document.getElementById('playlists-grid');
    if (!container) return;
    container.innerHTML = '<div class="playlists-loading"><div class="spinner"></div></div>';
    try {
        // Fetch saved playlists AND generated-playlist history in parallel
        const [saved, resultsData] = await Promise.all([
            apiCall('/playlists/saved'),
            apiCall('/results?limit=100&type=prompt_playlist,seed_playlist,mcp_playlist').catch(() => ({ results: [] })),
        ]);

        const savedPlaylists = (Array.isArray(saved) ? saved : (saved.playlists || [])).map(p => ({
            ...p,
            _is_result: false,
        }));

        // Normalize result items to match the saved-playlist shape
        const historyItems = ((resultsData && resultsData.results) || []).map(r => ({
            id: r.id,
            name: r.title,
            prompt: r.prompt || '',
            created_at: r.created_at,
            source_mode: r.source_mode || null,
            track_count: r.track_count || 0,
            tags: [],
            rating: null,
            tracks: [],
            _is_result: true,
            _subtitle: r.subtitle || '',
        }));

        // Merge — saved IDs are integers, result IDs are hex strings so no collision
        _playlists = [...savedPlaylists, ...historyItems].sort(
            (a, b) => new Date(b.created_at || 0) - new Date(a.created_at || 0)
        );

        renderPlaylists();
    } catch (e) {
        container.innerHTML = `<p class="playlists-empty">Could not load playlists: ${escapeHtml(e.message)}</p>`;
    }
}

async function deletePlaylist(id, isResult = false) {
    if (!confirm('Delete this playlist?')) return;
    try {
        const endpoint = isResult
            ? `/results/${encodeURIComponent(id)}`
            : `/playlists/saved/${encodeURIComponent(id)}`;
        await apiCall(endpoint, { method: 'DELETE' });
        _playlists = _playlists.filter(p => String(p.id) !== String(id));
        renderPlaylists();
    } catch (e) {
        alert('Could not delete playlist: ' + e.message);
    }
}

async function updatePlaylistMeta(id, updates, isResult = false) {
    if (isResult) return; // Result history items don't support name/tag/rating edits
    try {
        await apiCall(`/playlists/saved/${encodeURIComponent(id)}`, {
            method: 'PUT',
            body: JSON.stringify(updates),
        });
    } catch (e) {
        console.error('Failed to update playlist:', e);
    }
}

async function playPlaylist(playlist) {
    // item_keys are not included in the list response — fetch lazily on play
    let item_keys = playlist.item_keys;
    if (!item_keys?.length) {
        try {
            if (playlist._is_result) {
                // Results store tracks in the snapshot (GenerateResponse shape)
                const detail = await apiCall(`/results/${playlist.id}`);
                item_keys = (detail.snapshot?.tracks || []).map(t => t.item_key).filter(Boolean);
            } else {
                // Saved playlists store tracks_json with item_key per track
                const data = await apiCall(`/playlists/saved/${playlist.id}/tracks`);
                item_keys = (data.tracks || []).map(t => t.item_key).filter(Boolean);
            }
        } catch (e) {
            alert('Could not load tracks: ' + e.message);
            return;
        }
    }
    if (!item_keys?.length) {
        alert('No playable tracks in this playlist.');
        return;
    }
    // Fetch zones to pick one
    try {
        const zones = await apiCall('/roon/zones');
        const active = (zones.zones || []).filter(z => z.state !== 'loading');
        if (!active.length) { alert('No active Roon zones found.'); return; }
        const zoneId = active[0].zone_id;
        await apiCall('/queue', {
            method: 'POST',
            body: JSON.stringify({ zone_id: zoneId, item_keys }),
        });
        showToast('▶ Playing: ' + (playlist.name || 'Playlist'));
    } catch (e) {
        alert('Could not play playlist: ' + e.message);
    }
}

async function saveForArc(playlist) {
    showArcModal(playlist);
}

// ── Render ────────────────────────────────────────────────────────────────────
function renderFilters() {
    const bar = document.getElementById('playlists-filter-bar');
    if (!bar) return;
    bar.innerHTML = `
        <div class="playlists-filter-group">
            <button class="plf-btn plf-btn--active" data-source="all">All</button>
            <button class="plf-btn" data-source="library">Library</button>
            <button class="plf-btn" data-source="hybrid">Hybrid</button>
            <button class="plf-btn" data-source="qobuz">Qobuz</button>
        </div>
        <div class="playlists-sort-group">
            <select id="playlists-sort" class="plf-select" aria-label="Sort playlists">
                <option value="newest">Newest</option>
                <option value="rating">Rating</option>
                <option value="name">Name</option>
            </select>
        </div>
    `;

    bar.querySelectorAll('.plf-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            bar.querySelectorAll('.plf-btn').forEach(b => b.classList.remove('plf-btn--active'));
            btn.classList.add('plf-btn--active');
            _filter.source = btn.dataset.source;
            renderPlaylists();
        });
    });

    document.getElementById('playlists-sort')?.addEventListener('change', e => {
        _filter.sort = e.target.value;
        renderPlaylists();
    });
}

function bindSearch() {
    document.getElementById('playlists-search')?.addEventListener('input', e => {
        _filter.query = e.target.value.toLowerCase();
        renderPlaylists();
    });
}

function filteredPlaylists() {
    let list = [..._playlists];
    if (_filter.source !== 'all') {
        list = list.filter(p => (p.source_mode || 'library') === _filter.source);
    }
    if (_filter.tag) {
        list = list.filter(p => (p.tags || []).includes(_filter.tag));
    }
    if (_filter.query) {
        list = list.filter(p =>
            (p.name || '').toLowerCase().includes(_filter.query) ||
            (p.prompt || '').toLowerCase().includes(_filter.query)
        );
    }
    if (_filter.sort === 'rating') {
        list.sort((a, b) => (b.rating || 0) - (a.rating || 0));
    } else if (_filter.sort === 'name') {
        list.sort((a, b) => (a.name || '').localeCompare(b.name || ''));
    } else {
        // newest first
        list.sort((a, b) => new Date(b.created_at || 0) - new Date(a.created_at || 0));
    }
    return list;
}

function renderPlaylists() {
    const container = document.getElementById('playlists-grid');
    if (!container) return;
    const list = filteredPlaylists();

    // Collect all tags for the tag filter row
    renderTagRow(list);

    if (!list.length) {
        container.innerHTML = '<p class="playlists-empty">No playlists found.</p>';
        return;
    }
    container.innerHTML = list.map(p => playlistCardHtml(p)).join('');

    // Bind card events
    container.querySelectorAll('.pl-card').forEach(card => {
        const id = card.dataset.id;
        const isResult = card.dataset.isResult === 'true';
        // IDs from saved_playlists are integers (stored as strings in dataset),
        // IDs from results are hex strings — compare as strings throughout.
        const playlist = _playlists.find(p => String(p.id) === id);
        if (!playlist) return;

        // Expand / collapse (with lazy track loading)
        card.querySelector('.pl-card-header')?.addEventListener('click', async e => {
            if (e.target.closest('button')) return; // don't expand on action clicks
            const isExpanding = !card.classList.contains('pl-card--expanded');
            card.classList.toggle('pl-card--expanded');
            if (isExpanding && !playlist._tracksLoaded) {
                const tracklistEl = card.querySelector('.pl-tracklist-inner');
                if (!tracklistEl) return;
                tracklistEl.innerHTML = '<div class="playlists-loading"><div class="spinner"></div></div>';
                try {
                    let tracks = [];
                    if (playlist._is_result) {
                        const detail = await apiCall(`/results/${playlist.id}`);
                        tracks = detail.snapshot?.tracks || [];
                    } else {
                        const data = await apiCall(`/playlists/saved/${playlist.id}/tracks`);
                        tracks = data.tracks || [];
                    }
                    playlist.tracks = tracks;
                    playlist._tracksLoaded = true;
                    if (tracks.length) {
                        tracklistEl.innerHTML = tracks.map((t, i) =>
                            `<div class="pl-track-row"><span class="pl-track-num">${i+1}</span><span class="pl-track-title">${escapeHtml(t.artist || '')} — ${escapeHtml(t.title || '')}</span></div>`
                        ).join('');
                    } else {
                        tracklistEl.innerHTML = '<p class="playlists-empty">No tracks found.</p>';
                    }
                } catch (err) {
                    tracklistEl.innerHTML = `<p class="playlists-empty">Could not load tracks: ${escapeHtml(err.message)}</p>`;
                }
            }
        });

        // Play button
        card.querySelector('.pl-action-play')?.addEventListener('click', e => {
            e.stopPropagation();
            playPlaylist(playlist);
        });

        // Save to Arc (saved playlists only)
        card.querySelector('.pl-action-arc')?.addEventListener('click', e => {
            e.stopPropagation();
            saveForArc(playlist);
        });

        // Delete
        card.querySelector('.pl-action-delete')?.addEventListener('click', e => {
            e.stopPropagation();
            deletePlaylist(id, isResult);
        });

        // Star rating (saved playlists only)
        card.querySelectorAll('.pl-star').forEach(star => {
            star.addEventListener('click', e => {
                e.stopPropagation();
                const rating = parseInt(star.dataset.rating);
                playlist.rating = rating;
                updatePlaylistMeta(id, { rating }, isResult);
                card.querySelectorAll('.pl-star').forEach(s => {
                    s.classList.toggle('pl-star--active', parseInt(s.dataset.rating) <= rating);
                });
            });
        });

        // Edit tags (saved playlists only)
        card.querySelector('.pl-tag-edit-btn')?.addEventListener('click', e => {
            e.stopPropagation();
            openTagEditor(card, playlist);
        });

        // Tag filter click
        card.querySelectorAll('.pl-tag').forEach(tagEl => {
            tagEl.addEventListener('click', e => {
                e.stopPropagation();
                const tag = tagEl.dataset.tag;
                _filter.tag = _filter.tag === tag ? null : tag;
                renderPlaylists();
            });
        });
    });
}

function renderTagRow(list) {
    const tagRow = document.getElementById('playlists-tag-row');
    if (!tagRow) return;
    const allTags = [...new Set(list.flatMap(p => p.tags || []))].sort();
    if (!allTags.length) { tagRow.innerHTML = ''; return; }
    tagRow.innerHTML = '<span class="plf-tag-label">Tags:</span>' +
        allTags.map(t => `<button class="plf-tag${_filter.tag === t ? ' plf-tag--active' : ''}" data-tag="${escapeHtml(t)}">#${escapeHtml(t)}</button>`).join('');
    tagRow.querySelectorAll('.plf-tag').forEach(btn => {
        btn.addEventListener('click', () => {
            _filter.tag = _filter.tag === btn.dataset.tag ? null : btn.dataset.tag;
            renderPlaylists();
        });
    });
}

function playlistCardHtml(p) {
    const tracks = p.tracks || [];
    const isResult = !!p._is_result;
    const rating = p.rating || 0;
    const stars = isResult ? '' : [1,2,3,4,5].map(n =>
        `<button class="pl-star${n <= rating ? ' pl-star--active' : ''}" data-rating="${n}" aria-label="${n} star">★</button>`
    ).join('');
    const tags = isResult ? '' : (p.tags || []).map(t =>
        `<span class="pl-tag${_filter.tag === t ? ' pl-tag--active' : ''}" data-tag="${escapeHtml(t)}">#${escapeHtml(t)}</span>`
    ).join('');
    const date = p.created_at ? new Date(p.created_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) : '';
    const sourceBadge = isResult
        ? '<span class="pl-source-badge pl-source-badge--history">history</span>'
        : `<span class="pl-source-badge pl-source-badge--${p.source_mode || 'library'}">${p.source_mode || 'library'}</span>`;
    const trackCount = p.track_count || tracks.length;
    const trackList = tracks.map((t, i) =>
        `<div class="pl-track-row"><span class="pl-track-num">${i+1}</span><span class="pl-track-title">${escapeHtml(t.artist || '')} — ${escapeHtml(t.title || '')}</span></div>`
    ).join('');
    const subtitle = p._subtitle ? `<div class="pl-card-subtitle">${escapeHtml(p._subtitle)}</div>` : '';

    return `
    <div class="pl-card${isResult ? ' pl-card--history' : ''}" data-id="${escapeHtml(String(p.id))}" data-is-result="${isResult}">
        <div class="pl-card-header">
            <div class="pl-card-info">
                <div class="pl-card-title">${escapeHtml(p.name || 'Untitled Playlist')}</div>
                ${p.prompt ? `<div class="pl-card-prompt">"${escapeHtml(p.prompt.slice(0, 100))}${p.prompt.length > 100 ? '…' : ''}"</div>` : ''}
                ${subtitle}
                <div class="pl-card-meta">
                    <span>${trackCount} tracks</span>
                    ${sourceBadge}
                    ${date ? `<span>${date}</span>` : ''}
                </div>
                ${!isResult ? `<div class="pl-card-tags">
                    ${tags}
                    <button class="pl-tag-edit-btn" title="Edit tags">+</button>
                </div>` : ''}
            </div>
            <div class="pl-card-side">
                ${!isResult ? `<div class="pl-stars" role="group" aria-label="Rating">${stars}</div>` : ''}
            </div>
        </div>
        <div class="pl-card-actions">
            <button class="btn btn-secondary pl-action-play">▶ Play</button>
            ${!isResult ? `<button class="btn btn-outline pl-action-arc">📱 Save for Arc</button>` : ''}
            <button class="btn-ghost pl-action-delete" title="Delete">🗑</button>
        </div>
        <div class="pl-tracklist">
            <div class="pl-tracklist-inner">${tracks.length ? trackList : ''}</div>
        </div>
    </div>`;
}

// ── Tag editor ────────────────────────────────────────────────────────────────
function openTagEditor(card, playlist) {
    const existing = document.querySelector('.pl-tag-editor');
    if (existing) existing.remove();

    const current = playlist.tags || [];
    const editor = document.createElement('div');
    editor.className = 'pl-tag-editor';
    editor.innerHTML = `
        <input class="pl-tag-input" type="text" placeholder="Add tag, press Enter" value="">
        <div class="pl-tag-editor-current">
            ${current.map(t => `<span class="pl-tag-editor-chip">${escapeHtml(t)} <button data-remove="${escapeHtml(t)}">×</button></span>`).join('')}
        </div>
    `;
    card.querySelector('.pl-card-header').appendChild(editor);

    const input = editor.querySelector('.pl-tag-input');
    input.focus();

    input.addEventListener('keydown', e => {
        if (e.key === 'Enter') {
            e.preventDefault();
            const tag = input.value.trim().replace(/^#/, '').toLowerCase();
            if (tag && !current.includes(tag)) {
                current.push(tag);
                playlist.tags = current;
                updatePlaylistMeta(playlist.id, { tags: current });
                renderPlaylists();
            }
        }
        if (e.key === 'Escape') editor.remove();
    });

    editor.querySelectorAll('[data-remove]').forEach(btn => {
        btn.addEventListener('click', () => {
            const tag = btn.dataset.remove;
            playlist.tags = current.filter(t => t !== tag);
            updatePlaylistMeta(playlist.id, { tags: playlist.tags });
            renderPlaylists();
        });
    });
}

// ── Arc modal ─────────────────────────────────────────────────────────────────
function showArcModal(playlist) {
    const existing = document.getElementById('arc-save-modal');
    if (existing) existing.remove();

    const modal = document.createElement('div');
    modal.id = 'arc-save-modal';
    modal.className = 'modal-overlay';
    modal.setAttribute('role', 'dialog');
    modal.setAttribute('aria-modal', 'true');
    modal.innerHTML = `
        <div class="modal-card">
            <button class="modal-close" id="arc-modal-close" aria-label="Close">×</button>
            <h2>Save for Roon Arc</h2>
            <div class="form-group">
                <label for="arc-playlist-name">Playlist name</label>
                <input type="text" id="arc-playlist-name" class="form-input" value="${escapeHtml(playlist.name || 'My Playlist')}">
            </div>
            <label class="checkbox-label">
                <input type="checkbox" id="arc-add-favorites" checked>
                <span>Add albums to favorites</span>
            </label>
            <div id="arc-modal-result" class="arc-modal-result hidden"></div>
            <div class="modal-actions">
                <button id="arc-modal-save" class="btn btn-primary">Save</button>
                <button id="arc-modal-cancel" class="btn btn-secondary">Cancel</button>
            </div>
        </div>
    `;
    document.body.appendChild(modal);

    modal.querySelector('#arc-modal-close').addEventListener('click', () => modal.remove());
    modal.querySelector('#arc-modal-cancel').addEventListener('click', () => modal.remove());
    modal.addEventListener('click', e => { if (e.target === modal) modal.remove(); });

    modal.querySelector('#arc-modal-save').addEventListener('click', async () => {
        const name = modal.querySelector('#arc-playlist-name').value.trim();
        const addFavorites = modal.querySelector('#arc-add-favorites').checked;
        const resultEl = modal.querySelector('#arc-modal-result');
        const saveBtn = modal.querySelector('#arc-modal-save');
        saveBtn.disabled = true;
        saveBtn.textContent = 'Saving…';
        resultEl.className = 'arc-modal-result';
        resultEl.textContent = '';
        try {
            const resp = await apiCall('/qobuz/prepare-for-arc', {
                method: 'POST',
                body: JSON.stringify({
                    playlist_id: playlist.id,
                    name,
                    add_to_favorites: addFavorites,
                }),
            });
            resultEl.className = 'arc-modal-result arc-modal-result--success';
            resultEl.textContent = `✓ Saved as Qobuz playlist — available in Roon Arc (${resp.saved || 0} tracks, ${resp.skipped || 0} skipped)`;
            saveBtn.textContent = 'Saved';
        } catch (e) {
            resultEl.className = 'arc-modal-result arc-modal-result--error';
            resultEl.textContent = 'Error: ' + e.message;
            saveBtn.disabled = false;
            saveBtn.textContent = 'Save';
        }
    });
}

// ── Toast helper ──────────────────────────────────────────────────────────────
function showToast(msg) {
    const el = document.getElementById('success-toast');
    const msgEl = document.getElementById('success-message');
    if (el && msgEl) { msgEl.textContent = msg; el.classList.remove('hidden'); setTimeout(() => el.classList.add('hidden'), 3000); }
}
