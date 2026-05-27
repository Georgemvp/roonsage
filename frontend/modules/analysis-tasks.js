/**
 * Analysis Task Bar + v13.0 settings sections
 * Polls all four analysis APIs and updates the floating tray + settings panels.
 */

import { apiCall } from './api.js';

// ── Polling ─────────────────────────────────────────────────────────────────

const POLL_INTERVAL_ACTIVE = 3000;
const POLL_INTERVAL_IDLE   = 30000;

let _pollTimer = null;
let _collapsed = false;
let _dismissed = false;

function _anyActive(statuses) {
    return statuses.some(s =>
        s?.status === 'running' ||
        s?.status === 'analyzing' ||
        s?.is_running ||
        (s?.worker_running && (s?.pending ?? 0) > 0) ||
        s?.scan?.active
    );
}

async function _poll() {
    const [af, cl, clap, lyr, enrich] = await Promise.allSettled([
        apiCall('/audio-features/status').catch(() => null),
        apiCall('/clustering/status').catch(() => null),
        apiCall('/clap/status').catch(() => null),
        apiCall('/lyrics/status').catch(() => null),
        apiCall('/enrichment/status').catch(() => null),
    ]).then(rs => rs.map(r => r.value ?? null));

    _updateTaskBar(af, cl, clap, lyr, enrich);
    _updateSettingsSections(cl, clap, lyr);

    const interval = _anyActive([af, cl, clap, lyr, enrich]) ? POLL_INTERVAL_ACTIVE : POLL_INTERVAL_IDLE;
    _pollTimer = setTimeout(_poll, interval);
}

export function startAnalysisTaskPoller() {
    if (_pollTimer) return;
    _poll();
}

export function stopAnalysisTaskPoller() {
    if (_pollTimer) { clearTimeout(_pollTimer); _pollTimer = null; }
}

// ── Task Bar ─────────────────────────────────────────────────────────────────

function _badge(status, cls = '') {
    const map = {
        running:   ['running', 'Bezig…'],
        analyzing: ['running', 'Bezig…'],
        complete:  ['complete', 'Klaar'],
        failed:    ['failed', 'Fout'],
        idle:      ['idle', 'Inactief'],
    };
    const [state, label] = map[status] || ['idle', status || '—'];
    return { state, label };
}

function _setTask(id, pct, badgeText, badgeState, label) {
    const fill  = document.getElementById(`atb-${id}-fill`);
    const badge = document.getElementById(`atb-${id}-badge`);
    const lbl   = document.getElementById(`atb-${id}-label`);
    if (fill)  fill.style.width = `${Math.min(100, Math.max(0, pct))}%`;
    if (badge) { badge.textContent = badgeText; badge.dataset.state = badgeState; }
    if (lbl)   lbl.textContent = label;
}

