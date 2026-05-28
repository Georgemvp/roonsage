// =============================================================================
// Enrichment View — dedicated page
// =============================================================================

import { apiCall } from './api.js';
import { escapeHtml } from './utils.js';

let _pollInterval = null;
let _lastEnriched = null;
let _lastPollTime = null;

export async function initEnrichmentView() {
    _wireButtons();
    await _loadAll();
}

// ---------------------------------------------------------------------------
// Load all data sections
// ---------------------------------------------------------------------------

async function _loadAll() {
    const [status] = await Promise.all([
        apiCall('/enrichment/status').catch(() => null),
    ]);
    if (!status) {
        _setOverall(0, 'No enrichment data available.', null);
        return;
    }
    _applyStatus(status);
    await Promise.all([
        _loadTags(),
        _loadFailed(),
        _loadMissingList(),
    ]);
    if (status.worker_running) _startPolling();
}

// ---------------------------------------------------------------------------
// Status / progress
// ---------------------------------------------------------------------------

function _applyStatus(status) {
    const total    = (status.complete ?? 0) + (status.pending ?? 0) + (status.failed ?? 0) + (status.processing ?? 0);
    const enriched = status.enriched_total ?? status.complete ?? 0;
    const pct      = total > 0 ? Math.round((enriched / total) * 100) : 0;
    const mbCount  = status.mb_matches ?? 0;
    const lfCount  = status.lastfm_matches ?? 0;
    const libTotal = status.total_tracks ?? total;

    _setOverall(pct, `${enriched.toLocaleString()} of ${libTotal.toLocaleString()} tracks enriched`, status);

    // Source bars
    _setSourceBar('mb', libTotal > 0 ? Math.round((mbCount / libTotal) * 100) : 0, mbCount);
    _setSourceBar('lf', libTotal > 0 ? Math.round((lfCount / libTotal) * 100) : 0, lfCount);

    // Stacked breakdown bar
    _updateBreakdownBar(status.source_breakdown ?? {}, libTotal);

    // Recent activity
    _renderRecentActivity(status.recent_completed ?? []);

    // Worker state
    _updateWorkerUI(status);

    // skip_mb badge
    const skipBadge = document.getElementById('enrich2-skip-mb-badge');
    if (skipBadge) skipBadge.style.display = status.skip_mb ? '' : 'none';
}

function _setOverall(pct, sub, status) {
    const barEl  = document.getElementById('enrich2-overall-bar');
    const pctEl  = document.getElementById('enrich2-overall-pct');
    const subEl  = document.getElementById('enrich2-overall-sub');
    if (barEl)  barEl.style.width  = `${pct}%`;
    if (pctEl)  pctEl.textContent  = `${pct}%`;
    if (subEl)  subEl.textContent  = sub;
}

function _setSourceBar(source, pct, count) {
    const barEl   = document.getElementById(`enrich2-${source}-bar`);
    const pctEl   = document.getElementById(`enrich2-${source}-pct`);
    const countEl = document.getElementById(`enrich2-${source}-count`);
    if (barEl)   barEl.style.width  = `${pct}%`;
    if (pctEl)   pctEl.textContent  = `${pct}%`;
    if (countEl && count != null) countEl.textContent = count.toLocaleString();
}

function _updateBreakdownBar(breakdown, total) {
    const both = breakdown['both'] ?? 0;
    const mb   = breakdown['musicbrainz'] ?? 0;
    const lf   = breakdown['lastfm'] ?? 0;
    const none = breakdown['none'] ?? 0;

    const base = Math.max(total, both + mb + lf + none, 1);
    const pct  = v => `${Math.round((v / base) * 100)}%`;

    const setBars = (id, val) => {
        const el = document.getElementById(id);
        if (el) el.style.width = pct(val);
    };
    setBars('enrich2-bar-both', both);
    setBars('enrich2-bar-mb',   mb);
    setBars('enrich2-bar-lf',   lf);
    setBars('enrich2-bar-none', none);
}

