/**
 * RoonSage — ES module entry point
 *
 * Imports all feature modules and runs the DOMContentLoaded init.
 * No logic lives here — everything is in frontend/modules/*.js.
 */

import { state }                          from './modules/state.js';
import { focusManager }                   from './modules/focus.js';
import { artPlaceholderHtml }             from './modules/utils.js';
import { fetchSetupStatus, apiCall }      from './modules/api.js';
import { viewFromHash, modeFromHash, loadSavedResult } from './modules/router.js';
import { renderHistoryFeed }              from './modules/history.js';
import {
    updateView, updateMode, updateStep,
    hideError, hideSuccess, hideSuccessModal, dismissSuccessModal,
    closeBottomSheet, setLoading
} from './modules/ui.js';
import { checkLibraryStatus }             from './modules/library.js';
import { setupEventListeners }            from './modules/events.js';
import { loadSettings, loadNotificationSettings, initNotificationButtons, initEnrichmentButtons } from './modules/playlist.js';
import { initAudioFeaturesButtons } from './modules/audio-features.js';
import {
    dismissClientPicker, dismissPlayChoice, dismissPlaySuccess, setSaveMode
} from './modules/instant-queue.js';
import { setupRecEventListeners, renderPromptPills, PLAYLIST_PROMPT_GROUPS } from './modules/recommend.js';
import { setupHistoryEventListeners }     from './modules/history.js';
import { enterSetupWizard }               from './modules/setup-wizard.js';
import { startNowPlaying, openZonePicker } from './modules/nowplaying.js';
import { initTemplates }                  from './modules/templates.js';
import { startActivityMonitor }           from './modules/activity.js';
import { initPWA }                        from './modules/pwa.js';
import { initAnalysisTasks }              from './modules/analysis-tasks.js';
import { loadHomeListenFeed }             from './modules/home-listen.js';

// View modules are loaded on demand — keeps the initial JS payload small,
// and view-specific code (e.g. Chart.js use in taste.js) only loads when the
// user navigates to it. Routes that don't appear here stay eager because
// their setup must run at startup (event listeners, polling).
async function initViewModule(view) {
    switch (view) {
        case 'recommend': {
            const { initRecommendView } = await import('./modules/recommend.js');
            return initRecommendView();
        }
        case 'playlists': {
            const { initPlaylistsView } = await import('./modules/playlists.js');
            return initPlaylistsView();
        }
        case 'taste': {
            const { initTasteView } = await import('./modules/taste.js');
            return initTasteView();
        }
        case 'enrichment': {
            const { initEnrichmentView } = await import('./modules/enrichment.js');
            return initEnrichmentView();
        }
        default:
            return null;
    }
}

// =============================================================================
// Theme & Variation Init
// =============================================================================

/**
 * Stitch design: fade `.rs-reveal` elements in as they enter the viewport.
 * Re-observes any newly added .rs-reveal nodes via MutationObserver.
 */
function initScrollReveal() {
    if (!('IntersectionObserver' in window)) {
        document.querySelectorAll('.rs-reveal').forEach(el => el.classList.add('is-visible'));
        return;
    }
    const io = new IntersectionObserver((entries, observer) => {
        for (const entry of entries) {
            if (entry.isIntersecting) {
                entry.target.classList.add('is-visible');
                observer.unobserve(entry.target);
            }
        }
    }, { threshold: 0.08, rootMargin: '0px 0px -40px 0px' });
    const observe = (root) => {
        root.querySelectorAll('.rs-reveal:not(.is-visible)').forEach(el => io.observe(el));
    };
    observe(document);
    new MutationObserver((muts) => {
        for (const m of muts) {
            m.addedNodes.forEach(n => { if (n.nodeType === 1) observe(n); });
        }
    }).observe(document.body, { childList: true, subtree: true });
}

function initThemeToggle() {
    let savedTheme = 'dark';
    let savedVariation = '';
    try {
        savedTheme = localStorage.getItem('roonsage-theme') || 'dark';
        savedVariation = localStorage.getItem('roonsage-variation') || '';
    } catch (e) {}
    document.documentElement.setAttribute('data-theme', savedTheme);
    document.documentElement.setAttribute('data-variation', savedVariation);

    // Legacy theme toggle button (may no longer exist in sidebar layout)
    document.getElementById('theme-toggle-btn')?.addEventListener('click', () => {
        const current = document.documentElement.getAttribute('data-theme') || 'dark';
        const next = current === 'dark' ? 'light' : 'dark';
        setTheme(next);
    });
}

