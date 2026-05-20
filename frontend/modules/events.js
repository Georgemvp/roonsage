// events.js — Event Listeners and Handler Functions
// =============================================================================

import { state, allGenresSelected, allDecadesSelected } from './state.js';
import { apiCall, searchTracks, analyzeTrack, analyzePrompt, generatePlaylistStream, fetchRoonZones, createPlayQueue, fetchLibraryStats } from './api.js';
import { escapeHtml, trackArtHtml, artPlaceholderHtml } from './utils.js';
import { focusManager } from './focus.js';
import {
    updateView, updateMode, updateStep, updateFilters, updatePlaylist,
    setLoading, showError, hideError, showSuccess, resetPlaylistState,
    renderNarrativeBox, selectTrack, isMobileView, openBottomSheet, updateResultsFooter,
    updateFilterPreview, showProviderSettings, checkOllamaStatus, updateOllamaContextDisplay,
    updateCustomMaxTracks, validateCustomContextInline, validateCustomUrlInline,
    hideSuccessModal, dismissSuccessModal, closeBottomSheet, recalculateCostDisplay
} from './ui.js';
import { markHistoryStale } from './history.js';
import {
    openRecRestartModal, openPlaylistRestartModal,
    dismissRecRestartModal, dismissPlaylistRestartModal,
    handlePlayNow, toggleSaveModeDropdown, setSaveMode,
    refreshClientList, dismissPlayChoice, dismissClientPicker, dismissPlaySuccess,
    executePlayQueue, handlePlaySuccessNewPlaylist
} from './instant-queue.js';
import {
    loadSettings, handleRefinePlaylist, handleRefineSubmit, handleSaveToQobuz, handleSavePlaylist,
    handleSaveSettings, handleValidateQobuz, generatePlaylistName
} from './playlist.js';
import { showTimedStepLoading, showStepLoading, hideStepLoading, updateStepProgress, PLAYLIST_STEPS, PLAYLIST_STEP_MAP } from './loading.js';
import { resetRecState, initRecommendView, PLAYLIST_PROMPT_GROUPS, shufflePromptPills, handlePlaylistRefineNext, setupQuestionEventHandlers, renderPlaylistQuestions } from './recommend.js';
import { checkLibraryStatus, handleRefreshLibrary, showSyncModal } from './library.js';
import { viewFromHash, modeFromHash, navigateTo, loadSavedResult } from './router.js';

// pendingNavHash is declared here and exported so instant-queue.js can read/set it
export let pendingNavHash = null;
export function setPendingNavHash(v) { pendingNavHash = v; }

// =============================================================================
// Event Handlers
// =============================================================================

