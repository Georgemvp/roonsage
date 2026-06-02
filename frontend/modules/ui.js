import { state, allGenresSelected, allDecadesSelected } from './state.js';
import { apiCall, fetchConfig, updateConfig, fetchOllamaStatus, fetchOllamaModels, fetchOllamaModelInfo, fetchSetupStatus } from './api.js';
import { escapeHtml, artistHue, artPlaceholderHtml, trackArtHtml } from './utils.js';
import { focusManager } from './focus.js';
// Circular-dep imports — all resolved at call-time (ES modules handle function-level circularity fine)
import { lockScroll, removeNoScrollIfNoModals, dismissModal } from './instant-queue.js';
import { renderSourceModeStep } from './events.js';
import { loadSettings } from './playlist.js';
import { updateRecAlbumPreview } from './recommend.js';

// Maps data-nav hash → whether it should be active given current state
function _navHashIsActive(hash) {
    switch (hash) {
        case 'home':            return state.view === 'home';
        case 'playlist-prompt': return state.view === 'create' && state.mode === 'prompt';
        case 'playlist-seed':   return state.view === 'create' && state.mode === 'seed';
        case 'recommend-album': return state.view === 'recommend';
        case 'playlists':       return state.view === 'playlists';
        case 'discovery':       return state.view === 'discovery';
        case 'watchlist':       return state.view === 'watchlist';
        case 'dj-set':          return state.view === 'dj-set';
        case 'taste':           return state.view === 'taste';
        case 'automations':     return state.view === 'automations';
        case 'settings':        return state.view === 'settings';
        case 'enrichment':      return state.view === 'enrichment';
        default:                return false;
    }
}

export function updateView() {
    // Update views
    document.querySelectorAll('.view').forEach(view => {
        view.classList.toggle('active', view.id === `${state.view}-view`);
    });

    // Scroll main content area to top on view change
    window.scrollTo(0, 0);
    const rsMain = document.querySelector('.rs-main');
    if (rsMain) rsMain.scrollTop = 0;

    // ── Sidebar nav items (new design) ──────────────────────────
    document.querySelectorAll('.rs-sidebar .rs-nav-item[data-nav]').forEach(btn => {
        const isActive = _navHashIsActive(btn.dataset.nav);
        btn.classList.toggle('active', isActive);
        btn.setAttribute('aria-current', isActive ? 'page' : 'false');
    });

    // ── Legacy header nav (may not exist in new design — guard) ──
    const trigger = document.querySelector('.nav-dropdown-trigger');
    const isPlaylist = state.view === 'create';
    if (trigger) trigger.classList.toggle('active', isPlaylist);

    document.querySelectorAll('.nav-dropdown-item').forEach(item => {
        const hash = item.dataset.nav;
        const isSelected = isPlaylist && (
            (hash === 'playlist-prompt' && state.mode === 'prompt') ||
            (hash === 'playlist-seed' && state.mode === 'seed')
        );
        const check = item.querySelector('.nav-check');
        if (check) check.textContent = isSelected ? '✓' : '';
        item.classList.toggle('selected', isSelected);
    });

    document.querySelectorAll('.nav-btn[data-nav]').forEach(btn => {
        const isActive = _navHashIsActive(btn.dataset.nav);
        btn.classList.toggle('active', isActive);
        btn.setAttribute('aria-current', isActive ? 'true' : 'false');
    });

    document.querySelectorAll('.mobile-bottom-nav .mbn-btn[data-nav]').forEach(btn => {
        const isActive = _navHashIsActive(btn.dataset.nav);
        btn.classList.toggle('active', isActive);
        btn.setAttribute('aria-current', isActive ? 'page' : 'false');
    });
}

export function updateMode() {
    // Update step panels visibility
    const inputPrompt = document.getElementById('step-input-prompt');
    const inputSeed = document.getElementById('step-input-seed');

    if (state.step === 'input') {
        inputPrompt.classList.toggle('active', state.mode === 'prompt');
        inputSeed.classList.toggle('active', state.mode === 'seed');
    }

    // The slim-bar step indicator is re-rendered every updateStep() call based
    // on state.mode, so no per-step DOM mutation is needed here anymore.
}

// Step labels — keyed by internal step id. Used by the slim bar indicator.
const _STEP_LABELS = {
    input:      'Prompt',
    seed:       'Seed',
    refine:     'Verfijnen',
    dimensions: 'Dimensies',
    source:     'Bron',
    filters:    'Filters',
    results:    'Resultaten',
};

export function updateStep() {
    window.scrollTo(0, 0);
    const rsMain = document.querySelector('.rs-main');
    if (rsMain) rsMain.scrollTop = 0;

    const isResults = state.step === 'results';

    // Hide step progress on results step
    const stepProgress = document.getElementById('playlist-steps');
    if (stepProgress) stepProgress.style.display = isResults ? 'none' : '';

    // Toggle wide layout for results
    const appEl = document.querySelector('.app');
    if (appEl) appEl.classList.toggle('app--wide', isResults);

    // Toggle footer content for results vs other screens
    const appFooter = document.querySelector('.app-footer');
    if (appFooter) appFooter.classList.toggle('app-footer--results', isResults);

    // Clear any inline hide from album view so CSS class can control visibility
    const regenBtn = document.getElementById('regenerate-btn');
    if (regenBtn) regenBtn.style.display = '';

    // Steps array is mode-dependent: prompt uses refine, seed uses dimensions.
    // Note: 'results' is excluded from the visible indicator — once we render the
    // playlist, the indicator is hidden anyway.
    const steps = state.mode === 'prompt'
        ? ['input', 'refine', 'source', 'filters']
        : ['input', 'dimensions', 'source', 'filters'];
    const currentIndex = Math.max(0, steps.indexOf(state.step));

    // Render the slim bar-based progress indicator (replaces the legacy circles)
    if (stepProgress && !isResults) {
        // Show "Seed" instead of "Prompt" when in seed mode
        const labelOverrides = state.mode === 'seed' ? { ..._STEP_LABELS, input: 'Seed' } : _STEP_LABELS;
        const labelKeys = steps;
        const bars = labelKeys.map((_, i) => {
            const cls = i < currentIndex ? 'step-progress-bar--done'
                      : i === currentIndex ? 'step-progress-bar--active'
                      : '';
            return `<div class="step-progress-bar ${cls}"></div>`;
        }).join('');
        const currentLabel = labelOverrides[labelKeys[currentIndex]] || labelKeys[currentIndex] || '';
        stepProgress.innerHTML = `
            <div class="step-progress-bars" role="progressbar"
                 aria-valuemin="1" aria-valuemax="${labelKeys.length}" aria-valuenow="${currentIndex + 1}">
                ${bars}
            </div>
            <div class="step-progress-meta">
                <span class="step-progress-count">Stap ${currentIndex + 1} van ${labelKeys.length}</span>
                <span class="step-progress-name">${escapeHtml(currentLabel)}</span>
            </div>`;
    }

    // Update step panels
    document.querySelectorAll('.step-panel').forEach(panel => {
        panel.classList.remove('active');
    });

    if (state.step === 'input') {
        if (state.mode === 'prompt') {
            document.getElementById('step-input-prompt').classList.add('active');
        } else {
            document.getElementById('step-input-seed').classList.add('active');
        }
    } else if (state.step === 'refine') {
        document.getElementById('step-refine').classList.add('active');
    } else if (state.step === 'dimensions') {
        document.getElementById('step-dimensions').classList.add('active');
    } else if (state.step === 'source') {
        document.getElementById('step-source').classList.add('active');
        // Refresh Qobuz availability each time the source step is shown so that
        // logging into Qobuz in Roon after app-start is picked up without a full
        // page reload.
        fetchSetupStatus().then(s => {
            state.qobuzAvailable = !!s.qobuz_available;
            state.qobuzSaveAvailable = !!s.qobuz_save_available;
            renderSourceModeStep();
        }).catch(() => renderSourceModeStep());
    } else if (state.step === 'filters') {
        document.getElementById('step-filters').classList.add('active');
    } else if (state.step === 'results') {
        document.getElementById('step-results').classList.add('active');
    }
}

