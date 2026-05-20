// =============================================================================
// My Taste — Smaakprofiel visualisatie (Chart.js enhanced, v2)
// =============================================================================

import { apiCall } from './api.js';
import { escapeHtml } from './utils.js';

// ── Chart.js global defaults (dark theme) ────────────────────────────────────
if (typeof Chart !== 'undefined') {
    Chart.defaults.color = '#999';
    Chart.defaults.borderColor = 'rgba(255,255,255,0.1)';
    Chart.defaults.animation = false;
    Chart.defaults.responsive = true;
    Chart.defaults.maintainAspectRatio = false;
}

// Module-level chart instance registry — destroy before recreating
const _charts = {};

// Current time range in days (0 = all time)
let _timeRange = parseInt(localStorage.getItem('taste_time_range') || '30', 10);

// Amber palette helpers
const AMBER       = '#e5a00d';
const AMBER_70    = 'rgba(229,160,13,0.7)';
const AMBER_15    = 'rgba(229,160,13,0.15)';
const AMBER_SHADES = [
    '#e5a00d', '#c98b0b', '#ad7609', '#916108', '#754d06',
    '#593905', '#3d2503', '#f0b030', '#f5c55a', '#fad985',
];

function _destroyChart(key) {
    if (_charts[key]) {
        try { _charts[key].destroy(); } catch (_) { /* already gone */ }
        delete _charts[key];
    }
}

// ── Public init ──────────────────────────────────────────────────────────────
export async function initTasteView() {
    const view = document.getElementById('taste-view');
    if (!view) return;

    _showSkeleton();
    _setupFilterButtons();
    _setupLbButtons();

    try {
        const dayParam = _timeRange > 0 ? `?days=${_timeRange}` : '?days=3650';

        const [profile, stats, history, lbStatus] = await Promise.all([
            apiCall('/taste/profile').catch(() => null),
            apiCall(`/listening/stats${dayParam}`).catch(() => null),
            apiCall('/listening/history').catch(() => null),
            apiCall('/intelligence/listenbrainz/status').catch(() => null),
        ]);

        _renderIntelBanner(profile, stats, lbStatus);
        _renderTimelineChart(stats);
        _renderGenreDistChart(profile);
        _renderProfile(profile);         // radar chart
        _renderEraDoughnut(profile, null);
        _renderArtistChart(stats, null);  // will be overwritten by LB data if available
        _renderHistory(history);
        _renderTasteNotes(profile);

        if (lbStatus?.configured) {
            _renderLbStatus(lbStatus);
            const detailedStats = await apiCall(`/intelligence/listening-stats${dayParam}`).catch(() => null);
            if (detailedStats?.listenbrainz) {
                const lb = detailedStats.listenbrainz;
                _renderEraDoughnut(profile, lb);
                _renderHeatmap(lb.daily_activity);
                _renderArtistChart(stats, lb);
                _renderLbSections(lb, profile);
            }
        } else {
            _renderHeatmap(null);
        }
    } catch (e) {
        const section = document.getElementById('taste-status');
        if (section) section.textContent = 'Could not load taste data: ' + e.message;
    }
}

// ── Time Range Filter ─────────────────────────────────────────────────────────
function _setupFilterButtons() {
    const row = document.getElementById('taste-filter-row');
    if (!row) return;

    row.querySelectorAll('.taste-filter-btn').forEach(btn => {
        const range = parseInt(btn.dataset.range, 10);

        // Sync active state to stored preference
        btn.classList.toggle('taste-filter-btn--active', range === _timeRange);

        btn.addEventListener('click', () => {
            if (range === _timeRange) return;
            _timeRange = range;
            localStorage.setItem('taste_time_range', String(range));

            row.querySelectorAll('.taste-filter-btn').forEach(b =>
                b.classList.toggle('taste-filter-btn--active', parseInt(b.dataset.range, 10) === range)
            );

            // Destroy all charts before full re-render
            Object.keys(_charts).forEach(_destroyChart);
            initTasteView();
        });
    });
}