export function setupEventListeners() {
    // Unified navigation via data-nav attributes (header nav + home cards)
    document.querySelectorAll('[data-nav]').forEach(el => {
        el.addEventListener('click', () => {
            const hash = el.dataset.nav;
            // Special case: clicking Recommend Album while already there
            if (hash === 'recommend-album' && state.view === 'recommend') {
                if (state.rec.step !== 'prompt' || state.rec.loading) {
                    if (!state.rec.sessionId) {
                        // Saved result — nothing to lose, go straight to step 1
                        resetRecState();
                        history.replaceState(null, '', '#recommend-album');
                    } else {
                        openRecRestartModal();
                    }
                }
                return;
            }
            // Special case: clicking a playlist flow while already in that flow
            if (state.view === 'create') {
                const isCurrentMode = (hash === 'playlist-prompt' && state.mode === 'prompt') ||
                                      (hash === 'playlist-seed' && state.mode === 'seed');
                if (isCurrentMode && (state.step !== 'input' || state.loading)) {
                    if (state.step === 'results') {
                        // Results page — playlist already generated, nothing to lose
                        resetPlaylistState();
                        location.hash = '#' + hash;
                    } else {
                        openPlaylistRestartModal();
                    }
                    return;
                }
            }
            // Warn if navigating away from a mid-flow state
            if (state.view === 'create' && ((state.step !== 'input' && state.step !== 'results') || state.loading)) {
                pendingNavHash = hash;
                openPlaylistRestartModal();
                return;
            }
            if (state.view === 'recommend' && ((state.rec.step !== 'prompt' && state.rec.step !== 'results') || state.rec.loading)) {
                pendingNavHash = hash;
                openRecRestartModal();
                return;
            }
            location.hash = '#' + hash;
            // Close dropdown if open
            const dropdown = document.querySelector('.nav-dropdown');
            dropdown?.classList.remove('open');
            dropdown?.querySelector('.nav-dropdown-trigger')?.setAttribute('aria-expanded', 'false');
        });
    });

    // Dropdown toggle
    document.querySelector('.nav-dropdown-trigger')?.addEventListener('click', (e) => {
        e.stopPropagation();
        const dropdown = e.target.closest('.nav-dropdown');
        const isOpen = dropdown.classList.contains('open');
        dropdown.classList.toggle('open', !isOpen);
        e.target.closest('.nav-dropdown-trigger').setAttribute('aria-expanded', !isOpen);
    });

    // Close dropdown on outside click
    document.addEventListener('click', (e) => {
        if (!e.target.closest('.nav-dropdown')) {
            const dropdown = document.querySelector('.nav-dropdown');
            dropdown?.classList.remove('open');
            dropdown?.querySelector('.nav-dropdown-trigger')?.setAttribute('aria-expanded', 'false');
        }
    });

    // Close dropdown on Escape
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            const dropdown = document.querySelector('.nav-dropdown');
            if (dropdown?.classList.contains('open')) {
                dropdown.classList.remove('open');
                dropdown.querySelector('.nav-dropdown-trigger')?.setAttribute('aria-expanded', 'false');
                dropdown.querySelector('.nav-dropdown-trigger')?.focus();
            }
        }
    });

    // Settings links in hints (use event delegation for dynamically inserted links)
    document.body.addEventListener('click', e => {
        const link = e.target.closest('.llm-required-hint a[data-view]');
        if (link) {
            e.preventDefault();
            const hash = link.dataset.view === 'settings' ? 'settings' : null;
            if (hash) location.hash = '#' + hash;
        }
    });

    // Hash-based routing for top-level views
    window.addEventListener('hashchange', () => {
        const hash = location.hash.slice(1);
        if (hash.startsWith('result/')) {
            const resultId = hash.split('/')[1];
            if (resultId) {
                loadSavedResult(resultId);
                return;
            }
        }
        const view = viewFromHash();
        const mode = modeFromHash();
        navigateTo(view, mode);
    });

    // Playlist prompt pills
    const playlistPillContainer = document.getElementById('playlist-prompt-pills');
    if (playlistPillContainer) {
        playlistPillContainer.addEventListener('click', e => {
            const pill = e.target.closest('.prompt-pill');
            if (!pill) return;
            document.getElementById('prompt-input').value = pill.textContent.trim();
        });
    }
    const playlistShuffleBtn = document.getElementById('playlist-prompt-shuffle');
    if (playlistShuffleBtn) {
        playlistShuffleBtn.addEventListener('click', () => shufflePromptPills('playlist-prompt-pills', PLAYLIST_PROMPT_GROUPS));
    }

    // Prompt analysis
    document.getElementById('analyze-prompt-btn').addEventListener('click', handleAnalyzePrompt);

    // Refine step (prompt mode)
    document.getElementById('refine-next-btn')?.addEventListener('click', handlePlaylistRefineNext);
    const playlistQuestionsContainer = document.getElementById('playlist-questions-container');
    if (playlistQuestionsContainer) {
        const playlistQState = {
            get questions() { return state.questions; },
            get answers() { return state.questionAnswers; },
            get answerTexts() { return state.questionTexts; },
        };
        setupQuestionEventHandlers(playlistQuestionsContainer, playlistQState, renderPlaylistQuestions);
    }

    // Track search
    document.getElementById('search-tracks-btn').addEventListener('click', handleSearchTracks);
    document.getElementById('track-search-input').addEventListener('keypress', e => {
        if (e.key === 'Enter') handleSearchTracks();
    });

    // Continue to filters
    document.getElementById('continue-to-filters-btn').addEventListener('click', handleContinueToFilters);

    // Genre toggle all
    document.getElementById('genre-toggle-all').addEventListener('click', () => {
        state.selectedGenres = allGenresSelected() ? [] : state.availableGenres.map(g => g.name);
        updateFilters();
        updateFilterPreview();
    });

    // Genre chips
    document.getElementById('genre-chips').addEventListener('click', e => {
        const chip = e.target.closest('.chip');
        if (!chip) return;

        const genre = chip.dataset.genre;
        if (state.selectedGenres.includes(genre)) {
            state.selectedGenres = state.selectedGenres.filter(g => g !== genre);
        } else {
            state.selectedGenres.push(genre);
        }
        updateFilters();
        updateFilterPreview();
    });

    // Decade toggle all
    document.getElementById('decade-toggle-all').addEventListener('click', () => {
        state.selectedDecades = allDecadesSelected() ? [] : state.availableDecades.map(d => d.name);
        updateFilters();
        updateFilterPreview();
    });

    // Decade chips
    document.getElementById('decade-chips').addEventListener('click', e => {
        const chip = e.target.closest('.chip');
        if (!chip) return;

        const decade = chip.dataset.decade;
        if (state.selectedDecades.includes(decade)) {
            state.selectedDecades = state.selectedDecades.filter(d => d !== decade);
        } else {
            state.selectedDecades.push(decade);
        }
        updateFilters();
        updateFilterPreview();
    });

    // Track count (local recalculation - no API call needed)
    document.querySelectorAll('.count-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            state.trackCount = parseInt(btn.dataset.count);
            updateFilters();
            recalculateCostDisplay();
        });
    });

    // Note: limit-btn listeners are set up dynamically in updateTrackLimitButtons()

    // Exclude live checkbox
    document.getElementById('exclude-live').addEventListener('change', e => {
        state.excludeLive = e.target.checked;
        updateFilterPreview();
    });

    // Minimum rating buttons
    document.querySelectorAll('.rating-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            state.minRating = parseInt(btn.dataset.rating);
            updateFilters();
            updateFilterPreview();
        });
    });

    // Generate playlist
    document.getElementById('generate-btn').addEventListener('click', handleGenerate);

    // Regenerate
    document.getElementById('regenerate-btn').addEventListener('click', handleGenerate);

    // Source mode cards
    document.getElementById('source-mode-cards')?.addEventListener('click', e => {
        const card = e.target.closest('.source-card');
        if (!card || card.disabled) return;
        state.sourceMode = card.dataset.source;
        renderSourceModeStep();
    });

    // Qobuz percentage slider
    document.getElementById('qobuz-percentage-slider')?.addEventListener('input', e => {
        state.qobuzPercentage = parseInt(e.target.value);
        const label = document.getElementById('qobuz-pct-label');
        if (label) label.textContent = state.qobuzPercentage;
    });

    // Source step continue button
    document.getElementById('source-continue-btn')?.addEventListener('click', handleContinueFromSource);

    // Back to filters
    document.getElementById('back-to-filters-btn').addEventListener('click', () => {
        state.step = 'filters';
        updateStep();
    });

    // Remove track (with selection management)
    document.getElementById('playlist-tracks').addEventListener('click', e => {
        const removeBtn = e.target.closest('.track-remove');
        if (!removeBtn) return;

        const itemKey = removeBtn.dataset.itemKey;
        const removedIndex = state.playlist.findIndex(t => t.item_key === itemKey);
        state.playlist = state.playlist.filter(t => t.item_key !== itemKey);

        // If removed track was selected, auto-select next or first
        if (state.selectedTrackKey === itemKey) {
            if (state.playlist.length > 0) {
                const nextIndex = Math.min(removedIndex, state.playlist.length - 1);
                state.selectedTrackKey = state.playlist[nextIndex].item_key;
            } else {
                state.selectedTrackKey = null;
            }
        }

        updatePlaylist();
    });

    // Save playlist
    document.getElementById('save-playlist-btn').addEventListener('click', handleSavePlaylist);

    // Save settings
    document.getElementById('save-settings-btn').addEventListener('click', handleSaveSettings);

    // Validate Qobuz credentials
    document.getElementById('validate-qobuz-btn')?.addEventListener('click', handleValidateQobuz);

    // Validate ListenBrainz token
    document.getElementById('validate-lb-btn')?.addEventListener('click', async () => {
        const btn = document.getElementById('validate-lb-btn');
        const resultEl = document.getElementById('lb-validate-result');
        const token = document.getElementById('lb-token')?.value?.trim();
        const username = document.getElementById('lb-username')?.value?.trim();
        if (!token) {
            if (resultEl) resultEl.textContent = 'Voer een token in.';
            return;
        }
        if (btn) { btn.disabled = true; btn.textContent = 'Valideren...'; }
        try {
            const res = await fetch('/api/setup/validate-listenbrainz', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ token, username }),
            });
            const data = await res.json();
            if (data.valid) {
                if (resultEl) resultEl.innerHTML = `<span style="color:#4caf50">✓ Verbonden als <strong>${data.user_name || username}</strong></span>`;
                const dot = document.querySelector('#lb-settings-status .status-dot');
                const txt = document.querySelector('#lb-settings-status .status-text');
                if (dot) { dot.style.background = '#4caf50'; }
                if (txt) txt.textContent = `Verbonden als ${data.user_name || username}`;
            } else {
                if (resultEl) resultEl.innerHTML = `<span style="color:#e57373">✗ ${data.message || 'Ongeldig token'}</span>`;
            }
        } catch (e) {
            if (resultEl) resultEl.textContent = 'Fout: ' + e.message;
        }
        if (btn) { btn.disabled = false; btn.textContent = 'Valideren'; }
    });

    // ── Last.fm: Validate credentials ──────────────────────────────────────
    document.getElementById('validate-lastfm-btn')?.addEventListener('click', async () => {
        const btn      = document.getElementById('validate-lastfm-btn');
        const resultEl = document.getElementById('lastfm-validate-result');
        const apiKey   = document.getElementById('lastfm-api-key')?.value?.trim();
        const apiSecret = document.getElementById('lastfm-api-secret')?.value?.trim();
        const username = document.getElementById('lastfm-username')?.value?.trim();

        if (!apiKey || !apiSecret || !username) {
            if (resultEl) resultEl.textContent = 'Vul API key, API secret en gebruikersnaam in.';
            return;
        }
        if (btn) { btn.disabled = true; btn.textContent = 'Valideren...'; }
        try {
            const res = await fetch('/api/setup/validate-lastfm', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ api_key: apiKey, api_secret: apiSecret, username }),
            });
            const data = await res.json();
            if (data.valid) {
                if (resultEl) resultEl.innerHTML = `<span style="color:#4caf50">✓ Verbonden als <strong>${data.username || username}</strong>. Klik nu op Autoriseren voor scrobbling.</span>`;
                const dot = document.querySelector('#lastfm-settings-status .status-dot');
                const txt = document.querySelector('#lastfm-settings-status .status-text');
                if (dot) dot.style.background = '#4caf50';
                if (txt) txt.textContent = `Verbonden als ${data.username || username}`;
            } else {
                if (resultEl) resultEl.innerHTML = `<span style="color:#e57373">✗ ${data.message || data.error || 'Ongeldige gegevens'}</span>`;
            }
        } catch (e) {
            if (resultEl) resultEl.textContent = 'Fout: ' + e.message;
        }
        if (btn) { btn.disabled = false; btn.textContent = 'Valideren'; }
    });

    // ── Last.fm: Authorise (get token + open auth URL) ──────────────────────
    let _lastfmPendingToken = null;
    document.getElementById('lastfm-auth-btn')?.addEventListener('click', async () => {
        const btn      = document.getElementById('lastfm-auth-btn');
        const resultEl = document.getElementById('lastfm-validate-result');
        const step2    = document.getElementById('lastfm-auth-step2');
        const authLink = document.getElementById('lastfm-auth-link');

        if (btn) { btn.disabled = true; btn.textContent = 'Token ophalen...'; }
        try {
            const res  = await fetch('/api/intelligence/lastfm/auth/token', { method: 'POST' });
            const data = await res.json();
            if (!res.ok) {
                if (resultEl) resultEl.innerHTML = `<span style="color:#e57373">✗ ${data.detail || 'Kon geen token ophalen'}</span>`;
                return;
            }
            _lastfmPendingToken = data.token;
            if (authLink) { authLink.href = data.auth_url; }
            if (step2) step2.style.display = '';
            // Open the auth URL automatically
            window.open(data.auth_url, '_blank');
            if (resultEl) resultEl.innerHTML = `<span style="color:#e5a00d">🔗 Autorisatiepagina geopend. Keer terug en klik op "Sessie voltooien".</span>`;
        } catch (e) {
            if (resultEl) resultEl.textContent = 'Fout: ' + e.message;
        }
        if (btn) { btn.disabled = false; btn.textContent = 'Autoriseren'; }
    });

    // ── Last.fm: Complete auth (exchange token for session key) ────────────
    document.getElementById('lastfm-complete-auth-btn')?.addEventListener('click', async () => {
        const btn      = document.getElementById('lastfm-complete-auth-btn');
        const resultEl = document.getElementById('lastfm-auth-result');
        const step2    = document.getElementById('lastfm-auth-step2');

        if (!_lastfmPendingToken) {
            if (resultEl) resultEl.textContent = 'Geen token beschikbaar. Klik eerst op Autoriseren.';
            return;
        }
        if (btn) { btn.disabled = true; btn.textContent = 'Sessie ophalen...'; }
        try {
            const res  = await fetch('/api/intelligence/lastfm/auth/session', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ token: _lastfmPendingToken }),
            });
            const data = await res.json();
            if (!res.ok) {
                if (resultEl) resultEl.innerHTML = `<span style="color:#e57373">✗ ${data.detail || 'Sessie ophalen mislukt'}</span>`;
                return;
            }
            _lastfmPendingToken = null;
            if (step2) step2.style.display = 'none';
            const dot = document.querySelector('#lastfm-settings-status .status-dot');
            const txt = document.querySelector('#lastfm-settings-status .status-text');
            if (dot) dot.style.background = '#4caf50';
            if (txt) txt.textContent = `Verbonden als ${data.username}`;
            const validateResult = document.getElementById('lastfm-validate-result');
            if (validateResult) validateResult.innerHTML = `<span style="color:#4caf50">✓ Last.fm sessie actief voor <strong>${data.username}</strong>. Scrobbling ingeschakeld!</span>`;
        } catch (e) {
            if (resultEl) resultEl.textContent = 'Fout: ' + e.message;
        }
        if (btn) { btn.disabled = false; btn.textContent = 'Sessie voltooien'; }
    });

    // Success modal - Start New Playlist
    document.getElementById('new-playlist-btn').addEventListener('click', hideSuccessModal);

    // Provider selection change
    document.getElementById('llm-provider').addEventListener('change', (e) => {
        showProviderSettings(e.target.value);
    });

    // Library refresh link
    const refreshLink = document.getElementById('footer-refresh-link');
    if (refreshLink) {
        refreshLink.addEventListener('click', (e) => {
            e.preventDefault();
            handleRefreshLibrary();
        });
    }

    // Ollama URL change - trigger status check
    let ollamaUrlTimeout = null;
    document.getElementById('ollama-url').addEventListener('input', (e) => {
        // Debounce the status check
        if (ollamaUrlTimeout) clearTimeout(ollamaUrlTimeout);
        ollamaUrlTimeout = setTimeout(() => {
            const url = e.target.value.trim();
            if (url) {
                checkOllamaStatus(url);
            }
        }, 500);
    });

    // Ollama model selection change - update context display
    document.getElementById('ollama-model-analysis').addEventListener('change', async (e) => {
        const url = document.getElementById('ollama-url').value.trim();
        const model = e.target.value;
        if (url && model) {
            await updateOllamaContextDisplay(url, model);
        }
    });

    // Custom context window change - update max tracks display and validate inline
    document.getElementById('custom-context-window').addEventListener('input', () => {
        updateCustomMaxTracks();
        validateCustomContextInline();
    });

    // Custom URL validation on blur
    document.getElementById('custom-url').addEventListener('blur', () => {
        validateCustomUrlInline();
    });

    // Play Now button
    document.getElementById('play-now-btn').addEventListener('click', handlePlayNow);

    // Playlist Start Over link
    document.getElementById('playlist-start-over')?.addEventListener('click', resetPlaylistState);

    // Playlist Refinement
    document.getElementById('refine-playlist-btn')?.addEventListener('click', handleRefinePlaylist);
    document.getElementById('refine-submit-btn')?.addEventListener('click', handleRefineSubmit);
    document.getElementById('save-to-qobuz-btn')?.addEventListener('click', handleSaveToQobuz);
    document.getElementById('refine-input')?.addEventListener('keydown', (e) => {
        // Ctrl+Enter / Cmd+Enter submits the refinement
        if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
            e.preventDefault();
            handleRefineSubmit();
        }
    });

    // Refresh clients in client picker modal
    document.getElementById('refresh-clients-btn').addEventListener('click', refreshClientList);

    // Replace Queue / Play Next choice modal buttons
    document.getElementById('replace-queue-btn').addEventListener('click', () => {
        executePlayQueue(state._pendingClientId, 'replace');
    });
    document.getElementById('play-next-btn').addEventListener('click', () => {
        executePlayQueue(state._pendingClientId, 'play_next');
    });

    // Play success modal — Start New Playlist
    document.getElementById('play-success-new-btn').addEventListener('click', handlePlaySuccessNewPlaylist);

    // Save mode dropdown toggle
    document.getElementById('save-mode-dropdown-btn').addEventListener('click', toggleSaveModeDropdown);

    // Save mode option selection (Create / Replace / Append)
    document.querySelectorAll('.save-mode-option').forEach(opt => {
        opt.addEventListener('click', () => setSaveMode(opt.dataset.mode));
    });

    // Bottom sheet close handlers
    const bottomSheet = document.getElementById('bottom-sheet');
    if (bottomSheet) {
        // Close on backdrop tap
        bottomSheet.querySelector('.bottom-sheet-backdrop').addEventListener('click', closeBottomSheet);

        // Close on swipe down (simple implementation)
        let touchStartY = 0;
        const content = bottomSheet.querySelector('.bottom-sheet-content');
        content.addEventListener('touchstart', (e) => {
            touchStartY = e.touches[0].clientY;
        });
        content.addEventListener('touchend', (e) => {
            const touchEndY = e.changedTouches[0].clientY;
            if (touchEndY - touchStartY > 50) {
                closeBottomSheet();
            }
        });
    }

    // Escape key dismisses the topmost visible modal
    document.addEventListener('keydown', (e) => {
        if (e.key !== 'Escape') return;
        const modals = [
            { id: 'playlist-restart-modal', dismiss: dismissPlaylistRestartModal },
            { id: 'rec-restart-modal', dismiss: dismissRecRestartModal },
            { id: 'play-choice-modal', dismiss: dismissPlayChoice },
            { id: 'client-picker-modal', dismiss: dismissClientPicker },
            { id: 'play-success-modal', dismiss: dismissPlaySuccess },
            { id: 'success-modal', dismiss: dismissSuccessModal },
            { id: 'bottom-sheet', dismiss: closeBottomSheet },
        ];
        for (const { id, dismiss } of modals) {
            const el = document.getElementById(id);
            if (el && !el.classList.contains('hidden')) {
                dismiss();
                break;
            }
        }
    });

    // Swipe left/right on main content to switch between top-level tabs (mobile)
    setupSwipeNavigation();
}