function _updateTaskBar(af, cl, clap, lyr, enrich) {
    const bar = document.getElementById('analysis-task-bar');
    if (!bar) return;

    // Audio features
    if (af) {
        const done = af.n_analyzed ?? 0;
        const total = (done + (af.n_pending ?? 0));
        const pct = total > 0 ? (done / total) * 100 : (af.status === 'complete' ? 100 : 0);
        const { state, label } = _badge(af.worker_status || (af.n_pending > 0 ? 'idle' : 'complete'));
        _setTask('af', pct, label, state, total > 0 ? `${done.toLocaleString()} / ${total.toLocaleString()}` : '');
    }

    // Clustering
    if (cl) {
        const pct = cl.status === 'complete' ? 100 : cl.status === 'running' ? 50 : 0;
        const { state, label } = _badge(cl.status);
        const detail = cl.n_clusters ? `${cl.n_clusters.toLocaleString()} clusters` : '';
        _setTask('cl', pct, label, state, detail);
    }

    // CLAP
    if (clap) {
        const done = clap.n_done ?? 0;
        const total = clap.n_total ?? 0;
        const pct = total > 0 ? (done / total) * 100 : 0;
        const { state, label } = _badge(clap.status);
        _setTask('clap', pct, label, state, total > 0 ? `${done.toLocaleString()} / ${total.toLocaleString()}` : (!clap.enabled ? 'Uitgeschakeld' : ''));
    }

    // Lyrics
    if (lyr) {
        const done = lyr.n_embedded ?? 0;
        const total = lyr.n_total ?? 0;
        const pct = total > 0 ? (done / total) * 100 : 0;
        const { state, label } = _badge(lyr.status);
        _setTask('lyrics', pct, label, state, total > 0 ? `${done.toLocaleString()} / ${total.toLocaleString()}` : (!lyr.enabled ? 'Uitgeschakeld' : ''));
    }

    // Path resolver scan (from AF status)
    if (af?.scan) {
        const scan = af.scan;
        const scanActive = scan.active || scan.phase === 'walking' || scan.phase === 'matching';
        const pct = scan.files_seen > 0 ? (scan.files_indexed / scan.files_seen) * 100 : (scan.phase === 'complete' ? 100 : 0);
        const phaseLabel = { idle: 'Inactief', walking: 'Bezig…', matching: 'Koppelen…', complete: 'Klaar' }[scan.phase] || '—';
        const badgeState = scanActive ? 'running' : (scan.phase === 'complete' ? 'complete' : 'idle');
        const label = scan.files_seen > 0 ? `${(scan.files_indexed ?? 0).toLocaleString()} / ${scan.files_seen.toLocaleString()} bestanden` : '';
        _setTask('scan', pct, phaseLabel, badgeState, label);
    }

    // Enrichment
    if (enrich) {
        const total = (enrich.pending ?? 0) + (enrich.complete ?? 0) + (enrich.failed ?? 0);
        const done = enrich.complete ?? 0;
        const pct = total > 0 ? (done / total) * 100 : 0;
        const activelyRunning = enrich.worker_running && (enrich.pending ?? 0) > 0;
        const badgeState = activelyRunning ? 'running' : (done > 0 ? 'complete' : 'idle');
        const badgeText = activelyRunning ? 'Bezig…' : (done > 0 ? 'Klaar' : 'Inactief');
        _setTask('enrich', pct, badgeText, badgeState, total > 0 ? `${done.toLocaleString()} / ${total.toLocaleString()}` : '');
    }

    // Auto-show when something is active (unless user dismissed)
    const active = _anyActive([af, cl, clap, lyr, enrich]);
    if (active && _dismissed) _dismissed = false;
    if (!_dismissed) {
        bar.classList.toggle('hidden', !active && !_alwaysVisible());
    }

    // Sidebar dot indicator
    const dot = document.getElementById('sidebar-tasks-dot');
    if (dot) dot.style.display = active ? '' : 'none';
}

function _alwaysVisible() {
    try { return localStorage.getItem('atb-pinned') === '1'; } catch { return false; }
}

// ── Settings Sections ────────────────────────────────────────────────────────

function _workerBadgeText(status) {
    return { running: 'Bezig', analyzing: 'Bezig', complete: 'Klaar', failed: 'Fout', idle: 'Inactief' }[status] || (status || '');
}

function _setPbar(fillId, pct) {
    const el = document.getElementById(fillId);
    if (el) el.style.width = `${Math.min(100, Math.max(0, pct))}%`;
}

function _setText(id, val) {
    const el = document.getElementById(id);
    if (el) el.textContent = val ?? '';
}

function _setBadge(id, status) {
    const el = document.getElementById(id);
    if (!el) return;
    el.textContent = _workerBadgeText(status);
    el.dataset.state = status || 'idle';
}