export function setTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    try { localStorage.setItem('roonsage-theme', theme); } catch (e) {}
    _syncAppearanceUI();
}

export function setVariation(variation) {
    document.documentElement.setAttribute('data-variation', variation);
    try { localStorage.setItem('roonsage-variation', variation); } catch (e) {}
    _syncAppearanceUI();
}

function _syncAppearanceUI() {
    const theme     = document.documentElement.getAttribute('data-theme') || 'dark';
    const variation = document.documentElement.getAttribute('data-variation') || '';
    const LABELS    = { viola: 'Viola', ember: 'Ember', slate: 'Slate' };

    document.querySelectorAll('[data-theme-opt]').forEach(btn =>
        btn.classList.toggle('on', btn.dataset.themeOpt === theme));
    document.querySelectorAll('[data-variation]').forEach(btn =>
        btn.classList.toggle('on', btn.dataset.variation === variation));

    const labelEl = document.getElementById('variation-label');
    if (labelEl) labelEl.textContent = LABELS[variation] || variation;
}

function initAppearanceControls() {
    _syncAppearanceUI();

    document.addEventListener('click', e => {
        const themeBtn = e.target.closest('[data-theme-opt]');
        if (themeBtn) { setTheme(themeBtn.dataset.themeOpt); return; }

        const varBtn = e.target.closest('.rs-variation-swatches [data-variation]');
        if (varBtn) { setVariation(varBtn.dataset.variation); return; }
    });
}

// Update sidebar zone button from now-playing state
export function updateSidebarZone(zoneName, isActive) {
    const nameEl = document.getElementById('sidebar-zone-name');
    const dotEl  = document.getElementById('sidebar-zone-dot');
    if (nameEl) nameEl.textContent = zoneName || 'No zone active';
    if (dotEl) {
        dotEl.classList.toggle('rs-zone-dot--inactive', !isActive);
    }
}

// =============================================================================
// Home Preview — live data for feature cards and taste snapshot
// =============================================================================