export function updateFilters() {
    // Remember which chip had focus so we can restore it after re-render
    const focused = document.activeElement;
    const focusedGenre = focused?.dataset?.genre;
    const focusedDecade = focused?.dataset?.decade;

    // Update genre chips
    const genreContainer = document.getElementById('genre-chips');
    genreContainer.innerHTML = state.availableGenres.map(genre => {
        const isSelected = state.selectedGenres.includes(genre.name);
        return `
        <button class="chip ${isSelected ? 'selected' : ''}"
                data-genre="${escapeHtml(genre.name)}"
                aria-pressed="${isSelected}">
            ${escapeHtml(genre.name)}
            ${genre.count != null ? `<span class="chip-count">${genre.count}</span>` : ''}
        </button>
    `}).join('');

    // Sync genre toggle label
    const genreToggle = document.getElementById('genre-toggle-all');
    if (genreToggle) {
        const allSelected = allGenresSelected();
        genreToggle.textContent = allSelected ? 'Deselect All' : 'Select All';
        genreToggle.setAttribute('aria-label',
            allSelected ? 'Deselect all genres' : 'Select all genres');
    }

    // Update decade chips
    const decadeContainer = document.getElementById('decade-chips');
    decadeContainer.innerHTML = state.availableDecades.map(decade => {
        const isSelected = state.selectedDecades.includes(decade.name);
        return `
        <button class="chip ${isSelected ? 'selected' : ''}"
                data-decade="${escapeHtml(decade.name)}"
                aria-pressed="${isSelected}">
            ${escapeHtml(decade.name)}
            ${decade.count != null ? `<span class="chip-count">${decade.count}</span>` : ''}
        </button>
    `}).join('');

    // Sync decade toggle label
    const decadeToggle = document.getElementById('decade-toggle-all');
    if (decadeToggle) {
        const allSelected = allDecadesSelected();
        decadeToggle.textContent = allSelected ? 'Deselect All' : 'Select All';
        decadeToggle.setAttribute('aria-label',
            allSelected ? 'Deselect all decades' : 'Select all decades');
    }

    // Restore focus to the chip that was active before re-render
    if (focusedGenre) {
        genreContainer.querySelector(`[data-genre="${CSS.escape(focusedGenre)}"]`)?.focus();
    } else if (focusedDecade) {
        decadeContainer.querySelector(`[data-decade="${CSS.escape(focusedDecade)}"]`)?.focus();
    }

    // Update track count buttons
    document.querySelectorAll('.count-btn').forEach(btn => {
        const isActive = parseInt(btn.dataset.count) === state.trackCount;
        btn.classList.toggle('active', isActive);
        btn.setAttribute('aria-pressed', isActive ? 'true' : 'false');
    });

    // Update max tracks to AI buttons
    const maxAllowed = state.config?.max_tracks_to_ai || 3500;
    document.querySelectorAll('.limit-btn').forEach(btn => {
        const limit = parseInt(btn.dataset.limit);
        const isActive = limit === state.maxTracksToAI ||
            (limit === 0 && state.maxTracksToAI >= maxAllowed);
        btn.classList.toggle('active', isActive);
        btn.setAttribute('aria-pressed', isActive ? 'true' : 'false');
    });

    // Update checkboxes
    document.getElementById('exclude-live').checked = state.excludeLive;
    const useTasteEl = document.getElementById('use-taste-profile');
    if (useTasteEl) useTasteEl.checked = state.useTasteProfile;
    const recUseTasteEl = document.getElementById('rec-use-taste-profile');
    if (recUseTasteEl) recUseTasteEl.checked = state.rec.useTasteProfile;

    // Update rating buttons
    document.querySelectorAll('.rating-btn').forEach(btn => {
        const isActive = parseInt(btn.dataset.rating) === state.minRating;
        btn.classList.toggle('active', isActive);
        btn.setAttribute('aria-pressed', isActive ? 'true' : 'false');
    });
}

export function updateModelSuggestion() {
    const suggestion = document.getElementById('gemini-suggestion');
    if (!suggestion || !state.config) return;

    const provider = state.config.llm_provider;
    const maxTracks = state.config.max_tracks_to_ai || 3500;
    const isLocalProvider = state.config.is_local_provider;

    // Cloud provider baselines for comparison
    const ANTHROPIC_MAX = 3500;  // ~200K context
    const GEMINI_MAX = 18000;    // ~1M context

    if (isLocalProvider && maxTracks < ANTHROPIC_MAX) {
        // Local model with small context - suggest a more powerful model
        suggestion.textContent = 'Switch to a model with a larger context window in Settings for higher track limits.';
        suggestion.classList.remove('hidden');
    } else if (!isLocalProvider && provider !== 'gemini') {
        // Cloud provider that isn't Gemini - suggest Gemini specifically
        const multiplier = provider === 'openai' ? '8x' : '5x';
        suggestion.textContent = `Switch to Gemini in Settings for ${multiplier} higher track limits.`;
        suggestion.classList.remove('hidden');
    } else {
        // Using Gemini or a local model with large context - no suggestion needed
        suggestion.classList.add('hidden');
    }
}