// Tab order for swipe navigation (left = forward, right = back)
const SWIPE_TABS = [
    'playlist-prompt',
    'playlists',
    'taste',
    'discovery',
    'settings',
];

function setupSwipeNavigation() {
    const mainEl = document.getElementById('main-content');
    if (!mainEl) return;

    let touchStartX = 0;
    let touchStartY = 0;
    let touchStartTime = 0;

    mainEl.addEventListener('touchstart', (e) => {
        touchStartX = e.touches[0].clientX;
        touchStartY = e.touches[0].clientY;
        touchStartTime = Date.now();
    }, { passive: true });

    mainEl.addEventListener('touchend', (e) => {
        const dx = e.changedTouches[0].clientX - touchStartX;
        const dy = e.changedTouches[0].clientY - touchStartY;
        const elapsed = Date.now() - touchStartTime;

        // Require: mostly horizontal, ≥ 50 px, completed within 400 ms
        if (Math.abs(dx) < 50) return;
        if (Math.abs(dy) > Math.abs(dx) * 0.8) return; // too vertical
        if (elapsed > 400) return;

        // Bail if a modal is open
        const openModal = document.querySelector(
            '.modal-overlay:not(.hidden), #bottom-sheet:not(.hidden)'
        );
        if (openModal) return;

        // Resolve current tab from state
        let currentHash = location.hash.slice(1) || 'home';
        // Normalise create-view hashes to the first tab
        if (currentHash === 'playlist-seed') currentHash = 'playlist-prompt';

        const currentIdx = SWIPE_TABS.indexOf(currentHash);
        if (currentIdx === -1) return; // not a swipeable view

        const nextIdx = dx < 0
            ? Math.min(currentIdx + 1, SWIPE_TABS.length - 1) // swipe left → forward
            : Math.max(currentIdx - 1, 0);                    // swipe right → back

        if (nextIdx === currentIdx) return; // already at boundary

        // Haptic feedback (if supported)
        if (navigator.vibrate) navigator.vibrate(10);

        location.hash = '#' + SWIPE_TABS[nextIdx];
    }, { passive: true });
}

