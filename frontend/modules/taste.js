// =============================================================================
// My Taste — Smaakprofiel visualisatie
// =============================================================================

import { apiCall } from './api.js';
import { escapeHtml } from './utils.js';

let _chartInstances = {};

// ── Public init ──────────────────────────────────────────────────────────────
export async function initTasteView() {
    const view = document.getElementById('taste-view');
    if (!view) return;

    // Show skeleton while loading
    _showSkeleton();

    try {
        const [profile, stats, history] = await Promise.all([
            apiCall('/taste/profile').catch(() => null),
            apiCall('/listening/stats').catch(() => null),
            apiCall('/listening/history').catch(() => null),
        ]);

        _renderProfile(profile);
        _renderStats(stats);
        _renderHistory(history);
        _renderTasteNotes(profile);
    } catch (e) {
        const section = document.getElementById('taste-status');
        if (section) section.textContent = 'Could not load taste data: ' + e.message;
    }
}

// ── Skeleton ──────────────────────────────────────────────────────────────────
function _showSkeleton() {
    const status = document.getElementById('taste-status');
    if (status) { status.textContent = 'Loading…'; }
}

// ── Genre Radar ───────────────────────────────────────────────────────────────
function _renderProfile(profile) {
    const status = document.getElementById('taste-status');
    if (status) status.textContent = '';

    const radarSection = document.getElementById('taste-radar-section');
    if (!radarSection) return;

    if (!profile) {
        radarSection.innerHTML = '<p class="taste-empty">No taste profile yet. Generate some playlists first!</p>';
        return;
    }

    // Top genres from profile
    const genres = profile.top_genres || [];
    if (!genres.length) {
        radarSection.innerHTML = '<p class="taste-empty">Not enough listening data for a genre chart yet.</p>';
        return;
    }

    const labels = genres.slice(0, 8).map(g => g.name || g.genre || String(g));
    const values = genres.slice(0, 8).map(g => g.count || g.score || 1);
    const max = Math.max(...values, 1);
    const normalised = values.map(v => Math.round((v / max) * 100));

    radarSection.innerHTML = `<canvas id="genre-radar-chart" aria-label="Genre radar chart" role="img"></canvas>`;

    const ctx = document.getElementById('genre-radar-chart').getContext('2d');
    if (_chartInstances.radar) _chartInstances.radar.destroy();

    _chartInstances.radar = new Chart(ctx, {
        type: 'radar',
        data: {
            labels,
            datasets: [{
                label: 'Genres',
                data: normalised,
                backgroundColor: 'rgba(229, 160, 13, 0.15)',
                borderColor: '#e5a00d',
                pointBackgroundColor: '#e5a00d',
                pointBorderColor: '#1a1a1a',
                pointHoverBackgroundColor: '#fff',
                pointHoverBorderColor: '#e5a00d',
            }],
        },
        options: {
            responsive: true,
            plugins: {
                legend: { display: false },
            },
            scales: {
                r: {
                    angleLines: { color: '#333' },
                    grid: { color: '#333' },
                    pointLabels: { color: '#e0e0e0', font: { size: 12 } },
                    ticks: { display: false },
                    suggestedMin: 0,
                    suggestedMax: 100,
                },
            },
        },
    });
}

