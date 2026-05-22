// =============================================================================
// DJ Set view — beatmatched, harmonically-mixed set builder
// =============================================================================
//
// Renders the form in #dj-set-view, calls /api/audio-features/dj-set, draws
// the resulting BPM curve in a Chart.js canvas, and provides "Play on zone"
// which dispatches the curated set via the standard play_tracks endpoint.

import { apiCall } from './api.js';
import { showSuccess } from './ui.js';

let _initialized = false;
let _lastResult = null;
let _curveChart = null;
let _selectedGenres = new Set();

function _esc(s) {
    return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function _updateGenreCountLabel() {
    const el = document.getElementById('dj-genre-selected-count');
    if (!el) return;
    el.textContent = _selectedGenres.size > 0
        ? `(${_selectedGenres.size} geselecteerd)`
        : '(optioneel — alles als niets geselecteerd)';
}

async function _loadGenres() {
    const cloud = document.getElementById('dj-genre-cloud');
    if (!cloud) return;
    try {
        const data = await apiCall('/library/stats');
        const genres = data.genres || [];
        if (!genres.length) {
            cloud.innerHTML = '<span style="color:var(--text-muted);font-size:0.85em;">Geen genres gevonden.</span>';
            return;
        }
        cloud.innerHTML = genres.map(g => `
            <button type="button"
                class="discovery-genre-pill${_selectedGenres.has(g.name) ? ' discovery-genre-pill--selected' : ''}"
                data-dj-genre="${_esc(g.name)}"
                title="${g.count} tracks"
            >${_esc(g.name)} <span class="discovery-genre-count">${g.count}</span></button>
        `).join('');
        cloud.querySelectorAll('[data-dj-genre]').forEach(btn => {
            btn.addEventListener('click', () => {
                const genre = btn.dataset.djGenre;
                if (_selectedGenres.has(genre)) {
                    _selectedGenres.delete(genre);
                    btn.classList.remove('discovery-genre-pill--selected');
                } else {
                    _selectedGenres.add(genre);
                    btn.classList.add('discovery-genre-pill--selected');
                }
                _updateGenreCountLabel();
            });
        });
    } catch {
        cloud.innerHTML = '<span style="color:var(--text-muted);font-size:0.85em;">Genres konden niet worden geladen.</span>';
    }
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
    const hasValence = curve.some(c => c.valence != null);
    const datasets = [
        {
            label: 'BPM', data: curve.map(c => c.bpm),
            borderColor: '#e5a00d', tension: 0.3, yAxisID: 'y',
        },
        {
            label: 'Energy (×100)', data: curve.map(c => Math.round((c.energy || 0) * 100)),
            borderColor: '#5fb3b3', tension: 0.3, yAxisID: 'y',
        },
    ];
    if (hasValence) {
        datasets.push({
            label: 'Mood/Valence (×100)', data: curve.map(c => Math.round((c.valence || 0) * 100)),
            borderColor: '#b388ff', borderDash: [4, 3], tension: 0.3, yAxisID: 'y',
        });
    }
    _curveChart = new Chart(canvas, {
        type: 'line',
        data: { labels, datasets },
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

    const genres = Array.from(_selectedGenres);
    const startMood = document.getElementById('dj-start-mood')?.value || null;
    const endMood   = document.getElementById('dj-end-mood')?.value   || null;

    const payload = {
        duration_minutes: parseInt(document.getElementById('dj-duration').value, 10) || 60,
        start_bpm: parseFloat(document.getElementById('dj-start-bpm').value) || 110,
        end_bpm: parseFloat(document.getElementById('dj-end-bpm').value) || 128,
        energy_curve: document.getElementById('dj-curve').value || 'ramp_up',
        genres,
        start_mood: startMood || null,
        end_mood:   (endMood && endMood !== startMood) ? endMood : null,
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
        await apiCall('/queue', {
            method: 'POST',
            body: JSON.stringify({ item_keys: itemKeys, zone_id: zoneId, mode: 'replace' }),
        });
        showSuccess(`▶ DJ set van ${itemKeys.length} tracks gestart.`);
        if (status) { status.textContent = ''; }
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
    await Promise.all([_populateZones(), _loadGenres()]);
}