// ── Intelligence Banner ───────────────────────────────────────────────────────
function _renderIntelBanner(profile, stats, lbStatus) {
    const totalPlaylists = profile?.stats?.total_playlists ?? '—';
    const peakHour = profile?.listening_patterns?.peak_hour ?? profile?.peak_hour ?? null;
    const peakLabel = peakHour != null ? `Peak: ${String(peakHour).padStart(2, '0')}:00` : 'Peak: —';
    const skipRate  = stats?.skip_rate != null ? `${Math.round(stats.skip_rate * 100)}%` : '—';
    const totalPlays = stats?.total_plays ?? '—';
    const scrobbles  = lbStatus?.scrobble_count ?? null;

    const subtitleEl = document.getElementById('taste-intel-subtitle');
    if (subtitleEl) {
        if (totalPlays === '—' || totalPlays === 0) {
            subtitleEl.textContent = 'Listening monitor actief — data verschijnt na een paar nummers';
        } else {
            const parts = [`Based on ${totalPlays} listened tracks`];
            if (scrobbles != null) parts.push(`${scrobbles} scrobbles`);
            subtitleEl.textContent = parts.join(' and ');
        }
    }

    const playlistsEl = document.getElementById('intel-chip-playlists');
    if (playlistsEl) playlistsEl.textContent = `${totalPlaylists} playlists`;
    const peakEl = document.getElementById('intel-chip-peak');
    if (peakEl) peakEl.textContent = peakLabel;
    const skipEl = document.getElementById('intel-chip-skip');
    if (skipEl) skipEl.textContent = `Skip: ${skipRate}`;
}

// ── Chart 1: Listening Activity Timeline ─────────────────────────────────────
function _renderTimelineChart(stats) {
    const canvas = document.getElementById('taste-timeline-chart');
    if (!canvas) return;
    _destroyChart('timeline');

    // Build daily buckets from stats.daily_plays or stats.recent_days
    const dailyData = stats?.daily_plays || stats?.recent_days || [];

    if (!dailyData.length) {
        _showChartEmpty(canvas, 'No activity data yet. Start listening!');
        return;
    }

    // Normalise: each entry can be {date, count} or {day, plays}
    const days = _buildDailyBuckets(dailyData, _timeRange || 30);
    const labels = days.map(d => d.label);
    const values = days.map(d => d.count);

    const ctx = canvas.getContext('2d');
    _charts.timeline = new Chart(ctx, {
        type: 'bar',
        data: {
            labels,
            datasets: [{
                label: 'Tracks played',
                data: values,
                backgroundColor: AMBER_70,
                borderColor: AMBER,
                borderWidth: 1,
                borderRadius: 3,
            }],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            animation: false,
            plugins: {
                legend: { display: false },
                tooltip: {
                    backgroundColor: '#222',
                    titleColor: '#e0e0e0',
                    bodyColor: AMBER,
                    callbacks: {
                        label: ctx => ` ${ctx.parsed.y} tracks`,
                    },
                },
            },
            scales: {
                x: {
                    grid: { color: 'rgba(153,153,153,0.15)' },
                    ticks: {
                        color: '#999',
                        maxTicksLimit: 12,
                        maxRotation: 0,
                    },
                },
                y: {
                    beginAtZero: true,
                    grid: { color: 'rgba(153,153,153,0.15)' },
                    ticks: {
                        color: '#999',
                        precision: 0,
                    },
                },
            },
        },
    });
}

/** Build array of {label, count} covering the last N days (fills gaps with 0) */
function _buildDailyBuckets(rawData, days) {
    const buckets = {};

    // Populate from API data — support multiple shapes
    for (const item of rawData) {
        const key = item.date || item.day || null;
        const val = item.count ?? item.plays ?? item.listen_count ?? 0;
        if (key) buckets[key] = (buckets[key] || 0) + val;
    }

    const result = [];
    const now = new Date();
    const count = Math.min(days, 365);

    for (let i = count - 1; i >= 0; i--) {
        const d = new Date(now);
        d.setDate(now.getDate() - i);
        const key = d.toISOString().slice(0, 10);           // "YYYY-MM-DD"
        const shortLabel = `${d.getDate()}/${d.getMonth() + 1}`;
        result.push({ label: shortLabel, count: buckets[key] || 0 });
    }
    return result;
}