function _updateWorkerUI(status) {
    const badge      = document.getElementById('enrich2-worker-badge');
    const runBtn     = document.getElementById('enrich2-run-btn');
    const pauseBtn   = document.getElementById('enrich2-pause-btn');
    const resumeBtn  = document.getElementById('enrich2-resume-btn');

    const { worker_running, worker_paused } = status;

    if (badge) {
        badge.style.display = '';
        if (worker_running && !worker_paused) {
            badge.textContent = 'Running';
            badge.className   = 'enrich-worker-badge enrich-worker-badge--running';
        } else if (worker_paused) {
            badge.textContent = 'Paused';
            badge.className   = 'enrich-worker-badge enrich-worker-badge--paused';
        } else {
            badge.textContent = 'Idle';
            badge.className   = 'enrich-worker-badge';
        }
    }

    if (runBtn)    runBtn.style.display    = (worker_running && !worker_paused) ? 'none' : '';
    if (pauseBtn)  pauseBtn.style.display  = (worker_running && !worker_paused) ? '' : 'none';
    if (resumeBtn) resumeBtn.style.display = worker_paused ? '' : 'none';
}

function _updateETA(rate, remaining) {
    const etaEl = document.getElementById('enrich2-eta');
    if (!etaEl) return;
    if (rate <= 0) { etaEl.style.display = 'none'; return; }
    const mins = Math.round(remaining);
    if (mins < 1) { etaEl.textContent = '< 1 min remaining'; }
    else if (mins < 60) { etaEl.textContent = `~${mins} min remaining`; }
    else { etaEl.textContent = `~${Math.round(mins / 60)}h remaining`; }
    etaEl.style.display = '';
}

// ---------------------------------------------------------------------------
// Tag cloud
// ---------------------------------------------------------------------------

async function _loadTags() {
    const card = document.getElementById('enrich2-tags-card');
    const list = document.getElementById('enrich2-tags-list');
    const total = document.getElementById('enrich2-tags-total');
    if (!list) return;

    const data = await apiCall('/enrichment/tags?limit=30').catch(() => null);
    if (!data || !data.tags?.length) return;

    const maxCount = data.tags[0].count;
    list.innerHTML = data.tags.map(t => {
        const size = 11 + Math.round((t.count / maxCount) * 10);
        return `<span class="chip" style="font-size:${size}px;cursor:default" title="${t.count} tracks">${escapeHtml(t.name)}</span>`;
    }).join('');

    if (total) total.textContent = `${data.total_unique.toLocaleString()} unique tags`;
    if (card)  card.style.display = '';
}

// ---------------------------------------------------------------------------
// Failed tracks
// ---------------------------------------------------------------------------

async function _loadFailed() {
    const card    = document.getElementById('enrich2-failed-card');
    const list    = document.getElementById('enrich2-failed-list');
    const countEl = document.getElementById('enrich2-failed-count');
    if (!list) return;

    const data = await apiCall('/enrichment/queue?status=failed&page_size=20').catch(() => null);
    if (!data || !data.total) return;

    if (countEl) countEl.textContent = `(${data.total.toLocaleString()})`;

    list.innerHTML = data.items.map(item => `
        <div style="display:flex;align-items:flex-start;gap:12px;padding:8px 0;border-bottom:1px solid var(--color-border)">
            <div style="flex:1;min-width:0">
                <div style="font-size:13px;font-weight:500">${escapeHtml(item.artist)} — ${escapeHtml(item.title)}</div>
                ${item.error_message ? `<div style="font-size:11px;color:var(--text-muted);margin-top:2px">${escapeHtml(item.error_message)}</div>` : ''}
            </div>
            <span style="font-size:11px;color:#ef4444;flex-shrink:0">${item.attempts} attempt${item.attempts !== 1 ? 's' : ''}</span>
        </div>
    `).join('');

    if (card) card.style.display = '';
}