export async function handleAnalyzePrompt() {
    const prompt = document.getElementById('prompt-input').value.trim();
    if (!prompt) {
        showError('Please enter a prompt');
        return;
    }

    state.prompt = prompt;
    // Reset session costs for new flow
    state.sessionTokens = 0;
    state.sessionCost = 0;

    const stepLoader = showTimedStepLoading([
        { id: 'parsing', text: 'Parsing your request...', status: 'active' },
        { id: 'questions', text: 'Crafting questions...', status: 'pending' },
        { id: 'matching', text: 'Matching to your library...', status: 'pending' },
    ]);

    // Fire filter analysis in parallel (cached as a promise for the refine→filters transition)
    state.filterAnalysisPromise = analyzePrompt(prompt).catch(() => null);

    try {
        // Fire question generation (reuse recommend endpoint)
        const data = await apiCall('/recommend/questions', {
            method: 'POST',
            body: JSON.stringify({ prompt }),
        });

        state.questions = data.questions;
        state.questionAnswers = data.questions.map(() => null);
        state.questionTexts = data.questions.map(() => '');

        renderPlaylistQuestions();
        state.step = 'refine';
        updateStep();
    } catch (error) {
        showError(error.message);
    } finally {
        stepLoader.finish();
    }
}

export async function handleSearchTracks() {
    const query = document.getElementById('track-search-input').value.trim();
    if (!query) {
        showError('Please enter a search query');
        return;
    }

    setLoading(true, 'Searching tracks...');

    try {
        const tracks = await searchTracks(query);
        renderSearchResults(tracks);
    } catch (error) {
        showError(error.message);
    } finally {
        setLoading(false);
    }
}

