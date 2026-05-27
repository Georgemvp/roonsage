// =============================================================================
// Song Alchemy (v13.0) + Saved Profiles + Surprise Me (v13.4)
// =============================================================================

import { apiCall } from './api.js';

let _initialized = false;
let _add = new Map();        // item_key -> {artist, title}
let _subtract = new Map();
let _lastMix = null;
let _lastSurprise = null;
let _zoneCache = null;
let _radarChart = null;

async function searchTracks(q) {
    if (!q || q.length < 2) return [];
    try {
        const data = await apiCall(`/library/search?q=${encodeURIComponent(q)}`);
        return (data.tracks || data.results || []).slice(0, 25);
    } catch { return []; }
}

function renderSearchResults(tracks) {
    const list = document.getElementById('alchemy-search-results');
    list.innerHTML = tracks.map(t => `
      <div class="alchemy-result-row" data-item-key="${t.item_key}">
        <div class="alchemy-meta">
          <div><strong>${t.title || ''}</strong></div>
          <div style="color:var(--text-muted);font-size:12px;">${t.artist || ''}</div>
        </div>
        <button class="btn btn-secondary alchemy-add" data-action="add">+</button>
        <button class="btn btn-secondary alchemy-sub" data-action="subtract">−</button>
      </div>
    `).join('');
    list.querySelectorAll('button').forEach(btn => {
        btn.addEventListener('click', (e) => {
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
        });
    });
}

function renderBuckets() {
    const addList = document.getElementById('alchemy-add-list');
    const subList = document.getElementById('alchemy-subtract-list');
    const render = (map) => Array.from(map.entries()).map(([k, m]) => `
        <li>
          <span>${m.artist || ''} – ${m.title || ''}</span>
          <button class="btn btn-secondary" data-remove="${k}">×</button>
        </li>
    `).join('');
    addList.innerHTML = render(_add);
    subList.innerHTML = render(_subtract);
    addList.querySelectorAll('button[data-remove]').forEach(b =>
        b.addEventListener('click', () => { _add.delete(b.dataset.remove); renderBuckets(); }));
    subList.querySelectorAll('button[data-remove]').forEach(b =>
        b.addEventListener('click', () => { _subtract.delete(b.dataset.remove); renderBuckets(); }));
}

function renderMix(mix, containerId = 'alchemy-result') {
    const out = document.getElementById(containerId);
    if (!out) return;
    if (!mix.results || !mix.results.length) {
        out.innerHTML = '<div class="cluster-empty">No matches found.</div>';
        return;
    }
    out.innerHTML = `
      <div style="margin-bottom:8px;color:var(--text-muted);font-size:13px;">
        ${mix.results.length} matches · pool van ${mix.n_pool} tracks
      </div>
      ${mix.results.map(t => `
        <div class="alchemy-result-track">
          <div>
            <strong>${t.title}</strong>
            <span style="color:var(--text-muted);"> · ${t.artist}</span>
          </div>
          <span class="alchemy-score">${((t.similarity ?? 0) * 100).toFixed(1)}%</span>
        </div>
      `).join('')}
    `;
    if (containerId === 'alchemy-result') renderRadar(mix);
}

function renderRadar(mix) {
    const canvas = document.getElementById('alchemy-radar');
    if (!canvas || !window.Chart || !mix.target) return;
    canvas.hidden = false;
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
                { label: 'Result avg', data: meanData, borderColor: '#7aa6ff', backgroundColor: 'rgba(122,166,255,0.15)' },
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
        s.onload = resolve;
        s.onerror = reject;
        document.head.appendChild(s);
    });
}

async function fetchZones() {
    try {
        const zones = await apiCall('/roon/zones');
        return Array.isArray(zones) ? zones : [];
    } catch { return []; }
}

async function getDefaultZone() {
    if (_zoneCache) return _zoneCache;
    const zones = await fetchZones();
    _zoneCache = zones.length ? zones[0].zone_id : null;
    return _zoneCache;
}

function _renderZoneSelect(selectEl, zones, currentValue = null) {
    if (!selectEl) return;
    selectEl.innerHTML = zones.map(z =>
        `<option value="${z.zone_id}"${z.zone_id === currentValue ? ' selected' : ''}>${z.display_name}</option>`
    ).join('') || '<option value="">(geen zones gevonden)</option>';
}

// =============================================================================
// Tabs
// =============================================================================

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

// =============================================================================
// Profiles
// =============================================================================