// ── Chart 2: Genre Distribution (horizontal bar, top 15) ─────────────────────
function _renderGenreDistChart(profile) {
    const canvas = document.getElementById('taste-genre-dist-chart');
    if (!canvas) return;
    _destroyChart('genreDist');

    const rawGenres = profile?.top_genres || profile?.genres || [];
    if (!rawGenres.length) {
        _showChartEmpty(canvas, 'No genre data yet.');
        return;
    }

    // Normalise genre objects
    const genres = rawGenres
        .map(g => ({
            name:  g.name || g.genre || String(g),
            score: g.count || g.score || g.weight || 1,
        }))
        .sort((a, b) => b.score - a.score)
        .slice(0, 15);

    const max = Math.max(...genres.map(g => g.score), 1);
    const labels = genres.map(g => g.name);
    const values = genres.map(g => Math.round((g.score / max) * 100));

    // Amber gradient: darker for higher weight
    const colors = genres.map((_, i) => {
        const ratio = 1 - (i / (genres.length - 1 || 1)) * 0.65;
        const r = Math.round(229 * ratio + 50 * (1 - ratio));
        const g2 = Math.round(160 * ratio + 30 * (1 - ratio));
        const b  = Math.round(13  * ratio + 5  * (1 - ratio));
        return `rgba(${r},${g2},${b},0.85)`;
    });

    const ctx = canvas.getContext('2d');
    _charts.genreDist = new Chart(ctx, {
        type: 'bar',
        data: {
            labels,
            datasets: [{
                label: 'Genre weight',
                data: values,
                backgroundColor: colors,
                borderColor: colors.map(c => c.replace('0.85', '1')),
                borderWidth: 1,
                borderRadius: 3,
            }],
        },
        options: {
            indexAxis: 'y',
            responsive: true,
            maintainAspectRatio: false,
            animation: false,
            plugins: {
                legend: { display: false },
                tooltip: {
                    backgroundColor: '#222',
                    titleColor: '#e0e0e0',
                    bodyColor: AMBER,
                    callbacks: {
                        label: ctx => ` ${ctx.parsed.x}%`,
                    },
                },
            },
            scales: {
                x: {
                    beginAtZero: true,
                    max: 100,
                    grid: { color: 'rgba(153,153,153,0.15)' },
                    ticks: {
                        color: '#999',
                        callback: v => `${v}%`,
                    },
                },
                y: {
                    grid: { display: false },
                    ticks: { color: '#e0e0e0', font: { size: 11 } },
                },
            },
        },
    });
}

// ── Chart 3: Era Distribution (doughnut) ─────────────────────────────────────
function _renderEraDoughnut(profile, lbData) {
    const canvas = document.getElementById('taste-era-chart');
    if (!canvas) return;
    _destroyChart('era');

    const decadeBuckets = {};

    // Prefer LB era_activity; fall back to profile.decades
    if (lbData?.era_activity?.length) {
        for (const item of lbData.era_activity) {
            const decade = `${Math.floor(item.year / 10) * 10}s`;
            decadeBuckets[decade] = (decadeBuckets[decade] || 0) + item.listen_count;
        }
    } else if (profile?.decades) {
        for (const [decade, score] of Object.entries(profile.decades)) {
            const label = decade.endsWith('s') ? decade : `${decade}s`;
            decadeBuckets[label] = (decadeBuckets[label] || 0) + score;
        }
    }

    const eraEntries = Object.entries(decadeBuckets)
        .sort((a, b) => a[0].localeCompare(b[0]));

    if (!eraEntries.length) {
        _showChartEmpty(canvas, 'No era data yet.');
        return;
    }

    const labels = eraEntries.map(([d]) => d);
    const values = eraEntries.map(([, v]) => v);
    const total  = values.reduce((s, v) => s + v, 0);

    // Generate amber→warm-brown palette
    const colors = labels.map((_, i) => AMBER_SHADES[i % AMBER_SHADES.length]);

    const ctx = canvas.getContext('2d');
    _charts.era = new Chart(ctx, {
        type: 'doughnut',
        data: {
            labels,
            datasets: [{
                data: values,
                backgroundColor: colors,
                borderColor: '#1a1a1a',
                borderWidth: 2,
                hoverOffset: 6,
            }],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            animation: false,
            cutout: '62%',
            plugins: {
                legend: {
                    display: true,
                    position: 'bottom',
                    labels: {
                        color: '#e0e0e0',
                        padding: 14,
                        font: { size: 11 },
                        boxWidth: 12,
                    },
                },
                tooltip: {
                    backgroundColor: '#222',
                    titleColor: '#e0e0e0',
                    bodyColor: AMBER,
                    callbacks: {
                        label: ctx => {
                            const pct = total > 0 ? Math.round((ctx.parsed / total) * 100) : 0;
                            return ` ${ctx.label}: ${ctx.parsed} (${pct}%)`;
                        },
                    },
                },
            },
        },
        plugins: [{
            // Centre text showing total tracks
            id: 'centreText',
            afterDraw(chart) {
                const { ctx: c, chartArea: { top, left, width, height } } = chart;
                c.save();
                const cx = left + width / 2;
                const cy = top + height / 2 - 10;
                c.font = 'bold 22px DM Sans, sans-serif';
                c.fillStyle = '#e0e0e0';
                c.textAlign = 'center';
                c.textBaseline = 'middle';
                c.fillText(total.toLocaleString(), cx, cy);
                c.font = '11px DM Sans, sans-serif';
                c.fillStyle = '#999';
                c.fillText('tracks', cx, cy + 20);
                c.restore();
            },
        }],
    });
}