function _updateSettingsSections(cl, clap, lyr) {
    // Clustering
    if (cl) {
        _setText('cl-n-clusters', cl.n_clusters != null ? cl.n_clusters.toLocaleString() : '–');
        _setText('cl-n-tracks',   cl.n_tracks   != null ? cl.n_tracks.toLocaleString()   : '–');
        _setText('cl-n-noise',    cl.n_noise    != null ? cl.n_noise.toLocaleString()    : '–');
        const ts = cl.finished_at || cl.started_at;
        _setText('cl-last-run', ts ? new Date(ts).toLocaleString('nl-NL', { dateStyle: 'short', timeStyle: 'short' }) : '–');
        _setBadge('cl-status-badge', cl.status);
        _setText('cl-status-text', cl.error_message || '');

        const btn = document.getElementById('cl-run-btn');
        if (btn) btn.disabled = cl.status === 'running';
    }

    // CLAP
    if (clap) {
        const banner = document.getElementById('clap-disabled-banner');
        if (banner) banner.style.display = clap.enabled ? 'none' : '';

        const done = clap.n_done ?? 0;
        const total = clap.n_total ?? 0;
        const pending = total > done ? total - done : 0;
        _setText('clap-n-done',    done.toLocaleString());
        _setText('clap-n-pending', pending.toLocaleString());
        _setText('clap-n-failed',  (clap.n_failed ?? 0).toLocaleString());
        const pct = total > 0 ? (done / total) * 100 : 0;
        _setPbar('clap-progress-fill', pct);
        _setText('clap-progress-text', total > 0 ? `${done.toLocaleString()} / ${total.toLocaleString()}` : '');
        _setBadge('clap-status-badge', clap.status);

        const btn = document.getElementById('clap-start-btn');
        if (btn) btn.disabled = clap.status === 'running';
    }

    // Lyrics
    if (lyr) {
        const banner = document.getElementById('lyrics-disabled-banner');
        if (banner) banner.style.display = lyr.enabled ? 'none' : '';

        const done = lyr.n_embedded ?? 0;
        const total = lyr.n_total ?? 0;
        const pending = total > done ? total - done : 0;
        _setText('lyrics-n-done',    done.toLocaleString());
        _setText('lyrics-n-pending', pending.toLocaleString());
        _setText('lyrics-n-failed',  (lyr.n_failed ?? 0).toLocaleString());
        const pct = total > 0 ? (done / total) * 100 : 0;
        _setPbar('lyrics-progress-fill', pct);
        _setText('lyrics-progress-text', total > 0 ? `${done.toLocaleString()} / ${total.toLocaleString()}` : '');
        _setBadge('lyrics-status-badge', lyr.status);

        const btn = document.getElementById('lyrics-start-btn');
        if (btn) btn.disabled = lyr.status === 'running';
    }
}

// ── Settings Section Buttons ─────────────────────────────────────────────────

async function _runClustering() {
    const btn = document.getElementById('cl-run-btn');
    const result = document.getElementById('cl-action-result');
    if (!btn || !result) return;

    const params = {
        umap_n_neighbors:      parseInt(document.getElementById('cl-umap-neighbors')?.value) || 15,
        umap_min_dist:         parseFloat(document.getElementById('cl-umap-min-dist')?.value) || 0.1,
        hdbscan_min_cluster_size: parseInt(document.getElementById('cl-hdbscan-min-size')?.value) || 10,
        hdbscan_min_samples:   parseInt(document.getElementById('cl-hdbscan-min-samples')?.value) || 5,
    };

    btn.disabled = true;
    result.textContent = 'Clustering gestart…';
    result.style.color = '';

    try {
        await apiCall('/clustering/run', { method: 'POST', body: JSON.stringify(params) });
        result.textContent = 'Clustering loopt op de achtergrond. De taakbalk toont de voortgang.';

        // Show task bar and start fast polling
        const bar = document.getElementById('analysis-task-bar');
        if (bar) { bar.classList.remove('hidden'); _dismissed = false; }
        _restartPoll(POLL_INTERVAL_ACTIVE);
    } catch (e) {
        result.style.color = 'var(--error)';
        result.textContent = `Fout: ${e.message || e}`;
        btn.disabled = false;
    }
}

