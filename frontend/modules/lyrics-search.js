// =============================================================================
// Lyrics Search (v13.0)
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
    const el = document.getElementById('lyrics-status-block');
    if (!el) return;
    const phase = status.status || 'idle';
    el.className = `clap-status cluster-status cluster-status--${phase}`;
    el.innerHTML = `
      <div><strong>Lyrics index:</strong> ${status.enabled ? 'enabled' : 'disabled'} · ${phase}
        ${status.n_total ? ` · ${status.n_embedded}/${status.n_total} embedded` : ''}
        ${status.n_no_lyrics ? ` · ${status.n_no_lyrics} without lyrics` : ''}
      </div>
      ${status.error_message ? `<div class="cluster-error">${status.error_message}</div>` : ''}
      <div style="margin-top:6px;">
        <button id="lyrics-start-btn" class="btn btn-secondary btn-sm" ${status.enabled && phase !== 'running' ? '' : 'disabled'}>
          ${phase === 'running' ? 'Indexing…' : 'Start lyrics indexing'}
        </button>
      </div>
    `;
    const startBtn = document.getElementById('lyrics-start-btn');
    if (startBtn) startBtn.addEventListener('click', startAnalysis);
}

async function refreshStatus() {
    try {
        const s = await apiCall('/lyrics/status');
        renderStatus(s);
        return s;
    } catch (err) {
        const el = document.getElementById('lyrics-status-block');
        if (el) el.innerHTML = `<div class="cluster-error">${err.message}</div>`;
        return null;
    }
}

async function startAnalysis() {
    try {
        await apiCall('/lyrics/analyze', { method: 'POST' });
    } catch (err) {
        if (err.status !== 409) {
            alert(`Lyrics analysis failed to start: ${err.message}`);
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
    const out = document.getElementById('lyrics-results');
    if (!data.results || !data.results.length) {
        out.innerHTML = '<div class="cluster-empty">No matches.</div>';
        return;
    }
    out.innerHTML = `
      <div style="margin-bottom:8px;color:var(--text-muted);font-size:13px;">
        ${data.results.length} matches for "${data.query}"
      </div>
      ${data.results.map(t => `
        <div class="lyrics-result" data-item-key="${t.item_key}">
          <div class="lyrics-result-meta">
            <strong>${t.title || ''}</strong>
            <span style="color:var(--text-muted);"> · ${t.artist || ''}</span>
            <span class="alchemy-score">${((t.similarity ?? 0) * 100).toFixed(1)}%</span>
          </div>
          ${t.snippet ? `<div class="lyrics-snippet">${t.snippet}</div>` : ''}
        </div>
      `).join('')}
    `;
    out.querySelectorAll('.lyrics-result').forEach(row => {
        row.addEventListener('click', async () => {
            const key = row.dataset.itemKey;
            try {
                const detail = await apiCall(`/lyrics/track/${encodeURIComponent(key)}`);
                let full = row.querySelector('.lyrics-full');
                if (full) { full.remove(); return; }
                full = document.createElement('pre');
                full.className = 'lyrics-full';
                full.textContent = detail.lyrics || '(no lyrics stored)';
                row.appendChild(full);
            } catch (err) {/* ignore */}
        });
    });
}

async function runSearch(query) {
    if (!query.trim()) return;
    const searchBtn = document.getElementById('lyrics-search-btn');
    const playBtn = document.getElementById('lyrics-play-btn');
    searchBtn.disabled = true;
    searchBtn.textContent = 'Searching…';
    try {
        const data = await apiCall('/lyrics/search', {
            method: 'POST',
            body: JSON.stringify({ query, limit: 25 }),
        });
        _lastResults = data;
        renderResults(data);
        playBtn.disabled = !data.results.length;
    } catch (err) {
        document.getElementById('lyrics-results').innerHTML =
            `<div class="cluster-error">${err.message}</div>`;
    } finally {
        searchBtn.disabled = false;
        searchBtn.textContent = 'Search';
    }
}

export async function initLyricsSearchView() {
    if (_initialized) return;
    _initialized = true;

    const input = document.getElementById('lyrics-search-input');
    const searchBtn = document.getElementById('lyrics-search-btn');
    const playBtn = document.getElementById('lyrics-play-btn');

    searchBtn.addEventListener('click', () => runSearch(input.value));
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') runSearch(input.value); });

    document.querySelectorAll('#lyrics-search-view .clap-suggest').forEach(el => {
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
