// =============================================================================
// Song Paths (v13.0)
// =============================================================================

import { apiCall } from './api.js';

let _initialized = false;
let _lastPath = null;
let _zoneCache = null;

async function searchTracks(q) {
    if (!q || q.length < 2) return [];
    try {
        const data = await apiCall(`/library/search?q=${encodeURIComponent(q)}`);
        return (data.tracks || data.results || []).slice(0, 25);
    } catch { return []; }
}

function fillDatalist(listId, tracks) {
    const list = document.getElementById(listId);
    if (!list) return;
    list.innerHTML = tracks.map(t =>
        `<option value="${t.artist} – ${t.title}" data-item-key="${t.item_key}"></option>`
    ).join('');
}

function resolveItemKey(inputEl, listId) {
    const list = document.getElementById(listId);
    if (!list) return null;
    const v = inputEl.value;
    for (const opt of list.options) {
        if (opt.value === v) return opt.dataset.itemKey;
    }
    return null;
}

async function getDefaultZone() {
    if (_zoneCache) return _zoneCache;
    try {
        const zones = await apiCall('/roon/zones');
        _zoneCache = zones && zones.length ? zones[0].zone_id : null;
    } catch { _zoneCache = null; }
    return _zoneCache;
}

function renderPath(result) {
    const container = document.getElementById('song-paths-result');
    if (!result || !result.path || !result.path.length) {
        container.innerHTML = '<div class="cluster-empty">No path found.</div>';
        return;
    }
    container.innerHTML = `
      <div style="margin-bottom:8px;color:var(--text-muted);font-size:13px;">
        ${result.steps} tracks · method: ${result.method}
      </div>
      ${result.path.map((t, i) => `
        <div class="song-paths-track">
          <span class="song-paths-track-index">${(i + 1).toString().padStart(2, '0')}</span>
          <div>
            <div><strong>${t.title}</strong></div>
            <div style="color:var(--text-muted);font-size:12px;">${t.artist}</div>
          </div>
          <div class="song-paths-track-bars" title="Energy / Valence / BPM">
            <div class="song-paths-bar" title="Energy ${(t.energy ?? 0).toFixed(2)}"><span style="width:${((t.energy ?? 0) * 100).toFixed(0)}%"></span></div>
            <div class="song-paths-bar" title="Valence ${(t.valence ?? 0).toFixed(2)}"><span style="width:${((t.valence ?? 0) * 100).toFixed(0)}%;background:#4caf50;"></span></div>
            <div class="song-paths-bar" title="BPM ${(t.bpm ?? 0).toFixed(0)}"><span style="width:${Math.min(100, ((t.bpm ?? 0) / 200) * 100).toFixed(0)}%;background:#7aa6ff;"></span></div>
          </div>
        </div>
      `).join('')}
    `;
}

export async function initSongPathsView() {
    if (_initialized) return;
    _initialized = true;

    const fromInput = document.getElementById('song-paths-from');
    const toInput = document.getElementById('song-paths-to');
    const stepsRange = document.getElementById('song-paths-steps');
    const stepsLabel = document.getElementById('song-paths-steps-value');
    const methodSel = document.getElementById('song-paths-method');
    const findBtn = document.getElementById('song-paths-find');
    const playBtn = document.getElementById('song-paths-play');

    stepsRange.addEventListener('input', () => { stepsLabel.textContent = stepsRange.value; });

    let debTimerFrom, debTimerTo;
    fromInput.addEventListener('input', () => {
        clearTimeout(debTimerFrom);
        debTimerFrom = setTimeout(async () => fillDatalist('song-paths-from-list', await searchTracks(fromInput.value)), 250);
    });
    toInput.addEventListener('input', () => {
        clearTimeout(debTimerTo);
        debTimerTo = setTimeout(async () => fillDatalist('song-paths-to-list', await searchTracks(toInput.value)), 250);
    });

    findBtn.addEventListener('click', async () => {
        const fromKey = resolveItemKey(fromInput, 'song-paths-from-list');
        const toKey = resolveItemKey(toInput, 'song-paths-to-list');
        if (!fromKey || !toKey) {
            alert('Pick both start and end tracks from the suggestion list.');
            return;
        }
        findBtn.disabled = true;
        findBtn.textContent = 'Finding…';
        try {
            const result = await apiCall('/song-path', {
                method: 'POST',
                body: JSON.stringify({
                    from_track_id: fromKey,
                    to_track_id: toKey,
                    max_steps: parseInt(stepsRange.value, 10),
                    method: methodSel.value,
                }),
            });
            _lastPath = result;
            renderPath(result);
            playBtn.disabled = false;
        } catch (err) {
            document.getElementById('song-paths-result').innerHTML =
                `<div class="cluster-error">Failed: ${err.message}</div>`;
        } finally {
            findBtn.disabled = false;
            findBtn.textContent = 'Find path';
        }
    });

    playBtn.addEventListener('click', async () => {
        if (!_lastPath) return;
        const zone = await getDefaultZone();
        if (!zone) { alert('No Roon zone available.'); return; }
        const itemKeys = _lastPath.path.map(t => t.item_key);
        try {
            await apiCall('/queue', {
                method: 'POST',
                body: JSON.stringify({ item_keys: itemKeys, zone_id: zone, mode: 'replace' }),
            });
        } catch (err) {
            alert(`Play failed: ${err.message}`);
        }
    });
}
