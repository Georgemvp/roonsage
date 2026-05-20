// =============================================================================
// Discovery — Cache-Powered Discovery view
// =============================================================================

import { apiCall } from './api.js';
import { escapeHtml } from './utils.js';

// ── Public entry point ────────────────────────────────────────────────────────

export async function initDiscoveryView() {
    const view = document.getElementById('discovery-view');
    if (!view) return;

    view.innerHTML = _skeletonHtml();

    try {
        const data = await apiCall('/discovery/sections');
        _render(view, data);
    } catch (e) {
        view.innerHTML = `<p class="discovery-error">Could not load discovery data: ${escapeHtml(e.message)}</p>`;
    }
}

// ── Skeleton ──────────────────────────────────────────────────────────────────

function _skeletonHtml() {
    return `
        <div class="discovery-skeleton">
            <div class="skeleton-block skeleton-title"></div>
            <div class="skeleton-block skeleton-row"></div>
            <div class="skeleton-block skeleton-row"></div>
            <div class="skeleton-block skeleton-row"></div>
        </div>`;
}

// ── Main renderer ─────────────────────────────────────────────────────────────

function _render(view, data) {
    const undiscovered = data.undiscovered_albums || [];
    const cuts         = data.deep_cuts           || [];
    const forgotten    = data.forgotten_favorites  || [];
    const genres       = data.genre_explorer       || [];

    const hasAny = undiscovered.length || cuts.length || forgotten.length || genres.length;

    if (!hasAny) {
        view.innerHTML = `
            <h2 class="view-title">Discover</h2>
            <p class="discovery-empty">
                No discovery data yet — keep listening and RoonSage will surface hidden gems from your library.
            </p>`;
        return;
    }

    view.innerHTML = `
        <h2 class="view-title">Discover</h2>
        <p class="discovery-subtitle">Pure library intelligence — zero AI, zero external APIs.</p>

        ${_renderUndiscoveredAlbums(undiscovered)}
        ${_renderDeepCuts(cuts)}
        ${_renderForgottenFavorites(forgotten)}
        ${_renderGenreExplorer(genres)}
    `;

    // Wire up play buttons after render
    view.querySelectorAll('[data-play-key]').forEach(btn => {
        btn.addEventListener('click', () => _playItem(btn));
    });

    // Wire up genre pills
    view.querySelectorAll('.discovery-genre-pill[data-genre]').forEach(pill => {
        pill.addEventListener('click', () => {
            const genre = pill.dataset.genre;
            // Navigate to home/generate with genre pre-filled
            const promptInput = document.getElementById('playlist-prompt');
            if (promptInput) {
                promptInput.value = genre;
                window.location.hash = 'playlist-prompt';
            }
        });
    });
}

// ── Section: Undiscovered Albums ──────────────────────────────────────────────

function _renderUndiscoveredAlbums(albums) {
    if (!albums.length) return '';

    const cards = albums.map(a => `
        <div class="discovery-album-card">
            <div class="discovery-album-info">
                <span class="discovery-album-title">${escapeHtml(a.album)}</span>
                <span class="discovery-album-artist">${escapeHtml(a.artist)}</span>
                <span class="discovery-album-meta">${a.artist_play_count} artist plays — 0 album plays</span>
            </div>
            ${a.parent_item_key ? `
            <button
                class="btn btn-secondary btn-sm discovery-play-btn"
                data-play-key="${escapeHtml(a.parent_item_key)}"
                data-play-type="album"
                title="Play ${escapeHtml(a.album)}"
                aria-label="Play ${escapeHtml(a.album)} by ${escapeHtml(a.artist)}"
            >▶ Play</button>` : ''}
        </div>
    `).join('');

    return `
        <section class="discovery-section" aria-labelledby="discovery-undiscovered-heading">
            <div class="discovery-section-header">
                <h3 class="discovery-section-title" id="discovery-undiscovered-heading">
                    Undiscovered Albums
                </h3>
                <span class="discovery-section-badge">${albums.length}</span>
            </div>
            <p class="discovery-section-desc">
                Albums by your favourite artists you've never played.
            </p>
            <div class="discovery-album-grid">
                ${cards}
            </div>
        </section>`;
}

// ── Section: Deep Cuts ────────────────────────────────────────────────────────

function _renderDeepCuts(tracks) {
    if (!tracks.length) return '';

    const rows = tracks.map(t => `
        <div class="discovery-track-row">
            <div class="discovery-track-info">
                <span class="discovery-track-title">${escapeHtml(t.title)}</span>
                <span class="discovery-track-meta">${escapeHtml(t.artist)} — ${escapeHtml(t.album || '—')}</span>
            </div>
            <div class="discovery-track-right">
                <span class="discovery-play-count">${t.play_count === 0 ? 'Unplayed' : `${t.play_count}×`}</span>
                ${t.item_key ? `
                <button
                    class="btn btn-secondary btn-sm discovery-play-btn"
                    data-play-key="${escapeHtml(t.item_key)}"
                    data-play-type="track"
                    title="Play ${escapeHtml(t.title)}"
                    aria-label="Play ${escapeHtml(t.title)}"
                >▶</button>` : ''}
            </div>
        </div>
    `).join('');

    return `
        <section class="discovery-section" aria-labelledby="discovery-deepcuts-heading">
            <div class="discovery-section-header">
                <h3 class="discovery-section-title" id="discovery-deepcuts-heading">
                    Deep Cuts
                </h3>
                <span class="discovery-section-badge">${tracks.length}</span>
            </div>
            <p class="discovery-section-desc">
                Rarely played tracks from your top artists — the ones hiding on side B.
            </p>
            <div class="discovery-track-list">
                ${rows}
            </div>
        </section>`;
}