export function renderSearchResults(tracks) {
    const container = document.getElementById('search-results');

    if (!tracks.length) {
        container.innerHTML = '<p class="text-muted">No tracks found</p>';
        return;
    }

    container.innerHTML = tracks.map(track => `
        <div class="search-result-item" data-item-key="${escapeHtml(track.item_key)}"
             role="option" tabindex="0"
             aria-label="${escapeHtml(track.title)} by ${escapeHtml(track.artist)}">
            ${trackArtHtml(track)}
            <div class="track-info">
                <div class="track-title">${escapeHtml(track.title)}</div>
                <div class="track-artist">${escapeHtml(track.artist)} - ${escapeHtml(track.album)}</div>
            </div>
        </div>
    `).join('');

    // Add click and keyboard handlers
    container.querySelectorAll('.search-result-item').forEach(item => {
        item.addEventListener('click', () => selectSeedTrack(item.dataset.itemKey, tracks));
        item.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                selectSeedTrack(item.dataset.itemKey, tracks);
            }
        });
    });
}

export async function selectSeedTrack(itemKey, tracks) {
    // Check if services are configured before proceeding
    if (!state.config?.roon_connected) {
        showError('Connect to Roon in Settings first');
        return;
    }
    if (!state.config?.llm_configured) {
        showError('Configure an LLM provider in Settings to analyze tracks');
        return;
    }

    const track = tracks.find(t => t.item_key === itemKey);
    if (!track) return;

    state.seedTrack = track;
    // Reset session costs for new flow
    state.sessionTokens = 0;
    state.sessionCost = 0;

    const stepLoader = showTimedStepLoading([
        { id: 'metadata', text: 'Loading track metadata...', status: 'active' },
        { id: 'analyzing', text: 'Analyzing musical characteristics...', status: 'pending' },
        { id: 'dimensions', text: 'Generating exploration dimensions...', status: 'pending' },
    ]);

    try {
        const response = await analyzeTrack(track);

        // Track analysis costs
        state.sessionTokens += response.token_count || 0;
        state.sessionCost += response.estimated_cost || 0;

        state.dimensions = response.dimensions;
        state.selectedDimensions = [];

        renderSeedTrack();
        renderDimensions();

        state.step = 'dimensions';
        updateStep();
    } catch (error) {
        showError(error.message);
    } finally {
        stepLoader.finish();
    }
}