// ── Chart 4: Listening Heatmap (7×24 custom canvas) ──────────────────────────
function _renderHeatmap(dailyActivity) {
    const canvas = document.getElementById('taste-heatmap-canvas');
    const noDataEl = document.getElementById('heatmap-no-data');

    if (!canvas) return;

    const DAY_NAMES = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const DAY_SHORT  = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const grid = Array(7).fill(null).map(() => Array(24).fill(0));
    let maxVal = 0;
    let hasData = false;

    if (dailyActivity && typeof dailyActivity === 'object' && !Array.isArray(dailyActivity)) {
        // Dict format: {Monday: [{hour, listen_count}]}
        DAY_NAMES.forEach((dayName, di) => {
            for (const entry of (dailyActivity[dayName] || [])) {
                const h = entry.hour;
                const c = entry.listen_count || 0;
                if (h >= 0 && h < 24 && c > 0) {
                    grid[di][h] = c;
                    if (c > maxVal) maxVal = c;
                    hasData = true;
                }
            }
        });
    } else if (Array.isArray(dailyActivity) && dailyActivity.length) {
        // Legacy array: [{day_of_week, hour, listen_count}]
        for (const item of dailyActivity) {
            const d = item.day_of_week;
            const h = item.hour;
            const c = item.listen_count || 0;
            if (d >= 0 && d < 7 && h >= 0 && h < 24) {
                grid[d][h] = c;
                if (c > maxVal) maxVal = c;
                hasData = true;
            }
        }
    }

    if (!hasData) {
        canvas.style.display = 'none';
        if (noDataEl) noDataEl.style.display = '';
        return;
    }

    canvas.style.display = '';
    if (noDataEl) noDataEl.style.display = 'none';

    // ── Draw on canvas ──────────────────────────────────────────────────────
    const CELL  = 22;    // px per cell
    const GAP   = 3;
    const LEFT  = 44;    // left margin for day labels
    const TOP   = 24;    // top margin for hour labels
    const RIGHT = 16;

    const W = LEFT + 24 * (CELL + GAP) - GAP + RIGHT;
    const H = TOP  +  7 * (CELL + GAP) - GAP + 12;

    canvas.width  = W;
    canvas.height = H;

    // Adapt to container width (CSS handles max-width; we scale via CSS)
    canvas.style.width  = '100%';
    canvas.style.height = 'auto';

    const c = canvas.getContext('2d');
    c.clearRect(0, 0, W, H);

    // Hour labels (0, 6, 12, 18, 23)
    c.font = '10px DM Sans, sans-serif';
    c.fillStyle = '#666';
    c.textAlign = 'center';
    for (let h = 0; h < 24; h++) {
        if (h % 6 === 0 || h === 23) {
            const x = LEFT + h * (CELL + GAP) + CELL / 2;
            c.fillText(String(h), x, TOP - 6);
        }
    }

    // Day labels + cells
    c.textAlign = 'right';
    for (let d = 0; d < 7; d++) {
        const y = TOP + d * (CELL + GAP);
        c.fillStyle = '#666';
        c.font = '10px DM Sans, sans-serif';
        c.fillText(DAY_SHORT[d], LEFT - 6, y + CELL * 0.65);

        for (let h = 0; h < 24; h++) {
            const x = LEFT + h * (CELL + GAP);
            const val = grid[d][h];
            const intensity = maxVal > 0 ? val / maxVal : 0;
            const alpha = intensity < 0.01 ? 0 : 0.12 + intensity * 0.73;

            // Cell background
            c.fillStyle = `rgba(229,160,13,${alpha.toFixed(3)})`;
            _roundRect(c, x, y, CELL, CELL, 3);
            c.fill();

            // Subtle border on non-zero cells
            if (val > 0) {
                c.strokeStyle = `rgba(229,160,13,${Math.min(alpha + 0.15, 1).toFixed(3)})`;
                c.lineWidth = 0.5;
                _roundRect(c, x, y, CELL, CELL, 3);
                c.stroke();
            } else {
                // Empty cell outline
                c.strokeStyle = 'rgba(255,255,255,0.05)';
                c.lineWidth = 0.5;
                _roundRect(c, x, y, CELL, CELL, 3);
                c.stroke();
            }
        }
    }
}

