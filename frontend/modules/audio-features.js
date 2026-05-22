// =============================================================================
// Audio Feature Analysis — settings-panel UI
// =============================================================================
//
// Mirrors the enrichment panel: status polling, start/pause/resume buttons,
// and a path-rescan action. Status comes from /api/audio-features/status.

import { apiCall } from './api.js';

let _pollTimer = null;

function _setText(id, value) {
    const el = document.getElementById(id);
    if (el) el.textContent = value;
}

function _renderStatus(data) {
    if (!data) return;

    const banner = document.getElementById('af-disabled-banner');
    if (banner) banner.style.display = data.enabled ? 'none' : 'block';

    _setText('af-analysed',   data.analysed_total ?? 0);
    _setText('af-pending',    data.pending ?? 0);
    _setText('af-analyzing',  data.analyzing ?? 0);
    _setText('af-failed',     data.failed ?? 0);
    _setText('af-unresolved', data.unresolved ?? 0);

    const total = (data.analysed_total ?? 0) + (data.pending ?? 0)
                + (data.failed ?? 0) + (data.analyzing ?? 0);
    const pct = total > 0 ? Math.round((data.analysed_total ?? 0) / total * 100) : 0;

    const bar = document.getElementById('af-progress-bar');
    if (bar) bar.style.width = pct + '%';
    _setText('af-progress-text',
        total > 0 ? `${data.analysed_total} van ${total} tracks geanalyseerd (${pct}%)`
                  : 'Nog niets in de queue');

    const running = data.worker_running, paused = data.worker_paused;
    const fullBadge = data.full_features ? ' · full' : ' · BPM+key';
    _setText('af-worker-state',
        paused  ? '⏸ Gepauzeerd' :
        running ? `▶ Actief${fullBadge}` :
                  '⏹ Gestopt');

    const startBtn = document.getElementById('af-start-btn');
    const pauseBtn = document.getElementById('af-pause-btn');
    if (startBtn) startBtn.disabled = running && !paused;
    if (pauseBtn) pauseBtn.disabled = !running || paused;
}

export async function loadAudioFeaturesStatus() {
    try {
        const data = await apiCall('/audio-features/status');
        _renderStatus(data);
        return data;
    } catch (err) {
        console.warn('Audio features status failed:', err);
        return null;
    }
}

function _setResult(text, ok = true) {
    const el = document.getElementById('af-action-result');
    if (!el) return;
    el.textContent = text;
    el.style.color = ok ? '#4caf50' : '#f44336';
}

function _startPolling(intervalMs = 5000) {
    _stopPolling();
    _pollTimer = setInterval(async () => {
        const data = await loadAudioFeaturesStatus();
        if (!data || (!data.worker_running && !data.worker_paused)) _stopPolling();
    }, intervalMs);
}

function _stopPolling() {
    if (_pollTimer !== null) {
        clearInterval(_pollTimer);
        _pollTimer = null;
    }
}

async function _start() {
    _setResult('Bezig met starten…', true);
    try {
        const data = await apiCall('/audio-features/start', { method: 'POST' });
        _setResult(data.message || 'Gestart.', true);
        await loadAudioFeaturesStatus();
        _startPolling();
    } catch (err) {
        _setResult('✗ ' + err.message, false);
    }
}

async function _pause() {
    try {
        await apiCall('/audio-features/pause', { method: 'POST' });
        _setResult('Worker gepauzeerd.', true);
        await loadAudioFeaturesStatus();
        _stopPolling();
    } catch (err) {
        _setResult('✗ ' + err.message, false);
    }
}

async function _rescan() {
    _setResult('Bezig met scannen — dit kan even duren…', true);
    try {
        const data = await apiCall('/audio-features/rescan-paths', { method: 'POST' });
        _setResult(data.message, true);
        await loadAudioFeaturesStatus();
    } catch (err) {
        _setResult('✗ ' + err.message, false);
    }
}

export function initAudioFeaturesButtons() {
    document.getElementById('af-start-btn')?.addEventListener('click', _start);
    document.getElementById('af-pause-btn')?.addEventListener('click', _pause);
    document.getElementById('af-rescan-btn')?.addEventListener('click', _rescan);

    loadAudioFeaturesStatus().then(data => {
        if (data?.worker_running && !data?.worker_paused) _startPolling();
    });
}
