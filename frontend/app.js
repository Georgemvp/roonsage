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
import { setupRecEventListeners, initRecommendView, renderPromptPills, PLAYLIST_PROMPT_GROUPS } from './modules/recommend.js';
import { setupHistoryEventListeners }     from './modules/history.js';
import { enterSetupWizard }               from './modules/setup-wizard.js';
import { startNowPlaying }                from './modules/nowplaying.js';
import { initPlaylistsView }              from './modules/playlists.js';
import { initTasteView }                  from './modules/taste.js';
import { initTemplates }                  from './modules/templates.js';
import { initSchedulerSection }           from './modules/scheduler.js';
import { startActivityMonitor }           from './modules/activity.js';
import { initPWA }                        from './modules/pwa.js';

// =============================================================================
// Theme Toggle
// =============================================================================

function initThemeToggle() {
    let saved = 'dark';
    try { saved = localStorage.getItem('roonsage-theme') || 'dark'; } catch (e) {}
    document.documentElement.setAttribute('data-theme', saved);
    _updateThemeIcon(saved);

    document.getElementById('theme-toggle-btn')?.addEventListener('click', () => {
        const current = document.documentElement.getAttribute('data-theme') || 'dark';
        const next = current === 'dark' ? 'light' : 'dark';
        document.documentElement.setAttribute('data-theme', next);
        try { localStorage.setItem('roonsage-theme', next); } catch (e) {}
        _updateThemeIcon(next);
    });
}

function _updateThemeIcon(theme) {
    const dark  = document.getElementById('theme-icon-dark');
    const light = document.getElementById('theme-icon-light');
    if (dark)  dark.style.display  = theme === 'dark'  ? 'block' : 'none';
    if (light) light.style.display = theme === 'light' ? 'block' : 'none';
}

// =============================================================================
// Home Preview — live data for feature cards and taste snapshot
// =============================================================================

async function loadHomePreview() {
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
            if (peakHour != null) {
                const h = peakHour;
                const ampm = h >= 12 ? `${h > 12 ? h - 12 : h} PM` : `${h} AM`;
                const peakEl = document.getElementById('home-peak-hour');
                if (peakEl) peakEl.textContent = ampm;
            }
            const peakDay = taste.peak_day ?? taste.listening_patterns?.peak_day ?? null;
            if (peakDay) {
                const dayEl = document.getElementById('home-peak-day');
                if (dayEl) dayEl.textContent = peakDay.charAt(0).toUpperCase() + peakDay.slice(1) + 's';
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

    // Initialize theme toggle first (before any rendering)
    initThemeToggle();

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
    if (state.view === 'recommend') {
        initRecommendView();
    } else if (state.view === 'home') {
        renderHistoryFeed();
        loadHomePreview(); // fire-and-forget; populates feature card previews
    } else if (state.view === 'playlists') {
        initPlaylistsView();
    } else if (state.view === 'taste') {
        initTasteView();
    }

    // Start Now Playing polling (persistent — runs on all views)
    startNowPlaying();

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
        initPlaylistsView();
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