async function loadProfiles() {
    const wrap = document.getElementById('alchemy-profiles-list');
    if (!wrap) return;
    wrap.innerHTML = '<div style="color:var(--text-muted);font-size:13px;">Profielen laden…</div>';
    try {
        const profiles = await apiCall('/alchemy/profiles');
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
            <em>Opslaan als profiel…</em> om hem hier op te laten verschijnen.
          </div>
        `;
        return;
    }
    wrap.innerHTML = profiles.map(p => `
      <div class="alchemy-profile-card" data-profile-id="${p.id}">
        <div class="alchemy-profile-head">
          <h4>${p.name}</h4>
          <span class="alchemy-profile-meta">${p.zone_id ? '🔗 ' + p.zone_id : 'geen zone'}</span>
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
    `).join('');

    wrap.querySelectorAll('button[data-action]').forEach(btn => {
        btn.addEventListener('click', async () => {
            const id = btn.dataset.profileId;
            const action = btn.dataset.action;
            if (action === 'delete') {
                if (!confirm('Profiel verwijderen?')) return;
                try {
                    await apiCall(`/alchemy/profiles/${id}`, { method: 'DELETE' });
                    loadProfiles();
                } catch (err) {
                    alert(`Verwijderen mislukt: ${err.message}`);
                }
                return;
            }
            btn.disabled = true;
            const orig = btn.textContent;
            btn.textContent = 'Bezig…';
            try {
                const body = { limit: 25, play: action === 'play' };
                const data = await apiCall(`/alchemy/profiles/${id}/generate`, {
                    method: 'POST',
                    body: JSON.stringify(body),
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

async function saveCurrentMixAsProfile() {
    if (!_add.size) {
        alert('Selecteer eerst minstens één track in het + vak.');
        return;
    }
    const name = prompt('Profielnaam:', '');
    if (!name) return;
    const zones = await fetchZones();
    const zoneOptions = zones.map(z => `${z.zone_id} (${z.display_name})`).join('\n');
    const zoneAnswer = window.prompt(
        `Optioneel: koppel een zone (laat leeg voor geen koppeling).\n\nBeschikbaar:\n${zoneOptions}`,
        ''
    );
    const zoneId = (zoneAnswer || '').trim().split(' ')[0] || null;

    try {
        await apiCall('/alchemy/profiles', {
            method: 'POST',
            body: JSON.stringify({
                name: name.trim(),
                add_track_ids: Array.from(_add.keys()),
                subtract_track_ids: Array.from(_subtract.keys()),
                zone_id: zoneId,
            }),
        });
        // Switch to Profiles tab
        const tab = document.querySelector('.alchemy-tab[data-tab="profiles"]');
        if (tab) tab.click();
    } catch (err) {
        alert(`Opslaan mislukt: ${err.message}`);
    }
}

// =============================================================================
// Surprise Me
// =============================================================================

async function setupSurpriseBar() {
    const select = document.getElementById('alchemy-surprise-zone');
    const btn = document.getElementById('alchemy-surprise-btn');
    const playBtn = document.getElementById('alchemy-surprise-play-btn');
    const zones = await fetchZones();
    _renderZoneSelect(select, zones, zones[0]?.zone_id);

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
                document.getElementById('alchemy-result').innerHTML =
                    `<div class="cluster-empty">${data.error}</div>`;
                return;
            }
            _lastSurprise = data;
            renderMix(data);
            playBtn.disabled = false;
        } catch (err) {
            document.getElementById('alchemy-result').innerHTML =
                `<div class="cluster-error">Surprise mislukt: ${err.message}</div>`;
        } finally {
            btn.disabled = false;
            btn.textContent = orig;
        }
    });

    playBtn?.addEventListener('click', async () => {
        if (!_lastSurprise) return;
        const zoneId = select?.value;
        if (!zoneId) return;
        try {
            await apiCall('/alchemy/surprise', {
                method: 'POST',
                body: JSON.stringify({ zone_id: zoneId, limit: 25, play: true }),
            });
        } catch (err) {
            alert(`Afspelen mislukt: ${err.message}`);
        }
    });
}

// =============================================================================
// View init
// =============================================================================

export async function initAlchemyView() {
    if (_initialized) return;
    _initialized = true;

    await ensureChartJs().catch(() => {/* radar simply won't render */});

    const searchInput = document.getElementById('alchemy-search');
    const mixBtn = document.getElementById('alchemy-mix-btn');
    const playBtn = document.getElementById('alchemy-play-btn');
    const saveBtn = document.getElementById('alchemy-save-profile-btn');

    let debTimer;
    searchInput.addEventListener('input', () => {
        clearTimeout(debTimer);
        debTimer = setTimeout(async () => renderSearchResults(await searchTracks(searchInput.value)), 250);
    });

    mixBtn.addEventListener('click', async () => {
        if (!_add.size) { alert('Voeg minstens één track toe aan het + vak.'); return; }
        mixBtn.disabled = true;
        mixBtn.textContent = 'Mixing…';
        try {
            const mix = await apiCall('/alchemy/mix', {
                method: 'POST',
                body: JSON.stringify({
                    add: Array.from(_add.keys()),
                    subtract: Array.from(_subtract.keys()),
                    limit: 25,
                }),
            });
            _lastMix = mix;
            renderMix(mix);
            playBtn.disabled = false;
            if (saveBtn) saveBtn.disabled = false;
        } catch (err) {
            document.getElementById('alchemy-result').innerHTML =
                `<div class="cluster-error">Mix mislukt: ${err.message}</div>`;
        } finally {
            mixBtn.disabled = false;
            mixBtn.textContent = 'Mix';
        }
    });

    playBtn.addEventListener('click', async () => {
        if (!_lastMix) return;
        const zone = await getDefaultZone();
        if (!zone) { alert('Geen Roon zone beschikbaar.'); return; }
        const itemKeys = _lastMix.results.map(t => t.item_key);
        try {
            await apiCall('/queue', {
                method: 'POST',
                body: JSON.stringify({ item_keys: itemKeys, zone_id: zone, mode: 'replace' }),
            });
        } catch (err) {
            alert(`Afspelen mislukt: ${err.message}`);
        }
    });

    saveBtn?.addEventListener('click', saveCurrentMixAsProfile);

    setupTabs();
    setupSurpriseBar();
    renderBuckets();
}
