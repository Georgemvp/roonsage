// =============================================================================
// Router / Navigation
// =============================================================================

import { state } from './state.js';
import { apiCall } from './api.js';
import { updateView, updateMode, updateStep, resetPlaylistState, updatePlaylist, showError } from './ui.js';
import { resetRecState, initRecommendView, updateRecStep, renderRecResults } from './recommend.js';
import { loadSettings } from './playlist.js';
import { renderHistoryFeed } from './history.js';
import { initPlaylistsView } from './playlists.js';
import { initTasteView } from './taste.js';
import { initDiscoveryView } from './discovery.js';
import { initWatchlistView } from './watchlist.js';
import { initSchedulerSection } from './scheduler.js';
import { initAutomationsView } from './automations.js';
import { initDJSetView } from './dj-set.js';
import { initEnrichmentView } from './enrichment.js';

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
            resetRecState();
        }
    }
    if (modeChanged) {
        state.step = 'input';
        updateMode();
        updateStep();
    }
    if (view === 'settings') {
        loadSettings();
        initSchedulerSection();
    } else if (view === 'recommend') {
        initRecommendView();
    } else if (view === 'home') {
        renderHistoryFeed();
    } else if (view === 'playlists') {
        initPlaylistsView();
    } else if (view === 'taste') {
        initTasteView();
    } else if (view === 'discovery') {
        initDiscoveryView();
    } else if (view === 'watchlist') {
        initWatchlistView();
    } else if (view === 'automations') {
        initAutomationsView();
    } else if (view === 'dj-set') {
        initDJSetView();
    } else if (view === 'enrichment') {
        initEnrichmentView();
    }
}

export async function loadSavedResult(resultId) {
    try {
        const data = await apiCall(`/results/${encodeURIComponent(resultId)}`);

        if (data.type === 'album_recommendation') {
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
            updateRecStep();
            renderRecResults();
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