// Populate the home hero with now-playing state, falling back to recent history
async function loadHomeHero() {
    const hour = new Date().getHours();
    const greeting = hour < 12 ? 'Goedemorgen' : hour < 18 ? 'Goedemiddag' : 'Goedenavond';

    const hero = document.getElementById('home-hero');
    if (!hero) return;

    const greetingEl = document.getElementById('home-hero-greeting');
    if (greetingEl) greetingEl.textContent = greeting;

    try {
        // Try: currently playing zone first
        let track = null;
        let isLive = false;

        try {
            const zones = await apiCall('/roon/zones');
            const zoneList = Array.isArray(zones) ? zones : (zones?.zones || []);
            const activeZone = zoneList.find(z => z.state === 'playing' && z.now_playing);
            if (activeZone) {
                const np = activeZone.now_playing;
                track = {
                    title: np.one_line?.line1 || np.two_line?.line1 || '—',
                    artist: np.one_line?.line2 || np.two_line?.line2 || '',
                    zone: activeZone.display_name || activeZone.zone_id,
                    image_key: np.image_key,
                };
                isLive = true;
            }
        } catch (_) { /* ignore zone errors */ }

        // Fallback: most recent history entry. We pull a small window and
        // pick the first event that actually has artist + (album|track_title)
        // so a stray corrupt row can never blank out the hero.
        if (!track) {
            const data = await apiCall('/listening/history?days=30&limit=5').catch(() => null);
            const events = Array.isArray(data) ? data : (data?.events || []);
            const event = events.find(e =>
                e && e.artist && (e.album || e.track_title || e.title)
            ) || events[0];
            if (event) {
                track = {
                    title: event.album || event.track_title || event.title || '—',
                    artist: event.artist || '',
                    year: event.year,
                    genre: event.genre,
                    image_key: event.image_key,
                };
            }
        }

        // Empty state: no data available
        if (!track) {
            hero.classList.add('hero--empty');
            hero.querySelector('.hero-bg')?.remove();
            hero.querySelector('.hero-overlay')?.remove();
            const content = hero.querySelector('.hero-content');
            if (content) content.innerHTML = `
                <div class="hero-info" style="width:100%;text-align:center">
                    <div class="hero-title" style="font-size:1.6rem;color:var(--text-primary)">${greeting}</div>
                    <div class="hero-subtitle" style="color:var(--text-secondary)">AI-powered playlists, discovery en intelligence voor je Roon bibliotheek</div>
                </div>`;
            return;
        }

        // Fill elements
        const eyebrowEl = document.getElementById('home-hero-eyebrow');
        const titleEl   = document.getElementById('home-hero-title');
        const metaEl    = document.getElementById('home-hero-meta');
        const bgEl      = document.getElementById('home-hero-bg');
        const artImg    = document.getElementById('home-hero-art-img');

        const eyebrowLabel = isLive ? 'Nu aan het spelen' : 'RoonSage Insight Selection';
        if (eyebrowEl) eyebrowEl.innerHTML =
            `<span class="material-symbols-outlined" style="font-size:18px">${isLive ? 'graphic_eq' : 'auto_awesome'}</span> ${eyebrowLabel}`;
        if (titleEl)   titleEl.textContent   = track.title;

        const metaParts = isLive
            ? [track.artist, track.zone].filter(Boolean)
            : [track.artist, track.year, track.genre].filter(Boolean);
        if (metaEl) metaEl.textContent = metaParts.join(' · ') || '—';

        const insightEl = document.getElementById('home-hero-insight');
        if (insightEl) {
            insightEl.textContent = isLive
                ? `Speelt nu in ${track.zone || 'je actieve zone'}. Ontdek vergelijkbare albums of bouw een playlist rond deze sfeer.`
                : `Onlangs gespeeld uit je bibliotheek${track.genre ? ` · ${track.genre}` : ''}. Bekijk vergelijkbare muziek of start een nieuwe AI-playlist.`;
        }

        if (track.image_key) {
            const artUrl = `/api/art/${track.image_key}?width=300&height=300`;
            if (bgEl)    bgEl.style.backgroundImage = `url(${artUrl})`;
            if (artImg) {
                artImg.src = artUrl;
                artImg.style.display = 'block';
                artImg.onerror = () => { artImg.style.display = 'none'; };
            }
        }

        // Button actions
        document.getElementById('home-hero-play')?.addEventListener('click', () => {
            const artist = track.artist;
            location.hash = 'recommend-album';
            if (artist) {
                requestAnimationFrame(() => {
                    const input = document.querySelector('#recommend-view [name="artist"], #rec-artist-input');
                    if (input) input.value = artist;
                });
            }
        });
        document.getElementById('home-hero-queue')?.addEventListener('click', () => {
            location.hash = 'discovery';
        });

    } catch (e) {
        console.warn('Hero load failed:', e);
        hero.classList.add('hero--empty');
    }
}

