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

// Current zone filter (null = all zones)
let _zoneFilter = null;

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

// ── Stat card population ─────────────────────────────────────────────────────
function _populateStatCards(profile, stats) {
    const set = (id, val) => {
        const el = document.getElementById(id);
        if (el) el.textContent = val;
    };

    const totalHours = profile?.total_hours ?? stats?.total_hours ?? null;
    if (totalHours != null) set('ts-hours', Math.round(totalHours).toLocaleString());

    const uniqueTracks = profile?.unique_tracks ?? stats?.unique_tracks ?? null;
    if (uniqueTracks != null) set('ts-tracks', uniqueTracks.toLocaleString());

    const artistCount = profile?.unique_artists ?? stats?.unique_artists ?? null;
    if (artistCount != null) set('ts-artists', artistCount.toLocaleString());

    const peakHour = profile?.peak_hour ?? profile?.listening_patterns?.peak_hour ?? null;
    if (peakHour != null) {
        const h = peakHour;
        const ampm = h >= 12 ? `${h > 12 ? h - 12 : h}:00` : `${h}:00`;
        set('ts-peak', ampm);
    }

    const streak = profile?.day_streak ?? profile?.listening_patterns?.day_streak ?? null;
    if (streak != null) set('ts-streak', streak);
}

// ── Public init ──────────────────────────────────────────────────────────────
export async function initTasteView() {
    const view = document.getElementById('taste-view');
    if (!view) return;

    _showSkeleton();
    _setupFilterButtons();
    await _setupZoneFilter();
    _setupLbButtons();

    try {
        const days = _timeRange > 0 ? _timeRange : 3650;
        const dayParam = `?days=${days}`;
        const zoneParam = _zoneFilter ? `&zone=${encodeURIComponent(_zoneFilter)}` : '';

        let [profile, stats, history, lbStatus] = await Promise.all([
            apiCall('/taste/profile').catch(() => null),
            apiCall(`/listening/stats${dayParam}${zoneParam}`).catch(() => null),
            apiCall(`/listening/history${dayParam}${zoneParam}&limit=100`).catch(() => null),
            apiCall('/intelligence/listenbrainz/status').catch(() => null),
        ]);

        // Fallback: if profile has no top_genres, populate from cached library stats
        if (!profile?.top_genres?.length) {
            try {
                const libStats = await apiCall('/library/stats/cached');
                if (libStats?.genres?.length) {
                    const maxCount = Math.max(...libStats.genres.map(g => g.count));
                    if (!profile) profile = {};
                    profile.top_genres = libStats.genres.map(g => ({
                        name: g.name,
                        count: g.count,
                        score: g.count / maxCount,
                    }));
                }
            } catch (e) {
                console.warn('Library stats genre fallback failed:', e);
            }
        }

        // Fallback: if profile has no decades, populate from cached library stats
        if (!profile?.decades || !Object.keys(profile.decades || {}).length) {
            try {
                const libStats = await apiCall('/library/stats/cached');
                if (libStats?.decades?.length) {
                    const maxCount = Math.max(...libStats.decades.map(d => d.count));
                    const decadeScores = {};
                    libStats.decades.forEach(d => {
                        decadeScores[d.name] = d.count / maxCount;
                    });
                    if (!profile) profile = {};
                    profile.decades = decadeScores;
                }
            } catch (e) {
                console.warn('Library stats decade fallback failed:', e);
            }
        }

        _populateStatCards(profile, stats);
        _renderIntelBanner(profile, stats, lbStatus);
        _renderTasteStats(profile, stats);
        _renderHourlyBars(stats);
        _renderTimelineChart(stats);
        _renderGenreDistChart(profile);
        _renderProfile(profile);         // radar chart
        _renderEraDoughnut(profile, null);
        _renderArtistChart(stats, null);  // will be overwritten by LB data if available
        _renderHistory(history);
        _renderTasteNotes(profile);
        _renderMoodTags(profile);

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

// ── Zone Filter ───────────────────────────────────────────────────────────────
async function _setupZoneFilter() {
    const row = document.getElementById('taste-zone-row');
    if (!row) return;

    let zones = [];
    try {
        const data = await apiCall('/listening/stats/zones?days=3650');
        zones = (data || []).map(z => z.zone_name).filter(Boolean);
    } catch (_) { /* no zone data yet */ }

    // Remove any previously added buttons (avoid duplicates on re-render)
    row.innerHTML = '';

    if (!zones.length) {
        row.style.display = 'none';
        return;
    }
    row.style.display = '';

    const allBtn = document.createElement('button');
    allBtn.className = 'taste-filter-btn' + (_zoneFilter === null ? ' taste-filter-btn--active' : '');
    allBtn.textContent = 'All zones';
    allBtn.addEventListener('click', () => {
        if (_zoneFilter === null) return;
        _zoneFilter = null;
        Object.keys(_charts).forEach(_destroyChart);
        initTasteView();
    });
    row.appendChild(allBtn);

    zones.forEach(zone => {
        const btn = document.createElement('button');
        btn.className = 'taste-filter-btn' + (_zoneFilter === zone ? ' taste-filter-btn--active' : '');
        btn.textContent = zone;
        btn.addEventListener('click', () => {
            if (_zoneFilter === zone) return;
            _zoneFilter = zone;
            Object.keys(_charts).forEach(_destroyChart);
            initTasteView();
        });
        row.appendChild(btn);
    });
}

// ── Intelligence Banner ───────────────────────────────────────────────────────
function _renderIntelBanner(profile, stats, lbStatus) {
    const totalPlaylists = profile?.stats?.total_playlists ?? '—';
    const peakHour = profile?.listening_patterns?.peak_hour ?? profile?.peak_hour ?? null;
    const peakLabel = peakHour != null ? `Peak: ${String(peakHour).padStart(2, '0')}:00` : 'Peak: —';
    const skipRate  = stats?.skip_rate_pct != null ? `${stats.skip_rate_pct}%` : '—';
    const totalPlays = stats?.total_tracks ?? '—';
    const scrobbles  = lbStatus?.scrobble_count ?? null;

    const subtitleEl = document.getElementById('taste-intel-subtitle');
    if (subtitleEl) {
        if (totalPlays === '—' || totalPlays === 0) {
            subtitleEl.textContent = 'Listening monitor active — data will appear after a few tracks';
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

// ── Hourly activity bar chart (custom canvas, no Chart.js) ──────────────────
function _renderHourlyBars(stats) {
    const container = document.getElementById('taste-hourly-bars');
    if (!container) return;

    const hourly = Array(24).fill(0);
    const raw = stats?.hourly_breakdown || stats?.hour_distribution || [];
    if (Array.isArray(raw)) {
        raw.forEach(item => {
            const h = item.hour ?? item.h;
            const c = item.count ?? item.listen_count ?? item.plays ?? 0;
            if (h >= 0 && h < 24) hourly[h] += c;
        });
    }

    const max = Math.max(...hourly, 1);
    const accent = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#e5a00d';

    container.innerHTML = `
        <div style="display:flex;align-items:flex-end;gap:3px;height:64px;padding-bottom:18px">
            ${hourly.map((v, i) => {
                const h = Math.max(2, Math.round((v / max) * 50));
                const op = v === 0 ? 0.07 : 0.25 + 0.75 * (v / max);
                const label = i % 6 === 0 ? `${i}h` : '';
                return `<div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:3px">
                    <div title="${i}:00 — ${v} tracks" style="width:100%;height:${h}px;border-radius:3px 3px 0 0;background:${accent};opacity:${op.toFixed(2)}"></div>
                    <div style="font-size:0.55rem;color:var(--text-muted)">${label}</div>
                </div>`;
            }).join('')}
        </div>
    `;
}

// ── Taste Stats Grid ──────────────────────────────────────────────────────────
function _renderTasteStats(profile, listeningStats) {
    // Find or create the stats grid, inserted after the intel banner
    let statsGrid = document.querySelector('.rs-taste-stats');
    if (!statsGrid) {
        statsGrid = document.createElement('div');
        statsGrid.className = 'rs-taste-stats';
        const banner = document.querySelector('.taste-intel-banner');
        if (banner) {
            banner.after(statsGrid);
        } else {
            const view = document.getElementById('taste-view');
            if (view) view.prepend(statsGrid);
        }
    }

    const peakHour = profile?.listening_patterns?.peak_hour ?? profile?.peak_hour ?? null;
    const peakDay  = profile?.listening_patterns?.peak_day  ?? profile?.peak_day  ?? null;
    // Hours: prefer profile (all-time), fall back to listening stats total_minutes
    const totalHours = profile?.stats?.total_hours ?? profile?.total_hours
        ?? (listeningStats?.total_minutes != null ? listeningStats.total_minutes / 60 : null);
    // Artists: prefer profile, fall back to unique artists in stats
    const artistCount = (profile?.recently_active?.top_artists?.length)
        || Object.keys(profile?.artists || {}).length
        || listeningStats?.top_artists?.length
        || null;

    const stats = [
        {
            value: totalHours != null ? (totalHours < 1 ? '<1' : Math.round(totalHours)) : '—',
            label: 'Hours Listened',
            color: 'teal',
        },
        {
            value: Object.keys(profile?.genres || profile?.genre_scores || {}).length || (profile?.top_genres?.length ?? '—'),
            label: 'Genres',
            color: '',
        },
        {
            value: artistCount ?? '—',
            label: 'Artists Tracked',
            color: '',
        },
        {
            value: peakHour != null ? `${peakHour}:00` : '—',
            label: 'Peak Hour',
            color: 'amber',
        },
        {
            value: peakDay
                ? peakDay.charAt(0).toUpperCase() + peakDay.slice(1)
                : '—',
            label: 'Peak Day',
            color: 'amber',
        },
    ];

    statsGrid.innerHTML = stats.map(s => `
        <div class="rs-taste-stat">
            <div class="rs-taste-stat-value${s.color ? ' rs-taste-stat-value--' + s.color : ''}">${s.value}</div>
            <div class="rs-taste-stat-label">${s.label}</div>
        </div>
    `).join('');
}

// ── Mood Tags ─────────────────────────────────────────────────────────────────
function _renderMoodTags(profile) {
    // Only add mood/skip tags if the profile has them — don't overwrite the
    // existing Likes/Dislikes notes that _renderTasteNotes already renders.
    const rawMoods = profile?.moods || {};
    const moods = Array.isArray(rawMoods) ? rawMoods : Object.keys(rawMoods);
    const rawSkips = profile?.skip_signals || {};
    const skips = Array.isArray(rawSkips) ? rawSkips : [...(rawSkips.genres || []), ...(rawSkips.artists || [])];
    if (!moods.length && !skips.length) return;

    const notesSection = document.getElementById('taste-notes-section');
    if (!notesSection) return;

    let moodHtml = '';
    if (moods.length) {
        moodHtml += `
            <div class="taste-notes-block">
                <h3>Your Moods</h3>
                <div class="taste-mood-tags">${moods.map(m =>
                    `<span class="taste-mood-tag">${escapeHtml(m)}</span>`
                ).join('')}</div>
            </div>`;
    }
    if (skips.length) {
        moodHtml += `
            <div class="taste-notes-block">
                <h3>Usually Skip</h3>
                <div class="taste-mood-tags">${skips.map(s =>
                    `<span class="taste-mood-tag taste-mood-tag--skip">${escapeHtml(s)}</span>`
                ).join('')}</div>
            </div>`;
    }

    if (moodHtml) notesSection.insertAdjacentHTML('beforeend', moodHtml);
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

    let rawGenres = profile?.top_genres || [];
    if (!rawGenres.length && profile?.genres && typeof profile.genres === 'object' && !Array.isArray(profile.genres)) {
        rawGenres = Object.entries(profile.genres).map(([name, score]) => ({ name, score }));
    }
    if (!rawGenres.length && Array.isArray(profile?.genres)) {
        rawGenres = profile.genres;
    }
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
                    syncBtn.textContent = '✓ Synced';
                    setTimeout(() => initTasteView(), 500);
                } else {
                    syncBtn.textContent = '✗ Sync failed';
                }
            } catch {
                syncBtn.textContent = '✗ Sync failed';
            }
            setTimeout(() => { syncBtn.textContent = 'Sync Now'; syncBtn.disabled = false; }, 3000);
        });
    }

    const enrichBtn = document.getElementById('lb-enrich-btn');
    if (enrichBtn) {
        enrichBtn.addEventListener('click', async () => {
            enrichBtn.disabled = true;
            enrichBtn.textContent = 'Enriching…';
            try {
                const res = await apiCall('/intelligence/listening-history/enrich', { method: 'POST' });
                enrichBtn.textContent = `✓ ${res?.rows_updated || 0} rows updated`;
            } catch {
                enrichBtn.textContent = '✗ Error';
            }
            setTimeout(() => { enrichBtn.textContent = 'Enrich History'; enrichBtn.disabled = false; }, 3000);
        });
    }

    const recomputeBtn = document.getElementById('lb-recompute-btn');
    if (recomputeBtn) {
        recomputeBtn.addEventListener('click', async () => {
            recomputeBtn.disabled = true;
            recomputeBtn.textContent = 'Recomputing…';
            try {
                await apiCall('/intelligence/taste-profile/detailed');
                recomputeBtn.textContent = '✓ Profile updated';
                setTimeout(() => initTasteView(), 500);
            } catch {
                recomputeBtn.textContent = '✗ Error';
            }
            setTimeout(() => { recomputeBtn.textContent = 'Recompute Profile'; recomputeBtn.disabled = false; }, 3000);
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
    if (text) text.textContent = `Connected as ${status.username || 'unknown'}`;
    if (details) details.classList.remove('hidden');
    if (countChip) countChip.textContent = `${status.scrobble_count || 0} scrobbles`;
    if (syncChip && status.last_synced) {
        syncChip.textContent = `Sync: ${new Date(status.last_synced).toLocaleString('en-GB', { dateStyle: 'short', timeStyle: 'short' })}`;
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
        container.innerHTML = '<p class="lb-no-data">No data available.</p>';
        return;
    }
    const max = Math.max(...items.map(i => i.value), 1);
    container.innerHTML = items.map(item => `
        <div class="rs-genre-bar">
            <div class="rs-genre-name" title="${escapeHtml(String(item.label))}">${escapeHtml(String(item.label))}</div>
            <div class="rs-genre-track">
                <div class="rs-genre-fill" style="width:${Math.round((item.value / max) * 100)}%"></div>
            </div>
            <div class="rs-genre-pct">${item.value}</div>
        </div>
    `).join('');
}

// ── HTML list (loved tracks etc.) ────────────────────────────────────────────
function _renderLbList(containerId, items) {
    const container = document.getElementById(containerId);
    if (!container) return;
    if (!items?.length) {
        container.innerHTML = '<p class="lb-no-data">No data available.</p>';
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
            ? new Date(ev.timestamp).toLocaleDateString('en-GB', {
                weekday: 'long', day: 'numeric', month: 'long', year: 'numeric',
            })
            : 'Unknown date';
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
                ? `<img src="/api/art/${artKey}?width=40&height=40" alt="" onerror="this.style.display='none'">`
                : `<span class="taste-hist-art--placeholder">♪</span>`;
            const ts = ev.timestamp
                ? new Date(ev.timestamp).toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' })
                : '';
            const skippedClass = ev.skipped ? ' rs-track-row--skipped' : '';
            html += `
            <div class="rs-track-row${skippedClass}">
                <div class="rs-track-art">${artHtml}</div>
                <div class="rs-track-info">
                    <div class="rs-track-title">${escapeHtml(ev.title || ev.track || '')}</div>
                    <div class="rs-track-artist">${escapeHtml(ev.artist || '')}</div>
                </div>
                <div class="rs-track-dur">
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