/** Draw a rounded rectangle path */
function _roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.lineTo(x + w - r, y);
    ctx.quadraticCurveTo(x + w, y, x + w, y + r);
    ctx.lineTo(x + w, y + h - r);
    ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
    ctx.lineTo(x + r, y + h);
    ctx.quadraticCurveTo(x, y + h, x, y + h - r);
    ctx.lineTo(x, y + r);
    ctx.quadraticCurveTo(x, y, x + r, y);
    ctx.closePath();
}

// ── Chart 5: Top Artists (horizontal bar) ────────────────────────────────────
function _renderArtistChart(stats, lbData) {
    const canvas = document.getElementById('taste-artists-chart');
    if (!canvas) return;
    _destroyChart('artists');

    let artists = [];

    if (lbData?.top_artists?.length) {
        artists = lbData.top_artists.slice(0, 10).map(a => ({
            name:  a.artist_name || a.artist || a.name || '?',
            count: a.listen_count || a.plays || 0,
        }));
    } else if (stats?.top_artists?.length) {
        artists = stats.top_artists.slice(0, 10).map(a => ({
            name:  a.name || a.artist || String(a),
            count: a.count || a.plays || 0,
        }));
    }

    if (!artists.length) {
        _showChartEmpty(canvas, 'No artist data yet.');
        return;
    }

    artists.sort((a, b) => b.count - a.count);
    const labels = artists.map(a => a.name);
    const values = artists.map(a => a.count);

    const ctx = canvas.getContext('2d');
    _charts.artists = new Chart(ctx, {
        type: 'bar',
        data: {
            labels,
            datasets: [{
                label: 'Plays',
                data: values,
                backgroundColor: AMBER_70,
                borderColor: AMBER,
                borderWidth: 1,
                borderRadius: 3,
            }],
        },
        options: {
            indexAxis: 'y',
            responsive: true,
            maintainAspectRatio: false,
            animation: false,
            plugins: {
                legend: { display: false },
                tooltip: {
                    backgroundColor: '#222',
                    titleColor: '#e0e0e0',
                    bodyColor: AMBER,
                    callbacks: {
                        label: ctx => ` ${ctx.parsed.x} plays`,
                    },
                },
            },
            scales: {
                x: {
                    beginAtZero: true,
                    grid: { color: 'rgba(153,153,153,0.15)' },
                    ticks: { color: '#999', precision: 0 },
                },
                y: {
                    grid: { display: false },
                    ticks: { color: '#e0e0e0', font: { size: 11 } },
                },
            },
        },
    });
}

// ── Utility: empty-state overlay on canvas ────────────────────────────────────
function _showChartEmpty(canvas, msg) {
    const wrap = canvas.parentElement;
    if (wrap) {
        wrap.style.display = 'flex';
        wrap.style.alignItems = 'center';
        wrap.style.justifyContent = 'center';
        const el = wrap.querySelector('.chart-empty-msg') || document.createElement('p');
        el.className = 'chart-empty-msg lb-no-data';
        el.textContent = msg;
        canvas.style.display = 'none';
        if (!wrap.contains(el)) wrap.appendChild(el);
    }
}