async function loadRecentlyAdded() {
    try {
        const albumGrid = document.getElementById('home-album-grid');
        const bento = document.getElementById('home-bento');
        if (!albumGrid || !bento) return;

        const history = await apiCall('/listening/history?days=90&limit=20').catch(() => null);
        const events = Array.isArray(history) ? history : (history?.events || []);

        // Deduplicate by album, keep up to 4 (matches Stitch 4-col bento)
        const seen = new Set();
        const albums = [];
        for (const e of events) {
            const key = `${e.album || ''}::${e.artist || ''}`;
            if (!seen.has(key) && e.album) {
                seen.add(key);
                albums.push(e);
                if (albums.length >= 4) break;
            }
        }

        if (!albums.length) return;
        bento.style.display = '';

        albumGrid.innerHTML = albums.map(a => `
            <button class="rs-home-disc__item" data-artist="${(a.artist || '').replace(/"/g, '&quot;')}" data-album="${(a.album || '').replace(/"/g, '&quot;')}">
                <div class="rs-home-disc__art">
                    ${a.image_key
                        ? `<img src="/api/art/${a.image_key}?width=320&height=320" alt="" loading="lazy" onerror="this.style.display='none'">`
                        : `<div style="width:100%;height:100%;display:flex;align-items:center;justify-content:center;color:var(--text-muted);font-size:2.6rem">&#9835;</div>`}
                    <div class="rs-home-disc__overlay">
                        <span class="rs-home-disc__playbtn">
                            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1">play_arrow</span>
                        </span>
                    </div>
                </div>
                <div class="rs-home-disc__title" title="${(a.album || '').replace(/"/g, '&quot;')}">${a.album || 'Unknown Album'}</div>
                <div class="rs-home-disc__artist">${a.artist || ''}</div>
            </button>
        `).join('');

        // Wire play on click
        albumGrid.querySelectorAll('.rs-home-disc__item').forEach(btn => {
            btn.addEventListener('click', async () => {
                const artist = btn.dataset.artist;
                const album = btn.dataset.album;
                if (!artist || !album) return;
                try { await apiCall(`/roon/play-album?artist=${encodeURIComponent(artist)}&album=${encodeURIComponent(album)}`, { method: 'POST' }); } catch (e) { /* silent */ }
            });
        });
    } catch (e) {
        console.warn('Recently added load failed:', e);
    }
}

/**
 * Populate the bento Taste mini-radar with the user's top 5 genres.
 * Polygon points are in viewBox 0..100; we scale a pentagon by score.
 */
function _renderHomeRadar(sortedGenres) {
    const poly = document.getElementById('home-bento-radar-poly');
    if (!poly || !sortedGenres || !sortedGenres.length) return;
    const top5 = sortedGenres.slice(0, 5);
    // Pentagon base coords (viewBox 100x100, center at 50,50, radius 40)
    const base = [
        { angle: -90, label: 'top' },
        { angle: -18, label: 'right' },
        { angle:  54, label: 'br' },
        { angle: 126, label: 'bl' },
        { angle: 198, label: 'left' },
    ];
    const pts = top5.map((entry, i) => {
        const [, score] = entry;
        const r = 8 + Math.min(Math.max(score || 0, 0), 1) * 35; // 8..43
        const a = (base[i % 5].angle * Math.PI) / 180;
        const x = 50 + Math.cos(a) * r;
        const y = 50 + Math.sin(a) * r;
        return `${x.toFixed(1)},${y.toFixed(1)}`;
    }).join(' ');
    poly.setAttribute('points', pts);
    // Labels (top 3 visible)
    const setLabel = (id, name) => {
        const el = document.getElementById(id);
        if (el && name) el.textContent = name;
    };
    setLabel('home-bento-radar-top',    top5[0]?.[0]);
    setLabel('home-bento-radar-right',  top5[1]?.[0]);
    setLabel('home-bento-radar-bottom', top5[2]?.[0]);
    setLabel('home-bento-radar-left',   top5[4]?.[0]);
}

async function loadHomePreview() {
    loadRecentlyAdded(); // fire-and-forget
    try {
        // Taste preview + snapshot
        let taste = await apiCall('/taste/profile').catch(() => null);
        const _genreMap = (t) => t?.genre_scores || t?.genres || {};
        if (Object.keys(_genreMap(taste)).length === 0) {
            const detailed = await apiCall('/intelligence/taste-profile/detailed').catch(() => null);
            if (detailed) taste = detailed;
        }
        const genreMap = _genreMap(taste);
        if (Object.keys(genreMap).length > 0) {
            const sorted = Object.entries(genreMap).sort((a, b) => b[1] - a[1]);

            // Feature card preview (top 2 genres)
            const top2 = sorted.slice(0, 2);
            const preview = top2.map(([g, s]) => `${g} ${Math.round(s * 100)}%`).join(' · ');
            const previewEl = document.getElementById('home-taste-preview');
            if (previewEl) previewEl.textContent = preview || '—';

            // Taste snapshot genre bars (top 3)
            const top3 = sorted.slice(0, 3);
            const genresEl = document.getElementById('home-taste-genres');
            if (genresEl) {
                genresEl.innerHTML = top3.map(([name, score], i) => `
                    <div class="taste-snap-genre-row">
                        <span class="taste-snap-genre-name">${name}</span>
                        <div class="taste-snap-genre-bar"><div class="taste-snap-genre-fill" style="width:${Math.round(score * 100)}%;opacity:${1 - i * 0.2}"></div></div>
                        <span class="taste-snap-genre-pct">${Math.round(score * 100)}%</span>
                    </div>`).join('');
            }

            // Bento mini-radar (Stitch dashboard)
            _renderHomeRadar(sorted);

            // Hours ring + meta
            const totalHours = taste.total_hours ?? taste.stats?.total_hours ?? null;
            if (totalHours != null) {
                const h = Math.round(totalHours);
                const hoursEl = document.getElementById('home-total-hours');
                if (hoursEl) hoursEl.textContent = h;
                // Ring: stroke-dasharray=226, offset=226-226*(hours/maxHours)
                const ringEl = document.getElementById('home-hours-ring');
                if (ringEl) {
                    const maxHours = Math.max(h, 100);
                    const pct = Math.min(h / maxHours, 1);
                    ringEl.style.strokeDashoffset = String(226 - 226 * pct);
                }
            }
            const peakHour = taste.peak_hour ?? taste.listening_patterns?.peak_hour ?? null;
            const peakDay  = taste.peak_day ?? taste.listening_patterns?.peak_day ?? null;
            // Format hour into "10:00" + AM/PM split for the Stitch peak tile
            if (peakHour != null) {
                const h = peakHour;
                const hour12 = h === 0 ? 12 : (h > 12 ? h - 12 : h);
                const suffix = h >= 12 ? 'PM' : 'AM';
                // Bento peak: number + AM/PM as unit
                const peakEl = document.getElementById('home-peak-hour');
                if (peakEl) peakEl.textContent = `${hour12}:00`;
                const dayEl = document.getElementById('home-peak-day');
                if (dayEl) {
                    const dayLabel = peakDay
                        ? ` ${suffix} · ${peakDay.charAt(0).toUpperCase() + peakDay.slice(1)}s`
                        : ` ${suffix}`;
                    dayEl.textContent = dayLabel;
                }
            }
        }

        // Template count
        const templates = await apiCall('/templates').catch(() => null);
        if (Array.isArray(templates) && templates.length) {
            const el = document.getElementById('home-template-count');
            if (el) el.textContent = `${templates.length} templates`;
        }

        // Watchlist count
        const watchlist = await apiCall('/watchlist').catch(() => null);
        if (watchlist?.artists) {
            const newReleases = watchlist.new_releases?.length || 0;
            const el = document.getElementById('home-watchlist-count');
            if (el) el.textContent = `${watchlist.artists.length} artists${newReleases ? ` · ${newReleases} new` : ''}`;
        }

        // Automations count
        const autos = await apiCall('/automations').catch(() => null);
        if (Array.isArray(autos)) {
            const active = autos.filter(a => a.enabled).length;
            const el = document.getElementById('home-auto-count');
            if (el) el.textContent = `${active} active`;
        }

        // Playlists count
        const playlists = await apiCall('/results').catch(() => null);
        if (playlists?.results) {
            const el = document.getElementById('home-playlists-count');
            if (el) el.textContent = `${playlists.results.length} saved`;
        }

        // Enrichment status
        const enrich = await apiCall('/enrichment/status').catch(() => null);
        if (enrich) {
            const el = document.getElementById('home-enrich-count');
            if (el) {
                const pct = enrich.total > 0 ? Math.round((enrich.enriched / enrich.total) * 100) : 0;
                el.textContent = `${pct}% enriched`;
            }
        }

        // Discovery preview
        const discovery = await apiCall('/discovery/sections').catch(() => null);
        if (discovery?.undiscovered_albums) {
            const el = document.getElementById('home-discovery-count');
            if (el) el.textContent = `${discovery.undiscovered_albums.length} undiscovered albums`;
        }
    } catch (e) {
        console.warn('Home preview load failed:', e);
    }
}

// =============================================================================
// Initialization
// =============================================================================

document.addEventListener('DOMContentLoaded', async () => {
    // macOS + Safari: by default, Tab only focuses form inputs and elements
    // with explicit tabindex — buttons, links, and other native controls are
    // skipped. Observe the DOM and add tabindex="0" to any button or link
    // that lacks one, making them keyboard-navigable regardless of the
    // system "Keyboard navigation" preference.
    const ensureTabIndex = (root) => {
        root.querySelectorAll('button:not([tabindex]), a[href]:not([tabindex])').forEach(el => {
            el.setAttribute('tabindex', '0');
        });
    };
    ensureTabIndex(document);
    let tabIndexPending = false;
    new MutationObserver(() => {
        if (!tabIndexPending) {
            tabIndexPending = true;
            requestAnimationFrame(() => {
                ensureTabIndex(document.body);
                tabIndexPending = false;
            });
        }
    }).observe(document.body, { childList: true, subtree: true });

    // Initialize theme + variation (before any rendering)
    initThemeToggle();
    initAppearanceControls();
    initScrollReveal();

    // Register the service worker and wire install/update toasts. Safe to call
    // unconditionally — bails out on insecure contexts and unsupported browsers.
    initPWA();

    setupEventListeners();
    setupRecEventListeners();
    setupHistoryEventListeners();
    initTemplates();
    initNotificationButtons();
    initEnrichmentButtons();
    initAudioFeaturesButtons();
    initAnalysisTasks();
    state.view = viewFromHash();
    state.mode = modeFromHash();
    if (!location.hash) {
        history.replaceState(null, '', '#home');
    }
    updateView();
    updateMode();
    updateStep();
    renderPromptPills('playlist-prompt-pills', 'playlist-prompt-shuffle', PLAYLIST_PROMPT_GROUPS);

    // Load initial config
    try {
        await loadSettings();
        loadNotificationSettings();  // fire-and-forget; populates notification fields

        // Check setup wizard status (only on home view with no deep link)
        const initHash = location.hash.slice(1);
        if (state.view === 'home' && !initHash.startsWith('result/')) {
            try {
                const setupStatus = await fetchSetupStatus();
                // Persist Qobuz availability for the source mode UI — must be set
                // BEFORE enterSetupWizard() because that function returns early and
                // the line below would otherwise never execute during wizard sessions.
                state.qobuzAvailable = !!setupStatus.qobuz_available;
                state.qobuzSaveAvailable = !!setupStatus.qobuz_save_available;
                if (!setupStatus.setup_complete) {
                    enterSetupWizard(setupStatus);
                    return; // Wizard handles its own lifecycle
                }
            } catch (e) {
                // Setup endpoint unavailable — skip wizard, continue normally
                console.warn('Setup status check failed:', e);
            }
        }

        // Reveal home content + footer now that setup check is done
        document.querySelector('#home-view .home-content')?.classList.remove('home-content--loading');
        document.querySelector('.app-footer')?.classList.remove('app-footer--loading');

        // Check library cache status after config is loaded
        if (state.config?.roon_connected) {
            await checkLibraryStatus();
        }
    } catch (error) {
        // Settings will show as not configured
        console.error('Initialization error:', error);
    } finally {
        document.getElementById('app-loading')?.remove();
        // Don't reveal home content if setup wizard took over
        if (!state.setup.active) {
            document.querySelector('#home-view .home-content')?.classList.remove('home-content--loading');
            document.querySelector('.app-footer')?.classList.remove('app-footer--loading');
        }
    }

    // Initialize views AFTER config is loaded
    if (state.view === 'home') {
        renderHistoryFeed();
        loadHomeListenFeed();
        loadHomePreview(); // fire-and-forget; populates feature card previews
        loadHomeHero();
    } else {
        initViewModule(state.view);
    }

    // Start Now Playing polling (persistent — runs on all views)
    startNowPlaying();

    document.getElementById('sidebar-zone-btn')?.addEventListener('click', openZonePicker);

    // Start background activity monitor (enrichment, library sync indicator)
    startActivityMonitor();

    // Wire "Save for Arc" button in results view
    _wireArcButton();

    // Handle direct navigation to a saved result (e.g., bookmarked URL)
    const initHash = location.hash.slice(1);
    if (initHash.startsWith('result/')) {
        const resultId = initHash.split('/')[1];
        if (resultId) {
            loadSavedResult(resultId);
        }
    }

    // Restore save mode from localStorage
    let initialMode = 'replace_queue';
    try {
        const savedMode = localStorage.getItem('roonsage-save-mode');
        if (savedMode === 'replace_queue' || savedMode === 'play_now' || savedMode === 'queue_next') {
            initialMode = savedMode;
        }
    } catch (e) { /* private browsing / storage disabled */ }
    setSaveMode(initialMode);
});

// =============================================================================
// Save for Arc — results view integration
// =============================================================================

function _wireArcButton() {
    const btn = document.getElementById('save-for-arc-btn');
    if (!btn) return;

    btn.addEventListener('click', () => {
        const modal = document.getElementById('arc-global-modal');
        const nameInput = document.getElementById('arc-global-name');
        const resultEl  = document.getElementById('arc-global-result');
        const saveBtn   = document.getElementById('arc-global-save');
        if (!modal) return;

        // Pre-fill with playlist title
        if (nameInput) nameInput.value = state.playlistTitle || state.playlistName || 'My Playlist';
        if (resultEl)  { resultEl.textContent = ''; resultEl.className = 'arc-modal-result hidden'; }
        if (saveBtn)   { saveBtn.disabled = false; saveBtn.textContent = 'Save'; }
        modal.classList.remove('hidden');

        saveBtn?.addEventListener('click', async function _save() {
            const name = nameInput?.value.trim() || 'My Playlist';
            const addFav = document.getElementById('arc-global-favorites')?.checked ?? true;
            saveBtn.disabled = true;
            saveBtn.textContent = 'Saving…';
            resultEl.className = 'arc-modal-result';
            resultEl.textContent = '';
            try {
                const { apiCall: ac } = await import('./modules/api.js');
                const resp = await ac('/qobuz/prepare-for-arc', {
                    method: 'POST',
                    body: JSON.stringify({
                        item_keys: state.playlist.map(t => t.item_key).filter(Boolean),
                        name,
                        add_to_favorites: addFav,
                    }),
                });
                resultEl.className = 'arc-modal-result arc-modal-result--success';
                resultEl.textContent = `✓ Saved as Qobuz playlist — available in Roon Arc (${resp.saved || 0} tracks, ${resp.skipped || 0} skipped)`;
                saveBtn.textContent = 'Saved';
            } catch (e) {
                resultEl.className = 'arc-modal-result arc-modal-result--error';
                resultEl.textContent = 'Error: ' + e.message;
                saveBtn.disabled = false;
                saveBtn.textContent = 'Save';
            }
            // Remove one-time listener after first save attempt
            saveBtn.removeEventListener('click', _save);
        }, { once: true });
    });

    document.getElementById('arc-global-close')?.addEventListener('click', () => {
        document.getElementById('arc-global-modal')?.classList.add('hidden');
    });
    document.getElementById('arc-global-cancel')?.addEventListener('click', () => {
        document.getElementById('arc-global-modal')?.classList.add('hidden');
    });
    document.getElementById('arc-global-modal')?.addEventListener('click', e => {
        if (e.target === document.getElementById('arc-global-modal')) {
            document.getElementById('arc-global-modal').classList.add('hidden');
        }
    });
}

// Expose dismissArcModal for inline usage
window.dismissArcModal = () => document.getElementById('arc-global-modal')?.classList.add('hidden');

// Refresh button for playlists view
document.addEventListener('click', e => {
    if (e.target?.id === 'playlists-refresh-btn') {
        initViewModule('playlists');
    }
});

// Show arc button when playlist results are shown (whenever state.playlist changes)
const _originalUpdatePlaylist = window._originalUpdatePlaylist;
// Hook into hash changes to show/hide save-for-arc btn
window.addEventListener('hashchange', () => {
    const arcBtn = document.getElementById('save-for-arc-btn');
    if (arcBtn) arcBtn.classList.toggle('hidden', !state.playlist?.length);
});

// =============================================================================
// Globals for inline HTML event handlers (onclick="...", etc.)
// =============================================================================

window.artPlaceholderHtml  = artPlaceholderHtml;
window.hideError           = hideError;
window.hideSuccess         = hideSuccess;
window.hideSuccessModal    = hideSuccessModal;
window.dismissSuccessModal = dismissSuccessModal;
window.dismissClientPicker = dismissClientPicker;
window.dismissPlayChoice   = dismissPlayChoice;
window.dismissPlaySuccess  = dismissPlaySuccess;
window.closeBottomSheet    = closeBottomSheet;
