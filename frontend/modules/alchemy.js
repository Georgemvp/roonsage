// =============================================================================
// Song Alchemy — v13.0 / v13.4 / improved
// Two-column layout, zone selector, now playing seed, append mode,
// album art, feature bars, radar placeholder, profile modal,
// Qobuz save, subtract weight + track limit sliders
// =============================================================================

import { apiCall } from './api.js';

let _initialized = false;
let _add = new Map();       // item_key -> track metadata
let _subtract = new Map();
let _lastMix = null;
let _radarChart = null;
let _zonesMap = new Map();  // zone_id -> display_name
let _lastSearchResults = [];

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

async function searchTracks(q) {
    if (!q || q.length < 2) return [];
    try {
        const data = await apiCall(`/library/search?q=${encodeURIComponent(q)}`);
        return (data.tracks || data.results || (Array.isArray(data) ? data : [])).slice(0, 25);
    } catch { return []; }
}

function _artThumb(imageKey) {
    if (!imageKey) return '<div class="alchemy-art-placeholder">♪</div>';
    return `<img class="alchemy-art-thumb" src="/api/art/${encodeURIComponent(imageKey)}?width=40&height=40" alt="" loading="lazy" onerror="this.parentElement.innerHTML='<div class=alchemy-art-placeholder>♪</div>'">`;
}

function renderSearchResults(tracks) {
    _lastSearchResults = tracks;
    const list = document.getElementById('alchemy-search-results');
    if (!list) return;
    if (!tracks.length) { list.innerHTML = ''; return; }
    list.innerHTML = tracks.map(t => {
        const inAdd = _add.has(t.item_key);
        const inSub = _subtract.has(t.item_key);
        const rowClass = ['alchemy-result-row', inAdd ? 'alchemy-in-add' : inSub ? 'alchemy-in-sub' : ''].filter(Boolean).join(' ');
        return `
          <div class="${rowClass}" data-item-key="${t.item_key}">
            ${_artThumb(t.image_key || null)}
            <div class="alchemy-meta">
              <strong>${t.title || ''}</strong>
              <div style="color:var(--text-muted);font-size:11px;">${t.artist || ''}${t.album ? ' · ' + t.album : ''}</div>
            </div>
            <button class="btn btn-secondary alchemy-add${inAdd ? ' alchemy-btn-active-add' : ''}" data-action="add">${inAdd ? '✓ADD' : '+ADD'}</button>
            <button class="btn btn-secondary alchemy-sub${inSub ? ' alchemy-btn-active-sub' : ''}" data-action="subtract">${inSub ? '✓SUB' : '−SUB'}</button>
          </div>
        `;
    }).join('');
    list.querySelectorAll('button').forEach(btn => {
        btn.addEventListener('click', e => {
            const row = e.currentTarget.closest('.alchemy-result-row');
            const key = row.dataset.itemKey;
            const meta = tracks.find(t => t.item_key === key);
            if (!meta) return;
            if (btn.dataset.action === 'add') {
                _add.set(key, meta);
                _subtract.delete(key);
            } else {
                _subtract.set(key, meta);
                _add.delete(key);
            }
            renderBuckets();
            renderSearchResults(_lastSearchResults);
        });
    });
}

// ---------------------------------------------------------------------------
// Buckets
// ---------------------------------------------------------------------------

function renderBuckets() {
    const addList = document.getElementById('alchemy-add-list');
    const subList = document.getElementById('alchemy-subtract-list');
    const render = map => Array.from(map.entries()).map(([k, m]) => `
        <li>
          <span>${m.artist || ''} – ${m.title || ''}</span>
          <button class="btn btn-secondary" data-remove="${k}">×</button>
        </li>
    `).join('');
    if (addList) addList.innerHTML = render(_add);
    if (subList) subList.innerHTML = render(_subtract);
    addList?.querySelectorAll('button[data-remove]').forEach(b =>
        b.addEventListener('click', () => { _add.delete(b.dataset.remove); renderBuckets(); renderSearchResults(_lastSearchResults); }));
    subList?.querySelectorAll('button[data-remove]').forEach(b =>
        b.addEventListener('click', () => { _subtract.delete(b.dataset.remove); renderBuckets(); renderSearchResults(_lastSearchResults); }));
}

