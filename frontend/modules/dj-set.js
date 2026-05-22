// =============================================================================
// DJ Set view — beatmatched, harmonically-mixed set builder
// =============================================================================
//
// Renders the form in #dj-set-view, calls /api/audio-features/dj-set, draws
// the resulting BPM curve in a Chart.js canvas, and provides "Play on zone"
// which dispatches the curated set via the standard play_tracks endpoint.

import { apiCall } from './api.js';

let _initialized = false;
let _lastResult = null;
let _curveChart = null;

function _esc(s) {
    return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

async function _populateZones() {
    const select = document.getElementById('dj-zone');
    if (!select) return;
    try {
        const zones = await apiCall('/roon/zones');
        select.innerHTML = '';
        for (const z of zones) {
            const opt = document.createElement('option');
            opt.value = z.zone_id;
            opt.textContent = z.display_name;
            select.appendChild(opt);
        }
    } catch (err) {
        select.innerHTML = '<option value="">— No zones —</option>';
    }
}

function _renderTracks(tracks, curve) {
    const target = document.getElementById('dj-result');
    if (!target) return;
    if (!tracks?.length) {
        target.innerHTML = '<p class="auto-loading">Geen tracks gevonden. Heb je AUDIO_FEATURES_ENABLED aan en is de analyse al klaar?</p>';
        return;
    }
    const rows = tracks.map((t, i) => {
        const c = curve[i] || {};
        const bpm = c.bpm ? `${c.bpm.toFixed(0)} BPM` : '';
        return `
            <div class="auto-row">
                <span class="auto-row-num">${i + 1}</span>
                <div class="auto-row-main">
                    <div class="auto-row-title">${_esc(t.title)}</div>
                    <div class="auto-row-sub">${_esc(t.artist)} · ${_esc(t.album || '')}</div>
                </div>
                <span class="auto-badge auto-badge--neutral">${bpm}</span>
            </div>
        `;
    }).join('');
    target.innerHTML = rows;
}

function _renderCurve(curve) {
    const canvas = document.getElementById('dj-curve-chart');
    if (!canvas || typeof Chart === 'undefined') return;
    if (_curveChart) {
        _curveChart.destroy();
        _curveChart = null;
    }
    const labels = curve.map((_, i) => String(i + 1));
    _curveChart = new Chart(canvas, {
        type: 'line',
        data: {
            labels,
            datasets: [
                {
                    label: 'BPM', data: curve.map(c => c.bpm),
                    borderColor: '#e5a00d', tension: 0.3, yAxisID: 'y',
                },
                {
                    label: 'Energy (×100)', data: curve.map(c => Math.round((c.energy || 0) * 100)),
                    borderColor: '#5fb3b3', tension: 0.3, yAxisID: 'y',
                },
            ],
        },
        options: {
            responsive: true, maintainAspectRatio: false,
            scales: { y: { beginAtZero: false } },
        },
    });
}

async function _build(ev) {
    ev?.preventDefault();
    const status = document.getElementById('dj-status');
    const playBtn = document.getElementById('dj-play-btn');
    if (playBtn) playBtn.disabled = true;
    if (status) { status.textContent = 'Bouw set…'; status.style.color = ''; }

    const genresRaw = document.getElementById('dj-genres')?.value?.trim() || '';
    const genres = genresRaw ? genresRaw.split(',').map(g => g.trim()).filter(Boolean) : [];

    const payload = {
        duration_minutes: parseInt(document.getElementById('dj-duration').value, 10) || 60,
        start_bpm: parseFloat(document.getElementById('dj-start-bpm').value) || 110,
        end_bpm: parseFloat(document.getElementById('dj-end-bpm').value) || 128,
        energy_curve: document.getElementById('dj-curve').value || 'ramp_up',
        genres,
    };

    try {
        const data = await apiCall('/audio-features/dj-set', {
            method: 'POST',
            body: JSON.stringify(payload),
        });
        _lastResult = data;
        _renderTracks(data.tracks, data.curve || []);
        _renderCurve(data.curve || []);
        if (status) {
            status.textContent = `Set van ${data.returned} tracks (pool: ${data.total_matching}).`;
            status.style.color = '#4caf50';
        }
        if (playBtn && data.tracks?.length) playBtn.disabled = false;
    } catch (err) {
        if (status) {
            status.textContent = '✗ ' + (err.message || 'Onbekende fout');
            status.style.color = '#f44336';
        }
    }
}

async function _play() {
    if (!_lastResult?.tracks?.length) return;
    const zoneId = document.getElementById('dj-zone')?.value;
    if (!zoneId) {
        const status = document.getElementById('dj-status');
        if (status) {
            status.textContent = '✗ Kies een zone.';
            status.style.color = '#f44336';
        }
        return;
    }
    const itemKeys = _lastResult.tracks.map(t => t.item_key);
    const status = document.getElementById('dj-status');
    if (status) { status.textContent = 'Versturen naar Roon…'; status.style.color = ''; }
    try {
        await apiCall('/roon/play-tracks', {
            method: 'POST',
            body: JSON.stringify({ item_keys: itemKeys, zone_id: zoneId, mode: 'replace' }),
        });
        if (status) {
            status.textContent = `▶ Speelt ${itemKeys.length} tracks af op de gekozen zone.`;
            status.style.color = '#4caf50';
        }
    } catch (err) {
        if (status) {
            status.textContent = '✗ ' + (err.message || 'Playback mislukt');
            status.style.color = '#f44336';
        }
    }
}

export async function initDJSetView() {
    if (!_initialized) {
        document.getElementById('dj-form')?.addEventListener('submit', _build);
        document.getElementById('dj-play-btn')?.addEventListener('click', _play);
        _initialized = true;
    }
    await _populateZones();
}
