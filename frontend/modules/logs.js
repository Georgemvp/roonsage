// =============================================================================
// Logs — Live log viewer (Settings → Logs / sidebar Logs)
// =============================================================================
// Polls /api/logs/tail every 1s, only fetches entries newer than the last seq
// (incremental). Auto-scrolls to the latest unless the user has scrolled up.

import { apiCall } from './api.js';

let _state = {
    initialized: false,
    timer: null,
    lastSeq: 0,
    levelFilter: 'INFO',  // DEBUG | INFO | WARNING | ERROR
    loggerFilter: '',
    queryFilter: '',
    paused: false,
    autoscroll: true,
};

const LEVEL_RANK = { DEBUG: 10, INFO: 20, WARNING: 30, ERROR: 40, CRITICAL: 50 };

function _fmtTs(epoch) {
    const d = new Date(epoch * 1000);
    return d.toLocaleTimeString('nl-NL', { hour12: false }) + '.' +
           String(d.getMilliseconds()).padStart(3, '0');
}

function _esc(s) {
    return String(s ?? '')
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function _renderEntry(entry) {
    const cls = `rs-log-entry rs-log-${entry.level.toLowerCase()}`;
    const exc = entry.exception
        ? `<pre class="rs-log-exc">${_esc(entry.exception)}</pre>` : '';
    return `<div class="${cls}">
        <span class="rs-log-ts">${_fmtTs(entry.ts)}</span>
        <span class="rs-log-level">${entry.level}</span>
        <span class="rs-log-name">${_esc(entry.logger)}</span>
        <span class="rs-log-msg">${_esc(entry.msg)}</span>
        ${exc}
    </div>`;
}

async function _poll() {
    if (_state.paused) return;
    try {
        const params = new URLSearchParams({
            n: '200',
            since: String(_state.lastSeq),
            level: _state.levelFilter,
        });
        if (_state.loggerFilter) params.set('logger', _state.loggerFilter);
        if (_state.queryFilter) params.set('q', _state.queryFilter);
        const data = await apiCall('/logs/tail?' + params.toString());
        if (!data.entries.length) return;

        _state.lastSeq = Math.max(_state.lastSeq, data.last_seq || 0);
        const list = document.getElementById('logs-list');
        if (!list) return;

        // Append new entries; cap at 1000 rendered to keep DOM light.
        const html = data.entries.map(_renderEntry).join('');
        list.insertAdjacentHTML('beforeend', html);
        while (list.children.length > 1000) list.removeChild(list.firstElementChild);

        if (_state.autoscroll) list.scrollTop = list.scrollHeight;

        const counter = document.getElementById('logs-counter');
        if (counter) counter.textContent = `${data.buffered}/${data.capacity}`;
    } catch (e) {
        // Network blip — try again next tick.
        console.warn('logs poll failed:', e);
    }
}

function _resetAndReload() {
    _state.lastSeq = 0;
    const list = document.getElementById('logs-list');
    if (list) list.innerHTML = '';
    _poll();
}

function _wireControls() {
    const levelSel = document.getElementById('logs-level');
    if (levelSel) levelSel.addEventListener('change', () => {
        _state.levelFilter = levelSel.value;
        _resetAndReload();
    });

    const loggerInput = document.getElementById('logs-logger');
    if (loggerInput) loggerInput.addEventListener('input', () => {
        _state.loggerFilter = loggerInput.value.trim();
        _resetAndReload();
    });

    const qInput = document.getElementById('logs-q');
    if (qInput) qInput.addEventListener('input', () => {
        _state.queryFilter = qInput.value.trim();
        _resetAndReload();
    });

    document.getElementById('logs-pause')?.addEventListener('click', (e) => {
        _state.paused = !_state.paused;
        e.currentTarget.textContent = _state.paused ? '▶ Resume' : '❚❚ Pause';
        e.currentTarget.classList.toggle('rs-log-paused', _state.paused);
    });

    document.getElementById('logs-clear')?.addEventListener('click', () => {
        const list = document.getElementById('logs-list');
        if (list) list.innerHTML = '';
    });

    document.getElementById('logs-copy')?.addEventListener('click', () => {
        const list = document.getElementById('logs-list');
        if (!list) return;
        const text = [...list.querySelectorAll('.rs-log-entry')]
            .map(el => el.innerText.replace(/\s+/g, ' ').trim())
            .join('\n');
        navigator.clipboard?.writeText(text);
    });

    // Disable auto-scroll if user scrolls up; re-enable when they hit bottom.
    const list = document.getElementById('logs-list');
    list?.addEventListener('scroll', () => {
        const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 20;
        _state.autoscroll = atBottom;
    });
}

export function initLogsView() {
    if (!_state.initialized) {
        _wireControls();
        _state.initialized = true;
    }
    _resetAndReload();
    if (_state.timer) clearInterval(_state.timer);
    _state.timer = setInterval(_poll, 1000);
}

export function teardownLogsView() {
    if (_state.timer) {
        clearInterval(_state.timer);
        _state.timer = null;
    }
}
