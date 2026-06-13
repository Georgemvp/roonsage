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

function _renderScanProgress(scan) {
    const banner = document.getElementById('af-scan-banner');
    if (!banner) return;

    const active = scan?.active === true;
    const justFinished = scan?.phase === 'complete' && !active && scan?.last_result;

    if (!active && !justFinished) {
        banner.style.display = 'none';
        return;
    }

    banner.style.display = 'block';
    const phase = scan?.phase || 'idle';
    const seen  = scan?.files_seen ?? 0;
    const indexed = scan?.files_indexed ?? 0;

    let phaseLabel = '';
    let detail = '';
    if (phase === 'walking') {
        phaseLabel = '🔎 Library scannen…';
        detail = `${seen.toLocaleString()} bestanden gescand · ${indexed.toLocaleString()} getagged`;
    } else if (phase === 'matching') {
        phaseLabel = '🔗 Tracks matchen aan bestanden…';
        detail = `${seen.toLocaleString()} bestanden geïndexeerd — koppelen aan je Roon library`;
    } else if (phase === 'complete' && justFinished) {
        const r = scan.last_result;
        phaseLabel = '✓ Scan voltooid';
        detail = `${r.matched ?? 0} tracks gematched · ${r.unresolved ?? 0} niet gevonden · queue gevuld.`;
    }
    _setText('af-scan-phase', phaseLabel);
    _setText('af-scan-detail', detail);

    // Indeterminate-ish progress bar: pulse during walking, full when complete.
    // We don't know total files up-front, so we cap at ~80k (typical large library).
    const bar = document.getElementById('af-scan-bar');
    if (bar) {
        if (phase === 'complete') {
            bar.style.width = '100%';
        } else if (phase === 'matching') {
            bar.style.width = '95%';
        } else {
            const pct = Math.min(95, Math.round(seen / 80000 * 100));
            bar.style.width = pct + '%';
        }
    }

    // ETA: simple linear extrapolation based on elapsed time + an 80k cap.
    const eta = document.getElementById('af-scan-eta');
    if (eta) {
        if (phase === 'complete') {
            eta.textContent = `Klaar om ${new Date(scan.finished_at + 'Z').toLocaleTimeString()}.`;
        } else if (scan?.started_at && seen > 1000) {
            const started = new Date(scan.started_at + 'Z').getTime();
            const elapsedMs = Date.now() - started;
            const rate = seen / (elapsedMs / 1000); // files per second
            const estimatedTotal = Math.max(seen + 1000, 80000);
            const remainingSec = Math.max(0, (estimatedTotal - seen) / rate);
            const min = Math.round(remainingSec / 60);
            eta.textContent =
                `~${Math.round(rate)} bestanden/s — geschat nog ${min} min over (op basis van 80k library).`;
        } else {
            eta.textContent = 'Starten… (eerste paar duizend bestanden tellen)';
        }
    }
}

function _renderStatus(data) {
    if (!data) return;

    const banner = document.getElementById('af-disabled-banner');
    if (banner) banner.style.display = data.enabled ? 'none' : 'block';

    _renderScanProgress(data.scan);

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
        if (!data) return;
        // Keep polling while a scan is active OR worker is busy.
        const scanActive = data.scan?.active === true;
        if (!scanActive && !data.worker_running && !data.worker_paused) _stopPolling();
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
        const scanActive = data?.scan?.active === true;
        if ((data?.worker_running && !data?.worker_paused) || scanActive) _startPolling();
    });
}