export function updateTrackLimitButtons() {
    const container = document.querySelector('.track-limit-selector');
    if (!container || !state.config) return;

    updateModelSuggestion();

    const maxAllowed = state.config.max_tracks_to_ai || 3500;

    // Generate sensible limit options based on model capacity
    const options = [];

    // Always include some standard options that are below the max
    const standardOptions = [100, 250, 500, 1000, 2000, 5000, 10000, 18000];
    for (const opt of standardOptions) {
        if (opt <= maxAllowed) {
            options.push(opt);
        }
    }

    // Add "No limit" option (which means use model's max)
    options.push(0);

    // Render buttons
    container.innerHTML = options.map(limit => {
        const isActive = limit === state.maxTracksToAI ||
            (limit === 0 && state.maxTracksToAI >= maxAllowed);
        const label = limit === 0 ? `Max (${maxAllowed.toLocaleString()})` : limit.toLocaleString();
        return `<button class="limit-btn ${isActive ? 'active' : ''}" data-limit="${limit}">${label}</button>`;
    }).join('');

    // Re-attach event listeners (local recalculation - no API call needed)
    container.querySelectorAll('.limit-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            // Update active state visually
            container.querySelectorAll('.limit-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');

            const limit = parseInt(btn.dataset.limit);
            state.maxTracksToAI = limit === 0 ? maxAllowed : limit;
            updateFilters();
            recalculateCostDisplay();
        });
    });
}

export function updateAlbumLimitButtons() {
    const container = document.querySelector('.album-limit-selector');
    if (!container || !state.config) return;

    updateRecModelSuggestion();

    const maxAllowed = state.config.max_albums_to_ai || 2500;

    // Generate options filtered by model capacity
    const options = [];
    const standardOptions = [1000, 2500, 5000, 10000, 35000];
    for (const opt of standardOptions) {
        if (opt <= maxAllowed) {
            options.push(opt);
        }
    }

    // Add "Max" option (uses model's max)
    options.push(0);

    // Render buttons
    container.innerHTML = options.map(limit => {
        const isActive = limit === state.rec.maxAlbumsToAI ||
            (limit === 0 && state.rec.maxAlbumsToAI >= maxAllowed);
        const label = limit === 0 ? `Max (${maxAllowed.toLocaleString()})` : limit.toLocaleString();
        return `<button class="limit-btn ${isActive ? 'active' : ''}" data-limit="${limit}">${label}</button>`;
    }).join('');

    // Clamp current selection to what the model supports
    if (state.rec.maxAlbumsToAI > maxAllowed) {
        state.rec.maxAlbumsToAI = maxAllowed;
    }

    // Re-attach event listeners
    container.querySelectorAll('.limit-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            container.querySelectorAll('.limit-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');

            const limit = parseInt(btn.dataset.limit);
            state.rec.maxAlbumsToAI = limit === 0 ? maxAllowed : limit;
            updateRecAlbumPreview();
        });
    });
}

export function updateRecModelSuggestion() {
    const suggestion = document.getElementById('rec-gemini-suggestion');
    if (!suggestion || !state.config) return;

    const provider = state.config.llm_provider;
    const maxAlbums = state.config.max_albums_to_ai || 2500;
    const isLocalProvider = state.config.is_local_provider;

    const ANTHROPIC_MAX_ALBUMS = 7100;
    const GEMINI_MAX_ALBUMS = 35900;

    if (isLocalProvider && maxAlbums < ANTHROPIC_MAX_ALBUMS) {
        suggestion.textContent = 'Switch to a model with a larger context window in Settings for higher album limits.';
        suggestion.classList.remove('hidden');
    } else if (!isLocalProvider && provider !== 'gemini') {
        const multiplier = provider === 'openai' ? '8x' : '5x';
        suggestion.textContent = `Switch to Gemini in Settings for ${multiplier} higher album limits.`;
        suggestion.classList.remove('hidden');
    } else {
        suggestion.classList.add('hidden');
    }
}

// AbortController for cancelling in-flight filter preview requests
export let filterPreviewController = null;
export let filterPreviewLoadingTimeout = null;

export async function updateFilterPreview() {
    console.log('[RoonSage] updateFilterPreview called');
    const previewTracks = document.getElementById('preview-tracks');
    const previewCost = document.getElementById('preview-cost');

    // Cancel any in-flight request
    if (filterPreviewController) {
        filterPreviewController.abort();
    }
    filterPreviewController = new AbortController();

    // Clear any pending loading timeout
    if (filterPreviewLoadingTimeout) {
        clearTimeout(filterPreviewLoadingTimeout);
    }

    // Only show loading state if request takes longer than 150ms
    filterPreviewLoadingTimeout = setTimeout(() => {
        previewTracks.innerHTML = '<span class="preview-spinner"></span> Counting...';
        previewCost.textContent = '';
    }, 150);

    try {
        // All selected = no filter (avoids excluding untagged tracks)
        const requestBody = {
            genres: allGenresSelected() ? [] : state.selectedGenres,
            decades: allDecadesSelected() ? [] : state.selectedDecades,
            track_count: state.trackCount,
            max_tracks_to_ai: state.maxTracksToAI,
            exclude_live: state.excludeLive,
        };
        console.log('[RoonSage] Filter preview request:', requestBody);

        const data = await apiCall('/filter/preview', {
            method: 'POST',
            body: JSON.stringify(requestBody),
            signal: filterPreviewController.signal,
        });
        console.log('[RoonSage] Filter preview response:', data);

        // Clear loading timeout - response arrived fast
        clearTimeout(filterPreviewLoadingTimeout);

        // Cache the matching_tracks for local recalculation
        state.lastFilterPreview = {
            matching_tracks: data.matching_tracks,
        };

        // Update display
        updateFilterPreviewDisplay(data.matching_tracks, data.tracks_to_send, data.estimated_cost);
    } catch (error) {
        // Clear loading timeout on error too
        clearTimeout(filterPreviewLoadingTimeout);

        // Ignore abort errors - they're expected when cancelling
        if (error.name === 'AbortError') {
            console.log('[RoonSage] Filter preview request cancelled');
            return;
        }
        console.error('Filter preview error:', error);
        previewTracks.textContent = '-- matching tracks';
        previewCost.textContent = 'Est. cost: --';
    }
}

export function updateFilterPreviewDisplay(matchingTracks, tracksToSend, estimatedCost) {
    const previewTracks = document.getElementById('preview-tracks');
    const previewCost = document.getElementById('preview-cost');

    // Update track count display
    let trackText;
    if (matchingTracks >= 0) {
        if (tracksToSend < matchingTracks) {
            trackText = `${matchingTracks.toLocaleString()} tracks (sending ${tracksToSend.toLocaleString()} to AI, selected randomly)`;
        } else {
            trackText = `${matchingTracks.toLocaleString()} tracks`;
        }
    } else {
        trackText = 'Unknown';
    }
    previewTracks.textContent = trackText;

    // For local providers, hide cost estimate (show tokens only)
    const isLocalProvider = state.config?.is_local_provider ?? false;
    if (matchingTracks < 0) {
        previewCost.textContent = isLocalProvider ? '' : 'Est. cost: --';
    } else if (isLocalProvider) {
        // Don't show cost for local providers
        previewCost.textContent = '';
    } else {
        previewCost.textContent = `Est. cost: $${estimatedCost.toFixed(4)}`;
    }

    // Update "All/Max" button label based on whether filtered tracks fit in context
    const maxBtn = document.querySelector('.limit-btn[data-limit="0"]');
    if (maxBtn && state.config) {
        const maxAllowed = state.config.max_tracks_to_ai || 3500;
        maxBtn.textContent = matchingTracks <= maxAllowed ? 'All' : `Max (${maxAllowed.toLocaleString()})`;
    }
}

