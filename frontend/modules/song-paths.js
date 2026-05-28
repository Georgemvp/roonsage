// =============================================================================
// Song Paths (v13.0+)
// =============================================================================

import { apiCall } from './api.js';

let _lastPath = null;

async function searchTracks(q) {
    if (!q || q.length < 2) return [];
    try {
        const data = await apiCall(`/library/search?q=${encodeURIComponent(q)}`);
        return (data.tracks || data.results || data || []).slice(0, 20);
    } catch { return []; }
}

/**
 * Wire up a custom autocomplete on inputEl / dropdownEl.
 * Returns { getKey, setTrack } — getKey() returns the selected item_key,
 * setTrack(track) programmatically selects a result.
 */
function makeAutocomplete(inputEl, dropdownEl) {
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
            dropdownEl.innerHTML = '<div class="sp-ac-empty">Geen resultaten</div>';
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
    }

    return { getKey: () => selectedKey, setTrack };
}

// ---------------------------------------------------------------------------
// Zone loader
// ---------------------------------------------------------------------------

async function loadZones(zoneSel) {
    try {
        const zones = await apiCall('/roon/zones');
        if (!zones || !zones.length) return;
        zoneSel.innerHTML = zones.map(z =>
            `<option value="${z.zone_id}">${z.display_name}</option>`
        ).join('');
    } catch {
        zoneSel.innerHTML = '<option value="">— niet beschikbaar —</option>';
    }
}

// ---------------------------------------------------------------------------
// Now Playing
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Transition quality indicator
// ---------------------------------------------------------------------------

function transitionBadge(dist) {
    if (dist == null) return '';
    let color, label;
    if (dist < 0.15) { color = '#4caf50'; label = 'smooth'; }
    else if (dist < 0.35) { color = '#e5a00d'; label = 'ok'; }
    else { color = '#e57373'; label = 'rough'; }
    return `<div class="sp-transition" title="Transitie-afstand: ${dist.toFixed(2)}">
        <span class="sp-transition-dot" style="background:${color}"></span>
        <span class="sp-transition-label" style="color:${color}">${label}</span>
    </div>`;
}

// ---------------------------------------------------------------------------
// Render path
// ---------------------------------------------------------------------------

function renderPath(result) {
    const container = document.getElementById('song-paths-result');
    if (!result || !result.path || !result.path.length) {
        container.innerHTML = '<div class="cluster-empty">Geen pad gevonden.</div>';
        return;
    }
    const rows = result.path.map((t, i) => {
        const badge = i < result.path.length - 1 ? transitionBadge(t.transition_dist) : '';
        return `
        <div class="song-paths-track">
          <span class="song-paths-track-index">${(i + 1).toString().padStart(2, '0')}</span>
          <div>
            <div><strong>${t.title}</strong></div>
            <div style="color:var(--text-muted);font-size:12px;">${t.artist}</div>
          </div>
          <div class="song-paths-track-bars" title="Energy / Valence / BPM">
            <div class="song-paths-bar" title="Energy ${(t.energy ?? 0).toFixed(2)}">
              <span style="width:${((t.energy ?? 0) * 100).toFixed(0)}%"></span></div>
            <div class="song-paths-bar" title="Valence ${(t.valence ?? 0).toFixed(2)}">
              <span style="width:${((t.valence ?? 0) * 100).toFixed(0)}%;background:#4caf50;"></span></div>
            <div class="song-paths-bar" title="BPM ${(t.bpm ?? 0).toFixed(0)}">
              <span style="width:${Math.min(100, ((t.bpm ?? 0) / 200) * 100).toFixed(0)}%;background:#7aa6ff;"></span></div>
          </div>
          ${badge}
        </div>`;
    }).join('');

    container.innerHTML = `
      <div style="margin-bottom:8px;color:var(--text-muted);font-size:13px;">
        ${result.steps} tracks · method: ${result.method}
      </div>
      ${rows}`;
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

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

    if (!fromInput || !toInput) return;

    // Guard against double-init on back-navigation (DOM-bound, not module-bound)
    if (fromInput.dataset.acInit) return;
    fromInput.dataset.acInit = '1';

    const fromAc = makeAutocomplete(fromInput, fromDrop);
    const toAc = makeAutocomplete(toInput, toDrop);

    stepsRange.addEventListener('input', () => { stepsLabel.textContent = stepsRange.value; });

    // Load zones
    await loadZones(zoneSel);

    // Now Playing button
    nowPlayingBtn.addEventListener('click', async () => {
        nowPlayingBtn.disabled = true;
        nowPlayingBtn.textContent = '…';
        try {
            const np = await fetchNowPlaying();
            if (!np) { alert('Niets speelt momenteel af.'); return; }

            // Search for the track to get its item_key
            const results = await searchTracks(`${np.artist} ${np.title}`);
            if (!results.length) { alert(`Kon "${np.title}" niet vinden in de library.`); return; }

            // Pick the closest match (first result)
            fromAc.setTrack(results[0]);

            // Also switch to the playing zone
            for (const opt of zoneSel.options) {
                if (opt.value && zoneSel.options[zoneSel.selectedIndex].value === '') {
                    // try to match zone if we know it
                }
            }
        } catch (err) {
            alert(`Fout: ${err.message}`);
        } finally {
            nowPlayingBtn.disabled = false;
            nowPlayingBtn.innerHTML = '&#9654; Nu aan';
        }
    });

    findBtn.addEventListener('click', async () => {
        const fromKey = fromAc.getKey();
        const toKey = toAc.getKey();
        if (!fromKey || !toKey) {
            alert('Kies beide tracks via de suggesties.');
            return;
        }
        findBtn.disabled = true;
        findBtn.textContent = 'Finding…';
        try {
            const mood = moodSel?.value || null;
            const result = await apiCall('/song-path', {
                method: 'POST',
                body: JSON.stringify({
                    from_track_id: fromKey,
                    to_track_id: toKey,
                    max_steps: parseInt(stepsRange.value, 10),
                    method: methodSel.value,
                    mood: mood || undefined,
                }),
            });
            _lastPath = result;
            renderPath(result);
            playBtn.disabled = false;
        } catch (err) {
            document.getElementById('song-paths-result').innerHTML =
                `<div class="cluster-error">Mislukt: ${err.message}</div>`;
        } finally {
            findBtn.disabled = false;
            findBtn.textContent = 'Find path';
        }
    });

    playBtn.addEventListener('click', async () => {
        if (!_lastPath) return;
        const zone = zoneSel.value;
        if (!zone) { alert('Geen Roon zone geselecteerd.'); return; }
        const itemKeys = _lastPath.path.map(t => t.item_key);
        try {
            await apiCall('/queue', {
                method: 'POST',
                body: JSON.stringify({ item_keys: itemKeys, zone_id: zone, mode: 'replace' }),
            });
        } catch (err) {
            alert(`Afspelen mislukt: ${err.message}`);
        }
    });
}
