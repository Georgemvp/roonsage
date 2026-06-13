// =============================================================================
// Router / Navigation
// =============================================================================

import { state } from './state.js';
import { apiCall } from './api.js';
import { updateView, updateMode, updateStep, resetPlaylistState, updatePlaylist, showError } from './ui.js';
import { renderHistoryFeed } from './history.js';
// recommend.js (1178 lines) and playlist.js (703 lines) are lazy-loaded inside
// the route handlers that need them — keeps them out of the bootstrap graph.

// React microfrontend mount helper.
//
// New views (Dashboard, LibraryHealth, Personas, AutomationBuilder, SonicRadio)
// are built with Vite + React + TS in frontend/react/. The Docker build copies
// the bundle to /app/react-dist/ (outside the frontend/ bind mount) and FastAPI
// mounts it at /static/react/. The Vite output puts assets in dist/assets/, so
// the runtime URL is /static/react/assets/main.js — that script attaches
// `window.RoonSageReact = { mount, unmount }`.
//
// We import the bundle once on first React-view navigation and reuse the global
// for subsequent mounts/unmounts. The container is the .rs-react-host div
// inside each `<div id="<view>-view" class="view">` shell.
let _reactBundlePromise = null;
function _loadReactBundle() {
    if (_reactBundlePromise) return _reactBundlePromise;
    const v = window.ROONSAGE_VERSION || 'dev';
    _reactBundlePromise = import(`/static/react/assets/main.js?v=${v}`)
        .catch((err) => {
            console.warn('React bundle failed to load:', err);
            _reactBundlePromise = null;
            throw err;
        });
    return _reactBundlePromise;
}

// Track the currently mounted React host so we can unmount it on view-change.
let _activeReactHost = null;

export async function mountReactView(viewName) {
    const host = document.querySelector(`#${viewName}-view .rs-react-host`);
    if (!host) {
        console.warn(`No React host for view "${viewName}"`);
        return;
    }
    try {
        await _loadReactBundle();
        if (!window.RoonSageReact) {
            console.warn('RoonSageReact global missing after bundle load');
            return;
        }
        if (_activeReactHost && _activeReactHost !== host) {
            window.RoonSageReact.unmount(_activeReactHost);
        }
        window.RoonSageReact.mount(viewName, host);
        _activeReactHost = host;
    } catch (e) {
        host.innerHTML = `<div style="padding:32px;color:#f87171">React-view kon niet laden — ${e.message}</div>`;
    }
}

export function unmountActiveReactView() {
    if (_activeReactHost && window.RoonSageReact) {
        window.RoonSageReact.unmount(_activeReactHost);
        _activeReactHost = null;
    }
}

const REACT_VIEWS = new Set([
    'dashboard',
    'library-health',
    'personas',
    'automation-builder',
    'sonic-radio',
]);

// View-init imports are dynamic — each module only loads when the user
// navigates to that view (see _loadView below).
export const VIEW_MODULES = {
    'recommend':   () => import('./recommend.js').then(m => m.initRecommendView()),
    'playlists':   () => import('./playlists.js').then(m => m.initPlaylistsView()),
    'taste':       () => import('./taste.js').then(m => m.initTasteView()),
    'discovery':   () => import('./discovery.js').then(m => m.initDiscoveryView()),
    'watchlist':   () => import('./watchlist.js').then(m => m.initWatchlistView()),
    'automations': () => import('./automations.js').then(m => m.initAutomationsView()),
    'dj-set':      () => import('./dj-set.js').then(m => m.initDJSetView()),
    'enrichment':  () => import('./enrichment.js').then(m => m.initEnrichmentView()),
    'music-map':   () => import('./music-map.js').then(m => m.initMusicMapView()),
    'song-paths':  () => import('./song-paths.js').then(m => m.initSongPathsView()),
    'alchemy':     () => import('./alchemy.js').then(m => m.initAlchemyView()),
    'circadian':   () => import('./circadian.js').then(m => m.initCircadianView()),
    'circadian-auto': () => import('./circadian-auto.js').then(m => m.initCircadianAutoView()),
    'clap-search': () => import('./clap-search.js').then(m => m.initClapSearchView()),
    'lyrics-search': () => import('./lyrics-search.js').then(m => m.initLyricsSearchView()),
    'sonic-fingerprint': () => import('./sonic-fingerprint.js').then(m => m.initSonicFingerprintView()),
    'journal':     () => import('./journal.js').then(m => m.initJournalView()),
    'logs':        () => import('./logs.js').then(m => m.initLogsView()),
    'workers':     () => import('./workers.js').then(m => m.initWorkersView()),
    'stats':       () => import('./stats.js').then(m => m.initStatsView()),
};

