// =============================================================================
// Playlist Library Module
// =============================================================================

import { apiCall } from './api.js';
import { escapeHtml } from './utils.js';
import { state } from './state.js';
import { showSuccess } from './ui.js';

// ── Local state ──────────────────────────────────────────────────────────────
let _playlists = [];
let _filter = { source: 'all', tag: null, sort: 'newest', query: '' };
let _activeTab = 'playlists';
let _djSets = [];

// ── Public init ──────────────────────────────────────────────────────────────
export function initPlaylistsView() {
    _bindTabs();
    if (_activeTab === 'dj-sets') {
        loadDJSets();
    } else {
        renderFilters();
        loadPlaylists();
        bindSearch();
    }
}

function _bindTabs() {
    document.querySelectorAll('.rs-playlist-tab').forEach(btn => {
        btn.addEventListener('click', () => {
            const tab = btn.dataset.tab;
            if (tab === _activeTab) return;
            _activeTab = tab;
            document.querySelectorAll('.rs-playlist-tab').forEach(b => {
                b.classList.toggle('on', b.dataset.tab === tab);
                b.setAttribute('aria-selected', b.dataset.tab === tab ? 'true' : 'false');
            });
            const playlistsPane = document.getElementById('playlists-tab-content');
            const djPane        = document.getElementById('dj-sets-tab-content');
            if (tab === 'all') {
                if (playlistsPane) playlistsPane.style.display = '';
                if (djPane)        djPane.style.display        = '';
                renderFilters(); loadPlaylists(); bindSearch(); loadDJSets();
            } else if (tab === 'dj-sets') {
                if (playlistsPane) playlistsPane.style.display = 'none';
                if (djPane)        djPane.style.display        = '';
                loadDJSets();
            } else {
                if (playlistsPane) playlistsPane.style.display = '';
                if (djPane)        djPane.style.display        = 'none';
                renderFilters(); loadPlaylists(); bindSearch();
            }
        });
    });
}

function _updatePlaylistCounts() {
    const setText = (id, val) => { const el = document.getElementById(id); if (el) el.textContent = val; };
    setText('pl-count-all', _playlists.length + _djSets.length);
    setText('pl-count-playlist', _playlists.length);
    setText('pl-count-djset', _djSets.length);
}