async function _startClap() {
    const btn = document.getElementById('clap-start-btn');
    const result = document.getElementById('clap-action-result');
    if (!btn || !result) return;

    btn.disabled = true;
    result.textContent = 'CLAP analyse gestart…';
    result.style.color = '';

    try {
        await apiCall('/clap/analyze', { method: 'POST' });
        result.textContent = 'Analyse loopt op de achtergrond.';
        const bar = document.getElementById('analysis-task-bar');
        if (bar) { bar.classList.remove('hidden'); _dismissed = false; }
        _restartPoll(POLL_INTERVAL_ACTIVE);
    } catch (e) {
        result.style.color = 'var(--error)';
        result.textContent = `Fout: ${e.message || e}`;
        btn.disabled = false;
    }
}

async function _startLyrics() {
    const btn = document.getElementById('lyrics-start-btn');
    const result = document.getElementById('lyrics-action-result');
    if (!btn || !result) return;

    btn.disabled = true;
    result.textContent = 'Lyrics analyse gestart…';
    result.style.color = '';

    try {
        await apiCall('/lyrics/analyze', { method: 'POST' });
        result.textContent = 'Analyse loopt op de achtergrond.';
        const bar = document.getElementById('analysis-task-bar');
        if (bar) { bar.classList.remove('hidden'); _dismissed = false; }
        _restartPoll(POLL_INTERVAL_ACTIVE);
    } catch (e) {
        result.style.color = 'var(--error)';
        result.textContent = `Fout: ${e.message || e}`;
        btn.disabled = false;
    }
}

function _restartPoll(intervalMs = POLL_INTERVAL_ACTIVE) {
    if (_pollTimer) { clearTimeout(_pollTimer); _pollTimer = null; }
    _pollTimer = setTimeout(_poll, intervalMs);
}

// ── Init ─────────────────────────────────────────────────────────────────────

export function initAnalysisTasks() {
    // Task bar toggle / close / pin
    document.getElementById('atb-toggle-btn')?.addEventListener('click', () => {
        _collapsed = !_collapsed;
        const body = document.getElementById('atb-body');
        const btn  = document.getElementById('atb-toggle-btn');
        if (body) body.style.display = _collapsed ? 'none' : '';
        if (btn)  btn.textContent = _collapsed ? '▲' : '▼';
    });

    document.getElementById('atb-close-btn')?.addEventListener('click', () => {
        _dismissed = true;
        localStorage.setItem('atb-pinned', '0');
        document.getElementById('analysis-task-bar')?.classList.add('hidden');
        document.getElementById('atb-pin-btn')?.classList.remove('atb-pin-active');
    });

    document.getElementById('atb-pin-btn')?.addEventListener('click', () => {
        const pinned = _alwaysVisible();
        localStorage.setItem('atb-pinned', pinned ? '0' : '1');
        const btn = document.getElementById('atb-pin-btn');
        if (btn) btn.classList.toggle('atb-pin-active', !pinned);
        if (!pinned) {
            _dismissed = false;
            document.getElementById('analysis-task-bar')?.classList.remove('hidden');
        }
    });

    // Sidebar "Taken" button — shows + pins the task bar
    document.getElementById('sidebar-tasks-btn')?.addEventListener('click', () => {
        const bar = document.getElementById('analysis-task-bar');
        if (!bar) return;
        const isHidden = bar.classList.contains('hidden');
        if (isHidden) {
            _dismissed = false;
            bar.classList.remove('hidden');
            localStorage.setItem('atb-pinned', '1');
            document.getElementById('atb-pin-btn')?.classList.add('atb-pin-active');
        } else {
            localStorage.setItem('atb-pinned', '0');
            bar.classList.add('hidden');
            _dismissed = true;
            document.getElementById('atb-pin-btn')?.classList.remove('atb-pin-active');
        }
    });

    // Apply persisted pin state on load
    if (_alwaysVisible()) {
        document.getElementById('analysis-task-bar')?.classList.remove('hidden');
        document.getElementById('atb-pin-btn')?.classList.add('atb-pin-active');
    }

    // Settings section buttons
    document.getElementById('cl-run-btn')?.addEventListener('click', _runClustering);
    document.getElementById('clap-start-btn')?.addEventListener('click', _startClap);
    document.getElementById('lyrics-start-btn')?.addEventListener('click', _startLyrics);

    // Start polling
    startAnalysisTaskPoller();
}
