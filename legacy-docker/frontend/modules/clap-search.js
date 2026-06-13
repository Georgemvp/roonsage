// =============================================================================
// CLAP Search (v13.0)
// =============================================================================

import { apiCall } from './api.js';

let _initialized = false;
let _lastResults = null;
let _zoneCache = null;
let _pollTimer = null;
let _searchAbort = null;

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

function _esc(s) {
    return (s == null ? '' : String(s))
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function _artThumb(imageKey) {
    if (!imageKey) return '<div class="alchemy-art-placeholder">♪</div>';
    return `<img class="alchemy-art-thumb" src="/api/art/${encodeURIComponent(imageKey)}?width=40&height=40" alt="" loading="lazy" onerror="this.parentElement.innerHTML='&lt;div class=alchemy-art-placeholder&gt;&#9834;&lt;/div&gt;'">`;
}

function renderSkeleton(count = 8) {
    const out = document.getElementById('clap-results');
    if (!out) return;
    const row = `
      <div class="alchemy-result-track" style="opacity:.55;">
        <div class="alchemy-art-placeholder" style="background:linear-gradient(90deg,var(--border),var(--bg-surface),var(--border));background-size:200% 100%;animation:clapSkeleton 1.2s linear infinite;"></div>
        <div class="alchemy-result-track-info">
          <div style="height:12px;width:60%;background:var(--border);border-radius:3px;margin-bottom:4px;"></div>
          <div style="height:10px;width:40%;background:var(--border);border-radius:3px;"></div>
        </div>
      </div>`;
    out.innerHTML = `
      <style>@keyframes clapSkeleton{0%{background-position:0 0}100%{background-position:-200% 0}}</style>
      <div style="margin-bottom:8px;color:var(--text-muted);font-size:13px;">Searching…</div>
      ${row.repeat(count)}
    `;
}

function renderResults(data) {
    const out = document.getElementById('clap-results');
    if (!data.results || !data.results.length) {
        out.innerHTML = '<div class="cluster-empty">No matches.</div>';
        return;
    }
    out.innerHTML = `
      <div style="margin-bottom:8px;color:var(--text-muted);font-size:13px;">
        ${data.results.length} matches for "${_esc(data.query)}"
      </div>
      ${data.results.map(t => `
        <div class="alchemy-result-track clap-result-row" data-item-key="${_esc(t.item_key)}" role="button" tabindex="0" title="Click to play this track" style="cursor:pointer;">
          ${_artThumb(t.image_key)}
          <div class="alchemy-result-track-info">
            <div><strong>${_esc(t.title || '')}</strong> <span style="color:var(--text-muted);"> · ${_esc(t.artist || '')}</span></div>
            <div style="color:var(--text-muted);font-size:11px;">${_esc(t.album || '')}${t.year ? ' · ' + t.year : ''}</div>
          </div>
          <span class="alchemy-score">${((t.similarity ?? 0) * 100).toFixed(1)}%</span>
        </div>
      `).join('')}
    `;
    out.querySelectorAll('.clap-result-row').forEach(row => {
        const playOne = async () => {
            const key = row.dataset.itemKey;
            const zone = await getDefaultZone();
            if (!zone) { alert('No Roon zone available.'); return; }
            row.style.opacity = '0.6';
            try {
                await apiCall('/queue', {
                    method: 'POST',
                    body: JSON.stringify({ item_keys: [key], zone_id: zone, mode: 'replace' }),
                });
            } catch (err) {
                alert(`Play failed: ${err.message}`);
            } finally {
                row.style.opacity = '';
            }
        };
        row.addEventListener('click', playOne);
        row.addEventListener('keydown', e => {
            if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); playOne(); }
        });
    });
}

async function runSearch(query) {
    if (!query.trim()) return;
    const searchBtn = document.getElementById('clap-search-btn');
    const playBtn = document.getElementById('clap-play-btn');
    const appendBtn = document.getElementById('clap-append-btn');
    const limitSel = document.getElementById('clap-limit');
    const limit = parseInt(limitSel?.value || '25', 10);

    // Cancel any in-flight search so the latest query wins.
    if (_searchAbort) _searchAbort.abort();
    _searchAbort = new AbortController();
    const myAbort = _searchAbort;

    searchBtn.disabled = true;
    searchBtn.textContent = 'Searching…';
    renderSkeleton(Math.min(limit, 8));
    try {
        const data = await apiCall('/clap/search', {
            method: 'POST',
            body: JSON.stringify({ query, limit }),
            signal: myAbort.signal,
        });
        if (myAbort.signal.aborted) return;
        _lastResults = data;
        renderResults(data);
        playBtn.disabled = !data.results.length;
        appendBtn.disabled = !data.results.length;
    } catch (err) {
        if (err.name === 'AbortError') return;
        document.getElementById('clap-results').innerHTML =
            `<div class="cluster-error">${err.message}</div>`;
    } finally {
        if (!myAbort.signal.aborted) {
            searchBtn.disabled = false;
            searchBtn.textContent = 'Search';
        }
    }
}

async function queueAll(mode) {
    if (!_lastResults) return;
    const zone = await getDefaultZone();
    if (!zone) { alert('No Roon zone available.'); return; }
    const itemKeys = _lastResults.results.map(t => t.item_key);
    try {
        await apiCall('/queue', {
            method: 'POST',
            body: JSON.stringify({ item_keys: itemKeys, zone_id: zone, mode }),
        });
    } catch (err) {
        alert(`${mode === 'append' ? 'Append' : 'Play'} failed: ${err.message}`);
    }
}

export async function initClapSearchView() {
    if (_initialized) return;
    _initialized = true;

    const input = document.getElementById('clap-search-input');
    const searchBtn = document.getElementById('clap-search-btn');
    const playBtn = document.getElementById('clap-play-btn');
    const appendBtn = document.getElementById('clap-append-btn');

    searchBtn.addEventListener('click', () => runSearch(input.value));
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') runSearch(input.value); });

    document.querySelectorAll('#clap-search-view .clap-suggest').forEach(el => {
        el.addEventListener('click', () => {
            input.value = el.dataset.q;
            runSearch(input.value);
        });
    });

    playBtn.addEventListener('click', () => queueAll('replace'));
    appendBtn?.addEventListener('click', () => queueAll('append'));

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