export function recalculateCostDisplay() {
    // Recalculate cost locally without API call (for track_count/max_tracks changes)
    if (!state.lastFilterPreview || !state.config) return;

    // If cost rates aren't available (old config), fall back to API call
    if (state.config.cost_per_million_input === undefined) {
        updateFilterPreview();
        return;
    }

    const { matching_tracks } = state.lastFilterPreview;
    const maxAllowed = state.config.max_tracks_to_ai || 3500;

    // Calculate tracks_to_send
    let tracks_to_send;
    if (matching_tracks <= 0) {
        tracks_to_send = 0;
    } else if (state.maxTracksToAI === 0 || state.maxTracksToAI >= maxAllowed) {
        // "Max" mode - send up to model's limit
        tracks_to_send = Math.min(matching_tracks, maxAllowed);
    } else {
        tracks_to_send = Math.min(matching_tracks, state.maxTracksToAI);
    }

    // Cost formula (matches backend: separate rates for analysis + generation models)
    const analysis_input = 1100;
    const analysis_output = 300;
    const gen_input = tracks_to_send * 40;
    const gen_output = state.trackCount * 60;

    // Analysis model cost (e.g. Sonnet)
    const analysis_in_rate = state.config.analysis_cost_per_million_input ?? state.config.cost_per_million_input;
    const analysis_out_rate = state.config.analysis_cost_per_million_output ?? state.config.cost_per_million_output;
    const analysis_cost = (analysis_input / 1_000_000) * analysis_in_rate + (analysis_output / 1_000_000) * analysis_out_rate;

    // Generation model cost (e.g. Haiku)
    const gen_cost = (gen_input / 1_000_000) * state.config.cost_per_million_input + (gen_output / 1_000_000) * state.config.cost_per_million_output;

    const estimated_cost = analysis_cost + gen_cost;

    updateFilterPreviewDisplay(matching_tracks, tracks_to_send, estimated_cost);
}

export function renderNarrativeBox() {
    const container = document.getElementById('narrative-box');
    if (!container) return;

    if (!state.narrative) {
        container.classList.add('hidden');
        return;
    }

    container.classList.remove('hidden');

    container.innerHTML = `
        <p class="narrative-text">${escapeHtml(state.narrative)}</p>
    `;

    // Update prompt pill
    const promptPill = document.getElementById('results-prompt-pill');
    if (promptPill) {
        if (state.userRequest) {
            promptPill.textContent = `\u{1F4AC} "${state.userRequest}"`;
            promptPill.classList.remove('hidden');
        } else {
            promptPill.classList.add('hidden');
        }
    }
}

export function showTrackReason(itemKey) {
    const panel = document.getElementById('track-reason-panel');
    if (!panel) return;

    const placeholder = panel.querySelector('.reason-placeholder');
    const content = panel.querySelector('.reason-content');

    if (!itemKey) {
        // Show placeholder
        placeholder.classList.remove('hidden');
        content.classList.add('hidden');
        return;
    }

    // Find track in playlist
    const track = state.playlist.find(t => t.item_key === itemKey);
    if (!track) return;

    // Get reason for this track
    const reason = state.trackReasons[itemKey] || 'Selected for this playlist';

    // Update album art
    const artContainer = panel.querySelector('.reason-album-art-container');
    if (artContainer) {
        if (track.art_url) {
            artContainer.innerHTML = `<img class="reason-album-art" src="${escapeHtml(track.art_url)}" alt="${escapeHtml(track.album)} album art" data-artist="${escapeHtml(track.artist || '')}" onerror="this.outerHTML=artPlaceholderHtml(this.dataset.artist,true)">`;
        } else {
            artContainer.innerHTML = artPlaceholderHtml(track.artist, true);
        }
        artContainer.style.display = '';
    }

    // Update panel content
    panel.querySelector('.reason-track-title').textContent = track.title;
    panel.querySelector('.reason-track-artist').textContent = `${track.artist} - ${track.album}`;
    panel.querySelector('.reason-text').textContent = reason;

    // Show content, hide placeholder
    placeholder.classList.add('hidden');
    content.classList.remove('hidden');
}

export function selectTrack(itemKey) {
    state.selectedTrackKey = itemKey;

    // Toggle .selected class on track rows
    document.querySelectorAll('.playlist-track').forEach(el => {
        const isSelected = el.dataset.itemKey === itemKey;
        el.classList.toggle('selected', isSelected);
        el.setAttribute('aria-selected', isSelected ? 'true' : 'false');
    });

    // Update detail panel
    showTrackReason(itemKey);
}

export function isMobileView() {
    return window.innerWidth <= 768;
}

export function openBottomSheet(itemKey) {
    const sheet = document.getElementById('bottom-sheet');
    if (!sheet) return;

    // Find track in playlist
    const track = state.playlist.find(t => t.item_key === itemKey);
    if (!track) return;

    // Get reason for this track
    const reason = state.trackReasons[itemKey] || 'Selected for this playlist';

    // Update content
    sheet.querySelector('.bottom-sheet-track-title').textContent = track.title;
    sheet.querySelector('.bottom-sheet-track-artist').textContent = `${track.artist} - ${track.album}`;
    sheet.querySelector('.bottom-sheet-reason').textContent = reason;

    // Show sheet
    sheet.classList.remove('hidden');
    focusManager.openModal(sheet);
    lockScroll();
}

export function closeBottomSheet() {
    const sheet = document.getElementById('bottom-sheet');
    if (!sheet) return;

    sheet.classList.add('hidden');
    removeNoScrollIfNoModals();
    focusManager.closeModal(sheet);
}

/**
 * Render an AcoustID verification badge for a track, if verification data is present.
 *
 * Badge types:
 *   ✓  (green)  — verified match, confidence > 0.85
 *   ⚠  (amber)  — possible mismatch, confidence 0.60–0.85 or version flags present
 *   (none)      — not verified (verified === null / undefined) or confidence below 0.60
 *                  but we don't block display
 */
function renderVerificationBadge(track) {
    // Only show badge when track has been through verification
    if (track.verified === undefined || track.verified === null) return '';
    if (track.match_confidence === undefined || track.match_confidence === null) return '';

    const confidence = track.match_confidence;
    const flags = track.version_flags || [];
    const reason = track.match_reason || '';

    if (track.verified && confidence >= 0.85 && flags.length === 0) {
        return `<span class="verify-badge verify-badge--match" title="Verified match (${Math.round(confidence * 100)}%): ${reason}">✓</span>`;
    }

    // Possible mismatch: version flags present, or confidence 0.60–0.85
    const flagText = flags.length ? `Version: ${flags.join(', ')}. ` : '';
    return `<span class="verify-badge verify-badge--warn" title="${flagText}Confidence ${Math.round(confidence * 100)}%: ${reason}">⚠</span>`;
}