// ---------------------------------------------------------------------------
// Feature mini-bars in results
// ---------------------------------------------------------------------------

const _FEAT_LABELS = { bpm: 'BPM', energy: 'Energy', danceability: 'Dance', valence: 'Valence' };

function _featureBars(track) {
    const bpmHtml = track.bpm != null
        ? `<span class="alchemy-feat-tag">${Math.round(track.bpm)} BPM</span>`
        : '';
    const bars = ['energy', 'danceability', 'valence'].map(f => {
        if (track[f] == null) return '';
        const pct = Math.round((track[f] ?? 0) * 100);
        return `<span class="alchemy-feat-bar-wrap" title="${_FEAT_LABELS[f]}: ${pct}%">
            <span class="alchemy-feat-bar-label">${_FEAT_LABELS[f]}</span>
            <span class="alchemy-feat-bar-track"><span class="alchemy-feat-bar-fill" style="width:${pct}%"></span></span>
        </span>`;
    }).join('');
    if (!bpmHtml && !bars) return '';
    return `<div class="alchemy-feat-row">${bpmHtml}${bars}</div>`;
}

// ---------------------------------------------------------------------------
// Mix results
// ---------------------------------------------------------------------------

function renderMix(mix, containerId = 'alchemy-result') {
    const out = document.getElementById(containerId);
    if (!out) return;
    if (!mix.results || !mix.results.length) {
        out.innerHTML = '<div class="cluster-empty">Geen overeenkomsten gevonden.</div>';
        return;
    }
    out.innerHTML = `
      <div style="margin-bottom:8px;color:var(--text-muted);font-size:13px;">
        ${mix.results.length} matches · pool van ${mix.n_pool} tracks
      </div>
      ${mix.results.map(t => `
        <div class="alchemy-result-track">
          ${_artThumb(t.image_key || null)}
          <div class="alchemy-result-track-info">
            <div><strong>${t.title}</strong> <span style="color:var(--text-muted);"> · ${t.artist}</span></div>
            ${_featureBars(t)}
          </div>
          <span class="alchemy-score">${((t.similarity ?? 0) * 100).toFixed(1)}%</span>
        </div>
      `).join('')}
    `;
    if (containerId === 'alchemy-result') renderRadar(mix);
}

// ---------------------------------------------------------------------------
// Radar chart
// ---------------------------------------------------------------------------

function renderRadar(mix) {
    const canvas = document.getElementById('alchemy-radar');
    const placeholder = document.getElementById('alchemy-radar-placeholder');
    if (!canvas || !window.Chart || !mix.target) return;
    canvas.hidden = false;
    if (placeholder) placeholder.hidden = true;
    const labels = mix.feature_columns;
    const targetData = labels.map(l => Math.max(0, Math.min(1, mix.target[l] ?? 0)));
    const meanData = labels.map(l => Math.max(0, Math.min(1, (mix.result_mean || {})[l] ?? 0)));
    if (_radarChart) { _radarChart.destroy(); _radarChart = null; }
    _radarChart = new window.Chart(canvas, {
        type: 'radar',
        data: {
            labels,
            datasets: [
                { label: 'Target', data: targetData, borderColor: '#e5a00d', backgroundColor: 'rgba(229,160,13,0.2)' },
                { label: 'Resultaat gem.', data: meanData, borderColor: '#7aa6ff', backgroundColor: 'rgba(122,166,255,0.15)' },
            ],
        },
        options: {
            scales: { r: { min: 0, max: 1, ticks: { display: false } } },
            plugins: { legend: { labels: { color: '#ddd' } } },
        },
    });
}

async function ensureChartJs() {
    if (window.Chart) return;
    await new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = 'https://cdn.jsdelivr.net/npm/chart.js';
        s.onload = resolve; s.onerror = reject;
        document.head.appendChild(s);
    });
}

// ---------------------------------------------------------------------------
// Zones
// ---------------------------------------------------------------------------

