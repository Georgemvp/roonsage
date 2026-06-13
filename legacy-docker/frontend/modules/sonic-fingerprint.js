// =============================================================================
// Sonic Fingerprint (v13.1)
// =============================================================================

import { apiCall } from './api.js';
import { getCurrentZoneId, openZonePicker } from './nowplaying.js';

let _initialized = false;
let _chart = null;
let _lastRecs = null;

async function _loadChartJs() {
    if (window.Chart) return;
    await new Promise((res, rej) => {
        const s = document.createElement('script');
        s.src = 'https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js';
        s.onload = res;
        s.onerror = rej;
        document.head.appendChild(s);
    });
}

async function _renderRadar(fingerprint) {
    await _loadChartJs();
    const canvas = document.getElementById('sf-radar');
    if (!canvas) return;
    if (_chart) { _chart.destroy(); _chart = null; }

    const labels = fingerprint.feature_columns.map(c => c.charAt(0).toUpperCase() + c.slice(1));
    _chart = new window.Chart(canvas, {
        type: 'radar',
        data: {
            labels,
            datasets: [{
                label: 'Jouw profiel',
                data: fingerprint.fingerprint,
                backgroundColor: 'rgba(146,112,212,0.18)',
                borderColor: 'var(--accent, #9270d4)',
                pointBackgroundColor: 'var(--accent, #9270d4)',
                borderWidth: 2,
            }],
        },
        options: {
            scales: {
                r: {
                    min: 0, max: 1,
                    ticks: { display: false },
                    grid: { color: 'rgba(128,128,128,0.15)' },
                    pointLabels: { color: 'var(--text-secondary)', font: { size: 11 } },
                },
            },
            plugins: { legend: { display: false } },
        },
    });
}

function _renderResults(results) {
    const el = document.getElementById('sf-results');
    if (!el) return;
    if (!results.length) {
        el.innerHTML = '<p style="color:var(--text-muted);font-size:0.85rem;">Geen aanbevelingen gevonden.</p>';
        return;
    }
    el.innerHTML = results.map(r => `
        <div class="sf-track">
            <div class="sf-track-info">
                <div class="sf-track-title">${r.title}</div>
                <div class="sf-track-meta">${r.artist} · ${r.album} · <strong>${Math.round(r.similarity * 100)}%</strong> match</div>
            </div>
            <span class="sf-plays" title="Gespeeld">${r.play_count}×</span>
        </div>
    `).join('');
}

async function _load() {
    const meta = document.getElementById('sf-meta');
    const playBtn = document.getElementById('sf-play-btn');
    if (meta) meta.innerHTML = '<span style="color:var(--text-muted)">Laden…</span>';

    const limit = parseInt(document.getElementById('sf-limit')?.value || '25', 10);

    try {
        const [profile, recs] = await Promise.all([
            apiCall('/sonic-fingerprint/profile'),
            apiCall(`/sonic-fingerprint/recommendations?limit=${limit}`),
        ]);

        if (profile.error) {
            if (meta) meta.textContent = profile.error;
            return;
        }

        if (meta) meta.innerHTML = `
            <p class="sf-meta-line"><strong>${profile.n_source_tracks}</strong> tracks als basis</p>
            <p class="sf-meta-line" style="font-size:0.82rem;color:var(--text-muted)">Top gespeelde tracks uit je bibliotheek</p>
        `;

        await _renderRadar(profile);
        _lastRecs = recs;
        _renderResults(recs.results || []);
        if (playBtn) playBtn.disabled = !(recs.results?.length);
    } catch (e) {
        if (meta) meta.textContent = `Fout: ${e.message}`;
    }
}

async function _play() {
    const btn = document.getElementById('sf-play-btn');
    const limit = parseInt(document.getElementById('sf-limit')?.value || '25', 10);
    const zoneId = getCurrentZoneId();
    if (!zoneId) { openZonePicker(); return; }
    if (btn) btn.disabled = true;
    try {
        await apiCall('/sonic-fingerprint/play', {
            method: 'POST',
            body: JSON.stringify({ zone_id: zoneId, limit }),
        });
    } catch (e) {
        alert(`Afspelen mislukt: ${e.message}`);
    } finally {
        if (btn) btn.disabled = false;
    }
}


// ---- Sonic Radio controls --------------------------------------------------