export function renderSeedTrack() {
    const container = document.getElementById('selected-track');
    const track = state.seedTrack;

    container.innerHTML = `
        ${trackArtHtml(track)}
        <div class="track-info">
            <div class="track-title">${escapeHtml(track.title)}</div>
            <div class="track-artist">${escapeHtml(track.artist)} - ${escapeHtml(track.album)}</div>
        </div>
    `;
}

export function renderDimensions() {
    const container = document.getElementById('dimensions-list');
    const focusedId = document.activeElement?.dataset?.dimensionId;

    container.innerHTML = state.dimensions.map(dim => {
        const isSelected = state.selectedDimensions.includes(dim.id);
        return `
        <div class="dimension-card ${isSelected ? 'selected' : ''}"
             data-dimension-id="${escapeHtml(dim.id)}"
             role="checkbox" tabindex="0"
             aria-checked="${isSelected}"
             aria-label="${escapeHtml(dim.label)}: ${escapeHtml(dim.description)}">
            <div class="dimension-label">${escapeHtml(dim.label)}</div>
            <div class="dimension-description">${escapeHtml(dim.description)}</div>
        </div>
    `}).join('');

    // Add click and keyboard handlers
    container.querySelectorAll('.dimension-card').forEach(card => {
        const toggle = () => {
            const dimId = card.dataset.dimensionId;
            if (state.selectedDimensions.includes(dimId)) {
                state.selectedDimensions = state.selectedDimensions.filter(d => d !== dimId);
            } else {
                state.selectedDimensions.push(dimId);
            }
            renderDimensions();
        };
        card.addEventListener('click', toggle);
        card.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                toggle();
            }
        });
    });

    if (focusedId) {
        container.querySelector(`[data-dimension-id="${CSS.escape(focusedId)}"]`)?.focus();
    }
}