async function fetchZones() {
    try {
        const zones = await apiCall('/roon/zones');
        const list = Array.isArray(zones) ? zones : [];
        _zonesMap = new Map(list.map(z => [z.zone_id, z.display_name]));
        return list;
    } catch { return []; }
}

function _renderZoneSelect(selectEl, zones, currentValue = null) {
    if (!selectEl) return;
    selectEl.innerHTML = zones.map(z =>
        `<option value="${z.zone_id}"${z.zone_id === currentValue ? ' selected' : ''}>${z.display_name}</option>`
    ).join('') || '<option value="">(geen zones gevonden)</option>';
}

// ---------------------------------------------------------------------------
// Qobuz save
// ---------------------------------------------------------------------------

async function saveToQobuz(tracks) {
    const name = prompt('Naam van de Qobuz playlist:', 'Alchemy Mix');
    if (!name) return;
    const resultEl = document.getElementById('alchemy-qobuz-result');
    if (resultEl) { resultEl.hidden = false; resultEl.textContent = 'Opslaan…'; resultEl.className = 'alchemy-qobuz-result'; }
    try {
        const result = await apiCall('/qobuz/playlist/save', {
            method: 'POST',
            body: JSON.stringify({
                name: name.trim(),
                tracks: tracks.map(t => ({ artist: t.artist || '', title: t.title || '' })),
                description: 'Gegenereerd via Song Alchemy',
                is_public: false,
            }),
        });
        if (resultEl) {
            const saved = result.tracks_saved || 0;
            const total = saved + (result.tracks_unmatched || 0);
            resultEl.textContent = result.success
                ? `${saved}/${total} tracks opgeslagen als "${result.playlist_name || name}"`
                : result.error || 'Opslaan mislukt';
            resultEl.className = `alchemy-qobuz-result ${result.success ? 'is-success' : 'is-error'}`;
        }
    } catch (err) {
        if (resultEl) { resultEl.textContent = err.message || 'Opslaan mislukt'; resultEl.className = 'alchemy-qobuz-result is-error'; }
    }
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

function setupTabs() {
    const tabs = document.querySelectorAll('.alchemy-tab');
    tabs.forEach(t => t.addEventListener('click', () => {
        tabs.forEach(x => x.classList.remove('is-active'));
        t.classList.add('is-active');
        const target = t.dataset.tab;
        document.querySelectorAll('.alchemy-tab-panel').forEach(panel => {
            const active = panel.id === `alchemy-tab-${target}`;
            panel.classList.toggle('is-active', active);
            panel.hidden = !active;
        });
        if (target === 'profiles') loadProfiles();
    }));
}

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

async function loadProfiles() {
    const wrap = document.getElementById('alchemy-profiles-list');
    if (!wrap) return;
    wrap.innerHTML = '<div style="color:var(--text-muted);font-size:13px;">Profielen laden…</div>';
    try {
        const [profiles] = await Promise.all([
            apiCall('/alchemy/profiles'),
            fetchZones(),
        ]);
        renderProfiles(profiles);
    } catch (err) {
        wrap.innerHTML = `<div class="cluster-error">Kon profielen niet laden: ${err.message}</div>`;
    }
}

function renderProfiles(profiles) {
    const wrap = document.getElementById('alchemy-profiles-list');
    if (!wrap) return;
    if (!profiles || !profiles.length) {
        wrap.innerHTML = `
          <div class="alchemy-empty">
            Nog geen profielen opgeslagen. Bouw eerst een Mix en klik op
            <em>Profiel opslaan…</em> om hem hier op te laten verschijnen.
          </div>
        `;
        return;
    }
    wrap.innerHTML = profiles.map(p => {
        const zoneName = p.zone_id ? (_zonesMap.get(p.zone_id) || p.zone_id) : 'geen zone';
        return `
          <div class="alchemy-profile-card" data-profile-id="${p.id}">
            <div class="alchemy-profile-head">
              <h4>${p.name}</h4>
              <span class="alchemy-profile-meta">${p.zone_id ? '🔗 ' + zoneName : 'geen zone'}</span>
            </div>
            <div class="alchemy-profile-feats">
              ${Object.entries(p.add_features || {}).map(([k, v]) =>
                  `<span class="alchemy-profile-feat">${k}: ${(v ?? 0).toFixed(2)}</span>`
              ).join('')}
            </div>
            <div class="alchemy-profile-actions">
              <button class="btn btn-primary btn-sm" data-action="play" data-profile-id="${p.id}">&#9654; Speel af</button>
              <button class="btn btn-secondary btn-sm" data-action="gen" data-profile-id="${p.id}">Genereer</button>
              <button class="btn btn-secondary btn-sm" data-action="delete" data-profile-id="${p.id}">Verwijder</button>
            </div>
            <div class="alchemy-profile-result" id="alchemy-profile-result-${p.id}"></div>
          </div>
        `;
    }).join('');

    wrap.querySelectorAll('button[data-action]').forEach(btn => {
        btn.addEventListener('click', async () => {
            const id = btn.dataset.profileId;
            const action = btn.dataset.action;
            if (action === 'delete') {
                if (!confirm('Profiel verwijderen?')) return;
                try {
                    await apiCall(`/alchemy/profiles/${id}`, { method: 'DELETE' });
                    loadProfiles();
                } catch (err) { alert(`Verwijderen mislukt: ${err.message}`); }
                return;
            }
            btn.disabled = true;
            const orig = btn.textContent;
            btn.textContent = 'Bezig…';
            try {
                const data = await apiCall(`/alchemy/profiles/${id}/generate`, {
                    method: 'POST',
                    body: JSON.stringify({ limit: 25, play: action === 'play' }),
                });
                renderMix(data, `alchemy-profile-result-${id}`);
            } catch (err) {
                const out = document.getElementById(`alchemy-profile-result-${id}`);
                if (out) out.innerHTML = `<div class="cluster-error">${err.message}</div>`;
            } finally {
                btn.disabled = false;
                btn.textContent = orig;
            }
        });
    });
}

// ---------------------------------------------------------------------------
// Profile modal
// ---------------------------------------------------------------------------

function openProfileModal(zones) {
    const modal = document.getElementById('alchemy-profile-modal');
    const nameInput = document.getElementById('alchemy-profile-name-input');
    const zoneSelect = document.getElementById('alchemy-profile-zone-select');
    if (!modal) return;
    nameInput.value = '';
    _renderZoneSelect(zoneSelect, zones, null);
    const noZone = document.createElement('option');
    noZone.value = ''; noZone.textContent = '— geen zone —';
    zoneSelect.insertBefore(noZone, zoneSelect.firstChild);
    zoneSelect.value = '';
    modal.hidden = false;
    nameInput.focus();
}

function closeProfileModal() {
    const modal = document.getElementById('alchemy-profile-modal');
    if (modal) modal.hidden = true;
}

async function saveCurrentMixAsProfile() {
    if (!_add.size) { alert('Selecteer eerst minstens één track in het ADD vak.'); return; }
    const zones = await fetchZones();
    openProfileModal(zones);
}

// ---------------------------------------------------------------------------
// Surprise Me
// ---------------------------------------------------------------------------

async function setupSurpriseBar() {
    const select = document.getElementById('alchemy-surprise-zone');
    const btn = document.getElementById('alchemy-surprise-btn');
    const playBtn = document.getElementById('alchemy-surprise-play-btn');
    const zones = await fetchZones();
    _renderZoneSelect(select, zones, zones[0]?.zone_id);

    let _lastSurpriseData = null;

    btn?.addEventListener('click', async () => {
        const zoneId = select?.value;
        if (!zoneId) { alert('Geen zone geselecteerd.'); return; }
        btn.disabled = true;
        const orig = btn.textContent;
        btn.textContent = 'Verrassen…';
        try {
            const data = await apiCall('/alchemy/surprise', {
                method: 'POST',
                body: JSON.stringify({ zone_id: zoneId, limit: 25 }),
            });
            if (data.error) {
                document.getElementById('alchemy-result').innerHTML = `<div class="cluster-empty">${data.error}</div>`;
                return;
            }
            _lastSurpriseData = data;
            renderMix(data);
            if (playBtn) playBtn.disabled = false;
            // Show mix tab with results
            const mixTab = document.querySelector('.alchemy-tab[data-tab="mix"]');
            if (mixTab && !mixTab.classList.contains('is-active')) mixTab.click();
        } catch (err) {
            document.getElementById('alchemy-result').innerHTML = `<div class="cluster-error">Surprise mislukt: ${err.message}</div>`;
        } finally {
            btn.disabled = false;
            btn.textContent = orig;
        }
    });

    playBtn?.addEventListener('click', async () => {
        if (!_lastSurpriseData) return;
        const zoneId = select?.value;
        if (!zoneId) return;
        try {
            await apiCall('/alchemy/surprise', {
                method: 'POST',
                body: JSON.stringify({ zone_id: zoneId, limit: 25, play: true }),
            });
        } catch (err) { alert(`Afspelen mislukt: ${err.message}`); }
    });
}

// ---------------------------------------------------------------------------
// Now playing as ADD seed
// ---------------------------------------------------------------------------

async function useNowPlayingAsAdd() {
    try {
        const zones = await apiCall('/roon/zones');
        if (!zones?.length) { alert('Geen Roon zones beschikbaar.'); return; }
        const np = zones[0].now_playing;
        if (!np) { alert('Er speelt nu niets.'); return; }
        const title = np.three_line?.line1 || np.one_line?.line1 || '';
        const artist = np.three_line?.line2 || np.one_line?.line2 || '';
        if (!title) { alert('Kan het huidige nummer niet herkennen.'); return; }
        const results = await apiCall(`/library/search?q=${encodeURIComponent(title + ' ' + artist)}`);
        const tracks = results.tracks || results.results || (Array.isArray(results) ? results : []);
        const match = tracks.find(t =>
            t.title?.toLowerCase() === title.toLowerCase() &&
            (t.artist || '').toLowerCase().includes((artist || '').toLowerCase())
        ) || tracks[0];
        if (!match) { alert(`Nummer "${title}" niet gevonden in bibliotheek.`); return; }
        _add.set(match.item_key, match);
        _subtract.delete(match.item_key);
        renderBuckets();
        renderSearchResults(_lastSearchResults);
    } catch (err) { alert(`Fout: ${err.message}`); }
}

// ---------------------------------------------------------------------------
// View init
// ---------------------------------------------------------------------------

export async function initAlchemyView() {
    if (_initialized) return;
    _initialized = true;

    await ensureChartJs().catch(() => {});

    const searchInput = document.getElementById('alchemy-search');
    const mixBtn = document.getElementById('alchemy-mix-btn');
    const playBtn = document.getElementById('alchemy-play-btn');
    const appendBtn = document.getElementById('alchemy-append-btn');
    const saveQobuzBtn = document.getElementById('alchemy-save-qobuz-btn');
    const saveProfileBtn = document.getElementById('alchemy-save-profile-btn');
    const nowPlayingBtn = document.getElementById('alchemy-nowplaying-btn');
    const limitSlider = document.getElementById('alchemy-limit');
    const limitVal = document.getElementById('alchemy-limit-val');
    const swSlider = document.getElementById('alchemy-subtract-weight');
    const swVal = document.getElementById('alchemy-subtract-weight-val');
    const zoneSelect = document.getElementById('alchemy-mix-zone');
    const modalConfirmBtn = document.getElementById('alchemy-modal-confirm');
    const modalCancelBtn = document.getElementById('alchemy-modal-cancel');

    // Populate zone selector for mix tab
    fetchZones().then(zones => _renderZoneSelect(zoneSelect, zones, zones[0]?.zone_id));

    // Sliders
    limitSlider?.addEventListener('input', () => { if (limitVal) limitVal.textContent = limitSlider.value; });
    swSlider?.addEventListener('input', () => { if (swVal) swVal.textContent = parseFloat(swSlider.value).toFixed(1); });

    // Search with debounce
    let debTimer;
    searchInput?.addEventListener('input', () => {
        clearTimeout(debTimer);
        debTimer = setTimeout(async () => renderSearchResults(await searchTracks(searchInput.value)), 250);
    });

    // Now playing as ADD
    nowPlayingBtn?.addEventListener('click', useNowPlayingAsAdd);

    // Mix
    mixBtn?.addEventListener('click', async () => {
        if (!_add.size) { alert('Voeg minstens één track toe aan het ADD vak.'); return; }
        mixBtn.disabled = true;
        mixBtn.textContent = 'Mixing…';
        try {
            const limit = parseInt(limitSlider?.value || '25', 10);
            const subtractWeight = parseFloat(swSlider?.value || '0.5');
            const mix = await apiCall('/alchemy/mix', {
                method: 'POST',
                body: JSON.stringify({
                    add: Array.from(_add.keys()),
                    subtract: Array.from(_subtract.keys()),
                    limit,
                    subtract_weight: subtractWeight,
                }),
            });
            _lastMix = mix;
            renderMix(mix);
            if (playBtn) playBtn.disabled = false;
            if (appendBtn) appendBtn.disabled = false;
            if (saveQobuzBtn) saveQobuzBtn.disabled = false;
            if (saveProfileBtn) saveProfileBtn.disabled = false;
        } catch (err) {
            const out = document.getElementById('alchemy-result');
            if (out) out.innerHTML = `<div class="cluster-error">Mix mislukt: ${err.message}</div>`;
        } finally {
            mixBtn.disabled = false;
            mixBtn.textContent = 'Mix';
        }
    });

    // Play (replace queue)
    playBtn?.addEventListener('click', async () => {
        if (!_lastMix) return;
        const zoneId = zoneSelect?.value;
        if (!zoneId) { alert('Geen zone geselecteerd.'); return; }
        try {
            await apiCall('/queue', {
                method: 'POST',
                body: JSON.stringify({ item_keys: _lastMix.results.map(t => t.item_key), zone_id: zoneId, mode: 'replace' }),
            });
        } catch (err) { alert(`Afspelen mislukt: ${err.message}`); }
    });

    // Append to queue
    appendBtn?.addEventListener('click', async () => {
        if (!_lastMix) return;
        const zoneId = zoneSelect?.value;
        if (!zoneId) { alert('Geen zone geselecteerd.'); return; }
        try {
            await apiCall('/queue', {
                method: 'POST',
                body: JSON.stringify({ item_keys: _lastMix.results.map(t => t.item_key), zone_id: zoneId, mode: 'append' }),
            });
        } catch (err) { alert(`Toevoegen mislukt: ${err.message}`); }
    });

    // Save to Qobuz
    saveQobuzBtn?.addEventListener('click', () => {
        if (_lastMix?.results?.length) saveToQobuz(_lastMix.results);
    });

    // Save as profile
    saveProfileBtn?.addEventListener('click', saveCurrentMixAsProfile);

    // Modal confirm
    modalConfirmBtn?.addEventListener('click', async () => {
        const nameInput = document.getElementById('alchemy-profile-name-input');
        const zoneInput = document.getElementById('alchemy-profile-zone-select');
        const name = nameInput?.value?.trim();
        if (!name) { nameInput?.focus(); return; }
        try {
            await apiCall('/alchemy/profiles', {
                method: 'POST',
                body: JSON.stringify({
                    name,
                    add_track_ids: Array.from(_add.keys()),
                    subtract_track_ids: Array.from(_subtract.keys()),
                    zone_id: zoneInput?.value || null,
                }),
            });
            closeProfileModal();
            document.querySelector('.alchemy-tab[data-tab="profiles"]')?.click();
        } catch (err) { alert(`Opslaan mislukt: ${err.message}`); }
    });

    // Modal cancel + overlay click
    modalCancelBtn?.addEventListener('click', closeProfileModal);
    document.getElementById('alchemy-profile-modal')?.addEventListener('click', e => {
        if (e.target === e.currentTarget) closeProfileModal();
    });

    setupTabs();
    setupSurpriseBar();
    renderBuckets();
}
