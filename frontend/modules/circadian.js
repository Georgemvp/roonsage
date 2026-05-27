// =============================================================================
// Circadian Rhythm view (v13.4)
// 24-hour audio-feature profile + time-of-day playlist generation
// =============================================================================

import { apiCall } from './api.js';

let _initialized = false;
let _profile = null;
let _chart = null;
let _lastResult = null;

async function ensureChartJs() {
    if (window.Chart) return;
    await new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = 'https://cdn.jsdelivr.net/npm/chart.js';
        s.onload = resolve;
        s.onerror = reject;
        document.head.appendChild(s);
    });
}

function _formatHour(h) {
    return String(h).padStart(2, '0') + ':00';
}

function renderChart(profile) {
    const canvas = document.getElementById('circadian-chart');
    if (!canvas || !window.Chart) return;

    const labels = Array.from({ length: 24 }, (_, i) => _formatHour(i));
    const features = profile.feature_columns || [];
    const palette = {
        energy: '#e5a00d',
        danceability: '#7aa6ff',
        valence: '#74c285',
        instrumentalness: '#c084fc',
        acousticness: '#f87171',
    };

    const datasets = features.map(f => ({
        label: f,
        data: labels.map((_, h) => profile.hours[h]?.[f] ?? 0),
        borderColor: palette[f] || '#888',
        backgroundColor: (palette[f] || '#888') + '20',
        tension: 0.35,
        pointRadius: 2,
    }));

    if (_chart) { _chart.destroy(); _chart = null; }
    _chart = new window.Chart(canvas, {
        type: 'line',
        data: { labels, datasets },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            interaction: { mode: 'nearest', intersect: false },
            scales: {
                y: { min: 0, max: 1, ticks: { color: '#aaa' } },
                x: { ticks: { color: '#aaa', maxTicksLimit: 12 } },
            },
            plugins: { legend: { labels: { color: '#ddd' } } },
        },
    });

    const meta = document.getElementById('circadian-meta');
    if (meta) {
        const interp = profile.interpolated_hours || [];
        const degraded = profile.degraded
            ? '<strong style="color:#f87171;">Te weinig data — alle uren tonen het globale gemiddelde.</strong>'
            : interp.length
                ? `Geïnterpoleerde uren: ${interp.map(_formatHour).join(', ')}`
                : 'Alle 24 uren zijn rechtstreeks afgeleid uit jouw luistergeschiedenis.';
        meta.innerHTML = `
          <div>Total samples: ${profile.total_samples}</div>
          <div style="margin-top:4px;">${degraded}</div>
        `;
    }
}

async function loadProfile() {
    try {
        _profile = await apiCall('/circadian/profile');
        renderChart(_profile);
    } catch (err) {
        const meta = document.getElementById('circadian-meta');
        if (meta) meta.innerHTML = `<div class="cluster-error">Profiel laden mislukt: ${err.message}</div>`;
    }
}

async function loadZones() {
    try {
        const zones = await apiCall('/roon/zones');
        const sel = document.getElementById('circadian-zone');
        if (!sel) return;
        sel.innerHTML = (zones || []).map(z =>
            `<option value="${z.zone_id}">${z.display_name}</option>`
        ).join('') || '<option value="">(geen zones)</option>';
    } catch {/* zones optional */}
}

function renderResults(data) {
    const out = document.getElementById('circadian-results');
    if (!out) return;
    if (data.error) {
        out.innerHTML = `<div class="cluster-empty">${data.error}</div>`;
        return;
    }
    if (!data.results || !data.results.length) {
        out.innerHTML = '<div class="cluster-empty">Geen resultaten.</div>';
        return;
    }
    out.innerHTML = `
      <div style="margin:12px 0 8px;color:var(--text-muted);font-size:13px;">
        ${data.results.length} tracks · pool van ${data.n_pool} · uur ${_formatHour(data.hour)}
        ${data.interpolated ? '<span style="color:#f87171;"> · geïnterpoleerd</span>' : ''}
      </div>
      ${data.results.map(t => `
        <div class="alchemy-result-track">
          <div>
            <strong>${t.title}</strong>
            <span style="color:var(--text-muted);"> · ${t.artist}</span>
          </div>
          <span class="alchemy-score">${(((t.match) ?? 0) * 100).toFixed(1)}%</span>
        </div>
      `).join('')}
    `;
}

async function generateForHour(hour, limit) {
    const out = document.getElementById('circadian-results');
    if (out) out.innerHTML = '<div style="color:var(--text-muted);">Berekenen…</div>';
    try {
        const data = await apiCall(`/circadian/playlist?hour=${hour}&limit=${limit}`);
        _lastResult = data;
        renderResults(data);
        const playBtn = document.getElementById('circadian-play-btn');
        if (playBtn) playBtn.disabled = !(data.results && data.results.length);
        return data;
    } catch (err) {
        if (out) out.innerHTML = `<div class="cluster-error">Genereren mislukt: ${err.message}</div>`;
        return null;
    }
}

export async function initCircadianView() {
    if (_initialized) return;
    _initialized = true;

    await ensureChartJs().catch(() => {/* chart simply won't render */});
    await Promise.all([loadProfile(), loadZones()]);

    const hourSlider = document.getElementById('circadian-hour');
    const hourLabel = document.getElementById('circadian-hour-label');
    const limitSel = document.getElementById('circadian-limit');
    const nowBtn = document.getElementById('circadian-now-btn');
    const playBtn = document.getElementById('circadian-play-btn');
    const zoneSel = document.getElementById('circadian-zone');

    // Default the slider to the current local hour.
    const currentHour = new Date().getHours();
    if (hourSlider) hourSlider.value = String(currentHour);
    if (hourLabel) hourLabel.textContent = _formatHour(currentHour);

    hourSlider?.addEventListener('input', () => {
        const h = parseInt(hourSlider.value, 10) || 0;
        if (hourLabel) hourLabel.textContent = _formatHour(h);
    });

    hourSlider?.addEventListener('change', async () => {
        const h = parseInt(hourSlider.value, 10) || 0;
        const limit = parseInt(limitSel?.value || '25', 10);
        await generateForHour(h, limit);
    });

    nowBtn?.addEventListener('click', async () => {
        const h = new Date().getHours();
        if (hourSlider) hourSlider.value = String(h);
        if (hourLabel) hourLabel.textContent = _formatHour(h);
        const limit = parseInt(limitSel?.value || '25', 10);
        await generateForHour(h, limit);
    });

    playBtn?.addEventListener('click', async () => {
        if (!_lastResult || !_lastResult.results?.length) return;
        const zoneId = zoneSel?.value;
        if (!zoneId) { alert('Geen zone geselecteerd.'); return; }
        playBtn.disabled = true;
        const orig = playBtn.textContent;
        playBtn.textContent = 'Afspelen…';
        try {
            await apiCall('/circadian/play', {
                method: 'POST',
                body: JSON.stringify({
                    zone_id: zoneId,
                    hour: _lastResult.hour,
                    limit: _lastResult.results.length,
                    mode: 'replace',
                }),
            });
        } catch (err) {
            alert(`Afspelen mislukt: ${err.message}`);
        } finally {
            playBtn.disabled = false;
            playBtn.textContent = orig;
        }
    });

    // Auto-generate for "now" on first visit
    const limit = parseInt(limitSel?.value || '25', 10);
    await generateForHour(currentHour, limit);
}