// ── ListenBrainz buttons ──────────────────────────────────────────────────────
function _setupLbButtons() {
    const syncBtn = document.getElementById('lb-sync-btn');
    if (syncBtn) {
        syncBtn.addEventListener('click', async () => {
            syncBtn.disabled = true;
            syncBtn.textContent = 'Syncing…';
            try {
                const res = await apiCall('/intelligence/listenbrainz/sync', { method: 'POST' });
                if (res?.status === 'ok') {
                    syncBtn.textContent = '✓ Gesynchroniseerd';
                    setTimeout(() => initTasteView(), 500);
                } else {
                    syncBtn.textContent = '✗ Fout bij sync';
                }
            } catch {
                syncBtn.textContent = '✗ Fout bij sync';
            }
            setTimeout(() => { syncBtn.textContent = 'Sync nu'; syncBtn.disabled = false; }, 3000);
        });
    }

    const enrichBtn = document.getElementById('lb-enrich-btn');
    if (enrichBtn) {
        enrichBtn.addEventListener('click', async () => {
            enrichBtn.disabled = true;
            enrichBtn.textContent = 'Verrijken…';
            try {
                const res = await apiCall('/intelligence/listening-history/enrich', { method: 'POST' });
                enrichBtn.textContent = `✓ ${res?.rows_updated || 0} rijen bijgewerkt`;
            } catch {
                enrichBtn.textContent = '✗ Fout';
            }
            setTimeout(() => { enrichBtn.textContent = 'Verrijk history'; enrichBtn.disabled = false; }, 3000);
        });
    }

    const recomputeBtn = document.getElementById('lb-recompute-btn');
    if (recomputeBtn) {
        recomputeBtn.addEventListener('click', async () => {
            recomputeBtn.disabled = true;
            recomputeBtn.textContent = 'Herberekenen…';
            try {
                await apiCall('/intelligence/taste-profile/detailed');
                recomputeBtn.textContent = '✓ Profiel bijgewerkt';
                setTimeout(() => initTasteView(), 500);
            } catch {
                recomputeBtn.textContent = '✗ Fout';
            }
            setTimeout(() => { recomputeBtn.textContent = 'Herbereken profiel'; recomputeBtn.disabled = false; }, 3000);
        });
    }
}

// ── ListenBrainz status card ──────────────────────────────────────────────────
function _renderLbStatus(status) {
    const sections = document.getElementById('lb-taste-sections');
    if (sections) sections.classList.remove('hidden');

    const dot        = document.getElementById('lb-status-dot');
    const text       = document.getElementById('lb-status-text');
    const details    = document.getElementById('lb-status-details');
    const countChip  = document.getElementById('lb-scrobble-count');
    const syncChip   = document.getElementById('lb-last-sync');
    const profileLink = document.getElementById('lb-profile-link');

    if (dot) dot.classList.add('status-dot--ok');
    if (text) text.textContent = `Verbonden als ${status.username || 'onbekend'}`;
    if (details) details.classList.remove('hidden');
    if (countChip) countChip.textContent = `${status.scrobble_count || 0} scrobbles`;
    if (syncChip && status.last_synced) {
        syncChip.textContent = `Sync: ${new Date(status.last_synced).toLocaleString('nl-NL', { dateStyle: 'short', timeStyle: 'short' })}`;
    }
    if (profileLink && status.profile_url) {
        profileLink.href = status.profile_url;
        profileLink.classList.remove('hidden');
    }
}

// ── ListenBrainz extra data sections ─────────────────────────────────────────
function _renderLbSections(lbData, profile) {
    // Countries bar chart (HTML bars, kept simple)
    if (lbData?.artist_map?.length) {
        const countryData = lbData.artist_map
            .sort((a, b) => (b.artist_count || 0) - (a.artist_count || 0))
            .slice(0, 10)
            .map(c => ({ label: c.country, value: c.artist_count || 0 }));
        _renderBarChart('lb-countries-section', countryData);
    }

    // Loved tracks list
    if (lbData?.feedback_loved?.length) {
        _renderLbList('lb-loved-section', lbData.feedback_loved.slice(0, 15).map(r => {
            const meta = r.track_metadata || {};
            return {
                name: `${meta.artist_name || '?'} — ${meta.track_name || '?'}`,
                meta: '❤️',
            };
        }));
    }
}

// ── HTML bar chart (countries etc.) ──────────────────────────────────────────
function _renderBarChart(containerId, items) {
    const container = document.getElementById(containerId);
    if (!container) return;
    if (!items?.length) {
        container.innerHTML = '<p class="lb-no-data">Geen data beschikbaar.</p>';
        return;
    }
    const max = Math.max(...items.map(i => i.value), 1);
    container.innerHTML = items.map(item => `
        <div class="lb-bar-row">
            <div class="lb-bar-label" title="${escapeHtml(String(item.label))}">${escapeHtml(String(item.label))}</div>
            <div class="lb-bar-track">
                <div class="lb-bar-fill" style="width:${Math.round((item.value / max) * 100)}%"></div>
            </div>
            <div class="lb-bar-value">${item.value}</div>
        </div>
    `).join('');
}

