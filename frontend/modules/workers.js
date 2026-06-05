// =============================================================================
// Workers — background worker dashboard (status + pause/resume)
// =============================================================================
// Polls /api/workers/status every 2s and renders a glass card per worker with
// queue progress and pause/resume controls for the controllable ones.

import { apiCall } from './api.js';
import { subscribe } from './ws.js';

let _timer = null;
let _wired = false;

// Live-feed state: per-channel { processing: Map<key, {label, since}>, recent: [] }
const _live = {
    enrichment:    { processing: new Map(), recent: [] },
    audio_features:{ processing: new Map(), recent: [] },
};
const RECENT_KEEP = 8;
let _wsDisposers = [];

function _esc(s) {
    return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function _stateBadge(w) {
    if (w.error)    return '<span class="rs-worker-badge rs-worker-badge--err">error</span>';
    if (w.disabled) return '<span class="rs-worker-badge rs-worker-badge--off">disabled</span>';
    if (w.paused)   return '<span class="rs-worker-badge rs-worker-badge--paused">paused</span>';
    if (w.running)  return '<span class="rs-worker-badge rs-worker-badge--ok">running</span>';
    return '<span class="rs-worker-badge rs-worker-badge--off">idle</span>';
}

function _queueLine(q) {
    if (!q) return '';
    const parts = [];
    if (q.pending)    parts.push(`<span class="rs-worker-q rs-worker-q--pending">${q.pending} pending</span>`);
    if (q.processing) parts.push(`<span class="rs-worker-q rs-worker-q--proc">${q.processing} processing</span>`);
    if (q.failed)     parts.push(`<span class="rs-worker-q rs-worker-q--failed">${q.failed} failed</span>`);
    if (q.complete)   parts.push(`<span class="rs-worker-q rs-worker-q--done">${q.complete} done</span>`);
    return `<div class="rs-worker-queue">${parts.join('')}</div>`;
}

function _controls(w) {
    if (!w.controllable || w.disabled) return '';
    const btn = w.paused
        ? `<button class="btn btn-primary btn-sm" data-worker-action="resume" data-worker="${w.name}">▶ Resume</button>`
        : `<button class="btn btn-secondary btn-sm" data-worker-action="pause" data-worker="${w.name}">❚❚ Pause</button>`;
    return `<div class="rs-worker-controls">${btn}</div>`;
}

function _channelFor(workerName) {
    // Map worker.name (returned by /api/workers/status) → WS channel.
    if (!workerName) return null;
    const n = workerName.toLowerCase();
    if (n.includes('enrichment')) return 'enrichment';
    if (n.includes('audio'))      return 'audio_features';
    return null;
}

function _liveFeed(channel) {
    const live = _live[channel];
    if (!live) return '';
    const proc = [...live.processing.values()].slice(0, 4);
    const recent = live.recent.slice(0, RECENT_KEEP);

    if (!proc.length && !recent.length) return '';

    const procRows = proc.map(p => `
        <li class="rs-worker-feed-row rs-worker-feed-row--proc">
            <span class="rs-worker-feed-dot"></span>
            <span class="rs-worker-feed-text">${_esc(p.label)}</span>
        </li>`).join('');

    const recentRows = recent.map(r => `
        <li class="rs-worker-feed-row rs-worker-feed-row--${r.success ? 'ok' : 'err'}">
            <span class="rs-worker-feed-mark">${r.success ? '✓' : '×'}</span>
            <span class="rs-worker-feed-text">${_esc(r.label)}</span>
        </li>`).join('');

    return `
        <div class="rs-worker-feed">
            <div class="rs-worker-feed-title">Live</div>
            <ul class="rs-worker-feed-list">${procRows}${recentRows}</ul>
        </div>`;
}

function _renderWorker(w) {
    const pct = (w.progress_pct ?? null);
    const bar = pct === null ? '' : `
        <div class="rs-worker-bar"><div class="rs-worker-bar-fill" style="width:${pct}%"></div></div>
        <div class="rs-worker-pct">${pct}%</div>`;
    const channel = _channelFor(w.name);
    return `<div class="rs-glass-card rs-worker-card" data-worker-name="${_esc(w.name)}">
        <div class="rs-worker-head">
            <span class="rs-worker-name">${_esc(w.label)}</span>
            ${_stateBadge(w)}
        </div>
        <div class="rs-worker-detail">${_esc(w.detail || '')}</div>
        ${bar}
        ${_queueLine(w.queue)}
        ${_controls(w)}
        ${channel ? _liveFeed(channel) : ''}
    </div>`;
}

function _liveLabel(payload) {
    const { artist, title, file_path } = payload || {};
    if (artist || title) return `${artist || '?'} — ${title || '?'}`;
    if (file_path) {
        const parts = String(file_path).split('/');
        return parts[parts.length - 1] || file_path;
    }
    return payload?.item_key ? `item ${payload.item_key}` : 'item';
}

function _onChannelEvent(channel, data) {
    const live = _live[channel];
    if (!live || !data) return;
    if (data.type === 'item_start') {
        live.processing.set(data.item_key, {
            label: _liveLabel(data),
            since: Date.now(),
        });
        _refreshFeed(channel);
    } else if (data.type === 'item_complete') {
        const prev = live.processing.get(data.item_key);
        live.processing.delete(data.item_key);
        live.recent.unshift({
            label: prev?.label || _liveLabel(data),
            success: data.success !== false,
            ts: Date.now(),
        });
        live.recent = live.recent.slice(0, RECENT_KEEP);
        _refreshFeed(channel);
    }
    // batch_complete events fall through — polling picks them up.
}

function _refreshFeed(channel) {
    // Only touch the matching card's feed area so the rest of the page stays calm.
    document.querySelectorAll(`.rs-worker-card[data-worker-name]`).forEach(card => {
        const name = card.dataset.workerName;
        if (_channelFor(name) !== channel) return;
        const existing = card.querySelector('.rs-worker-feed');
        const html = _liveFeed(channel);
        if (existing) existing.outerHTML = html || existing.outerHTML;
        else if (html) card.insertAdjacentHTML('beforeend', html);
    });
}

async function _poll() {
    try {
        const data = await apiCall('/workers/status');
        const grid = document.getElementById('workers-grid');
        if (!grid) return;
        grid.innerHTML = (data.workers || []).map(_renderWorker).join('');
    } catch (e) {
        console.warn('workers poll failed:', e);
    }
}

function _wire() {
    const grid = document.getElementById('workers-grid');
    if (!grid) return;
    grid.addEventListener('click', async (e) => {
        const btn = e.target.closest('[data-worker-action]');
        if (!btn) return;
        const name = btn.dataset.worker;
        const action = btn.dataset.workerAction;
        btn.disabled = true;
        try {
            await apiCall(`/workers/${encodeURIComponent(name)}/${action}`, { method: 'POST' });
        } catch (err) {
            console.warn('worker action failed:', err);
        }
        _poll();  // refresh immediately
    });
    _wired = true;
}

export function initWorkersView() {
    if (!_wired) _wire();
    _poll();
    if (_timer) clearInterval(_timer);
    _timer = setInterval(_poll, 2000);

    // Subscribe to per-item events so the feed pulses live without polling.
    _wsDisposers.forEach(d => d());
    _wsDisposers = [
        subscribe('enrichment',     d => _onChannelEvent('enrichment', d)),
        subscribe('audio_features', d => _onChannelEvent('audio_features', d)),
    ];
}

export function teardownWorkersView() {
    if (_timer) { clearInterval(_timer); _timer = null; }
    _wsDisposers.forEach(d => d());
    _wsDisposers = [];
}