function _renderResultsArtMosaic() {
    const mosaicEl = document.getElementById('results-art-mosaic');
    if (!mosaicEl) return;
    if (!state.playlist || state.playlist.length === 0) {
        mosaicEl.innerHTML = '';
        return;
    }
    const items = state.playlist.slice(0, 8).map(track => `
        <div class="rs-results-art-mosaic-item">
            ${track.art_url
                ? `<img src="${escapeHtml(track.art_url)}" alt="" loading="lazy" onerror="this.style.display='none'">`
                : ''}
        </div>
    `).join('');
    mosaicEl.innerHTML = items;
}

function _renderResultsAiBadge() {
    const badge = document.getElementById('results-ai-badge');
    if (!badge) return;
    if (!state.playlist || state.playlist.length === 0) {
        badge.classList.add('hidden');
        return;
    }
    badge.classList.remove('hidden');
    badge.textContent = '✦ AI gegenereerd';
}

export function updatePlaylist() {
    // Render narrative box
    renderNarrativeBox();

    // Render results-zone enhancements (art mosaic + AI badge)
    _renderResultsArtMosaic();
    _renderResultsAiBadge();

    const container = document.getElementById('playlist-tracks');
    container.innerHTML = state.playlist.map((track, index) => `
        <div class="playlist-track" role="option" tabindex="0"
             data-item-key="${escapeHtml(track.item_key)}"
             aria-selected="false"
             aria-label="${escapeHtml(track.title)} by ${escapeHtml(track.artist)}">
            <span class="track-number">${index + 1}</span>
            <div class="track-art-wrap">${trackArtHtml(track)}</div>
            <div class="track-info">
                <div class="track-title">
                    ${escapeHtml(track.title)}
                    ${track.source === 'qobuz' ? '<span class="qobuz-badge" title="Via Qobuz">Qobuz</span>' : ''}
                    ${renderVerificationBadge(track)}
                </div>
                <div class="track-artist">${escapeHtml(track.artist)}</div>
                <span class="rs-track-album">${escapeHtml(track.album || '')}</span>
            </div>
            <button class="rs-track-options" tabindex="0" title="Opties" aria-label="Opties">···</button>
            <button class="track-remove" tabindex="0" data-item-key="${escapeHtml(track.item_key)}"
                    aria-label="Remove ${escapeHtml(track.title)}">&times;</button>
        </div>
    `).join('');

    // Click handlers: desktop = select track, mobile = open bottom sheet
    container.querySelectorAll('.playlist-track').forEach(trackEl => {
        trackEl.addEventListener('click', (e) => {
            if (e.target.closest('.track-remove')) return;
            if (isMobileView()) {
                openBottomSheet(trackEl.dataset.itemKey);
            } else {
                selectTrack(trackEl.dataset.itemKey);
            }
        });

        // Keyboard: Enter/Space to select
        trackEl.addEventListener('keydown', (e) => {
            if (e.target.closest('.track-remove')) return;
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                if (isMobileView()) {
                    openBottomSheet(trackEl.dataset.itemKey);
                } else {
                    selectTrack(trackEl.dataset.itemKey);
                }
            }
        });
    });

    // Auto-select: restore previous selection or pick first track (desktop)
    if (!isMobileView() && state.playlist.length > 0) {
        const hasSelected = state.selectedTrackKey &&
            state.playlist.some(t => t.item_key === state.selectedTrackKey);
        if (hasSelected) {
            selectTrack(state.selectedTrackKey);
        } else {
            selectTrack(state.playlist[0].item_key);
        }
    } else if (state.playlist.length === 0) {
        state.selectedTrackKey = null;
        showTrackReason(null);
    }

    // Show/hide refinement button depending on whether a request is stored
    const refineBtn = document.getElementById('refine-playlist-btn');
    if (refineBtn) {
        refineBtn.classList.toggle('hidden', !state.lastRequest);
    }

    // Show/hide Qobuz save button based on availability and playlist content
    const qobuzSaveBtn = document.getElementById('save-to-qobuz-btn');
    if (qobuzSaveBtn) {
        const visible = state.qobuzSaveAvailable && state.playlist.length > 0;
        qobuzSaveBtn.classList.toggle('hidden', !visible);
        // Reset result feedback when playlist changes
        const qobuzResult = document.getElementById('qobuz-save-result');
        if (qobuzResult) qobuzResult.classList.add('hidden');
    }

    // Show/hide Save for Arc button when Qobuz save is available and playlist has tracks
    const arcBtn = document.getElementById('save-for-arc-btn');
    if (arcBtn) {
        arcBtn.classList.toggle('hidden', !(state.qobuzSaveAvailable && state.playlist.length > 0));
    }

    // Update footer
    updateResultsFooter();

}

export function updateResultsFooter() {
    const headerTrackCountEl = document.getElementById('results-track-count');
    const costDisplay = document.getElementById('cost-display');

    const count = state.playlist.length;

    // Update header track count
    const trackText = `♫ ${count} track${count !== 1 ? 's' : ''}`;
    if (headerTrackCountEl) headerTrackCountEl.textContent = trackText;

    // Update cost display in app footer
    const isLocalProvider = state.config?.is_local_provider ?? false;
    if (costDisplay) {
        if (isLocalProvider) {
            costDisplay.textContent = `${state.tokenCount.toLocaleString()} tokens`;
        } else {
            costDisplay.textContent = `${state.tokenCount.toLocaleString()} tokens ($${state.estimatedCost.toFixed(4)})`;
        }
    }

}

