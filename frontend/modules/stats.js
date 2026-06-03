// =============================================================================
// Stats — Listening dashboard (KPI cards, timeline, genre donut, top lists)
// =============================================================================
// One backend call (/api/stats/overview), Chart.js for the timeline + donut.
// Reuses ensureChartJS() from taste.js so Chart.js is loaded once, lazily.

import { apiCall } from './api.js';
import { ensureChartJS } from './taste.js';

let _range = '30d';
let _wired = false;
const _charts = {};

function _esc(s) {
    return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function _destroy(key) {
    if (_charts[key]) { _charts[key].destroy(); delete _charts[key]; }
}

function _kpiCards(d) {
    const k = d.kpi, w = d.window;
    const card = (label, value, sub) => `
        <div class="rs-glass-card rs-stat-kpi">
            <div class="rs-stat-kpi-val">${value}</div>
            <div class="rs-stat-kpi-label">${label}</div>
            ${sub ? `<div class="rs-stat-kpi-sub">${sub}</div>` : ''}
        </div>`;
    return [
        card('Plays vandaag', k.today),
        card('Deze week', k.week),
        card('Deze maand', k.month),
        card('All-time', k.all_time),
        card('Luistertijd (venster)', `${w.minutes}m`, `${w.unique_artists} artists · ${w.unique_albums} albums`),
        card('Skip-rate (venster)', `${w.skip_rate}%`, `${w.plays} plays`),
    ].join('');
}

function _topList(items, kind) {
    if (!items.length) return '<p class="rs-stat-empty">Nog geen data in dit venster.</p>';
    return items.map((it, i) => {
        const name = kind === 'album' ? it.album : it.artist;
        const sub = kind === 'album' ? _esc(it.artist) : '';
        const playBtn = kind === 'album'
            ? `<button class="rs-stat-play" data-artist="${_esc(it.artist)}" data-album="${_esc(it.album)}" title="Afspelen" aria-label="Afspelen">▶</button>`
            : '';
        return `<div class="rs-stat-row">
            <span class="rs-stat-rank">${i + 1}</span>
            <span class="rs-stat-row-main">
                <span class="rs-stat-row-name">${_esc(name)}</span>
                ${sub ? `<span class="rs-stat-row-sub">${sub}</span>` : ''}
            </span>
            <span class="rs-stat-row-plays">${it.plays}</span>
            ${playBtn}
        </div>`;
    }).join('');
}

function _healthRings(h) {
    const ring = (label, pct, count, total) => `
        <div class="rs-stat-health">
            <div class="rs-stat-ring" style="--pct:${pct}">
                <span>${pct}%</span>
            </div>
            <div class="rs-stat-health-label">${label}</div>
            <div class="rs-stat-health-sub">${count} / ${total}</div>
        </div>`;
    return ring('Enriched', h.enriched_pct, h.enriched, h.total_tracks)
         + ring('Audio features', h.analysed_pct, h.analysed, h.total_tracks);
}

async function _renderTimeline(timeline) {
    const ctx = document.getElementById('stats-timeline-chart');
    if (!ctx) return;
    _destroy('timeline');
    _charts.timeline = new window.Chart(ctx, {
        type: 'bar',
        data: {
            labels: timeline.map(t => t.day.slice(5)),  // MM-DD
            datasets: [{
                data: timeline.map(t => t.plays),
                backgroundColor: 'rgba(229,160,13,0.55)',
                borderRadius: 3,
            }],
        },
        options: {
            plugins: { legend: { display: false } },
            scales: { x: { grid: { display: false } }, y: { beginAtZero: true } },
        },
    });
}

async function _renderGenreDonut(genres) {
    const ctx = document.getElementById('stats-genre-chart');
    if (!ctx) return;
    _destroy('genre');
    const palette = ['#e5a00d', '#00d4aa', '#4ea3ff', '#e95c59', '#a06cd5',
                     '#fb8c00', '#43a047', '#ec407a', '#26c6da', '#8d6e63'];
    _charts.genre = new window.Chart(ctx, {
        type: 'doughnut',
        data: {
            labels: genres.map(g => g.genre),
            datasets: [{ data: genres.map(g => g.plays), backgroundColor: palette, borderWidth: 0 }],
        },
        options: { plugins: { legend: { position: 'right', labels: { boxWidth: 12 } } }, cutout: '62%' },
    });
}

async function _load() {
    const root = document.getElementById('stats-body');
    if (!root) return;
    root.classList.add('rs-stat-loading');
    try {
        const d = await apiCall(`/stats/overview?range=${encodeURIComponent(_range)}`);
        await ensureChartJS();

        document.getElementById('stats-kpis').innerHTML = _kpiCards(d);
        document.getElementById('stats-top-artists').innerHTML = _topList(d.top_artists, 'artist');
        document.getElementById('stats-top-albums').innerHTML = _topList(d.top_albums, 'album');
        document.getElementById('stats-health').innerHTML = _healthRings(d.library_health);

        _renderTimeline(d.timeline);
        _renderGenreDonut(d.genres);
    } catch (e) {
        console.warn('stats load failed:', e);
        root.innerHTML = '<p class="rs-stat-empty">Stats konden niet geladen worden.</p>';
    } finally {
        root.classList.remove('rs-stat-loading');
    }
}

function _wire() {
    document.querySelectorAll('[data-stats-range]').forEach(btn => {
        btn.addEventListener('click', () => {
            _range = btn.dataset.statsRange;
            document.querySelectorAll('[data-stats-range]').forEach(b =>
                b.classList.toggle('active', b === btn));
            _load();
        });
    });

    // Delegated album play buttons
    document.getElementById('stats-top-albums')?.addEventListener('click', async (e) => {
        const btn = e.target.closest('.rs-stat-play');
        if (!btn) return;
        const { artist, album } = btn.dataset;
        if (!artist || !album) return;
        btn.disabled = true;
        try {
            await apiCall(`/roon/play-album?artist=${encodeURIComponent(artist)}&album=${encodeURIComponent(album)}`,
                { method: 'POST' });
        } catch (_) { /* silent */ }
        btn.disabled = false;
    });

    _wired = true;
}

export function initStatsView() {
    if (!_wired) _wire();
    _load();
}