// ---------------------------------------------------------------------------
// Missing metadata list
// ---------------------------------------------------------------------------

async function _loadMissingList() {
    const listEl  = document.getElementById('enrich2-missing-list');
    const countEl = document.getElementById('enrich2-missing-count');
    if (!listEl) return;

    const data = await apiCall('/enrichment/missing?limit=20').catch(() => null);
    const items = data?.tracks ?? [];

    if (!items.length) {
        listEl.innerHTML = '<p style="color:var(--text-muted);padding:16px 0">No missing metadata found.</p>';
        if (countEl) countEl.textContent = '';
        return;
    }

    if (countEl) {
        const totalMissing = data?.total_missing ?? items.length;
        countEl.textContent = `${items.length} shown of ${totalMissing.toLocaleString()}`;
    }

    listEl.innerHTML = items.map(item => {
        const artHtml = item.image_key
            ? `<img src="/api/art/${item.image_key}?width=48&height=48" alt="" loading="lazy" style="width:48px;height:48px;object-fit:cover;border-radius:4px" onerror="this.style.display='none'">`
            : '<div style="width:48px;height:48px;border-radius:4px;background:var(--color-border)"></div>';
        return `
            <div class="rs-enrich-missing-row">
                <div class="rs-enrich-missing-art">${artHtml}</div>
                <div class="rs-enrich-missing-info">
                    <div class="rs-enrich-missing-title">${escapeHtml(item.title || 'Unknown')}</div>
                    <div class="rs-enrich-missing-artist">${escapeHtml(item.artist || '')}${item.album ? ` · ${escapeHtml(item.album)}` : ''}</div>
                </div>
                <button class="btn btn-outline btn-sm rs-enrich-missing-fix" data-track-id="${escapeHtml(String(item.id || ''))}">Fix</button>
            </div>
        `;
    }).join('');

    listEl.querySelectorAll('.rs-enrich-missing-fix').forEach(btn => {
        btn.addEventListener('click', async () => {
            const id = btn.dataset.trackId;
            if (!id) return;
            btn.disabled = true;
            btn.textContent = '…';
            try {
                await apiCall('/enrichment/enrich-single', {
                    method: 'POST',
                    body: JSON.stringify({ track_id: id }),
                });
                btn.textContent = 'Done';
                btn.style.color = 'var(--color-accent)';
            } catch (e) {
                btn.textContent = 'Err';
                btn.disabled = false;
            }
        });
    });
}

// ---------------------------------------------------------------------------
// Recent activity
// ---------------------------------------------------------------------------

function _renderRecentActivity(items) {
    const card = document.getElementById('enrich2-recent-card');
    const list = document.getElementById('enrich2-recent-list');
    if (!list || !items.length) return;

    list.innerHTML = items.map(item => `
        <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid var(--color-border);font-size:13px">
            <span>${escapeHtml(item.artist)} — ${escapeHtml(item.title)}</span>
            <span style="color:var(--text-muted);font-size:11px;flex-shrink:0;margin-left:8px">${_fmtTime(item.processed_at)}</span>
        </div>
    `).join('');

    if (card) card.style.display = '';
}

function _fmtTime(ts) {
    if (!ts) return '';
    try {
        const d = new Date(ts);
        const now = Date.now();
        const diff = Math.round((now - d.getTime()) / 60000);
        if (diff < 1)  return 'just now';
        if (diff < 60) return `${diff}m ago`;
        if (diff < 1440) return `${Math.round(diff / 60)}h ago`;
        return d.toLocaleDateString();
    } catch { return ''; }
}

// ---------------------------------------------------------------------------
// Polling
// ---------------------------------------------------------------------------