// ── HTML list (loved tracks etc.) ────────────────────────────────────────────
function _renderLbList(containerId, items) {
    const container = document.getElementById(containerId);
    if (!container) return;
    if (!items?.length) {
        container.innerHTML = '<p class="lb-no-data">Geen data beschikbaar.</p>';
        return;
    }
    container.innerHTML = items.map((item, i) => `
        <div class="lb-list-item">
            <span class="lb-list-item-name">${i + 1}. ${escapeHtml(item.name || '')}</span>
            <span class="lb-list-item-meta">${escapeHtml(item.meta || '')}</span>
        </div>
    `).join('');
}

// ── Skeleton ──────────────────────────────────────────────────────────────────
function _showSkeleton() {
    const status = document.getElementById('taste-status');
    if (status) { status.textContent = 'Loading…'; }
}

// ── Genre Radar (Chart.js radar) ──────────────────────────────────────────────
function _renderProfile(profile) {
    const status = document.getElementById('taste-status');
    if (status) status.textContent = '';

    const radarSection = document.getElementById('taste-radar-section');
    if (!radarSection) return;
    _destroyChart('radar');

    if (!profile) {
        radarSection.innerHTML = '<p class="taste-empty">No taste profile yet. Generate some playlists first!</p>';
        return;
    }

    const genres = profile.top_genres || [];
    if (!genres.length) {
        radarSection.innerHTML = '<p class="taste-empty">Not enough listening data for a genre chart yet.</p>';
        return;
    }

    const labels    = genres.slice(0, 8).map(g => g.name || g.genre || String(g));
    const values    = genres.slice(0, 8).map(g => g.count || g.score || 1);
    const max       = Math.max(...values, 1);
    const normalised = values.map(v => Math.round((v / max) * 100));

    radarSection.innerHTML = `<canvas id="genre-radar-chart" aria-label="Genre radar chart" role="img" style="height:260px"></canvas>`;

    const ctx = document.getElementById('genre-radar-chart').getContext('2d');
    _charts.radar = new Chart(ctx, {
        type: 'radar',
        data: {
            labels,
            datasets: [{
                label: 'Genres',
                data: normalised,
                backgroundColor: AMBER_15,
                borderColor: AMBER,
                pointBackgroundColor: AMBER,
                pointBorderColor: '#1a1a1a',
                pointHoverBackgroundColor: '#fff',
                pointHoverBorderColor: AMBER,
            }],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            animation: false,
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

// ── Listening History (grouped by day, max 20 items) ─────────────────────────
function _renderHistory(history) {
    const section = document.getElementById('taste-history-section');
    if (!section) return;

    const events = Array.isArray(history) ? history : (history?.events || []);
    if (!events.length) {
        section.innerHTML = '<p class="taste-empty">No recent listening history.</p>';
        return;
    }

    const limited = events.slice(0, 20);
    const groups  = new Map();

    for (const ev of limited) {
        const dateKey = ev.timestamp
            ? new Date(ev.timestamp).toLocaleDateString('nl-NL', {
                weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
            })
            : 'Onbekende datum';
        if (!groups.has(dateKey)) groups.set(dateKey, []);
        groups.get(dateKey).push(ev);
    }

    let html = '';
    let firstGroup = true;
    for (const [date, evs] of groups) {
        html += `<div class="date-group-header${firstGroup ? ' date-group-header--first' : ''}">${escapeHtml(date)}</div>`;
        firstGroup = false;
        for (const ev of evs) {
            const artKey = ev.image_key || ev.art_key;
            const artHtml = artKey
                ? `<img src="/api/art/${artKey}?width=40&height=40" class="taste-hist-art" alt="" onerror="this.style.display='none'">`
                : `<div class="taste-hist-art taste-hist-art--placeholder">♪</div>`;
            const ts = ev.timestamp
                ? new Date(ev.timestamp).toLocaleTimeString('nl-NL', { hour: '2-digit', minute: '2-digit' })
                : '';
            const skippedClass = ev.skipped ? ' taste-hist-event--skipped' : '';
            html += `
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
        }
    }
    section.innerHTML = html;
}

// ── Taste Notes (Voorkeuren) ───────────────────────────────────────────────────
function _renderTasteNotes(profile) {
    const section = document.getElementById('taste-notes-section');
    if (!section) return;

    const notes    = profile?.notes    || [];
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
