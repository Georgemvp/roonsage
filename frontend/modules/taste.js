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

    // Wire up LB action buttons
    _setupLbButtons();

    try {
        const [profile, stats, history, lbStatus] = await Promise.all([
            apiCall('/taste/profile').catch(() => null),
            apiCall('/listening/stats').catch(() => null),
            apiCall('/listening/history').catch(() => null),
            apiCall('/intelligence/listenbrainz/status').catch(() => null),
        ]);

        _renderProfile(profile);
        _renderStats(stats);
        _renderHistory(history);
        _renderTasteNotes(profile);

        // ListenBrainz sections (only when configured)
        if (lbStatus?.configured) {
            _renderLbStatus(lbStatus);
            // Load detailed stats
            const detailedStats = await apiCall('/intelligence/listening-stats?days=90').catch(() => null);
            if (detailedStats?.listenbrainz) {
                _renderLbSections(detailedStats.listenbrainz, profile);
            }
        }
    } catch (e) {
        const section = document.getElementById('taste-status');
        if (section) section.textContent = 'Could not load taste data: ' + e.message;
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

    const dot = document.getElementById('lb-status-dot');
    const text = document.getElementById('lb-status-text');
    const details = document.getElementById('lb-status-details');
    const countChip = document.getElementById('lb-scrobble-count');
    const syncChip = document.getElementById('lb-last-sync');
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

// ── ListenBrainz data sections ────────────────────────────────────────────────
function _renderLbSections(lbData, profile) {
    // Top genres (from local history merged with LB)
    _renderBarChart('lb-genres-section', _extractTopGenres(lbData, profile));

    // Era distribution
    if (profile?.lb_era_distribution && Object.keys(profile.lb_era_distribution).length) {
        const eraData = Object.entries(profile.lb_era_distribution)
            .sort((a, b) => a[0].localeCompare(b[0]))
            .map(([decade, count]) => ({ label: decade, value: count }));
        _renderBarChart('lb-era-section', eraData);
    }

    // Artist countries
    if (profile?.lb_artist_countries && Object.keys(profile.lb_artist_countries).length) {
        const countryData = Object.entries(profile.lb_artist_countries)
            .sort((a, b) => b[1] - a[1])
            .slice(0, 10)
            .map(([country, count]) => ({ label: country, value: count }));
        _renderBarChart('lb-countries-section', countryData);
    }

    // Top LB artists
    if (profile?.lb_top_artists?.length) {
        _renderLbList('lb-artists-section', profile.lb_top_artists.slice(0, 15).map(a => ({
            name: a.artist_name || a.artist,
            meta: `${a.listen_count || 0} plays`,
        })));
    }

    // Loved tracks
    if (profile?.lb_loved_recordings?.length) {
        _renderLbList('lb-loved-section', profile.lb_loved_recordings.slice(0, 15).map(r => {
            const meta = r.track_metadata || {};
            return {
                name: `${meta.artist_name || '?'} — ${meta.track_name || '?'}`,
                meta: '❤️',
            };
        }));
    }

    // Heatmap
    if (lbData?.daily_activity) {
        _renderHeatmap('lb-heatmap-section', lbData.daily_activity);
    }
}

function _extractTopGenres(lbData, profile) {
    // Try LB genre activity first, fall back to local profile genres
    const localGenres = profile?.genres || {};
    if (Object.keys(localGenres).length) {
        return Object.entries(localGenres)
            .sort((a, b) => b[1] - a[1])
            .slice(0, 12)
            .map(([genre, score]) => ({ label: genre, value: Math.round(score * 100) }));
    }
    return [];
}

function _renderBarChart(containerId, items) {
    const container = document.getElementById(containerId);
    if (!container) return;
    if (!items || !items.length) {
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

function _renderLbList(containerId, items) {
    const container = document.getElementById(containerId);
    if (!container) return;
    if (!items || !items.length) {
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

function _renderHeatmap(containerId, dailyActivity) {
    const container = document.getElementById(containerId);
    if (!container) return;

    // LB returns: {"Monday": [{hour, listen_count}, ...], "Tuesday": [...], ...}
    // Legacy fallback: array of {day_of_week, hour, listen_count}
    const DAY_NAMES = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    const days = ['Ma', 'Di', 'Wo', 'Do', 'Vr', 'Za', 'Zo'];
    const grid = Array(7).fill(null).map(() => Array(24).fill(0));
    let maxVal = 0;
    let hasData = false;

    if (dailyActivity && typeof dailyActivity === 'object' && !Array.isArray(dailyActivity)) {
        // Dict format (new): {dayName: [{hour, listen_count}]}
        DAY_NAMES.forEach((dayName, di) => {
            const entries = dailyActivity[dayName] || [];
            for (const entry of entries) {
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
        // Legacy array format: [{day_of_week, hour, listen_count}]
        for (const item of dailyActivity) {
            const d = item.day_of_week;  // 0-6
            const h = item.hour;         // 0-23
            const c = item.listen_count || 0;
            if (d >= 0 && d < 7 && h >= 0 && h < 24) {
                grid[d][h] = c;
                if (c > maxVal) maxVal = c;
                hasData = true;
            }
        }
    }

    if (!hasData) {
        container.innerHTML = '<p class="lb-no-data">Geen heatmap data. Sync ListenBrainz om data op te halen.</p>';
        return;
    }

    const hourLabels = Array.from({ length: 24 }, (_, i) => i % 6 === 0 ? String(i) : '');
    const hoursHtml = `<div class="lb-heatmap-labels">${hourLabels.map(l => `<div style="width:16px;text-align:center">${l}</div>`).join('')}</div>`;

    const rowsHtml = days.map((day, di) => {
        const cells = grid[di].map(v => {
            const intensity = maxVal > 0 ? v / maxVal : 0;
            const alpha = Math.round(intensity * 0.85 * 100) / 100;
            const color = `rgba(229, 160, 13, ${alpha})`;
            return `<div class="lb-heatmap-cell" style="background:${color}" title="${v} plays"></div>`;
        }).join('');
        return `<div style="display:flex;align-items:center;gap:3px">
            <div class="lb-heatmap-day-label">${day}</div>
            ${cells}
        </div>`;
    }).join('');

    container.innerHTML = hoursHtml + rowsHtml;
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