export const HASH_TO_VIEW = {
    'home': 'home',
    'playlist-prompt': 'create',
    'playlist-seed': 'create',
    'recommend-album': 'recommend',
    'settings': 'settings',
    'result': 'result',
    'playlists': 'playlists',
    'taste': 'taste',
    'discovery': 'discovery',
    'watchlist': 'watchlist',
    'automations': 'automations',
    'dj-set': 'dj-set',
    'enrichment': 'enrichment',
    'music-map': 'music-map',
    'song-paths': 'song-paths',
    'alchemy': 'alchemy',
    'circadian': 'circadian',
    'circadian-auto': 'circadian-auto',
    'clap-search': 'clap-search',
    'lyrics-search': 'lyrics-search',
    'sonic-fingerprint': 'sonic-fingerprint',
    'journal': 'journal',
    'logs': 'logs',
    'workers': 'workers',
    'stats': 'stats',
    // React-backed views (Tier 0+)
    'dashboard': 'dashboard',
    'library-health': 'library-health',
    'personas': 'personas',
    'automation-builder': 'automation-builder',
    'sonic-radio': 'sonic-radio',
    // Backward compat
    'make-playlist': 'create',
};
export const HASH_TO_MODE = {
    'playlist-prompt': 'prompt',
    'playlist-seed': 'seed',
    'make-playlist': 'prompt',
};
export const VIEW_TO_HASH = {
    'home': 'home',
    'create': null,  // determined by mode
    'recommend': 'recommend-album',
    'settings': 'settings',
    'playlists': 'playlists',
    'taste': 'taste',
    'discovery': 'discovery',
    'watchlist': 'watchlist',
    'automations': 'automations',
    'dj-set': 'dj-set',
    'enrichment': 'enrichment',
    'music-map': 'music-map',
    'song-paths': 'song-paths',
    'alchemy': 'alchemy',
    'circadian': 'circadian',
    'circadian-auto': 'circadian-auto',
    'clap-search': 'clap-search',
    'lyrics-search': 'lyrics-search',
    'sonic-fingerprint': 'sonic-fingerprint',
    'journal': 'journal',
    'logs': 'logs',
    'workers': 'workers',
    'stats': 'stats',
    // React-backed views
    'dashboard': 'dashboard',
    'library-health': 'library-health',
    'personas': 'personas',
    'automation-builder': 'automation-builder',
    'sonic-radio': 'sonic-radio',
};

export function hashForCurrentState() {
    if (state.view === 'create') {
        return state.mode === 'seed' ? 'playlist-seed' : 'playlist-prompt';
    }
    return VIEW_TO_HASH[state.view] || 'home';
}

export function viewFromHash() {
    const hash = location.hash.slice(1).split('/')[0]; // prefix-match for future deep links
    return HASH_TO_VIEW[hash] || 'home';
}

export function modeFromHash() {
    const hash = location.hash.slice(1).split('/')[0];
    return HASH_TO_MODE[hash] || 'prompt';
}