// ── Listening Stats ───────────────────────────────────────────────────────────
function _renderStats(stats) {
    const section = document.getElementById('taste-stats-section');
    if (!section) return;

    if (!stats) {
        section.innerHTML = '<p class="taste-empty">No listening statistics available yet.</p>';
        return;
    }

    // ── Top artists (horizontal bar) ──────────────────────────────────────────
    const topArtists = stats.top_artists || [];
    const artistsHtml = topArtists.length
        ? `<div class="taste-chart-block">
               <h3>Top Artiesten</h3>
               <canvas id="artists-bar-chart" aria-label="Top artists" role="img"></canvas>
           </div>`
        : '';

    // ── Day-of-week ───────────────────────────────────────────────────────────
    const byDay = stats.by_day_of_week || [];
    const byDayHtml = byDay.length
        ? `<div class="taste-chart-block">
               <h3>Luistertijd per dag</h3>
               <canvas id="day-bar-chart" aria-label="Listening by day" role="img"></canvas>
           </div>`
        : '';

    // ── Genre donut ───────────────────────────────────────────────────────────
    const genreBreak = stats.genre_breakdown || [];
    const genreDonutHtml = genreBreak.length
        ? `<div class="taste-chart-block">
               <h3>Genre verdeling (deze maand)</h3>
               <canvas id="genre-donut-chart" aria-label="Genre donut chart" role="img"></canvas>
           </div>`
        : '';

    // ── Metric pills ──────────────────────────────────────────────────────────
    const skipRate = stats.skip_rate != null ? `${Math.round(stats.skip_rate * 100)}%` : '—';
    const discRatio = stats.discovery_ratio != null ? `${Math.round(stats.discovery_ratio * 100)}%` : '—';

    section.innerHTML = `
        <div class="taste-metrics-grid">
            <div class="taste-metric">
                <div class="taste-metric-value">${skipRate}</div>
                <div class="taste-metric-label">Skip rate</div>
            </div>
            <div class="taste-metric">
                <div class="taste-metric-value">${discRatio}</div>
                <div class="taste-metric-label">Discovery ratio</div>
            </div>
            <div class="taste-metric">
                <div class="taste-metric-value">${stats.total_plays ?? '—'}</div>
                <div class="taste-metric-label">Totaal plays</div>
            </div>
            <div class="taste-metric">
                <div class="taste-metric-value">${stats.unique_artists ?? '—'}</div>
                <div class="taste-metric-label">Artiesten</div>
            </div>
        </div>
        <div class="taste-charts-grid">
            ${artistsHtml}
            ${byDayHtml}
            ${genreDonutHtml}
        </div>
    `;

    // Draw charts after DOM insertion
    requestAnimationFrame(() => {
        if (topArtists.length) {
            const ctx = document.getElementById('artists-bar-chart')?.getContext('2d');
            if (ctx) {
                if (_chartInstances.artists) _chartInstances.artists.destroy();
                _chartInstances.artists = new Chart(ctx, {
                    type: 'bar',
                    data: {
                        labels: topArtists.slice(0, 10).map(a => a.name || a.artist || String(a)),
                        datasets: [{
                            data: topArtists.slice(0, 10).map(a => a.count || a.plays || 1),
                            backgroundColor: 'rgba(229, 160, 13, 0.7)',
                            borderColor: '#e5a00d',
                            borderWidth: 1,
                        }],
                    },
                    options: {
                        indexAxis: 'y',
                        responsive: true,
                        plugins: { legend: { display: false } },
                        scales: {
                            x: { ticks: { color: '#a0a0a0' }, grid: { color: '#333' } },
                            y: { ticks: { color: '#e0e0e0' }, grid: { color: '#333' } },
                        },
                    },
                });
            }
        }

        if (byDay.length) {
            const ctx = document.getElementById('day-bar-chart')?.getContext('2d');
            if (ctx) {
                const days = ['Ma', 'Di', 'Wo', 'Do', 'Vr', 'Za', 'Zo'];
                if (_chartInstances.day) _chartInstances.day.destroy();
                _chartInstances.day = new Chart(ctx, {
                    type: 'bar',
                    data: {
                        labels: byDay.map((_, i) => days[i] || i),
                        datasets: [{
                            data: byDay,
                            backgroundColor: 'rgba(229, 160, 13, 0.7)',
                            borderColor: '#e5a00d',
                            borderWidth: 1,
                        }],
                    },
                    options: {
                        responsive: true,
                        plugins: { legend: { display: false } },
                        scales: {
                            x: { ticks: { color: '#e0e0e0' }, grid: { color: '#333' } },
                            y: { ticks: { color: '#a0a0a0' }, grid: { color: '#333' } },
                        },
                    },
                });
            }
        }

        if (genreBreak.length) {
            const ctx = document.getElementById('genre-donut-chart')?.getContext('2d');
            if (ctx) {
                const palette = ['#e5a00d','#f0b020','#c87a00','#ffcb47','#a05c00','#d4941a','#ffdf80','#8b5000'];
                if (_chartInstances.donut) _chartInstances.donut.destroy();
                _chartInstances.donut = new Chart(ctx, {
                    type: 'doughnut',
                    data: {
                        labels: genreBreak.map(g => g.genre || String(g)),
                        datasets: [{
                            data: genreBreak.map(g => g.count || 1),
                            backgroundColor: genreBreak.map((_, i) => palette[i % palette.length]),
                            borderColor: '#1a1a1a',
                            borderWidth: 2,
                        }],
                    },
                    options: {
                        responsive: true,
                        plugins: {
                            legend: { labels: { color: '#e0e0e0', font: { size: 11 } } },
                        },
                    },
                });
            }
        }
    });
}

// ── Recent Activity ───────────────────────────────────────────────────────────
function _renderHistory(history) {
    const section = document.getElementById('taste-history-section');
    if (!section) return;

    const events = Array.isArray(history) ? history : (history?.events || []);
    if (!events.length) {
        section.innerHTML = '<p class="taste-empty">No recent listening history.</p>';
        return;
    }

    section.innerHTML = events.slice(0, 30).map(ev => {
        const artKey = ev.image_key || ev.art_key;
        const artHtml = artKey
            ? `<img src="/api/art/${artKey}?width=40&height=40" class="taste-hist-art" alt="" onerror="this.style.display='none'">`
            : `<div class="taste-hist-art taste-hist-art--placeholder">♪</div>`;
        const ts = ev.timestamp ? new Date(ev.timestamp).toLocaleString('nl-NL', { weekday: 'short', hour: '2-digit', minute: '2-digit' }) : '';
        const skippedClass = ev.skipped ? ' taste-hist-event--skipped' : '';
        return `
        <div class="taste-hist-event${skippedClass}">
            ${artHtml}
            <div class="taste-hist-info">
                <div class="taste-hist-title">${escapeHtml(ev.title || ev.track || '')}</div>
                <div class="taste-hist-artist">${escapeHtml(ev.artist || '')}</div>
            </div>
            <div class="taste-hist-meta">
                ${ts ? `<span class="taste-hist-time">${ts}</span>` : ''}
                ${ev.skipped ? '<span class="taste-hist-skip">skipped</span>' : ''}
            </div>
        </div>`;
    }).join('');
}

// ── Taste Notes ───────────────────────────────────────────────────────────────
function _renderTasteNotes(profile) {
    const section = document.getElementById('taste-notes-section');
    if (!section) return;

    const notes   = profile?.notes   || [];
    const dislikes = profile?.dislikes || [];

    section.innerHTML = `
        <div class="taste-notes-block">
            <h3>Likes</h3>
            <div id="taste-notes-list" class="taste-chips-list">
                ${notes.map(n => `<span class="taste-chip">${escapeHtml(n)}</span>`).join('')}
                ${!notes.length ? '<span class="taste-empty-inline">None yet</span>' : ''}
            </div>
        </div>
        <div class="taste-notes-block">
            <h3>Dislikes</h3>
            <div id="taste-dislikes-list" class="taste-chips-list">
                ${dislikes.map(d => `<span class="taste-chip taste-chip--dislike">${escapeHtml(d)}</span>`).join('')}
                ${!dislikes.length ? '<span class="taste-empty-inline">None yet</span>' : ''}
            </div>
        </div>
    `;
}