export function updateSettings() {
    if (!state.config) return;

    document.getElementById('roon-host').value = state.config.roon_host || '';
    document.getElementById('roon-port').value = state.config.roon_port || 9330;
    document.getElementById('music-library').value = state.config.music_library || 'Music';
    document.getElementById('llm-provider').value = state.config.llm_provider || 'gemini';

    // Show warning if provider is set by environment variable
    const providerEnvWarning = document.getElementById('provider-env-warning');
    if (providerEnvWarning) {
        providerEnvWarning.classList.toggle('hidden', !state.config.provider_from_env);
    }

    // Roon token is handled internally — no manual token input in settings

    const llmApiKeyInput = document.getElementById('llm-api-key');
    llmApiKeyInput.placeholder = state.config.llm_api_key_set
        ? '••••••••••••••••  (configured)'
        : 'Your API key';

    // Update Ollama settings
    const ollamaUrl = document.getElementById('ollama-url');
    ollamaUrl.value = state.config.ollama_url || 'http://localhost:11434';

    // Update Custom provider settings
    const customUrl = document.getElementById('custom-url');
    const customApiKey = document.getElementById('custom-api-key');
    const customModel = document.getElementById('custom-model');
    const customContext = document.getElementById('custom-context-window');
    customUrl.value = state.config.custom_url || '';
    customApiKey.value = '';  // Never show actual key
    customApiKey.placeholder = state.config.llm_api_key_set && state.config.llm_provider === 'custom'
        ? '••••••••••••• (key saved)'
        : 'sk-... (optional)';
    customModel.value = state.config.model_analysis || '';  // Custom uses same model for both
    customContext.value = state.config.custom_context_window || 32768;

    // Update status indicators
    const roonStatus = document.getElementById('roon-status');
    if (roonStatus) {
        roonStatus.classList.toggle('connected', state.config.roon_connected);
        roonStatus.querySelector('.status-text').textContent =
            state.config.roon_connected ? 'Connected' : 'Not connected';
    }

    const llmStatus = document.getElementById('llm-status');
    llmStatus.classList.toggle('connected', state.config.llm_configured);
    llmStatus.querySelector('.status-text').textContent =
        state.config.llm_configured ? 'Configured' : 'Not configured';

    // Show provider-specific settings
    showProviderSettings(state.config.llm_provider);

    // Update Qobuz settings fields (app_id is auto-extracted, no field for it)
    const qobuzEmail = document.getElementById('qobuz-email');
    const qobuzPassword = document.getElementById('qobuz-password');
    if (qobuzEmail) qobuzEmail.value = state.config.qobuz_email || '';
    if (qobuzPassword) {
        qobuzPassword.value = '';
        qobuzPassword.placeholder = state.config.qobuz_password_set
            ? '••••••••••••  (opgeslagen)'
            : 'Wachtwoord';
    }
    const qobuzStatus = document.getElementById('qobuz-settings-status');
    if (qobuzStatus) {
        const configured = state.config.qobuz_password_set && state.config.qobuz_email;
        qobuzStatus.classList.toggle('connected', !!configured);
        qobuzStatus.querySelector('.status-text').textContent = configured ? 'Configured' : 'Not configured';
    }

    // ListenBrainz settings — mask the token, pre-fill the username
    const lbToken = document.getElementById('lb-token');
    const lbUsername = document.getElementById('lb-username');
    if (lbToken) {
        lbToken.value = '';
        lbToken.placeholder = state.config.listenbrainz_token_set
            ? '••••••••  (opgeslagen)'
            : 'Jouw LB user token';
    }
    if (lbUsername) {
        lbUsername.value = state.config.listenbrainz_username || '';
    }
    // Last.fm settings — mask API key/secret, pre-fill username
    const lfApiKey = document.getElementById('lastfm-api-key');
    const lfApiSecret = document.getElementById('lastfm-api-secret');
    const lfUsername = document.getElementById('lastfm-username');
    if (lfApiKey) {
        lfApiKey.value = '';
        lfApiKey.placeholder = state.config.lastfm_api_key_set
            ? '••••••••  (opgeslagen)'
            : 'Your Last.fm API key';
    }
    if (lfApiSecret) {
        lfApiSecret.value = '';
        lfApiSecret.placeholder = state.config.lastfm_api_key_set
            ? '••••••••  (opgeslagen)'
            : 'Your Last.fm API secret';
    }
    if (lfUsername) {
        lfUsername.value = state.config.lastfm_username || '';
    }

    const lbStatus = document.getElementById('lb-settings-status');
    if (lbStatus) {
        const configured = !!state.config.listenbrainz_token_set;
        lbStatus.classList.toggle('connected', configured);
        const txt = lbStatus.querySelector('.status-text');
        if (txt) {
            txt.textContent = configured
                ? (state.config.listenbrainz_username
                    ? `Connected as ${state.config.listenbrainz_username}`
                    : 'Connected')
                : 'Not configured';
        }
    }
}

export function showProviderSettings(provider) {
    // Hide all provider-specific settings
    const cloudSettings = document.getElementById('cloud-provider-settings');
    const ollamaSettings = document.getElementById('ollama-settings');
    const customSettings = document.getElementById('custom-settings');

    cloudSettings.classList.add('hidden');
    ollamaSettings.classList.add('hidden');
    customSettings.classList.add('hidden');

    // Show the appropriate settings
    if (provider === 'ollama') {
        ollamaSettings.classList.remove('hidden');
        // Trigger Ollama status check if URL is set
        const ollamaUrl = document.getElementById('ollama-url').value.trim();
        if (ollamaUrl) {
            checkOllamaStatus(ollamaUrl);
        }
    } else if (provider === 'custom') {
        customSettings.classList.remove('hidden');
        updateCustomMaxTracks();
    } else {
        // Cloud providers (anthropic, openai, gemini)
        cloudSettings.classList.remove('hidden');
    }
}

export async function checkOllamaStatus(url) {
    const statusEl = document.getElementById('ollama-status');
    const statusDot = statusEl.querySelector('.status-dot');
    const statusText = statusEl.querySelector('.status-text');

    statusText.textContent = 'Checking...';
    statusEl.classList.remove('connected', 'error');

    try {
        const status = await fetchOllamaStatus(url);
        if (status.connected) {
            statusEl.classList.add('connected');
            if (status.model_count > 0) {
                statusText.textContent = `Connected (${status.model_count} models)`;
                await populateOllamaModelDropdowns(url);
            } else {
                statusEl.classList.remove('connected');
                statusEl.classList.add('error');
                statusText.textContent = 'No models installed';
            }
        } else {
            statusEl.classList.add('error');
            statusText.textContent = status.error || 'Connection failed';
        }
    } catch (error) {
        statusEl.classList.add('error');
        statusText.textContent = 'Connection failed';
    }
}

export async function populateOllamaModelDropdowns(url) {
    const analysisSelect = document.getElementById('ollama-model-analysis');
    const generationSelect = document.getElementById('ollama-model-generation');
    const fastSelect = document.getElementById('ollama-model-fast');

    try {
        const response = await fetchOllamaModels(url);
        if (response.error) {
            console.error('Failed to fetch Ollama models:', response.error);
            return;
        }

        const models = response.models || [];
        const options = models.map(m => `<option value="${escapeHtml(m.name)}">${escapeHtml(m.name)}</option>`).join('');
        const defaultOption = '<option value="">-- Select model --</option>';
        const noneOption = '<option value="">(zelfde als generatie)</option>';

        analysisSelect.innerHTML = defaultOption + options;
        generationSelect.innerHTML = defaultOption + options;
        if (fastSelect) fastSelect.innerHTML = noneOption + options;

        // Enable the dropdowns
        analysisSelect.disabled = false;
        generationSelect.disabled = false;
        if (fastSelect) fastSelect.disabled = false;

        // Restore saved model selections from config
        if (state.config?.model_analysis) {
            analysisSelect.value = state.config.model_analysis;
        }
        if (state.config?.model_generation) {
            generationSelect.value = state.config.model_generation;
        }
        if (fastSelect && state.config?.fast_model) {
            fastSelect.value = state.config.fast_model;
        }

        // Auto-save fast_model on change
        if (fastSelect && !fastSelect.dataset.autoSaveWired) {
            fastSelect.dataset.autoSaveWired = '1';
            fastSelect.addEventListener('change', async () => {
                try {
                    await updateConfig({ fast_model: fastSelect.value });
                    state.config = state.config || {};
                    state.config.fast_model = fastSelect.value;
                    const lbl = fastSelect.value || '(zelfde als generatie)';
                    fastSelect.title = `Opgeslagen: ${lbl}`;
                } catch (e) {
                    console.error('fast_model save failed', e);
                }
            });
        }

        // If neither model is configured and models are available, default both to first model
        if (!analysisSelect.value && !generationSelect.value && models.length > 0) {
            const firstModel = models[0].name;
            analysisSelect.value = firstModel;
            generationSelect.value = firstModel;
        }

        // If a model is selected, fetch its context info
        if (analysisSelect.value) {
            await updateOllamaContextDisplay(url, analysisSelect.value);
        }
    } catch (error) {
        console.error('Error populating Ollama models:', error);
    }
}