// ── Section: Forgotten Favorites ──────────────────────────────────────────────

function _renderForgottenFavorites(tracks) {
    if (!tracks.length) return '';

    const rows = tracks.map(t => {
        const lastPlayed = t.last_played_at
            ? new Date(t.last_played_at).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' })
            : '—';

        return `
        <div class="discovery-track-row">
            <div class="discovery-track-info">
                <span class="discovery-track-title">${escapeHtml(t.title)}</span>
                <span class="discovery-track-meta">${escapeHtml(t.artist)} — ${escapeHtml(t.album || '—')}</span>
            </div>
            <div class="discovery-track-right">
                <span class="discovery-forgotten-meta">
                    <span class="discovery-play-count">${t.total_plays}×</span>
                    <span class="discovery-last-played">last: ${lastPlayed}</span>
                </span>
                ${t.item_key ? `
                <button
                    class="btn btn-secondary btn-sm discovery-play-btn"
                    data-play-key="${escapeHtml(t.item_key)}"
                    data-play-type="track"
                    title="Play ${escapeHtml(t.title)}"
                    aria-label="Play ${escapeHtml(t.title)}"
                >▶</button>` : ''}
            </div>
        </div>
    `}).join('');

    return `
        <section class="discovery-section" aria-labelledby="discovery-forgotten-heading">
            <div class="discovery-section-header">
                <h3 class="discovery-section-title" id="discovery-forgotten-heading">
                    Forgotten Favorites
                </h3>
                <span class="discovery-section-badge">${tracks.length}</span>
            </div>
            <p class="discovery-section-desc">
                Tracks you loved but haven't played in over 60 days.
            </p>
            <div class="discovery-track-list">
                ${rows}
            </div>
        </section>`;
}

// ── Section: Genre Explorer ───────────────────────────────────────────────────

function _renderGenreExplorer(genres) {
    if (!genres.length) return '';

    const maxCount = genres[0]?.artist_count || 1;
    const pills = genres.map(g => {
        const size = Math.max(0.75, Math.min(1.4, 0.75 + (g.artist_count / maxCount) * 0.65));
        return `
        <button
            class="discovery-genre-pill"
            data-genre="${escapeHtml(g.genre)}"
            style="font-size: ${size.toFixed(2)}rem;"
            aria-label="${escapeHtml(g.genre)}: ${g.artist_count} artists, ${g.track_count} tracks"
            title="${g.artist_count} artists · ${g.track_count} tracks"
        >${escapeHtml(g.genre)} <span class="discovery-genre-count">${g.artist_count}</span></button>
    `}).join('');

    return `
        <section class="discovery-section" aria-labelledby="discovery-genres-heading">
            <div class="discovery-section-header">
                <h3 class="discovery-section-title" id="discovery-genres-heading">
                    Genre Explorer
                </h3>
                <span class="discovery-section-badge">${genres.length} genres</span>
            </div>
            <p class="discovery-section-desc">
                Click a genre to start a playlist. Size reflects how many artists you have.
            </p>
            <div class="discovery-genre-cloud">
                ${pills}
            </div>
        </section>`;
}

// ── Playback helper ───────────────────────────────────────────────────────────

async function _playItem(btn) {
    const key  = btn.dataset.playKey;
    const type = btn.dataset.playType;

    if (!key) return;

    const originalText = btn.textContent;
    btn.disabled = true;
    btn.textContent = '…';

    try {
        // Resolve active zone from state (if available) or fall back to first zone
        let zoneId = window._roonState?.selectedZone || null;
        if (!zoneId) {
            try {
                const zonesResp = await apiCall('/roon/zones');
                const zones = zonesResp?.zones || zonesResp || [];
                if (zones.length) zoneId = zones[0].zone_id;
            } catch (_) { /* ignore */ }
        }

        if (!zoneId) {
            btn.textContent = '✗ No zone';
            setTimeout(() => { btn.textContent = originalText; btn.disabled = false; }, 2000);
            return;
        }

        const payload = {
            zone_id: zoneId,
            item_keys: [key],
        };

        if (type === 'album') {
            // For albums, use the search + play approach via the existing queue endpoint
            payload.replace_queue = true;
        }

        await apiCall('/queue', { method: 'POST', body: JSON.stringify(payload) });
        btn.textContent = '✓';
        setTimeout(() => { btn.textContent = originalText; btn.disabled = false; }, 2000);
    } catch (e) {
        btn.textContent = '✗';
        btn.title = e.message;
        setTimeout(() => { btn.textContent = originalText; btn.disabled = false; }, 2500);
    }
}