function _startPolling() {
    if (_pollInterval) return;
    _pollInterval = setInterval(async () => {
        const status = await apiCall('/enrichment/status').catch(() => null);
        if (!status) return;

        const now = Date.now();
        const enriched = status.enriched_total ?? 0;
        if (_lastEnriched !== null && _lastPollTime !== null) {
            const delta   = enriched - _lastEnriched;
            const elapsed = (now - _lastPollTime) / 60000;
            if (elapsed > 0 && delta > 0) {
                const rate      = delta / elapsed;
                const remaining = (status.pending ?? 0) / rate;
                _updateETA(rate, remaining);
            }
        }
        _lastEnriched = enriched;
        _lastPollTime = now;

        _applyStatus(status);

        if (!status.worker_running) {
            _stopPolling();
            await _loadFailed();
            await _loadMissingList();
        }
    }, 5000);
}

function _stopPolling() {
    if (_pollInterval) { clearInterval(_pollInterval); _pollInterval = null; }
    _lastEnriched = null;
    _lastPollTime = null;
    const etaEl = document.getElementById('enrich2-eta');
    if (etaEl) etaEl.style.display = 'none';
}

// ---------------------------------------------------------------------------
// Button wiring
// ---------------------------------------------------------------------------

function _wireButtons() {
    _wireBtn('enrich2-run-btn',    _handleRun);
    _wireBtn('enrich2-pause-btn',  _handlePause);
    _wireBtn('enrich2-resume-btn', _handleResume);
    _wireBtn('enrich2-retry-btn',  _handleRetryFailed);
}

function _wireBtn(id, handler) {
    const el = document.getElementById(id);
    if (!el) return;
    const fresh = el.cloneNode(true);
    el.parentNode.replaceChild(fresh, el);
    fresh.addEventListener('click', handler);
}

function _showResult(msg, isError = false) {
    const el = document.getElementById('enrich2-result');
    if (!el) return;
    el.textContent = msg;
    el.className = `enrich-result${isError ? ' enrich-result--error' : ' enrich-result--success'}`;
}

async function _handleRun() {
    const btn = document.getElementById('enrich2-run-btn');
    if (btn) { btn.disabled = true; btn.textContent = 'Starting…'; }
    try {
        const resp = await apiCall('/enrichment/start', { method: 'POST', body: '{}' });
        _showResult(resp?.message || 'Enrichment started.');
        setTimeout(() => _loadAll(), 1500);
    } catch (e) {
        _showResult('Error: ' + e.message, true);
    } finally {
        if (btn) { btn.disabled = false; btn.innerHTML = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="5 3 19 12 5 21 5 3"/></svg> Run Enrichment'; }
    }
}

async function _handlePause() {
    const btn = document.getElementById('enrich2-pause-btn');
    if (btn) btn.disabled = true;
    try {
        await apiCall('/enrichment/pause', { method: 'POST', body: '{}' });
        _showResult('Worker paused.');
        _stopPolling();
        setTimeout(() => _loadAll(), 500);
    } catch (e) {
        _showResult('Error: ' + e.message, true);
        if (btn) btn.disabled = false;
    }
}

async function _handleResume() {
    const btn = document.getElementById('enrich2-resume-btn');
    if (btn) btn.disabled = true;
    try {
        await apiCall('/enrichment/resume', { method: 'POST', body: '{}' });
        _showResult('Worker resumed.');
        setTimeout(() => _loadAll(), 500);
    } catch (e) {
        _showResult('Error: ' + e.message, true);
        if (btn) btn.disabled = false;
    }
}

async function _handleRetryFailed() {
    const btn = document.getElementById('enrich2-retry-btn');
    if (btn) { btn.disabled = true; btn.textContent = 'Resetting…'; }
    try {
        const resp = await apiCall('/enrichment/retry-failed', { method: 'POST', body: '{}' });
        _showResult(resp?.message || 'Failed items reset.');
        await _loadFailed();
    } catch (e) {
        _showResult('Error: ' + e.message, true);
    } finally {
        if (btn) { btn.disabled = false; btn.textContent = 'Retry All Failed'; }
    }
}