export async function updateOllamaContextDisplay(url, modelName) {
    const contextEl = document.getElementById('ollama-context-window');
    const maxTracksEl = document.getElementById('ollama-max-tracks');

    if (!modelName) {
        contextEl.textContent = '-- tokens';
        maxTracksEl.textContent = '(~-- tracks)';
        return;
    }

    try {
        const info = await fetchOllamaModelInfo(url, modelName);
        if (info && info.context_window) {
            // Show context window with note if using default
            const isDefault = info.context_detected === false;
            const defaultNote = isDefault ? ' (default - not detected)' : '';
            contextEl.textContent = `${info.context_window.toLocaleString()} tokens${defaultNote}`;

            // Calculate max tracks: (context - 1000 buffer) / 50 tokens per track
            const maxTracks = Math.max(100, Math.floor((info.context_window * 0.9 - 1000) / 50));
            maxTracksEl.textContent = `(~${maxTracks.toLocaleString()} tracks)`;

            // Save the context window to config so backend can calculate max_tracks_to_ai
            try {
                await updateConfig({ ollama_context_window: info.context_window });
                // Refresh config state to get updated max_tracks_to_ai
                state.config = await fetchConfig();
            } catch (saveError) {
                console.error('Failed to save Ollama context window:', saveError);
            }
        } else {
            contextEl.textContent = '32,768 tokens (default)';
            maxTracksEl.textContent = '(~556 tracks)';
        }
    } catch (error) {
        contextEl.textContent = '-- tokens';
        maxTracksEl.textContent = '(~-- tracks)';
    }
}

export function updateCustomMaxTracks() {
    const contextInput = document.getElementById('custom-context-window');
    const maxTracksEl = document.getElementById('custom-max-tracks');

    const contextWindow = parseInt(contextInput.value) || 32768;
    // Calculate max tracks: (context - 1000 buffer) / 50 tokens per track
    const maxTracks = Math.max(100, Math.floor((contextWindow * 0.9 - 1000) / 50));
    maxTracksEl.textContent = `(~${maxTracks.toLocaleString()} tracks)`;
}

export function validateCustomProviderInputs() {
    const customUrl = document.getElementById('custom-url').value.trim();
    const customModel = document.getElementById('custom-model').value.trim();
    const customContext = parseInt(document.getElementById('custom-context-window').value);

    const errors = [];

    // Validate URL
    if (customUrl) {
        try {
            const url = new URL(customUrl);
            if (!['http:', 'https:'].includes(url.protocol)) {
                errors.push('Custom URL must use http or https protocol');
            }
        } catch {
            errors.push('Custom URL is not a valid URL');
        }
    }

    // Validate context window
    if (isNaN(customContext) || customContext < 512) {
        errors.push('Context window must be at least 512 tokens');
    } else if (customContext > 2000000) {
        errors.push('Context window seems too large (max 2M tokens)');
    }

    return errors;
}

export function validateCustomUrlInline() {
    const customUrl = document.getElementById('custom-url').value.trim();
    const errorEl = document.getElementById('custom-url-error');

    if (!customUrl) {
        errorEl.textContent = '';
        errorEl.classList.add('hidden');
        return;
    }

    try {
        const url = new URL(customUrl);
        if (!['http:', 'https:'].includes(url.protocol)) {
            errorEl.textContent = 'Must use http or https protocol';
            errorEl.classList.remove('hidden');
        } else {
            errorEl.textContent = '';
            errorEl.classList.add('hidden');
        }
    } catch {
        errorEl.textContent = 'Invalid URL format';
        errorEl.classList.remove('hidden');
    }
}

export function validateCustomContextInline() {
    const customContext = parseInt(document.getElementById('custom-context-window').value);
    const errorEl = document.getElementById('custom-context-error');

    if (isNaN(customContext) || customContext < 512) {
        errorEl.textContent = 'Must be at least 512 tokens';
        errorEl.classList.remove('hidden');
    } else if (customContext > 2000000) {
        errorEl.textContent = 'Cannot exceed 2,000,000 tokens';
        errorEl.classList.remove('hidden');
    } else {
        errorEl.textContent = '';
        errorEl.classList.add('hidden');
    }
}

export function updateConfigRequiredUI() {
    const roonConnected = state.config?.roon_connected ?? false;
    const llmConfigured = state.config?.llm_configured ?? false;

    // Elements that require configuration
    const analyzeBtn = document.getElementById('analyze-prompt-btn');
    const continueBtn = document.getElementById('continue-to-filters-btn');
    const searchBtn = document.getElementById('search-tracks-btn');
    const searchInput = document.getElementById('track-search-input');
    const promptTextarea = document.querySelector('.prompt-textarea');

    // Hints
    const hintPrompt = document.getElementById('llm-required-hint-prompt');
    const hintDimensions = document.getElementById('llm-required-hint-dimensions');
    const hintSeed = document.getElementById('llm-required-hint-seed');

    // Determine what's missing
    const needsRoon = !roonConnected;
    const needsLLM = !llmConfigured;
    const needsConfig = needsRoon || needsLLM;

    // Update button/input states
    if (analyzeBtn) analyzeBtn.disabled = needsConfig;
    if (continueBtn) continueBtn.disabled = needsLLM; // Only needs LLM at this point
    if (searchBtn) searchBtn.disabled = needsRoon;
    if (searchInput) searchInput.disabled = needsRoon;
    if (promptTextarea) promptTextarea.disabled = needsRoon;

    // Build hint message based on what's missing
    let hintMessage = '';
    if (needsRoon && needsLLM) {
        hintMessage = '<a href="#" data-view="settings">Configure Roon and an LLM provider</a> to continue';
    } else if (needsRoon) {
        hintMessage = '<a href="#" data-view="settings">Connect to Roon</a> to continue';
    } else if (needsLLM) {
        hintMessage = '<a href="#" data-view="settings">Configure an LLM provider</a> to continue';
    }

    // Update hint content and visibility
    [hintPrompt, hintSeed].forEach(hint => {
        if (hint) {
            hint.innerHTML = hintMessage;
            hint.hidden = !needsConfig;
        }
    });

    // Dimensions hint only needs LLM (Roon is already connected at this step)
    if (hintDimensions) {
        hintDimensions.innerHTML = needsLLM ? '<a href="#" data-view="settings">Configure an LLM provider</a> to continue' : '';
        hintDimensions.hidden = !needsLLM;
    }
}

