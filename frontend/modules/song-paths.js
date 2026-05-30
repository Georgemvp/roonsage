// =============================================================================
// Song Paths (v13.0+ / redesigned UI)
// =============================================================================

import { apiCall } from './api.js';

let _lastPath = null;
let _pendingRestore = null;

/**
 * Restore a previously saved song-path result into the view.
 * If the view is already mounted, renders immediately.
 * Otherwise, stores the snapshot so initSongPathsView() picks it up.
 */
export function queuePathRestore(snapshot) {
    _pendingRestore = snapshot;
    const el = document.getElementById('song-paths-result');
    if (el) {
        _lastPath = snapshot;
        renderPath(el, snapshot);
        _pendingRestore = null;
    }
}

async function searchTracks(q) {
    if (!q || q.length < 2) return [];
    try {
        const data = await apiCall(`/library/search?q=${encodeURIComponent(q)}`);
        return (data.tracks || data.results || data || []).slice(0, 20);
    } catch { return []; }
}

function makeAutocomplete(inputEl, dropdownEl, onSelect) {
    let selectedKey = null;
    let activeIdx = -1;
    let debTimer = null;
    let lastResults = [];

    function getItems() { return dropdownEl.querySelectorAll('.sp-ac-item'); }

    function setActive(idx) {
        getItems().forEach((el, i) => el.classList.toggle('sp-ac-active', i === idx));
        activeIdx = idx;
    }

    function close() { dropdownEl.hidden = true; activeIdx = -1; }

    function esc(s) {
        return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function renderResults(tracks) {
        lastResults = tracks;
        if (!tracks.length) {
            dropdownEl.innerHTML = '<div class="sp-ac-empty">No results</div>';
            dropdownEl.hidden = false;
            return;
        }
        dropdownEl.innerHTML = tracks.map((t, i) =>
            `<div class="sp-ac-item" data-idx="${i}">
                <strong>${esc(t.title)}</strong>
                <small>${esc(t.artist)}${t.album ? ' · ' + esc(t.album) : ''}</small>
            </div>`
        ).join('');
        dropdownEl.hidden = false;
        activeIdx = -1;

        dropdownEl.querySelectorAll('.sp-ac-item').forEach(el => {
            el.addEventListener('mousedown', e => {
                e.preventDefault();
                selectTrack(parseInt(el.dataset.idx, 10));
            });
            el.addEventListener('mouseover', () => setActive(parseInt(el.dataset.idx, 10)));
        });
    }

    function selectTrack(idx) {
        const t = lastResults[idx];
        if (!t) return;
        selectedKey = t.item_key;
        inputEl.value = `${t.artist} – ${t.title}`;
        close();
        if (onSelect) onSelect(t);
    }

    inputEl.addEventListener('input', () => {
        selectedKey = null;
        clearTimeout(debTimer);
        const q = inputEl.value.trim();
        if (q.length < 2) { close(); return; }
        debTimer = setTimeout(async () => renderResults(await searchTracks(q)), 220);
    });

    inputEl.addEventListener('keydown', e => {
        const items = getItems();
        if (e.key === 'ArrowDown') { e.preventDefault(); setActive(Math.min(activeIdx + 1, items.length - 1)); }
        else if (e.key === 'ArrowUp') { e.preventDefault(); setActive(Math.max(activeIdx - 1, 0)); }
        else if (e.key === 'Enter' && activeIdx >= 0) { e.preventDefault(); selectTrack(activeIdx); }
        else if (e.key === 'Escape') close();
    });

    inputEl.addEventListener('blur', () => setTimeout(close, 150));
    inputEl.addEventListener('focus', () => { if (lastResults.length && !selectedKey) renderResults(lastResults); });

    function setTrack(track) {
        selectedKey = track.item_key;
        inputEl.value = `${track.artist} – ${track.title}`;
        lastResults = [track];
        close();
        if (onSelect) onSelect(track);
    }

    return { getKey: () => selectedKey, setTrack };
}

async function loadZones(zoneSel) {
    try {
        const zones = await apiCall('/roon/zones');
        if (!zones || !zones.length) return;
        zoneSel.innerHTML = zones.map(z =>
            `<option value="${z.zone_id}">${z.display_name}</option>`
        ).join('');
    } catch {
        zoneSel.innerHTML = '<option value="">— unavailable —</option>';
    }
}

async function fetchNowPlaying() {
    const zones = await apiCall('/roon/zones');
    if (!zones || !zones.length) return null;
    const playing = zones.find(z => z.state === 'playing' && z.now_playing);
    if (!playing) return null;
    const np = playing.now_playing;
    const three = np.three_line || {};
    const title = three.line1 || np.one_line?.line1;
    const artist = three.line2 || '';
    if (!title) return null;
    return { title, artist, zone_id: playing.zone_id };
}

function transitionBadge(dist) {
    if (dist == null) return '';
    let color, label;
    if (dist < 0.15) { color = '#4caf50'; label = 'smooth'; }
    else if (dist < 0.35) { color = '#e5a00d'; label = 'ok'; }
    else { color = '#e57373'; label = 'rough'; }
    return `<div class="sp-transition" title="Transition distance: ${dist.toFixed(2)}">
        <span class="sp-transition-dot" style="background:${color}"></span>
        <span class="sp-transition-label" style="color:${color}">${label}</span>
    </div>`;
}

function renderPath(result) {
    const container = document.getElementById('song-paths-result');
    const statsCount = document.getElementById('sp2-stats-count');

    if (!result || !result.path || !result.path.length) {
        container.innerHTML = '<div class="cluster-empty">No path found.</div>';
        if (statsCount) statsCount.textContent = '—';
        return;
    }

    const trackCount = result.path.length;
    const requested = result.requested_steps || 0;
    const shortNote = requested > 0 && trackCount < requested
        ? `<span style="color:var(--amber);margin-left:8px" title="Not enough analyzed tracks in the library to fill the requested length">⚠ ${trackCount} of ${requested} requested</span>`
        : '';

    if (statsCount) statsCount.textContent = `${trackCount} tracks`;

    const rows = result.path.map((t, i) => {
        const isFirst = i === 0;
        const isLast = i === result.path.length - 1;
        const badge = !isLast ? transitionBadge(t.transition_dist) : '';
        const rowClass = isFirst ? 'song-paths-track song-paths-track--endpoint' : isLast ? 'song-paths-track song-paths-track--endpoint' : 'song-paths-track';
        return `
        <div class="${rowClass}">
          <span class="song-paths-track-index">${(i + 1).toString().padStart(2, '0')}</span>
          <div style="min-width:0;flex:1">
            <div style="font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${t.title}</div>
            <div style="color:var(--text-muted);font-size:12px">${t.artist}${t.album ? ' · ' + t.album : ''}</div>
          </div>
          <div class="song-paths-track-meta">
            ${t.camelot ? `<span class="sp2-camelot-badge">${t.camelot}</span>` : ''}
            ${t.bpm ? `<span style="color:var(--text-muted);font-size:11px">${Math.round(t.bpm)} BPM</span>` : ''}
          </div>
          <div class="song-paths-track-bars" title="Energy / Valence / BPM">
            <div class="song-paths-bar" title="Energy ${(t.energy ?? 0).toFixed(2)}">
              <span style="width:${((t.energy ?? 0) * 100).toFixed(0)}%"></span></div>
            <div class="song-paths-bar" title="Valence ${(t.valence ?? 0).toFixed(2)}">
              <span style="width:${((t.valence ?? 0) * 100).toFixed(0)}%;background:#4caf50;"></span></div>
          </div>
          ${badge}
        </div>`;
    }).join('');

    container.innerHTML = `
      <div class="sp2-result-header">
        <span>${trackCount} tracks · <span style="color:var(--accent)">${result.method}</span></span>
        ${shortNote}
      </div>
      ${rows}`;
}

function updateNodeDisplay(side, track) {
    const artEl = document.getElementById(`sp2-${side}-art`);
    const emptyEl = document.getElementById(`sp2-${side}-empty`);
    const nameEl = document.getElementById(`sp2-${side}-name`);

    if (artEl) {
        artEl.src = `/api/art/${track.item_key}?width=160&height=160`;
        artEl.hidden = false;
    }
    if (emptyEl) emptyEl.hidden = true;
    if (nameEl) nameEl.textContent = `${track.artist} – ${track.title}`;
}

export async function initSongPathsView() {
    const fromInput = document.getElementById('song-paths-from');
    const toInput = document.getElementById('song-paths-to');
    const fromDrop = document.getElementById('song-paths-from-dropdown');
    const toDrop = document.getElementById('song-paths-to-dropdown');
    const stepsRange = document.getElementById('song-paths-steps');
    const stepsLabel = document.getElementById('song-paths-steps-value');
    const methodSel = document.getElementById('song-paths-method');
    const moodSel = document.getElementById('song-paths-mood');
    const zoneSel = document.getElementById('song-paths-zone');
    const nowPlayingBtn = document.getElementById('song-paths-now-playing');
    const findBtn = document.getElementById('song-paths-find');
    const playBtn = document.getElementById('song-paths-play');
    const moodPillsContainer = document.getElementById('sp2-mood-pills');

    if (!fromInput || !toInput) return;

    if (fromInput.dataset.acInit) return;
    fromInput.dataset.acInit = '1';

    function updateFindBtn() {
        if (findBtn) findBtn.disabled = !(fromAc.getKey() && toAc.getKey());
    }

    const fromAc = makeAutocomplete(fromInput, fromDrop, track => {
        updateNodeDisplay('start', track);
        updateFindBtn();
    });

    const toAc = makeAutocomplete(toInput, toDrop, track => {
        updateNodeDisplay('end', track);
        updateFindBtn();
    });

    // Clicking art/name focuses the search input
    const startArtWrap = document.getElementById('sp2-start-art-wrap');
    const endArtWrap = document.getElementById('sp2-end-art-wrap');
    if (startArtWrap) startArtWrap.addEventListener('click', () => fromInput.focus());
    if (endArtWrap) endArtWrap.addEventListener('click', () => toInput.focus());

    // Steps slider
    if (stepsRange) stepsRange.addEventListener('input', () => {
        if (stepsLabel) stepsLabel.textContent = stepsRange.value;
    });

    // Method description
    const METHOD_DESCS = {
        features: 'Kiest stap voor stap de best passende track op tempo, energie en toonaard. Snel en voorspelbaar.',
        clap: 'Vergelijkt hoe muziek écht klinkt — klankkleur, sfeer en instrumentatie. Vangt gelijkenissen die tempo en toon missen.',
        hybrid: 'Combineert klankkleur met tempo en toonaard voor de rijkste sonische brug. Aanbevolen voor de beste kwaliteit.',
    };
    const methodDescEl = document.getElementById('sp2-method-desc');
    function updateMethodDesc() {
        if (methodDescEl && methodSel) methodDescEl.textContent = METHOD_DESCS[methodSel.value] ?? '';
    }
    if (methodSel) {
        methodSel.addEventListener('change', updateMethodDesc);
        updateMethodDesc();
    }

    // Mood pills
    if (moodPillsContainer) {
        moodPillsContainer.addEventListener('click', e => {
            const pill = e.target.closest('.sp2-mood-pill');
            if (!pill) return;
            moodPillsContainer.querySelectorAll('.sp2-mood-pill').forEach(p => p.classList.remove('sp2-mood-pill-active'));
            pill.classList.add('sp2-mood-pill-active');
            if (moodSel) moodSel.value = pill.dataset.mood || '';
        });
    }

    await loadZones(zoneSel);

    // Now Playing
    if (nowPlayingBtn) {
        nowPlayingBtn.addEventListener('click', async () => {
            nowPlayingBtn.disabled = true;
            const origHTML = nowPlayingBtn.innerHTML;
            nowPlayingBtn.innerHTML = '<span class="material-symbols-outlined">hourglass_empty</span> Loading…';
            try {
                const np = await fetchNowPlaying();
                if (!np) { alert('Nothing is playing right now.'); return; }
                const results = await searchTracks(`${np.artist} ${np.title}`);
                if (!results.length) { alert(`Could not find "${np.title}" in the library.`); return; }
                fromAc.setTrack(results[0]);
            } catch (err) {
                alert(`Error: ${err.message}`);
            } finally {
                nowPlayingBtn.disabled = false;
                nowPlayingBtn.innerHTML = origHTML;
            }
        });
    }

    // Generate Path
    if (findBtn) {
        findBtn.addEventListener('click', async () => {
            const fromKey = fromAc.getKey();
            const toKey = toAc.getKey();
            if (!fromKey || !toKey) {
                alert('Select both tracks first.');
                return;
            }
            findBtn.disabled = true;
            findBtn.innerHTML = '<span class="material-symbols-outlined">hourglass_empty</span> Finding…';
            try {
                const mood = moodSel?.value || null;
                const result = await apiCall('/song-path', {
                    method: 'POST',
                    body: JSON.stringify({
                        from_track_id: fromKey,
                        to_track_id: toKey,
                        max_steps: parseInt(stepsRange?.value ?? 10, 10),
                        method: methodSel?.value ?? 'features',
                        mood: mood || undefined,
                    }),
                });
                _lastPath = result;
                renderPath(result);
                if (playBtn) playBtn.disabled = false;
            } catch (err) {
                document.getElementById('song-paths-result').innerHTML =
                    `<div class="cluster-error">Failed: ${err.message}</div>`;
            } finally {
                findBtn.disabled = !(fromAc.getKey() && toAc.getKey());
                findBtn.innerHTML = '<span class="material-symbols-outlined fill">auto_awesome</span> Generate Path';
            }
        });
    }

    // Play Path
    if (playBtn) {
        playBtn.addEventListener('click', async () => {
            if (!_lastPath) return;
            const zone = zoneSel?.value;
            if (!zone) { alert('No Roon zone selected.'); return; }
            const itemKeys = _lastPath.path.map(t => t.item_key);
            try {
                await apiCall('/queue', {
                    method: 'POST',
                    body: JSON.stringify({ item_keys: itemKeys, zone_id: zone, mode: 'replace' }),
                });
            } catch (err) {
                alert(`Playback failed: ${err.message}`);
            }
        });
    }

    // Restore a saved path that was queued before the view was mounted
    if (_pendingRestore) {
        _lastPath = _pendingRestore;
        renderPath(_pendingRestore);
        if (playBtn) playBtn.disabled = false;
        _pendingRestore = null;
    }
}