export function renderSourceModeStep() {
    const cards = document.querySelectorAll('#source-mode-cards .source-card');
    const pctRow = document.getElementById('qobuz-percentage-row');
    const unavailMsg = document.getElementById('qobuz-unavailable-msg');
    const slider = document.getElementById('qobuz-percentage-slider');
    const pctLabel = document.getElementById('qobuz-pct-label');

    // Show unavailability warning if Qobuz not configured
    if (!state.qobuzAvailable) {
        unavailMsg?.classList.remove('hidden');
    } else {
        unavailMsg?.classList.add('hidden');
    }

    // Render card states
    cards.forEach(card => {
        const src = card.dataset.source;
        const isSelected = state.sourceMode === src;
        const isQobuzCard = src === 'hybrid' || src === 'qobuz';
        const disabled = isQobuzCard && !state.qobuzAvailable;

        card.classList.toggle('selected', isSelected);
        card.setAttribute('aria-pressed', isSelected ? 'true' : 'false');
        card.disabled = disabled;
        card.classList.toggle('source-card--disabled', disabled);
        if (disabled) {
            card.title = 'Configure Qobuz in Roon to use this option';
        } else {
            card.title = '';
        }
    });

    // Show percentage slider only for hybrid mode
    if (state.sourceMode === 'hybrid' && state.qobuzAvailable) {
        pctRow?.classList.remove('hidden');
        if (slider) slider.value = state.qobuzPercentage;
        if (pctLabel) pctLabel.textContent = state.qobuzPercentage;
    } else {
        pctRow?.classList.add('hidden');
    }
}