// ── API helpers ──────────────────────────────────────────────────────────────
async function loadPlaylists() {
    const container = document.getElementById('playlists-grid');
    if (!container) return;
    container.innerHTML = '<div class="rs-loading"><div class="rs-spinner"></div><span class="rs-loading-text">Loading…</span></div>';
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
            _subtitle: r.ai_description || r.subtitle || '',
            _ai_tags: r.ai_tags || [],
        }));

        // Merge — saved IDs are integers, result IDs are hex strings so no collision
        _playlists = [...savedPlaylists, ...historyItems].sort(
            (a, b) => new Date(b.created_at || 0) - new Date(a.created_at || 0)
        );

        renderPlaylists();
    } catch (e) {
        container.innerHTML = `<p class="rs-empty">Could not load playlists: ${escapeHtml(e.message)}</p>`;
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
        container.innerHTML = `
            <div class="rs-empty-state">
                <div class="rs-empty-icon" style="background:rgba(146,112,212,0.15);color:#9270d4;">▦</div>
                <div class="rs-empty-title">Geen afspeellijsten</div>
                <div class="rs-empty-desc">Genereer je eerste AI-playlist met een prompt.</div>
                <button class="rs-empty-cta" style="background:rgba(146,112,212,0.15);color:#9270d4;border-color:#9270d4;"
                    onclick="window.location.hash='playlist'">Nieuwe playlist ✦</button>
            </div>`;
        return;
    }
    container.innerHTML = list.map(p => playlistCardHtml(p)).join('');
    _updatePlaylistCounts();

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
                tracklistEl.innerHTML = '<div class="rs-loading"><div class="rs-spinner"></div><span class="rs-loading-text">Loading tracks…</span></div>';
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
                        tracklistEl.innerHTML = '<p class="rs-empty">No tracks found.</p>';
                    }
                } catch (err) {
                    tracklistEl.innerHTML = `<p class="rs-empty">Could not load tracks: ${escapeHtml(err.message)}</p>`;
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
    <div class="rs-playlist-card pl-card${isResult ? ' pl-card--history' : ''}" data-id="${escapeHtml(String(p.id))}" data-is-result="${isResult}">
        <div class="pl-card-header">
            <div class="pl-card-info">
                <div class="rs-playlist-name pl-card-title">${escapeHtml(p.name || 'Untitled Playlist')}</div>
                ${p.prompt ? `<div class="pl-card-prompt">"${escapeHtml(p.prompt.slice(0, 100))}${p.prompt.length > 100 ? '…' : ''}"</div>` : ''}
                ${subtitle}
                <div class="rs-playlist-meta pl-card-meta">
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
            <button class="rs-btn rs-btn--secondary pl-action-play">▶ Play</button>
            ${!isResult ? `<button class="rs-btn rs-btn--secondary pl-action-arc">📱 Save for Arc</button>` : ''}
            <button class="rs-btn rs-btn--danger pl-action-delete" title="Delete">🗑</button>
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

// ── DJ Set → Qobuz Arc modal ─────────────────────────────────────────────────
function _showDJSetArcModal(set) {
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
            <h2>Opslaan voor Roon Arc</h2>
            <p style="color:var(--text-muted);font-size:0.88rem;margin-bottom:var(--spacing-sm);">
                Tracks worden opgezocht op Qobuz en als playlist opgeslagen.
                Zo kun je ze onderweg luisteren via Roon Arc.
            </p>
            <div class="form-group">
                <label for="arc-playlist-name">Naam op Qobuz</label>
                <input type="text" id="arc-playlist-name" class="form-input" value="${escapeHtml(set.name)}">
            </div>
            <label class="checkbox-label">
                <input type="checkbox" id="arc-add-favorites" checked>
                <span>Albums ook aan favorieten toevoegen</span>
            </label>
            <div id="arc-modal-result" class="arc-modal-result hidden"></div>
            <div class="modal-actions">
                <button id="arc-modal-save" class="btn btn-primary">Opslaan op Qobuz</button>
                <button id="arc-modal-cancel" class="btn btn-secondary">Annuleren</button>
            </div>
        </div>
    `;
    document.body.appendChild(modal);

    const close = () => modal.remove();
    modal.querySelector('#arc-modal-close').addEventListener('click', close);
    modal.querySelector('#arc-modal-cancel').addEventListener('click', close);
    modal.addEventListener('click', e => { if (e.target === modal) close(); });

    modal.querySelector('#arc-modal-save').addEventListener('click', async () => {
        const name = modal.querySelector('#arc-playlist-name').value.trim() || set.name;
        const addFavorites = modal.querySelector('#arc-add-favorites').checked;
        const resultEl = modal.querySelector('#arc-modal-result');
        const saveBtn = modal.querySelector('#arc-modal-save');
        saveBtn.disabled = true;
        saveBtn.textContent = 'Bezig…';
        resultEl.className = 'arc-modal-result';
        resultEl.textContent = '';

        const trackItems = (set.tracks || []).map(t => ({ title: t.title, artist: t.artist }));
        if (!trackItems.length) {
            resultEl.className = 'arc-modal-result arc-modal-result--error';
            resultEl.textContent = 'Geen tracks in deze set.';
            saveBtn.disabled = false;
            saveBtn.textContent = 'Opslaan op Qobuz';
            return;
        }

        try {
            const resp = await apiCall('/qobuz/prepare-for-arc', {
                method: 'POST',
                body: JSON.stringify({
                    playlist_name: name,
                    track_items: trackItems,
                    add_to_favorites: addFavorites,
                }),
            });
            resultEl.className = 'arc-modal-result arc-modal-result--success';
            resultEl.textContent = `✓ Opgeslagen als Qobuz-playlist — beschikbaar in Roon Arc (${resp.tracks_resolved || 0} tracks, ${resp.tracks_skipped || 0} niet gevonden)`;
            saveBtn.textContent = 'Opgeslagen';
        } catch (e) {
            resultEl.className = 'arc-modal-result arc-modal-result--error';
            resultEl.textContent = 'Fout: ' + e.message;
            saveBtn.disabled = false;
            saveBtn.textContent = 'Opslaan op Qobuz';
        }
    });
}

// ── Toast helper ──────────────────────────────────────────────────────────────
function showToast(msg) {
    showSuccess(msg);
}

// =============================================================================
// DJ Sets tab
// =============================================================================

export async function loadDJSets() {
    const grid = document.getElementById('dj-sets-grid');
    if (!grid) return;
    grid.innerHTML = '<div class="playlists-loading"><div class="spinner"></div></div>';
    try {
        _djSets = await apiCall('/dj-sets');
        renderDJSets();
    } catch (e) {
        grid.innerHTML = `<p class="playlists-empty">Kon DJ sets niet laden: ${escapeHtml(e.message)}</p>`;
    }
}

function _moodLabel(m) {
    return m ? m.charAt(0).toUpperCase() + m.slice(1) : '';
}

function _djSetCardHtml(s) {
    const date = s.created_at ? new Date(s.created_at).toLocaleDateString('nl-NL', { day: 'numeric', month: 'short', year: 'numeric' }) : '';
    const moodLine = [_moodLabel(s.start_mood), _moodLabel(s.end_mood)].filter(Boolean).join(' → ');
    const bpmLine = s.start_bpm != null
        ? `${Math.round(s.start_bpm)}–${Math.round(s.end_bpm || s.start_bpm)} BPM`
        : '';
    const genres = (s.genres || []).slice(0, 3).map(g => `<span class="pl-tag">${escapeHtml(g)}</span>`).join('');
    const trackList = (s.tracks || []).map((t, i) =>
        `<div class="pl-track-row"><span class="pl-track-num">${i + 1}</span><span class="pl-track-title">${escapeHtml(t.artist || '')} — ${escapeHtml(t.title || '')}</span></div>`
    ).join('');
    return `
    <div class="pl-card" data-dj-id="${s.id}">
        <div class="pl-card-header">
            <div class="pl-card-info">
                <div class="pl-card-title">${escapeHtml(s.name)}<span class="pl-dj-badge">DJ Set</span></div>
                <div class="pl-card-meta">
                    <span>${s.track_count} tracks</span>
                    ${bpmLine ? `<span>${bpmLine}</span>` : ''}
                    ${moodLine ? `<span>${moodLine}</span>` : ''}
                    ${date ? `<span>${date}</span>` : ''}
                </div>
                ${genres ? `<div class="pl-card-tags">${genres}</div>` : ''}
            </div>
        </div>
        <div class="pl-card-actions">
            <button class="btn btn-secondary dj-action-play">▶ Afspelen</button>
            <button class="btn btn-outline dj-action-arc">📱 Opslaan voor Arc</button>
            <button class="btn-ghost dj-action-delete" title="Verwijderen">🗑</button>
        </div>
        <div class="pl-tracklist">
            <div class="pl-tracklist-inner">${trackList}</div>
        </div>
    </div>`;
}

function renderDJSets() {
    const grid = document.getElementById('dj-sets-grid');
    if (!grid) return;
    if (!_djSets.length) {
        grid.innerHTML = `
            <div class="rs-empty-state">
                <div class="rs-empty-icon" style="background:rgba(146,112,212,0.15);color:#9270d4;">🎚</div>
                <div class="rs-empty-title">Nog geen DJ sets</div>
                <div class="rs-empty-desc">Bouw een set met beatmatching en sla hem op via de DJ Set pagina.</div>
                <button class="rs-empty-cta" style="background:rgba(146,112,212,0.15);color:#9270d4;border-color:#9270d4;"
                    onclick="window.location.hash='dj-set'">DJ Set bouwen</button>
            </div>`;
        return;
    }
    grid.innerHTML = _djSets.map(_djSetCardHtml).join('');
    _updatePlaylistCounts();

    grid.querySelectorAll('.pl-card[data-dj-id]').forEach(card => {
        const id = parseInt(card.dataset.djId, 10);
        const set = _djSets.find(s => s.id === id);

        // Expand/collapse tracklist on card click (not on button click)
        card.addEventListener('click', e => {
            if (e.target.closest('button')) return;
            card.querySelector('.pl-tracklist').classList.toggle('pl-tracklist--open');
        });

        card.querySelector('.dj-action-play')?.addEventListener('click', async () => {
            const zones = await apiCall('/roon/zones').catch(() => []);
            if (!zones.length) { alert('Geen Roon zones beschikbaar.'); return; }
            const zone = zones.length === 1 ? zones[0] : zones.find(z => z.display_name === 'Mac mini') || zones[0];
            const keys = (set.tracks || []).map(t => t.item_key).filter(Boolean);
            if (!keys.length) { alert('Geen afspeelbare tracks in deze set.'); return; }
            try {
                await apiCall('/queue', { method: 'POST', body: JSON.stringify({ item_keys: keys, zone_id: zone.zone_id, mode: 'replace' }) });
                showToast(`▶ ${set.name} speelt af op ${zone.display_name}`);
            } catch (e) {
                alert('Afspelen mislukt: ' + e.message);
            }
        });

        card.querySelector('.dj-action-arc')?.addEventListener('click', () => {
            _showDJSetArcModal(set);
        });

        card.querySelector('.dj-action-delete')?.addEventListener('click', async () => {
            if (!confirm(`"${set.name}" verwijderen?`)) return;
            try {
                await apiCall(`/dj-sets/${id}`, { method: 'DELETE' });
                _djSets = _djSets.filter(s => s.id !== id);
                renderDJSets();
            } catch (e) {
                alert('Verwijderen mislukt: ' + e.message);
            }
        });
    });
}
