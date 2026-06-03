// =============================================================================
// Workers — background worker dashboard (status + pause/resume)
// =============================================================================
// Polls /api/workers/status every 2s and renders a glass card per worker with
// queue progress and pause/resume controls for the controllable ones.

import { apiCall } from './api.js';

let _timer = null;
let _wired = false;

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

function _renderWorker(w) {
    const pct = (w.progress_pct ?? null);
    const bar = pct === null ? '' : `
        <div class="rs-worker-bar"><div class="rs-worker-bar-fill" style="width:${pct}%"></div></div>
        <div class="rs-worker-pct">${pct}%</div>`;
    return `<div class="rs-glass-card rs-worker-card">
        <div class="rs-worker-head">
            <span class="rs-worker-name">${_esc(w.label)}</span>
            ${_stateBadge(w)}
        </div>
        <div class="rs-worker-detail">${_esc(w.detail || '')}</div>
        ${bar}
        ${_queueLine(w.queue)}
        ${_controls(w)}
    </div>`;
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
}

export function teardownWorkersView() {
    if (_timer) { clearInterval(_timer); _timer = null; }
}
