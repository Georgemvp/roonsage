// =============================================================================
// Sonic Fingerprint (v13.1)
// =============================================================================

import { apiCall } from './api.js';
import { state } from './state.js';

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
    const zoneId = state.activeZone?.zone_id;
    if (!zoneId) { alert('Selecteer eerst een Roon zone.'); return; }
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

export async function initSonicFingerprintView() {
    if (_initialized) return;
    _initialized = true;

    document.getElementById('sf-limit')?.addEventListener('change', _load);
    document.getElementById('sf-play-btn')?.addEventListener('click', _play);

    await _load();
}
