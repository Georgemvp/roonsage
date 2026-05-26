// =============================================================================
// CLAP Search (v13.0)
// =============================================================================

import { apiCall } from './api.js';

let _initialized = false;
let _lastResults = null;
let _zoneCache = null;
let _pollTimer = null;

async function getDefaultZone() {
    if (_zoneCache) return _zoneCache;
    try {
        const zones = await apiCall('/roon/zones');
        _zoneCache = zones && zones.length ? zones[0].zone_id : null;
    } catch { _zoneCache = null; }
    return _zoneCache;
}

function renderStatus(status) {
    const el = document.getElementById('clap-status-block');
    if (!el) return;
    const enabled = status.enabled;
    const phase = status.status || 'idle';
    el.className = `clap-status cluster-status cluster-status--${phase}`;
    el.innerHTML = `
      <div><strong>CLAP:</strong> ${enabled ? 'enabled' : 'disabled'} · ${phase}
        ${status.n_total ? ` · ${status.n_done}/${status.n_total} analyzed` : ''}
        ${status.n_failed ? ` · ${status.n_failed} failed` : ''}
      </div>
      ${status.error_message ? `<div class="cluster-error">${status.error_message}</div>` : ''}
      <div style="margin-top:6px;">
        <button id="clap-start-btn" class="btn btn-secondary btn-sm" ${enabled && phase !== 'running' ? '' : 'disabled'}>
          ${phase === 'running' ? 'Analyzing…' : 'Start CLAP analysis'}
        </button>
      </div>
    `;
    const startBtn = document.getElementById('clap-start-btn');
    if (startBtn) startBtn.addEventListener('click', startAnalysis);
}

async function refreshStatus() {
    try {
        const s = await apiCall('/clap/status');
        renderStatus(s);
        return s;
    } catch (err) {
        const el = document.getElementById('clap-status-block');
        if (el) el.innerHTML = `<div class="cluster-error">${err.message}</div>`;
        return null;
    }
}

async function startAnalysis() {
    try {
        await apiCall('/clap/analyze', { method: 'POST' });
    } catch (err) {
        if (err.status !== 409) {
            alert(`CLAP analysis failed to start: ${err.message}`);
            return;
        }
        // 409 = already running; fall through to start polling
    }
    await refreshStatus();
    if (_pollTimer) clearInterval(_pollTimer);
    _pollTimer = setInterval(async () => {
        const s = await refreshStatus();
        if (!s || s.status !== 'running') {
            clearInterval(_pollTimer);
            _pollTimer = null;
        }
    }, 3000);
}

function renderResults(data) {
    const out = document.getElementById('clap-results');
    if (!data.results || !data.results.length) {
        out.innerHTML = '<div class="cluster-empty">No matches.</div>';
        return;
    }
    out.innerHTML = `
      <div style="margin-bottom:8px;color:var(--text-muted);font-size:13px;">
        ${data.results.length} matches for "${data.query}"
      </div>
      ${data.results.map(t => `
        <div class="alchemy-result-track">
          <div>
            <strong>${t.title || ''}</strong>
            <span style="color:var(--text-muted);"> · ${t.artist || ''}</span>
          </div>
          <span class="alchemy-score">${((t.similarity ?? 0) * 100).toFixed(1)}%</span>
        </div>
      `).join('')}
    `;
}

async function runSearch(query) {
    if (!query.trim()) return;
    const searchBtn = document.getElementById('clap-search-btn');
    const playBtn = document.getElementById('clap-play-btn');
    searchBtn.disabled = true;
    searchBtn.textContent = 'Searching…';
    try {
        const data = await apiCall('/clap/search', {
            method: 'POST',
            body: JSON.stringify({ query, limit: 25 }),
        });
        _lastResults = data;
        renderResults(data);
        playBtn.disabled = !data.results.length;
    } catch (err) {
        document.getElementById('clap-results').innerHTML =
            `<div class="cluster-error">${err.message}</div>`;
    } finally {
        searchBtn.disabled = false;
        searchBtn.textContent = 'Search';
    }
}

export async function initClapSearchView() {
    if (_initialized) return;
    _initialized = true;

    const input = document.getElementById('clap-search-input');
    const searchBtn = document.getElementById('clap-search-btn');
    const playBtn = document.getElementById('clap-play-btn');

    searchBtn.addEventListener('click', () => runSearch(input.value));
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') runSearch(input.value); });

    document.querySelectorAll('#clap-search-view .clap-suggest').forEach(el => {
        el.addEventListener('click', () => {
            input.value = el.dataset.q;
            runSearch(input.value);
        });
    });

    playBtn.addEventListener('click', async () => {
        if (!_lastResults) return;
        const zone = await getDefaultZone();
        if (!zone) { alert('No Roon zone available.'); return; }
        const itemKeys = _lastResults.results.map(t => t.item_key);
        try {
            await apiCall('/queue', {
                method: 'POST',
                body: JSON.stringify({ item_keys: itemKeys, zone_id: zone, mode: 'replace' }),
            });
        } catch (err) {
            alert(`Play failed: ${err.message}`);
        }
    });

    const s = await refreshStatus();
    if (s && s.status === 'running' && !_pollTimer) {
        _pollTimer = setInterval(async () => {
            const ps = await refreshStatus();
            if (!ps || ps.status !== 'running') {
                clearInterval(_pollTimer);
                _pollTimer = null;
            }
        }, 3000);
    }
}