let _radioPoll = null;
let _radioActiveZone = null;

function _setRadioStatus(text, isActive) {
    const el = document.getElementById('sf-radio-status');
    if (!el) return;
    el.textContent = text;
    el.classList.toggle('sf-radio-status--on', !!isActive);
}

function _renderRadioStats(stats) {
    const el = document.getElementById('sf-radio-stats');
    if (!el) return;
    if (!stats) { el.innerHTML = ''; return; }
    const drift = (stats.fingerprint_drift || 0).toFixed(3);
    el.innerHTML = `
      <div class="sf-radio-stat-row">
        <span>${stats.tracks_played || 0} gespeeld</span>
        <span>${stats.tracks_skipped || 0} skip</span>
        <span title="Hoeveel je profiel deze sessie is verschoven">drift ${drift}</span>
      </div>
    `;
}

async function _refreshRadioStatus() {
    try {
        const data = await apiCall('/sonic-radio/status');
        const mine = (data.sessions || []).find(s => s.zone_id === _radioActiveZone);
        if (mine) {
            _setRadioStatus('aan', true);
            _renderRadioStats(mine);
            document.getElementById('sf-radio-start-btn').disabled = true;
            document.getElementById('sf-radio-stop-btn').disabled = false;
        } else {
            _setRadioStatus('uit', false);
            _renderRadioStats(null);
            document.getElementById('sf-radio-start-btn').disabled = false;
            document.getElementById('sf-radio-stop-btn').disabled = true;
            _radioActiveZone = null;
            if (_radioPoll) { clearInterval(_radioPoll); _radioPoll = null; }
        }
    } catch (e) {
        console.warn('sonic-radio status failed', e);
    }
}

async function _startRadio() {
    const zoneId = getCurrentZoneId();
    if (!zoneId) { openZonePicker(); return; }
    const slider = document.getElementById('sf-radio-discovery');
    const ratio = (parseInt(slider?.value || '30', 10) || 30) / 100;
    const startBtn = document.getElementById('sf-radio-start-btn');
    if (startBtn) startBtn.disabled = true;
    try {
        await apiCall('/sonic-radio/start', {
            method: 'POST',
            body: JSON.stringify({
                zone_id: zoneId,
                discovery_ratio: ratio,
                play: true,
            }),
        });
        _radioActiveZone = zoneId;
        _setRadioStatus('aan', true);
        document.getElementById('sf-radio-stop-btn').disabled = false;
        if (_radioPoll) clearInterval(_radioPoll);
        _radioPoll = setInterval(_refreshRadioStatus, 5000);
    } catch (e) {
        alert(`Sonic Radio start mislukt: ${e.message}`);
        if (startBtn) startBtn.disabled = false;
    }
}

async function _stopRadio() {
    if (!_radioActiveZone) {
        await _refreshRadioStatus();
        return;
    }
    const stopBtn = document.getElementById('sf-radio-stop-btn');
    if (stopBtn) stopBtn.disabled = true;
    try {
        const result = await apiCall('/sonic-radio/stop', {
            method: 'POST',
            body: JSON.stringify({ zone_id: _radioActiveZone }),
        });
        _renderRadioStats(result);
    } catch (e) {
        alert(`Sonic Radio stop mislukt: ${e.message}`);
    } finally {
        _radioActiveZone = null;
        if (_radioPoll) { clearInterval(_radioPoll); _radioPoll = null; }
        _setRadioStatus('uit', false);
        document.getElementById('sf-radio-start-btn').disabled = false;
    }
}

export async function initSonicFingerprintView() {
    if (_initialized) return;
    _initialized = true;

    document.getElementById('sf-limit')?.addEventListener('change', _load);
    document.getElementById('sf-play-btn')?.addEventListener('click', _play);

    const slider = document.getElementById('sf-radio-discovery');
    const sliderVal = document.getElementById('sf-radio-discovery-val');
    slider?.addEventListener('input', () => {
        if (sliderVal) sliderVal.textContent = `${slider.value}%`;
    });
    document.getElementById('sf-radio-start-btn')?.addEventListener('click', _startRadio);
    document.getElementById('sf-radio-stop-btn')?.addEventListener('click', _stopRadio);

    await _load();
    await _refreshRadioStatus();
}