export function navigateTo(view, mode) {
    // During setup wizard, only allow navigation to settings
    if (state.setup.active && view !== 'settings' && view !== 'home') return;
    const viewChanged = state.view !== view;
    const modeChanged = mode && state.mode !== mode;
    if (!viewChanged && !modeChanged) return;
    if (mode) state.mode = mode;
    state.view = view;
    updateView();
    // Reset results-specific layout when leaving a results view
    if (viewChanged) {
        const appEl = document.querySelector('.app');
        if (appEl) appEl.classList.remove('app--wide');
        const appFooter = document.querySelector('.app-footer');
        if (appFooter) appFooter.classList.remove('app-footer--results');
        // Reset stale state when arriving at a feature view from elsewhere
        if (view === 'create' && state.step !== 'input') {
            resetPlaylistState();
        }
        if (view === 'recommend' && state.rec.step !== 'prompt') {
            import('./recommend.js').then(m => m.resetRecState());
        }
    }
    if (modeChanged) {
        state.step = 'input';
        updateMode();
        updateStep();
    }
    // Leaving a React view: unmount so its WebSocket subscriptions and timers
    // are released. Mount happens below for the new view.
    if (viewChanged && !REACT_VIEWS.has(view)) {
        unmountActiveReactView();
    }

    if (view === 'settings') {
        import('./playlist.js').then(m => m.loadSettings());
        import('./scheduler.js').then(m => m.initSchedulerSection());
    } else if (view === 'home') {
        renderHistoryFeed();
        import('./home-listen.js').then(m => m.loadHomeListenFeed());
    } else if (REACT_VIEWS.has(view)) {
        mountReactView(view);
    } else if (VIEW_MODULES[view]) {
        VIEW_MODULES[view]();
    }
}

export async function loadSavedResult(resultId) {
    try {
        const data = await apiCall(`/results/${encodeURIComponent(resultId)}`);

        if (data.type === 'song_path') {
            // Navigate to Song Paths view and restore the saved result
            window.location.hash = 'song-paths';
            import('./song-paths.js').then(m => m.queuePathRestore(data.snapshot));
            window.scrollTo(0, 0);
            return;
        } else if (data.type === 'album_recommendation') {
            // Populate recommend state from snapshot
            state.view = 'recommend';
            state.rec.recommendations = data.snapshot.recommendations || [];
            state.rec.tokenCount = data.snapshot.token_count || 0;
            state.rec.estimatedCost = data.snapshot.estimated_cost || 0;
            state.rec.researchWarning = data.snapshot.research_warning || null;
            state.rec.prompt = data.prompt;
            state.rec.step = 'results';
            state.rec.loading = false;

            updateView();
            const recMod = await import('./recommend.js');
            recMod.updateRecStep();
            recMod.renderRecResults();
        } else {
            // prompt_playlist or seed_playlist — populate playlist state
            state.view = 'create';
            state.mode = data.type === 'seed_playlist' ? 'seed' : 'prompt';
            state.step = 'results';

            const snapshot = data.snapshot;
            state.playlist = snapshot.tracks || [];
            state.playlistTitle = snapshot.playlist_title || data.title;
            state.narrative = snapshot.narrative || '';
            state.trackReasons = snapshot.track_reasons || {};
            state.playlistName = snapshot.playlist_title || data.title;
            state.tokenCount = snapshot.token_count || 0;
            state.estimatedCost = snapshot.estimated_cost || 0;
            state.selectedTrackKey = null;

            updateView();
            updateMode();
            updateStep();
            updatePlaylist();
        }

        window.scrollTo(0, 0);
        const rsMain = document.querySelector('.rs-main');
        if (rsMain) rsMain.scrollTop = 0;
    } catch (e) {
        // Result not found or deleted — show home with message
        console.warn('Failed to load saved result:', e);
        state.view = 'home';
        history.replaceState(null, '', '#home');
        updateView();
        showError('This result is no longer available.');
    }
}