export async function handleContinueFromSource() {
    // Load library stats for the filters step
    setLoading(true, 'Loading library...');
    try {
        const stats = await fetchLibraryStats();
        state.availableGenres = stats.genres;
        state.availableDecades = stats.decades;
        state.selectedGenres = stats.genres.map(g => g.name);
        state.selectedDecades = stats.decades.map(d => d.name);
    } catch {
        // Non-fatal: filters step will show empty chips
        state.availableGenres = [];
        state.availableDecades = [];
    } finally {
        setLoading(false);
    }

    state.step = 'filters';
    updateStep();
    updateFilters();
    updateFilterPreview();
}

export async function handleContinueToFilters() {
    if (!state.selectedDimensions.length) {
        showError('Please select at least one dimension');
        return;
    }

    state.additionalNotes = document.getElementById('additional-notes-input').value.trim();
    setLoading(true, 'Loading library data...');

    try {
        const stats = await fetchLibraryStats();
        state.availableGenres = stats.genres;
        state.availableDecades = stats.decades;
        state.selectedGenres = stats.genres.map(g => g.name);
        state.selectedDecades = stats.decades.map(d => d.name);

        state.step = 'source';
        updateStep();
    } catch (error) {
        showError(error.message);
    } finally {
        setLoading(false);
    }
}

export async function handleGenerate() {
    // All selected = no filter (avoids excluding untagged tracks)
    const request = {
        genres: allGenresSelected() ? [] : state.selectedGenres,
        decades: allDecadesSelected() ? [] : state.selectedDecades,
        track_count: state.trackCount,
        exclude_live: state.excludeLive,
        max_tracks_to_ai: state.maxTracksToAI,
        source_mode: state.sourceMode,
        qobuz_percentage: state.qobuzPercentage,
    };

    if (state.mode === 'prompt') {
        request.prompt = state.prompt;
        if (state.questionAnswers?.length) {
            request.refinement_answers = state.questionAnswers.map((ans, i) => {
                const text = state.questionTexts[i]?.trim();
                if (ans && text) return `${ans} (${text})`;
                if (ans) return ans;
                if (text) return text;
                return null;
            });
        }
    } else {
        request.seed_track = {
            item_key: state.seedTrack.item_key,
            selected_dimensions: state.selectedDimensions,
        };
        if (state.additionalNotes) {
            request.additional_notes = state.additionalNotes;
        }
    }

    // Store original request for potential refinement passes
    state.lastRequest = { ...request };

    showStepLoading(PLAYLIST_STEPS.map(s => ({ ...s })));

    generatePlaylistStream(
        request,
        // onProgress — map SSE step to consolidated visible step
        (data) => {
            const mapped = PLAYLIST_STEP_MAP[data.step];
            if (mapped) updateStepProgress(mapped);
        },
        // onComplete
        (response) => {
            // Mark final step complete before hiding
            updateStepProgress('__done__');

            // Add generation costs to session totals
            state.sessionTokens += response.token_count || 0;
            state.sessionCost += response.estimated_cost || 0;

            state.playlist = response.tracks;
            state.tokenCount = state.sessionTokens;
            state.estimatedCost = state.sessionCost;

            // Use generated title from response, or from state if already set via SSE
            if (response.playlist_title) {
                state.playlistTitle = response.playlist_title;
            }
            if (response.narrative) {
                state.narrative = response.narrative;
            }
            if (response.track_reasons) {
                state.trackReasons = response.track_reasons;
            }

            // Use generated title for playlist name, fallback to old method
            state.playlistName = state.playlistTitle || generatePlaylistName();

            // Reset selection so auto-select picks first new track
            state.selectedTrackKey = null;

            state.step = 'results';
            updateStep();
            updatePlaylist();
            window.scrollTo(0, 0);
            hideStepLoading();

            // Update URL to deep link for this result
            if (response.result_id) {
                history.replaceState(null, '', `#result/${response.result_id}`);
                markHistoryStale();
            }
        },
        // onError
        (error) => {
            showError(error.message);
            hideStepLoading();
        }
    );
}
