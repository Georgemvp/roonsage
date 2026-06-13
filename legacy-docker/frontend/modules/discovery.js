// =============================================================================
// Discovery — Cache-Powered Discovery view
// =============================================================================

import { apiCall } from './api.js';
import { escapeHtml } from './utils.js';
import { getCurrentZoneId } from './nowplaying.js';
import { renderMoodsSection } from './moods.js';
import { showSkeleton } from './loading.js';

// ── Public entry point ────────────────────────────────────────────────────────

export async function initDiscoveryView() {
    const view = document.getElementById('discovery-view');
    if (!view) return;

    // Layout-matching skeleton — replaced once data arrives
    showSkeleton('discovery-view');

    try {
        const data = await apiCall('/discovery/sections');
        _render(view, data);
    } catch (e) {
        view.innerHTML = `<p class="discovery-error">Could not load discovery data: ${escapeHtml(e.message)}</p>`;
    }
}

// ── Main renderer ─────────────────────────────────────────────────────────────

function _render(view, data) {
    const favorites    = data.favorites_in_library || [];
    const lbReleases   = data.lb_top_releases      || [];
    const lbLoved      = data.lb_loved_in_library  || [];
    const cuts         = data.deep_cuts            || [];
    const forgotten    = data.forgotten_favorites  || [];
    const genres       = data.genre_explorer       || [];
    const soundsWeek   = data.sounds_like_your_week || null;
    const recently     = data.recently_added       || [];
    const undiscovered = data.undiscovered_albums  || [];
    const decadePicks  = data.decade_picks         || [];
    const topTracks    = data.top_tracks           || [];
    const seasonal     = data.seasonal_mix         || null;

    const hasAny = favorites.length || lbReleases.length || lbLoved.length ||
                   cuts.length || forgotten.length || genres.length ||
                   recently.length || undiscovered.length ||
                   decadePicks.length || topTracks.length ||
                   (soundsWeek && soundsWeek.tracks && soundsWeek.tracks.length) ||
                   (seasonal && seasonal.tracks && seasonal.tracks.length);

    if (!hasAny) {
        view.innerHTML = `
            <h2 class="rs-view-title">Discover</h2>
            <p class="discovery-empty">
                No discovery data yet — keep listening and RoonSage will surface hidden gems from your library.
            </p>`;
        return;
    }

    view.innerHTML = `
        <h2 class="rs-view-title">Discover</h2>
        <p class="discovery-subtitle">Gevoed door je Last.fm &amp; ListenBrainz luistergeschiedenis.</p>

        ${_renderSpotlight(forgotten, favorites, lbReleases)}
        ${_renderStatsBar(data)}
        ${_renderFeaturedGem(favorites, lbReleases)}

        ${_renderSoundsLikeYourWeek(soundsWeek)}
        ${_renderSeasonalMix(seasonal)}
        ${_renderRecentlyAdded(recently)}
        ${_renderUndiscoveredAlbums(undiscovered)}
        ${_renderLbTopReleases(lbReleases)}
        ${_renderLbLoved(lbLoved)}
        ${_renderFavoritesInLibrary(favorites)}
        ${_renderTopTracks(topTracks)}
        ${_renderDeepCuts(cuts)}
        ${_renderForgottenFavorites(forgotten)}
        ${_renderDecadePicks(decadePicks)}
        <div id="discovery-moods-pane"></div>
        ${_renderGenreExplorer(genres)}
        <div id="discovery-similar-pane"></div>
    `;

    // Async sections — render after the main view is up so the page doesn't
    // block on the mood-tag endpoint (which can be slow on a cold DB).
    renderMoodsSection(document.getElementById('discovery-moods-pane'));
    _renderSimilarArtists();

    // Inject AI-generated taglines for populated sections (fire-and-forget)
    _enrichSectionDescriptions({ cuts, forgotten, genres });

    // Wire up play buttons after render
    view.querySelectorAll('[data-play-key]').forEach(btn => {
        btn.addEventListener('click', () => _playItem(btn));
    });

    // Wire up "queue all" buttons (sounds-like-your-week)
    view.querySelectorAll('[data-queue-keys]').forEach(btn => {
        btn.addEventListener('click', () => _queueAll(btn));
    });

    // Wire up genre pills
    view.querySelectorAll('.rs-tab[data-genre]').forEach(pill => {
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

// ── Section: Sounds Like Your Week (CLAP-powered) ───────────────────────────

function _renderSoundsLikeYourWeek(section) {
    if (!section) return '';
    const tracks = section.tracks || [];
    if (!tracks.length) {
        if (section.message) {
            return `
                <section class="rs-section" aria-labelledby="disc-soundsweek-heading">
                    <div class="rs-section-header">
                        <h3 class="rs-section-title" id="disc-soundsweek-heading">Sounds Like Your Week</h3>
                    </div>
                    <p class="discovery-section-desc">${escapeHtml(section.message)}</p>
                </section>`;
        }
        return '';
    }

    const keys = tracks.map(t => t.item_key).filter(Boolean);
    const windowLabel = section.window_days === 30 ? 'laatste 30 dagen' : 'laatste 7 dagen';
    const rows = tracks.map(t => `
        <div class="rs-track-row">
            <div class="rs-track-info">
                <span class="rs-track-title">${escapeHtml(t.title || '—')}</span>
                <span class="rs-track-artist">${escapeHtml(t.artist || '')}</span>
                <span class="rs-track-album">${escapeHtml(t.album || '')}</span>
            </div>
            <div class="discovery-track-right">
                <span class="alchemy-score" title="Cosine similarity to your weekly centroid">${t.match_pct ?? 0}%</span>
                ${t.item_key ? `
                <button class="btn btn-secondary btn-sm discovery-play-btn"
                    data-play-key="${escapeHtml(t.item_key)}" data-play-type="track"
                    title="Play ${escapeHtml(t.title || '')}">▶</button>` : ''}
            </div>
            <button class="rs-track-options" title="Opties" aria-label="Opties">···</button>
        </div>
    `).join('');

    return `
        <section class="rs-section" aria-labelledby="disc-soundsweek-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="disc-soundsweek-heading">Sounds Like Your Week</h3>
                <span class="discovery-section-badge">${tracks.length}</span>
            </div>
            <p class="discovery-section-desc">
                Onbespeelde tracks die sonisch het dichtst bij je luistergedrag van de ${escapeHtml(windowLabel)} liggen
                — gevoed door CLAP audio-embeddings (geen LLM).
            </p>
            ${keys.length ? `
            <div style="margin: 4px 0 10px;">
                <button class="btn btn-primary btn-sm"
                    data-queue-keys="${escapeHtml(keys.join(','))}"
                    data-queue-mode="replace">▶ Speel alle ${keys.length}</button>
                <button class="btn btn-secondary btn-sm"
                    data-queue-keys="${escapeHtml(keys.join(','))}"
                    data-queue-mode="append">+ Voeg toe aan queue</button>
            </div>` : ''}
            <div class="discovery-track-list">${rows}</div>
        </section>`;
}

// ── Section: LB Top Releases in Library ──────────────────────────────────────

// ── Discovery stats bar ──────────────────────────────────────────────────
function _renderStatsBar(data) {
    const stats = [
        {
            value: data.stats?.unplayed_albums ?? data.unplayed_albums ?? (data.favorites_in_library?.length || 0),
            label: 'Onbespeelde albums',
        },
        {
            value: data.stats?.unplayed_tracks ?? data.unplayed_tracks ?? (data.deep_cuts?.length || 0),
            label: 'Onbespeelde tracks',
        },
        {
            value: data.stats?.forgotten ?? data.forgotten_favorites?.length ?? 0,
            label: 'Vergeten favorieten',
        },
        {
            value: data.stats?.new_additions ?? data.lb_loved_in_library?.length ?? 0,
            label: 'Recent toegevoegd',
        },
    ];
    return `
        <div class="rs-disc-stats">
            ${stats.map(s => `
                <div class="rs-disc-stat">
                    <span class="rs-disc-stat-value">${s.value}</span>
                    <span class="rs-disc-stat-label">${escapeHtml(s.label)}</span>
                </div>
            `).join('')}
        </div>
    `;
}

// ── Spotlight (vergeten parel) ───────────────────────────────────────────
function _renderSpotlight(forgotten, favorites, lbReleases) {
    // Prefer a forgotten favorite (track); fall back to an album favourite
    const item = (forgotten && forgotten.length) ? forgotten[0]
               : (favorites && favorites.length) ? favorites[0]
               : (lbReleases && lbReleases.length) ? lbReleases[0]
               : null;
    if (!item) return '';

    const title = item.title || item.album || '—';
    const artist = item.artist || '';

    // Build "last played X" text from last_played_at if present
    let lastPlayedText = '';
    if (item.last_played_at) {
        const last = new Date(item.last_played_at);
        const now = new Date();
        const diffDays = Math.max(1, Math.floor((now - last) / (1000 * 60 * 60 * 24)));
        if (diffDays < 60) {
            lastPlayedText = `${diffDays} dagen geleden`;
        } else {
            const months = Math.floor(diffDays / 30);
            lastPlayedText = months === 1 ? '1 maand geleden' : `${months} maanden geleden`;
        }
    }

    const metaSuffix = lastPlayedText ? ` · Niet gespeeld ${escapeHtml(lastPlayedText)}` : '';

    // Art: image_key (album-level data) or fallback placeholder
    const artHtml = item.image_key
        ? `<img src="/api/art/${escapeHtml(item.image_key)}?width=400&height=400" alt="${escapeHtml(title)}" onerror="this.style.display='none'">`
        : '<div class="rs-album-art-placeholder">♪</div>';

    // Play target: album item_key if available (album favourite), else track item_key
    const playKey = item.parent_item_key || item.item_key || '';
    const playType = item.parent_item_key ? 'album' : 'track';

    return `
        <div class="rs-disc-spotlight">
            <div class="rs-disc-spotlight-glow"></div>
            <div class="rs-disc-spotlight-art">${artHtml}</div>
            <div class="rs-disc-spotlight-content">
                <span class="rs-disc-spotlight-badge">⚡ Vergeten parel</span>
                <div class="rs-disc-spotlight-title">${escapeHtml(title)}</div>
                <div class="rs-disc-spotlight-meta">${escapeHtml(artist)}${metaSuffix}</div>
                <div class="rs-disc-spotlight-actions">
                    ${playKey ? `<button class="rs-btn rs-btn--primary rs-btn--sm"
                        data-play-key="${escapeHtml(playKey)}" data-play-type="${playType}">Nu spelen</button>` : ''}
                </div>
            </div>
        </div>`;
}

// ── Featured Hidden Gem ──────────────────────────────────────────────────
function _renderFeaturedGem(favorites, lbReleases) {
    const album = favorites?.[0] || lbReleases?.[0];
    if (!album) return '';

    const artHtml = album.image_key
        ? `<img src="/api/art/${album.image_key}?width=400&height=400" alt="" onerror="this.style.display='none'">`
        : '';

    return `
        <div class="rs-disc-featured">
            <div class="rs-disc-featured-art">${artHtml}</div>
            <div class="rs-disc-featured-content">
                <div class="rs-disc-featured-label">Uitgelicht: Hidden Gem</div>
                <div class="rs-disc-featured-title">${escapeHtml(album.album || album.title || '—')}</div>
                <div class="rs-disc-featured-meta">${escapeHtml([album.artist, album.year, album.genre].filter(Boolean).join(' · '))}</div>
                ${album.parent_item_key ? `
                <button class="btn btn-primary btn-sm"
                    data-play-key="${escapeHtml(album.parent_item_key)}"
                    data-play-type="album">
                    ▶ Speel album
                </button>` : ''}
            </div>
        </div>
    `;
}

function _renderLbTopReleases(albums) {
    if (!albums.length) return '';

    const cards = albums.map(a => `
        <div class="rs-album-card">
            <div class="rs-album-art">${a.image_key
                ? `<img src="/api/art/${escapeHtml(a.image_key)}?width=200&height=200" alt="" loading="lazy" onerror="this.parentElement.innerHTML='<div class=rs-album-art-placeholder>&#9835;</div>'">`
                : `<div class="rs-album-art-placeholder">&#9835;</div>`}</div>
            <div class="rs-album-title">${escapeHtml(a.album)}</div>
            <div class="rs-album-artist">${escapeHtml(a.artist)}</div>
            <span class="discovery-album-meta">${a.listen_count} keer geluisterd</span>
            ${a.parent_item_key ? `
            <button class="btn btn-secondary btn-sm discovery-play-btn"
                data-play-key="${escapeHtml(a.parent_item_key)}" data-play-type="album"
                title="Play ${escapeHtml(a.album)}">▶ Play</button>` : ''}
        </div>
    `).join('');

    return `
        <section class="rs-section" aria-labelledby="disc-lbreleases-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="disc-lbreleases-heading">Jouw meest beluisterde albums</h3>
                <span class="discovery-section-badge">${albums.length}</span>
            </div>
            <p class="discovery-section-desc">Top albums uit je ListenBrainz geschiedenis die in je library staan.</p>
            <div class="rs-album-row">${cards}</div>
        </section>`;
}

// ── Section: LB Loved in Library ─────────────────────────────────────────────

function _renderLbLoved(tracks) {
    if (!tracks.length) return '';

    const rows = tracks.map(t => `
        <div class="rs-track-row">
            <div class="rs-track-info">
                <span class="rs-track-title">${escapeHtml(t.title)}</span>
                <span class="rs-track-artist">${escapeHtml(t.artist)}</span>
                <span class="rs-track-album">${escapeHtml(t.album || '')}</span>
            </div>
            <div class="discovery-track-right">
                <span class="discovery-play-count">♥</span>
                ${t.item_key ? `
                <button class="btn btn-secondary btn-sm discovery-play-btn"
                    data-play-key="${escapeHtml(t.item_key)}" data-play-type="track"
                    title="Play ${escapeHtml(t.title)}">▶</button>` : ''}
            </div>
            <button class="rs-track-options" title="Opties" aria-label="Opties">···</button>
        </div>
    `).join('');

    return `
        <section class="rs-section" aria-labelledby="disc-lbloved-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="disc-lbloved-heading">Geliefd op ListenBrainz</h3>
                <span class="discovery-section-badge">${tracks.length}</span>
            </div>
            <p class="discovery-section-desc">Nummers die je op ListenBrainz hebt geliked en in je library staan.</p>
            <div class="discovery-track-list">${rows}</div>
        </section>`;
}

// ── Section: Favorites in Library ────────────────────────────────────────────

// ── Section: Recently Added albums ────────────────────────────────────────────

function _renderRecentlyAdded(albums) {
    if (!albums.length) return '';
    const cards = albums.map(a => `
        <div class="rs-album-card">
            <div class="rs-album-art">${a.image_key
                ? `<img src="/api/art/${escapeHtml(a.image_key)}?width=200&height=200" alt="" loading="lazy" onerror="this.parentElement.innerHTML='<div class=rs-album-art-placeholder>&#9835;</div>'">`
                : `<div class="rs-album-art-placeholder">&#9835;</div>`}</div>
            <div class="rs-album-title">${escapeHtml(a.album)}</div>
            <div class="rs-album-artist">${escapeHtml(a.artist)}</div>
            ${a.added_at ? `<span class="discovery-album-meta">${escapeHtml(a.added_at.slice(0, 10))}</span>` : ''}
            ${a.parent_item_key ? `
            <button class="btn btn-secondary btn-sm discovery-play-btn"
                data-play-key="${escapeHtml(a.parent_item_key)}" data-play-type="album"
                title="Play ${escapeHtml(a.album)}">▶ Play</button>` : ''}
        </div>
    `).join('');
    return `
        <section class="rs-section" aria-labelledby="disc-recent-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="disc-recent-heading">Recently Added</h3>
                <span class="discovery-section-badge">${albums.length}</span>
            </div>
            <p class="discovery-section-desc">Albums waarvan de nieuwste track in de afgelopen 30 dagen aan je library is toegevoegd.</p>
            <div class="rs-album-row">${cards}</div>
        </section>`;
}

// ── Section: Undiscovered Albums ──────────────────────────────────────────────

function _renderUndiscoveredAlbums(albums) {
    if (!albums.length) return '';
    const cards = albums.map(a => `
        <div class="rs-album-card">
            <div class="rs-album-art">${a.image_key
                ? `<img src="/api/art/${escapeHtml(a.image_key)}?width=200&height=200" alt="" loading="lazy" onerror="this.parentElement.innerHTML='<div class=rs-album-art-placeholder>&#9835;</div>'">`
                : `<div class="rs-album-art-placeholder">&#9835;</div>`}</div>
            <div class="rs-album-title">${escapeHtml(a.album)}</div>
            <div class="rs-album-artist">${escapeHtml(a.artist)}</div>
            <span class="discovery-album-meta">Nooit gespeeld</span>
            ${a.parent_item_key ? `
            <button class="btn btn-secondary btn-sm discovery-play-btn"
                data-play-key="${escapeHtml(a.parent_item_key)}" data-play-type="album"
                title="Play ${escapeHtml(a.album)}">▶ Play</button>` : ''}
        </div>
    `).join('');
    return `
        <section class="rs-section" aria-labelledby="disc-undisc-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="disc-undisc-heading">Undiscovered Albums</h3>
                <span class="discovery-section-badge">${albums.length}</span>
            </div>
            <p class="discovery-section-desc">Albums van artiesten die je vaak speelt, maar dit album nog nooit. Vergeten hoekjes van je top-40.</p>
            <div class="rs-album-row">${cards}</div>
        </section>`;
}

// ── Section: Top Tracks ───────────────────────────────────────────────────────

function _renderTopTracks(tracks) {
    if (!tracks.length) return '';
    const rows = tracks.map((t, i) => `
        <div class="rs-track-row">
            <div class="rs-track-info">
                <span class="rs-track-rank">${i + 1}</span>
                <span class="rs-track-title">${escapeHtml(t.title)}</span>
                <span class="rs-track-artist">${escapeHtml(t.artist)}</span>
                <span class="rs-track-album">${escapeHtml(t.album || '')}</span>
            </div>
            <div class="discovery-track-right">
                <span class="discovery-play-count">${t.plays}×</span>
                ${t.item_key ? `
                <button class="btn btn-secondary btn-sm discovery-play-btn"
                    data-play-key="${escapeHtml(t.item_key)}" data-play-type="track"
                    title="Play ${escapeHtml(t.title)}">▶</button>` : ''}
            </div>
            <button class="rs-track-options" title="Opties" aria-label="Opties">···</button>
        </div>
    `).join('');
    return `
        <section class="rs-section" aria-labelledby="disc-top-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="disc-top-heading">Top Tracks</h3>
                <span class="discovery-section-badge">${tracks.length}</span>
            </div>
            <p class="discovery-section-desc">Je meest-gespeelde tracks ooit — pure listening history, geen LLM.</p>
            <div class="discovery-track-list">${rows}</div>
        </section>`;
}

// ── Section: Decade Picks (compact, één rij per decennium) ────────────────────

function _renderDecadePicks(decades) {
    if (!decades.length) return '';
    const blocks = decades.map(d => {
        const rows = (d.tracks || []).map(t => `
            <div class="rs-track-row">
                <div class="rs-track-info">
                    <span class="rs-track-title">${escapeHtml(t.title)}</span>
                    <span class="rs-track-artist">${escapeHtml(t.artist)}</span>
                </div>
                ${t.item_key ? `
                <button class="btn btn-secondary btn-sm discovery-play-btn"
                    data-play-key="${escapeHtml(t.item_key)}" data-play-type="track"
                    title="Play ${escapeHtml(t.title)}">▶</button>` : ''}
            </div>
        `).join('');
        return `
            <div class="rs-decade-block">
                <h4 class="rs-decade-heading">${escapeHtml(d.decade)} <span class="discovery-section-badge">${d.track_count}</span></h4>
                <div class="discovery-track-list">${rows}</div>
            </div>`;
    }).join('');
    return `
        <section class="rs-section" aria-labelledby="disc-decade-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="disc-decade-heading">Decade Picks</h3>
            </div>
            <p class="discovery-section-desc">Willekeurige hapjes uit elk decennium van je library.</p>
            <div class="rs-decade-grid">${blocks}</div>
        </section>`;
}

// ── Section: Seasonal Mix (NL-seizoenen) ──────────────────────────────────────

function _renderSeasonalMix(section) {
    if (!section || !section.season || !section.tracks?.length) return '';
    const rows = section.tracks.map(t => `
        <div class="rs-track-row">
            <div class="rs-track-info">
                <span class="rs-track-title">${escapeHtml(t.title)}</span>
                <span class="rs-track-artist">${escapeHtml(t.artist)}</span>
                <span class="rs-track-album">${escapeHtml(t.album || '')}</span>
            </div>
            ${t.item_key ? `
            <button class="btn btn-secondary btn-sm discovery-play-btn"
                data-play-key="${escapeHtml(t.item_key)}" data-play-type="track"
                title="Play ${escapeHtml(t.title)}">▶</button>` : ''}
            <button class="rs-track-options" title="Opties" aria-label="Opties">···</button>
        </div>
    `).join('');
    return `
        <section class="rs-section" aria-labelledby="disc-season-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="disc-season-heading">${escapeHtml(section.season)}</h3>
                <span class="discovery-section-badge">${section.tracks.length}</span>
            </div>
            <p class="discovery-section-desc">Seizoens-gerichte tracks uit je library, gefilterd op genre-trefwoorden.</p>
            <div class="discovery-track-list">${rows}</div>
        </section>`;
}

function _renderFavoritesInLibrary(albums) {
    if (!albums.length) return '';

    const cards = albums.map(a => `
        <div class="rs-album-card">
            <div class="rs-album-art">${a.image_key
                ? `<img src="/api/art/${escapeHtml(a.image_key)}?width=200&height=200" alt="" loading="lazy" onerror="this.parentElement.innerHTML='<div class=rs-album-art-placeholder>&#9835;</div>'">`
                : `<div class="rs-album-art-placeholder">&#9835;</div>`}</div>
            <div class="rs-album-title">${escapeHtml(a.album)}</div>
            <div class="rs-album-artist">${escapeHtml(a.artist)}</div>
            <span class="discovery-album-meta">${a.artist_play_count} plays van deze artiest</span>
            ${a.parent_item_key ? `
            <button class="btn btn-secondary btn-sm discovery-play-btn"
                data-play-key="${escapeHtml(a.parent_item_key)}" data-play-type="album"
                title="Play ${escapeHtml(a.album)}">▶ Play</button>` : ''}
        </div>
    `).join('');

    return `
        <section class="rs-section" aria-labelledby="disc-favorites-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="disc-favorites-heading">Meer van je favorieten</h3>
                <span class="discovery-section-badge">${albums.length}</span>
            </div>
            <p class="discovery-section-desc">Eén album per artiest uit je top-40, wisselt bij elke refresh.</p>
            <div class="rs-album-row">${cards}</div>
        </section>`;
}

// ── Section: Deep Cuts ────────────────────────────────────────────────────────

function _renderDeepCuts(tracks) {
    if (!tracks.length) return '';

    const rows = tracks.map(t => `
        <div class="rs-track-row">
            <div class="rs-track-info">
                <span class="rs-track-title">${escapeHtml(t.title)}</span>
                <span class="rs-track-artist">${escapeHtml(t.artist)}</span>
                <span class="rs-track-album">${escapeHtml(t.album || '')}</span>
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
            <button class="rs-track-options" title="Opties" aria-label="Opties">···</button>
        </div>
    `).join('');

    return `
        <section class="rs-section" aria-labelledby="discovery-deepcuts-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="discovery-deepcuts-heading">
                    Deep Cuts
                </h3>
                <span class="discovery-section-badge">${tracks.length}</span>
            </div>
            <p class="discovery-section-desc">
                Tracks from your top artists you've played fewer than 5 times — the ones hiding on side B.
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
        <div class="rs-track-row">
            <div class="rs-track-info">
                <span class="rs-track-title">${escapeHtml(t.title)}</span>
                <span class="rs-track-artist">${escapeHtml(t.artist)}</span>
                <span class="rs-track-album">${escapeHtml(t.album || '')}</span>
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
            <button class="rs-track-options" title="Opties" aria-label="Opties">···</button>
        </div>
    `}).join('');

    return `
        <section class="rs-section" aria-labelledby="discovery-forgotten-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="discovery-forgotten-heading">
                    Forgotten Favorites
                </h3>
                <span class="discovery-section-badge">${tracks.length}</span>
            </div>
            <p class="discovery-section-desc">
                Tracks you've played before but haven't heard in over 2 weeks.
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
            class="rs-tab"
            data-genre="${escapeHtml(g.genre)}"
            style="font-size: ${size.toFixed(2)}rem;"
            aria-label="${escapeHtml(g.genre)}: ${g.artist_count} artists, ${g.track_count} tracks"
            title="${g.artist_count} artists · ${g.track_count} tracks"
        >${escapeHtml(g.genre)} <span class="discovery-genre-count">${g.artist_count}</span></button>
    `}).join('');

    return `
        <section class="rs-section" aria-labelledby="discovery-genres-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="discovery-genres-heading">
                    Genre Explorer
                </h3>
                <span class="discovery-section-badge">${genres.length} genres</span>
            </div>
            <p class="discovery-section-desc">
                Click a genre to start a playlist. Size reflects how many artists you have.
            </p>
            <div class="rs-tab-bar discovery-genre-cloud">
                ${pills}
            </div>
        </section>`;
}

// ── Similar Artists ───────────────────────────────────────────────────────────

async function _renderSimilarArtists() {
    const container = document.getElementById('discovery-similar-pane');
    if (!container) return;
    container.innerHTML = '<p style="color:var(--text-muted)">Laden…</p>';
    try {
        const data = await apiCall('/taste/profile');
        const artists = data?.recommendations?.similar_artists || data?.similar_artists || [];
        if (!artists.length) {
            container.innerHTML = '';
            return;
        }
        container.innerHTML = `
            <section class="discovery-section">
                <h2 class="discovery-section-title">Vergelijkbare Artiesten</h2>
                <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:14px">
                    ${artists.slice(0, 12).map(a => `
                        <div style="background:var(--bg-surface);border:1px solid var(--border);border-radius:12px;padding:16px;display:flex;gap:14px;align-items:flex-start">
                            <div style="width:52px;height:52px;border-radius:8px;background:var(--bg-elevated);flex-shrink:0;display:flex;align-items:center;justify-content:center;font-size:1.3rem;font-weight:700;color:var(--text-muted)">${escapeHtml((a.artist_name || a.name || '?')[0])}</div>
                            <div style="flex:1;min-width:0">
                                <div style="font-size:0.88rem;font-weight:700;color:var(--text-primary);margin-bottom:2px">${escapeHtml(a.artist_name || a.name || '?')}</div>
                                <div style="font-size:0.72rem;color:var(--text-muted);margin-bottom:8px">${escapeHtml(a.genres?.join(', ') || '')}</div>
                                ${a.reason ? `<div style="font-size:0.75rem;color:var(--text-secondary);line-height:1.5">${escapeHtml(a.reason)}</div>` : ''}
                            </div>
                        </div>
                    `).join('')}
                </div>
            </section>`;
    } catch (e) {
        container.innerHTML = '';
    }
}

// ── Playback helper ───────────────────────────────────────────────────────────

async function _queueAll(btn) {
    const raw = btn.dataset.queueKeys || '';
    const mode = btn.dataset.queueMode || 'replace';
    const keys = raw.split(',').filter(Boolean);
    if (!keys.length) return;

    const originalText = btn.textContent;
    btn.disabled = true;
    btn.textContent = '…';
    try {
        let zoneId = getCurrentZoneId();
        if (!zoneId) {
            try {
                const zones = await apiCall('/roon/zones');
                const list = Array.isArray(zones) ? zones : (zones?.zones || []);
                if (list.length) zoneId = list[0].zone_id;
            } catch (_) { /* ignore */ }
        }
        if (!zoneId) {
            btn.textContent = '✗ No zone';
            setTimeout(() => { btn.textContent = originalText; btn.disabled = false; }, 2000);
            return;
        }
        await apiCall('/queue', {
            method: 'POST',
            body: JSON.stringify({ zone_id: zoneId, item_keys: keys, mode }),
        });
        btn.textContent = '✓';
        setTimeout(() => { btn.textContent = originalText; btn.disabled = false; }, 2000);
    } catch (e) {
        btn.textContent = '✗';
        btn.title = e.message;
        setTimeout(() => { btn.textContent = originalText; btn.disabled = false; }, 2500);
    }
}

async function _playItem(btn) {
    const key  = btn.dataset.playKey;
    const type = btn.dataset.playType;

    if (!key) return;

    const originalText = btn.textContent;
    btn.disabled = true;
    btn.textContent = '…';

    try {
        // Use zone currently active in the now-playing bar; fall back to first available
        let zoneId = getCurrentZoneId();
        if (!zoneId) {
            try {
                const zones = await apiCall('/roon/zones');
                const list = Array.isArray(zones) ? zones : (zones?.zones || []);
                if (list.length) zoneId = list[0].zone_id;
            } catch (_) { /* ignore */ }
        }

        if (!zoneId) {
            btn.textContent = '✗ No zone';
            setTimeout(() => { btn.textContent = originalText; btn.disabled = false; }, 2000);
            return;
        }

        if (type === 'album') {
            await apiCall('/roon/play-album', {
                method: 'POST',
                body: JSON.stringify({ album_item_key: key, zone_id: zoneId }),
            });
        } else {
            await apiCall('/queue', {
                method: 'POST',
                body: JSON.stringify({ zone_id: zoneId, item_keys: [key] }),
            });
        }
        btn.textContent = '✓';
        setTimeout(() => { btn.textContent = originalText; btn.disabled = false; }, 2000);
    } catch (e) {
        btn.textContent = '✗';
        btn.title = e.message;
        setTimeout(() => { btn.textContent = originalText; btn.disabled = false; }, 2500);
    }
}

// ── AI section descriptions ───────────────────────────────────────────────────

const _SECTION_DESC_MAP = {
    deep_cuts:           'discovery-deepcuts-heading',
    forgotten_favorites: 'discovery-forgotten-heading',
    genre_explorer:      'discovery-genres-heading',
};

async function _enrichSectionDescriptions({ cuts, forgotten, genres }) {
    const active = [
        { type: 'deep_cuts',           show: cuts.length > 0 },
        { type: 'forgotten_favorites', show: forgotten.length > 0 },
        { type: 'genre_explorer',      show: genres.length > 0 },
    ];

    for (const { type, show } of active) {
        if (!show) continue;
        try {
            const cached = await apiCall(`/background-ai/discovery-description/${type}`).catch(() => null);
            if (!cached?.tagline) continue;
            const heading = document.getElementById(_SECTION_DESC_MAP[type]);
            const descEl = heading?.closest('section')?.querySelector('.discovery-section-desc');
            if (descEl) {
                descEl.innerHTML = `<strong>${escapeHtml(cached.tagline)}</strong> — ${escapeHtml(cached.description || '')}`;
            }
        } catch (_) { /* non-critical */ }
    }
}