export function updateFooter() {
    const footerVersion = document.getElementById('footer-version');
    if (footerVersion && state.config?.version) {
        footerVersion.textContent = `v${state.config.version}`;
    }

    const footerModel = document.getElementById('footer-model');
    if (footerModel && state.config) {
        let modelText;
        if (state.config.llm_configured) {
            const analysis = state.config.model_analysis;
            const generation = state.config.model_generation;

            if (analysis && generation && analysis !== generation) {
                // Two different models - show both
                modelText = `${analysis} / ${generation}`;
            } else if (generation) {
                // Same model or only generation set
                modelText = generation;
            } else if (analysis) {
                modelText = analysis;
            } else {
                modelText = state.config.llm_provider;
            }
        } else {
            // Not configured - show "not configured" regardless of provider selection
            modelText = 'llm not configured';
        }
        footerModel.textContent = modelText;
        footerModel.title = modelText; // Tooltip for truncated names
    }
}

export let loadingIntervalId = null;

export function setLoading(loading, message = 'Loading...', substeps = null) {
    state.loading = loading;
    const overlay = document.getElementById('loading-overlay');
    const messageEl = document.getElementById('loading-message');
    const substepEl = document.getElementById('loading-substep');

    // Clear any existing substep interval
    if (loadingIntervalId) {
        clearInterval(loadingIntervalId);
        loadingIntervalId = null;
    }

    overlay.classList.toggle('hidden', !loading);
    if (loading) { lockScroll(); } else { removeNoScrollIfNoModals(); }
    messageEl.textContent = message;

    const contentEl = overlay.querySelector('.loading-modal-content');
    if (substepEl) {
        if (loading) {
            // Pre-measure the widest possible text to prevent layout shifts
            if (contentEl && substeps && substeps.length > 0) {
                const allTexts = [message, ...substeps];
                substepEl.style.visibility = 'hidden';
                let maxWidth = contentEl.offsetWidth;
                for (const text of allTexts) {
                    substepEl.textContent = text;
                    maxWidth = Math.max(maxWidth, contentEl.scrollWidth);
                }
                contentEl.style.minWidth = maxWidth + 'px';
                substepEl.style.visibility = '';
            }

            if (substeps && substeps.length > 0) {
                // Show progressive substeps
                let stepIndex = 0;
                substepEl.textContent = substeps[0];

                loadingIntervalId = setInterval(() => {
                    stepIndex++;
                    if (stepIndex < substeps.length) {
                        substepEl.textContent = substeps[stepIndex];
                    }
                    // Stay on last step until done
                }, 2000); // Change message every 2 seconds
            } else {
                substepEl.textContent = '';
            }
        } else {
            substepEl.textContent = '';
            if (contentEl) contentEl.style.minWidth = '';
        }
    }
}

// Toast types → icon glyph
const _TOAST_ICONS = { success: '✓', error: '⚠', info: '↻' };

function _renderToast(toastEl, type, message, subtitle, progress, onClose) {
    const icon = _TOAST_ICONS[type] || 'ℹ';
    toastEl.innerHTML = `
        <div class="toast-icon">${icon}</div>
        <div class="toast-body">
            <div class="toast-title">${escapeHtml(message)}</div>
            ${subtitle ? `<div class="toast-sub">${escapeHtml(subtitle)}</div>` : ''}
            ${progress !== undefined && progress !== null ? `
                <div class="toast-progress">
                    <div class="toast-progress-fill" style="width:${Math.max(0, Math.min(100, progress))}%"></div>
                </div>` : ''}
        </div>
        <button class="toast-close" aria-label="Sluiten">&times;</button>
    `;
    toastEl.querySelector('.toast-close')?.addEventListener('click', onClose);
}

export function showError(message, subtitle, progress) {
    const toast = document.getElementById('error-toast');
    if (!toast) return;
    _renderToast(toast, 'error', message, subtitle, progress, hideError);
    toast.classList.remove('hidden');
    setTimeout(() => hideError(), 5000);
}

export function hideError() {
    document.getElementById('error-toast')?.classList.add('hidden');
}

export function showSuccess(message, subtitle, progress) {
    const toast = document.getElementById('success-toast');
    if (!toast) return;
    _renderToast(toast, 'success', message, subtitle, progress, hideSuccess);
    toast.classList.remove('hidden');
    setTimeout(() => hideSuccess(), 3000);
}

export function hideSuccess() {
    document.getElementById('success-toast')?.classList.add('hidden');
}

export function showSuccessModal(name, trackCount, playlistUrl) {
    const modal = document.getElementById('success-modal');
    const summary = document.getElementById('success-modal-summary');
    const openBtn = document.getElementById('open-in-roon-btn');

    summary.textContent = `"${name}" queued ${trackCount} track${trackCount !== 1 ? 's' : ''} to Roon.`;

    // Roon has no web URLs — always hide the "Open in Roon" link button
    openBtn.style.display = 'none';

    modal.classList.remove('hidden');
    lockScroll();
    focusManager.openModal(modal);
}

export function dismissSuccessModal() {
    dismissModal('success-modal');
}

export function resetPlaylistState() {
    state.step = 'input';
    state.prompt = '';
    state.questions = [];
    state.questionAnswers = [];
    state.questionTexts = [];
    state.filterAnalysisPromise = null;
    state.seedTrack = null;
    state.dimensions = [];
    state.selectedDimensions = [];
    state.additionalNotes = '';
    state.selectedGenres = [];
    state.selectedDecades = [];
    state.playlist = [];
    state.playlistName = '';
    state.tokenCount = 0;
    state.estimatedCost = 0;
    state.sessionTokens = 0;
    state.sessionCost = 0;
    state.playlistTitle = '';
    state.narrative = '';
    state.trackReasons = {};
    state.userRequest = '';
    state.selectedTrackKey = null;
    state.lastRequest = null;
    document.getElementById('prompt-input').value = '';
    // Hide refinement panel and reset button
    const refinePanel = document.getElementById('refine-panel');
    if (refinePanel) refinePanel.classList.add('hidden');
    const refineBtn = document.getElementById('refine-playlist-btn');
    if (refineBtn) {
        refineBtn.classList.add('hidden');
        refineBtn.setAttribute('aria-expanded', 'false');
    }
    const refineInput = document.getElementById('refine-input');
    if (refineInput) refineInput.value = '';
    updateStep();
}

export function hideSuccessModal() {
    const modal = document.getElementById('success-modal');
    modal.classList.add('hidden');
    removeNoScrollIfNoModals();
    focusManager.closeModal(modal);
    resetPlaylistState();
}
