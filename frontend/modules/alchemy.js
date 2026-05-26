// =============================================================================
// Song Alchemy (v13.0)
// =============================================================================

import { apiCall } from './api.js';

let _initialized = false;
let _add = new Map();        // item_key -> {artist, title}
let _subtract = new Map();
let _lastMix = null;
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

function renderMix(mix) {
    const out = document.getElementById('alchemy-result');
    if (!mix.results || !mix.results.length) {
        out.innerHTML = '<div class="cluster-empty">No matches found.</div>';
        return;
    }
    out.innerHTML = `
      <div style="margin-bottom:8px;color:var(--text-muted);font-size:13px;">
        ${mix.results.length} matches · pool of ${mix.n_pool} tracks
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
    renderRadar(mix);
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

async function getDefaultZone() {
    if (_zoneCache) return _zoneCache;
    try {
        const zones = await apiCall('/roon/zones');
        _zoneCache = zones && zones.length ? zones[0].zone_id : null;
    } catch { _zoneCache = null; }
    return _zoneCache;
}

export async function initAlchemyView() {
    if (_initialized) return;
    _initialized = true;

    await ensureChartJs().catch(() => {/* radar simply won't render */});

    const searchInput = document.getElementById('alchemy-search');
    const mixBtn = document.getElementById('alchemy-mix-btn');
    const playBtn = document.getElementById('alchemy-play-btn');

    let debTimer;
    searchInput.addEventListener('input', () => {
        clearTimeout(debTimer);
        debTimer = setTimeout(async () => renderSearchResults(await searchTracks(searchInput.value)), 250);
    });

    mixBtn.addEventListener('click', async () => {
        if (!_add.size) { alert('Add at least one track to the + bucket.'); return; }
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
        } catch (err) {
            document.getElementById('alchemy-result').innerHTML =
                `<div class="cluster-error">Mix failed: ${err.message}</div>`;
        } finally {
            mixBtn.disabled = false;
            mixBtn.textContent = 'Mix';
        }
    });

    playBtn.addEventListener('click', async () => {
        if (!_lastMix) return;
        const zone = await getDefaultZone();
        if (!zone) { alert('No Roon zone available.'); return; }
        const itemKeys = _lastMix.results.map(t => t.item_key);
        try {
            await apiCall('/queue', {
                method: 'POST',
                body: JSON.stringify({ item_keys: itemKeys, zone_id: zone, mode: 'replace' }),
            });
        } catch (err) {
            alert(`Play failed: ${err.message}`);
        }
    });

    renderBuckets();
}
