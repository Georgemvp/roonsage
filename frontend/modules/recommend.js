// =============================================================================
// Recommendation View (006)
// =============================================================================

import { state } from './state.js';
import { apiCall, fetchLibraryStats } from './api.js';
import { escapeHtml, artPlaceholderHtml, trackArtHtml } from './utils.js';
import { focusManager } from './focus.js';
import { setLoading, showError, updateRecModelSuggestion, updateAlbumLimitButtons, isMobileView, openBottomSheet, hideError, updateStep, resetPlaylistState } from './ui.js';
import { showTimedStepLoading, showStepLoading, hideStepLoading, updateStepProgress } from './loading.js';
import { handleRefreshLibrary, checkLibraryStatus, showSyncModal } from './library.js';
import { markHistoryStale } from './history.js';
import { pendingNavHash, setPendingNavHash } from './events.js';
import { hashForCurrentState } from './router.js';
import { lockScroll, refreshClientList, dismissRecRestartModal, dismissPlaylistRestartModal } from './instant-queue.js';

export const PLAYLIST_PROMPT_GROUPS = [
    /* Mood / Energy */
    [
        "Happy but not annoying about it",
        "Sad in a way that feels good",
        "Angry, the productive kind",
        "Euphoric, peak of a good night",
        "Dreamy and slightly out of focus",
        "Quiet devastation, keep moving",
        "Wistful, not wallowing",
        "Warm like the end of something good",
        "Tense, something's about to happen",
        "Bittersweet and okay with it",
        "Dark but not hopeless",
        "Hopeful, first day of something",
        "Numb, just need the room filled",
        "Giddy, almost embarrassingly so",
        "Restless, needs to match the mood",
        "Nostalgic for something nameless",
        "Melancholy with good bones",
        "Calm but not sleepy",
        "Raw and unpolished",
        "The comedown after something great",
    ],
    /* Activity / Context */
    [
        "Cooking slowly, no one's waiting",
        "Late night drive, no destination",
        "Last hour before a deadline",
        "Long run, needs to pull you forward",
        "Pre-game, getting the nerve up",
        "Dinner party winding down well",
        "Highway, windows cracked",
        "Deep work, two hours, no surfacing",
        "Getting ready, building confidence",
        "Decompressing after a hard week",
        "Solo night in, no explanation",
        "Long flight, trying not to think",
        "Cleaning like you mean it",
        "Slow afternoon in the garden",
        "Walk home after something big",
        "After the party, just the dishes",
        "Slow dance, no one watching",
        "First coffee, easing in gently",
        "Walking a city you don't know",
        "BBQ that peaked an hour ago",
    ],
    /* Era / Decade */
    [
        "1970s soul, windows down",
        "Classic rock with actual grit",
        "1983, in the best possible way",
        "Early 90s indie, four-track raw",
        "Late 90s, before it all sped up",
        "1967, before psychedelia curdled",
        "2004 indie rock, blog-era peak",
        "Motown, hits and deep cuts both",
        "80s R&B, lush and unhurried",
        "90s hip hop, NY and LA both",
        "1972, recorded in someone's house",
        "Early 2010s, last of guitar bands",
        "British Invasion, no novelty acts",
        "1957 jazz, smoke and late hours",
        "2003 pop-punk, embarrassingly good",
        "Outlaw country, pre-mainstream",
        "80s post-punk, angular and cold",
        "90s rave, before it was a brand",
        "Krautrock, motorik and meditative",
        "Late 80s hip hop, the invention",
    ],
    /* Genre / Style */
    [
        "Jazz, late and smoky, no hurry",
        "Ambient, no pulse, just texture",
        "Punk, fast and under two minutes",
        "Soul with real weight behind it",
        "Metal that means what it says",
        "Acoustic folk, campfire honest",
        "Reggae, slow afternoon, no agenda",
        "Electronic, precise and cold",
        "Blues that invented everything else",
        "Country that earns the emotion",
        "Afrobeat, propulsive and communal",
        "Gospel with real conviction",
        "Indie pop, bright and aching",
        "Hardcore with something to say",
        "Bossa nova, unhurried and warm",
        "Lo-fi hip hop, dusty and patient",
        "Post-rock that earns its ending",
        "Disco, uncut and unapologetic",
        "Americana with dirt on it",
        "Shoegaze, loud and interior",
    ],
    /* Tempo / Danceability */
    [
        "Slow, nothing is rushing anywhere",
        "Midtempo groove, head nodding only",
        "Full energy, don't let up",
        "Dance floor, 120 BPM minimum",
        "Half-tempo, barely moving",
        "Builds slow, earns the drop",
        "Upbeat without being relentless",
        "Shuffling, laidback swing feel",
        "Relentless, no room to breathe",
        "Hypnotic, same thing, slight shifts",
        "Short and punchy, keep moving",
        "Slow burn that actually pays off",
        "Danceable, room for conversation",
        "Fast and slightly out of control",
        "Gentle pulse, background presence",
        "Syncopated and playful",
        "Doom tempo, slow and heavy",
        "Bouncy and major key, unashamed",
        "Sparse, lots of space in it",
        "Peaks and valleys, earns the quiet",
    ],
];

export const REC_PROMPT_GROUPS = [
    /* Mood / Vibe */
    [
        "Melancholy I want to sit inside",
        "Warm and analog, like vinyl sounds",
        "Bleak and beautiful at once",
        "Joyful with no irony in it",
        "Unsettling in a way I can't name",
        "Tender without being soft",
        "Cold and a little industrial",
        "Romantic but not embarrassing",
        "Restless and searching",
        "Nostalgic for a time before me",
        "Built for a real release",
        "Dense and patient, rewards time",
        "Strange and slightly off-kilter",
        "Cinematic, feels like a place",
        "Austere, almost nothing there",
        "Deeply sad, don't soften it",
        "Euphoric and earned, not cheap",
    ],
    /* Sounds-Like */
    [
        "Radiohead, but room to breathe",
        "Nick Cave with some hope left",
        "Early Springsteen, less polish",
        "Joni Mitchell making a jazz record",
        "Prince stripped to the bones",
        "Arcade Fire, quieter ambition",
        "Kendrick but more internal",
        "Tom Waits went fully ambient",
        "D'Angelo but tighter",
        "Velvet Underground energy",
        "PJ Harvey, more acoustic",
        "Late Miles Davis, electric",
        "Talking Heads but darker",
        "Coltrane went electric",
        "Portishead but less cold",
        "Neil Young without the dust",
        "Massive Attack but warmer",
    ],
    /* Genre Exploration */
    [
        "First jazz album, where to start",
        "Introduce me to krautrock",
        "Best entry point for ambient",
        "Soul that invented the form",
        "Metal without prior loyalty needed",
        "Country with actual grit in it",
        "Electronic that feels something",
        "Folk that doesn't lose me",
        "Hip hop with real patience in it",
        "Reggae beyond the obvious three",
        "Post-punk, angular, still alive",
        "Classical with a clear narrative",
        "Afrobeat with real propulsion",
        "Gospel with conviction, not comfort",
        "Experimental but I can stay",
        "Brazilian music beyond bossa",
        "Blues that explains what came after",
    ],
    /* Era / Era-Adjacent */
    [
        "Timeless, no decade owns it",
        "Pure 1970s warmth, room sound",
        "Sounds like 1983, best way",
        "Late 60s psychedelia, still intact",
        "Early 90s indie, lo-fi earnest",
        "1970s jazz fusion at its peak",
        "Mid-90s hip hop, NY and hungry",
        "80s synth that aged well",
        "Late 90s slowcore, unsparing",
        "2001–2005 indie rock landmark",
        "1960s soul, Detroit or Memphis",
        "70s singer-songwriter, confessional",
        "80s post-punk, cold and correct",
        "90s electronic, pre-mainstream",
        "Early 2000s R&B, sophisticated",
        "Recorded in the 70s, sounds eternal",
        "1960s modal jazz, serious",
    ],
    /* Emotional Occasion */
    [
        "Breakup, raw and recent",
        "Something ended well",
        "First listen back after time away",
        "Celebrating quietly, just yourself",
        "Heavy with no explanation",
        "The week before everything changes",
        "Feeling invisible, fine with it",
        "Early stage of falling for someone",
        "Grieving, need company in it",
        "Long Sunday, nowhere to be",
        "Proud and exhausted equally",
        "3am, completely awake",
        "The last day of something",
        "Ready to start over, actually ready",
        "Complicated happy",
        "Homesick for somewhere unreachable",
        "Tired of holding it together",
    ],
    /* Deep Cuts / Underrated */
    [
        "A masterpiece nobody talks about",
        "Criminally overlooked",
        "Best album, not their famous one",
        "Too weird for radio, too good",
        "One great record, then gone",
        "Cult classic, devoted few",
        "Critics loved it, world moved on",
        "Ahead of its time",
        "The album that got away",
        "Debut that deserved a career",
        "Side project better than the main",
        "Reissued, finally getting its due",
        "Sounds like nothing else here",
        "Famous producer, album outshines",
        "The one even fans missed",
    ],
];

export async function initRecommendView() {
    if (state.config?.roon_connected) {
        loadRecommendFilters();
    }
    renderPromptPills('rec-prompt-pills', 'rec-prompt-shuffle', REC_PROMPT_GROUPS);
    updateRecStep();
}

export async function loadRecommendFilters() {
    // Reuse genres/decades already fetched by loadSettings() if available
    if (state.availableGenres.length === 0) {
        try {
            const stats = await apiCall('/library/stats');
            state.availableGenres = stats.genres.map(g => ({ name: g.name, count: g.count }));
            state.availableDecades = stats.decades.map(d => ({ name: d.name, count: d.count }));
        } catch (e) {
            console.error('Failed to load recommend filters:', e);
            return;
        }
    }
    // No chips selected = no filter (all albums included)
    renderRecFilterChips();
    updateAlbumLimitButtons();
    updateRecAlbumPreview();
}

export function renderRecFilterChips() {
    const genreContainer = document.getElementById('rec-genre-chips');
    const decadeContainer = document.getElementById('rec-decade-chips');
    if (!genreContainer || !decadeContainer) return;

    genreContainer.innerHTML = state.availableGenres.map(genre => {
        const isSelected = state.rec.selectedGenres.includes(genre.name);
        return `<button class="chip ${isSelected ? 'selected' : ''}"
                data-genre="${escapeHtml(genre.name)}"
                aria-pressed="${isSelected}">
            ${escapeHtml(genre.name)}
        </button>`;
    }).join('');

    decadeContainer.innerHTML = state.availableDecades.map(decade => {
        const isSelected = state.rec.selectedDecades.includes(decade.name);
        return `<button class="chip ${isSelected ? 'selected' : ''}"
                data-decade="${escapeHtml(decade.name)}"
                aria-pressed="${isSelected}">
            ${escapeHtml(decade.name)}
        </button>`;
    }).join('');

    // Sync toggle labels
    const genreToggle = document.getElementById('rec-genre-toggle-all');
    if (genreToggle) {
        const allSelected = state.availableGenres.length > 0 &&
            state.rec.selectedGenres.length === state.availableGenres.length;
        genreToggle.textContent = allSelected ? 'Deselect All' : 'Select All';
    }
    const decadeToggle = document.getElementById('rec-decade-toggle-all');
    if (decadeToggle) {
        const allSelected = state.availableDecades.length > 0 &&
            state.rec.selectedDecades.length === state.availableDecades.length;
        decadeToggle.textContent = allSelected ? 'Deselect All' : 'Select All';
    }
}

export function pickOnePerGroup(groups) {
    return groups.map(g => g[Math.floor(Math.random() * g.length)]);
}

export function renderPromptPills(containerId, shuffleBtnId, groups) {
    const container = document.getElementById(containerId);
    if (!container) return;
    const selected = pickOnePerGroup(groups);
    container.innerHTML = selected.map(p =>
        `<button class="prompt-pill">${escapeHtml(p)}</button>`
    ).join('');
    const btn = document.getElementById(shuffleBtnId);
    if (btn) btn.hidden = groups.some(g => g.length <= 1);
}

export function shufflePromptPills(containerId, groups) {
    const container = document.getElementById(containerId);
    if (!container) return;
    const currentTexts = new Set(
        [...container.querySelectorAll('.prompt-pill')].map(p => p.textContent)
    );
    const selected = groups.map(group => {
        const available = group.filter(p => !currentTexts.has(p));
        const pool = available.length > 0 ? available : group;
        return pool[Math.floor(Math.random() * pool.length)];
    });
    const pills = container.querySelectorAll('.prompt-pill');
    pills.forEach(p => { p.style.opacity = '0'; });
    setTimeout(() => {
        pills.forEach((p, i) => {
            if (i < selected.length) p.textContent = selected[i];
        });
        pills.forEach(p => { p.style.opacity = '1'; });
    }, 150);
}

export function updateRecStep() {
    window.scrollTo(0, 0);

    const steps = ['prompt', 'refine', 'setup', 'results'];
    const currentIndex = steps.indexOf(state.rec.step);

    // Update panels
    document.querySelectorAll('.rec-panel').forEach(panel => {
        const panelStep = panel.id.replace('rec-step-', '');
        panel.classList.toggle('active', panelStep === state.rec.step);
    });

    // Update progress bar
    document.querySelectorAll('#rec-steps .step').forEach(stepEl => {
        const stepName = stepEl.dataset.step;
        const stepIndex = steps.indexOf(stepName);
        stepEl.classList.toggle('active', stepName === state.rec.step);
        stepEl.classList.toggle('completed', stepIndex < currentIndex);
    });

    // Update connectors
    document.querySelectorAll('#rec-steps .step-connector').forEach((connector, i) => {
        connector.classList.toggle('completed', i < currentIndex);
    });

    // Hide progress bar on results
    const isResults = state.rec.step === 'results';
    const recProgress = document.getElementById('rec-steps');
    if (recProgress) {
        recProgress.style.display = isResults ? 'none' : '';
    }

    // Toggle footer content for results vs other screens
    const appFooter = document.querySelector('.app-footer');
    if (appFooter) appFooter.classList.toggle('app-footer--results', isResults);

    // Hide regenerate button — it's playlist-only
    const regenBtn = document.getElementById('regenerate-btn');
    if (regenBtn) regenBtn.style.display = 'none';
}

export function setRecStep(step) {
    state.rec.step = step;
    updateRecStep();
}

// AbortController for cancelling in-flight recommend preview requests
export let recPreviewController = null;
export let recPreviewLoadingTimeout = null;

export async function updateRecAlbumPreview() {
    const countEl = document.getElementById('rec-preview-count');
    const costEl = document.getElementById('rec-preview-cost');
    if (!countEl) return;

    // Cancel any in-flight request
    if (recPreviewController) {
        recPreviewController.abort();
    }
    recPreviewController = new AbortController();

    // Clear any pending loading timeout
    if (recPreviewLoadingTimeout) {
        clearTimeout(recPreviewLoadingTimeout);
    }

    // Only show loading state if request takes longer than 150ms
    recPreviewLoadingTimeout = setTimeout(() => {
        countEl.innerHTML = '<span class="preview-spinner"></span> Counting...';
        costEl.textContent = '';
    }, 150);

    try {
        // All selected = no filter (avoids excluding untagged albums)
        const allGenres = state.availableGenres.length > 0 &&
            state.rec.selectedGenres.length === state.availableGenres.length;
        const allDecades = state.availableDecades.length > 0 &&
            state.rec.selectedDecades.length === state.availableDecades.length;
        const params = new URLSearchParams();
        if (!allGenres && state.rec.selectedGenres.length) {
            params.set('genres', state.rec.selectedGenres.join(','));
        }
        if (!allDecades && state.rec.selectedDecades.length) {
            params.set('decades', state.rec.selectedDecades.join(','));
        }
        params.set('max_albums', state.rec.maxAlbumsToAI);

        const response = await fetch(`/api/recommend/albums/preview?${params}`, {
            signal: recPreviewController.signal,
        });

        if (!response.ok) {
            throw new Error('Failed to get album preview');
        }

        const data = await response.json();

        // Clear loading timeout - response arrived fast
        clearTimeout(recPreviewLoadingTimeout);

        updateRecPreviewDisplay(data.matching_albums, data.albums_to_send, data.estimated_cost);
    } catch (error) {
        // Clear loading timeout on error too
        clearTimeout(recPreviewLoadingTimeout);

        // Ignore abort errors - they're expected when cancelling
        if (error.name === 'AbortError') {
            return;
        }
        console.error('Album preview error:', error);
        countEl.textContent = '-- albums';
        costEl.textContent = 'Est. cost: --';
    }
}

export function updateRecPreviewDisplay(matchingAlbums, albumsToSend, estimatedCost) {
    const countEl = document.getElementById('rec-preview-count');
    const costEl = document.getElementById('rec-preview-cost');

    // Update album count display
    if (albumsToSend < matchingAlbums) {
        countEl.textContent = `${matchingAlbums.toLocaleString()} albums (sending ${albumsToSend.toLocaleString()} to AI)`;
    } else {
        countEl.textContent = `${matchingAlbums.toLocaleString()} albums`;
    }

    // For local providers, hide cost estimate
    const isLocalProvider = state.config?.is_local_provider ?? false;
    if (isLocalProvider) {
        costEl.textContent = '';
    } else if (estimatedCost > 0) {
        costEl.textContent = `Est. cost: $${estimatedCost.toFixed(4)}`;
    } else {
        costEl.textContent = 'Est. cost: --';
    }

    // Update "All/Max" button label based on whether filtered albums fit in context
    const maxBtn = document.querySelector('.album-limit-selector .limit-btn[data-limit="0"]');
    if (maxBtn && state.config) {
        const maxAllowed = state.config.max_albums_to_ai || 2500;
        maxBtn.textContent = matchingAlbums <= maxAllowed ? 'All' : `Max (${maxAllowed.toLocaleString()})`;
    }
}

export async function handlePromptSubmit() {
    const prompt = document.getElementById('rec-prompt-input')?.value || '';
    if (!prompt.trim()) {
        showError('Please enter a prompt');
        return;
    }
    state.rec.prompt = prompt;

    const btn = document.getElementById('rec-prompt-next');
    if (btn) btn.disabled = true;

    const stepLoader = showTimedStepLoading([
        { id: 'analyzing', text: 'Analyzing your request...', status: 'active' },
        { id: 'questions', text: 'Crafting questions...', status: 'pending' },
    ]);

    // Fire filter analysis in parallel (cached as a promise for the setup step)
    state.rec.filterAnalysisPromise = apiCall('/recommend/analyze-prompt', {
        method: 'POST',
        body: JSON.stringify({
            prompt: state.rec.prompt,
            genres: state.availableGenres.map(g => g.name),
            decades: state.availableDecades.map(d => d.name),
        }),
    }).catch(() => null);  // Swallow errors — fallback handled in handleRefineNext

    try {
        // Fire question generation (only needs the prompt)
        const data = await apiCall('/recommend/questions', {
            method: 'POST',
            body: JSON.stringify({ prompt: state.rec.prompt }),
        });

        state.rec.questions = data.questions;
        state.rec.sessionId = data.session_id;
        state.rec.answers = data.questions.map(() => null);
        state.rec.answerTexts = data.questions.map(() => '');

        renderRecQuestions();
        setRecStep('refine');
    } catch (e) {
        showError(e.message);
    } finally {
        stepLoader.finish();
        if (btn) btn.disabled = false;
    }
}

export async function handleRefineNext() {
    const infoBanner = document.getElementById('rec-filter-info');

    // Await the cached filter analysis promise
    const filterData = await state.rec.filterAnalysisPromise;
    if (filterData) {
        state.rec.selectedGenres = filterData.genres || [];
        state.rec.selectedDecades = filterData.decades || [];
        if (infoBanner) infoBanner.classList.remove('hidden');
    } else {
        // Fallback: all included (empty = no filter)
        state.rec.selectedGenres = state.availableGenres.map(g => g.name);
        state.rec.selectedDecades = state.availableDecades.map(d => d.name);
        if (infoBanner) infoBanner.classList.add('hidden');
    }

    renderRecFilterChips();
    updateRecAlbumPreview();
    setRecStep('setup');
}


export function renderQuestions(questions, answers, answerTexts, containerId) {
    const container = document.getElementById(containerId);
    if (!container) return;

    container.innerHTML = questions.map((q, qi) => `
        <div class="question-card" data-question-index="${qi}">
            <p class="question-text">${escapeHtml(q.question_text)}</p>
            <div class="question-options">
                ${q.options.map((opt, oi) => `
                    <button class="option-pill ${answers[qi] === opt ? 'selected' : ''}"
                            data-question="${qi}" data-option="${oi}">
                        ${escapeHtml(opt)}
                    </button>
                `).join('')}
            </div>
            <input type="text" class="question-freetext" placeholder="Add your own detail (optional)"
                   data-question="${qi}" value="${escapeHtml(answerTexts[qi] || '')}">
            <button class="question-skip" data-question="${qi}">Skip this question</button>
        </div>
    `).join('');
}

export function renderRecQuestions() {
    renderQuestions(state.rec.questions, state.rec.answers, state.rec.answerTexts, 'rec-questions-container');
}

export function renderPlaylistQuestions() {
    renderQuestions(state.questions, state.questionAnswers, state.questionTexts, 'playlist-questions-container');
}

export function setupQuestionEventHandlers(container, stateObj, renderFn) {
    container.addEventListener('click', e => {
        const pill = e.target.closest('.option-pill');
        if (pill) {
            const qi = parseInt(pill.dataset.question);
            const oi = parseInt(pill.dataset.option);
            const option = stateObj.questions[qi]?.options[oi];
            if (stateObj.answers[qi] === option) {
                stateObj.answers[qi] = null;
            } else {
                stateObj.answers[qi] = option;
            }
            renderFn();
            return;
        }
        const skip = e.target.closest('.question-skip');
        if (skip) {
            const qi = parseInt(skip.dataset.question);
            stateObj.answers[qi] = null;
            stateObj.answerTexts[qi] = '';
            renderFn();
        }
    });

    container.addEventListener('input', e => {
        if (e.target.classList.contains('question-freetext')) {
            const qi = parseInt(e.target.dataset.question);
            stateObj.answerTexts[qi] = e.target.value;
        }
    });
}

export async function handlePlaylistRefineNext() {
    // Await the cached filter analysis promise (fired in parallel during handleAnalyzePrompt)
    const response = await state.filterAnalysisPromise;
    if (response) {
        // Track analysis costs
        state.sessionTokens += response.token_count || 0;
        state.sessionCost += response.estimated_cost || 0;

        state.availableGenres = response.available_genres;
        state.availableDecades = response.available_decades;
        state.selectedGenres = response.suggested_genres;
        state.selectedDecades = response.suggested_decades;
    } else {
        // Fallback: fetch stats directly if analysis failed
        try {
            const stats = await fetchLibraryStats();
            state.availableGenres = stats.genres;
            state.availableDecades = stats.decades;
            state.selectedGenres = stats.genres.map(g => g.name);
            state.selectedDecades = stats.decades.map(d => d.name);
        } catch {
            // Last resort: empty filters
            state.selectedGenres = [];
            state.selectedDecades = [];
        }
    }

    state.step = 'source';
    updateStep();
}

export async function handleRecSwitchToDiscovery() {
    state.rec.loading = true;
    const stepLoader = showTimedStepLoading([
        { id: 'switching', text: 'Switching to discovery mode...', status: 'active' },
    ]);

    try {
        const data = await apiCall('/recommend/switch-mode', {
            method: 'POST',
            body: JSON.stringify({
                session_id: state.rec.sessionId,
                mode: 'discovery',
            }),
        });

        state.rec.mode = 'discovery';
        state.rec.sessionId = data.session_id;
        document.querySelectorAll('.rec-mode-btn').forEach(b => {
            b.classList.toggle('active', b.dataset.recMode === 'discovery');
            b.setAttribute('aria-pressed', b.dataset.recMode === 'discovery' ? 'true' : 'false');
        });

        stepLoader.finish();
        handleRecGenerate();
    } catch (e) {
        stepLoader.finish();
        showError(e.message);
        state.rec.loading = false;
    }
}

export async function handleRecGenerate() {
    state.rec.loading = true;

    const progressSteps = [
        { id: 'selecting', text: 'Choosing albums from your library...', status: 'active' },
        { id: 'researching_primary', text: 'Researching an album...', status: 'pending' },
        { id: 'researching_secondary', text: 'Looking up additional picks...', status: 'pending' },
        { id: 'extracting_facts', text: 'Analyzing research sources...', status: 'pending' },
        { id: 'writing', text: 'Writing the pitch...', status: 'pending' },
        { id: 'validating', text: 'Fact-checking the pitch...', status: 'pending' },
        { id: 'rewriting', text: 'Refining the pitch...', status: 'pending' },
    ];
    showStepLoading(progressSteps);

    // Abort if no data arrives for 120 seconds (server hang, network loss)
    const controller = new AbortController();
    let staleTimer = setTimeout(() => controller.abort(), 120000);
    const resetStaleTimer = () => {
        clearTimeout(staleTimer);
        staleTimer = setTimeout(() => controller.abort(), 120000);
    };

    try {
        const response = await fetch('/api/recommend/generate', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            signal: controller.signal,
            body: JSON.stringify({
                session_id: state.rec.sessionId,
                answers: state.rec.answers,
                answer_texts: state.rec.answerTexts,
                mode: state.rec.mode,
                genres: (state.availableGenres.length > 0 && state.rec.selectedGenres.length === state.availableGenres.length) ? [] : state.rec.selectedGenres,
                decades: (state.availableDecades.length > 0 && state.rec.selectedDecades.length === state.availableDecades.length) ? [] : state.rec.selectedDecades,
                familiarity_pref: state.rec.familiarityPref,
                max_albums: state.rec.maxAlbumsToAI,
            }),
        });

        if (!response.ok) {
            const err = await response.json().catch(() => ({ detail: 'Request failed' }));
            throw new Error(err.detail || err.error || 'Generation failed');
        }

        // Read SSE stream
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            resetStaleTimer();

            buffer += decoder.decode(value, { stream: true });
            const lines = buffer.split('\n');
            buffer = lines.pop() || '';

            let currentEventType = '';
            let currentData = '';
            for (const line of lines) {
                if (line.startsWith('event: ')) {
                    currentEventType = line.slice(7).trim();
                    continue;
                }
                if (line.startsWith('data: ')) {
                    currentData += line.slice(6);
                    continue;
                }
                if (line === '' && currentData) {
                    let data;
                    try {
                        data = JSON.parse(currentData);
                    } catch (parseErr) {
                        console.warn('SSE parse error:', parseErr);
                        currentData = '';
                        currentEventType = '';
                        continue;
                    }
                    if (currentEventType === 'error' && data.message) {
                        throw new Error(data.message);
                    }
                    if (data.step) {
                        updateStepProgress(data.step);
                    }
                    if (data.recommendations) {
                        state.rec.recommendations = data.recommendations;
                        state.rec.tokenCount = data.token_count || 0;
                        state.rec.estimatedCost = data.estimated_cost || 0;
                        state.rec.researchWarning = data.research_warning;
                        if (data.result_id) {
                            state.rec.resultId = data.result_id;
                            markHistoryStale();
                        }
                    }
                    currentData = '';
                    currentEventType = '';
                }
            }
        }

        hideStepLoading();
        if (state.rec.recommendations.length === 0) {
            showError('No recommendations were received. Please try again.');
            return;
        }
        renderRecResults();
        setRecStep('results');

        // Update URL to deep link for this result
        if (state.rec.resultId) {
            history.replaceState(null, '', `#result/${state.rec.resultId}`);
        }
    } catch (e) {
        hideStepLoading();
        if (e.name === 'AbortError') {
            showError('Recommendation timed out — the server may be overloaded. Please try again.');
        } else {
            showError(e.message);
        }
    } finally {
        clearTimeout(staleTimer);
        state.rec.loading = false;
    }
}

export function renderRecResults() {
    const primary = state.rec.recommendations.find(r => r.rank === 'primary');
    const secondaries = state.rec.recommendations.filter(r => r.rank === 'secondary');

    // Research warning
    const warningEl = document.getElementById('rec-research-warning');
    if (warningEl && state.rec.researchWarning) {
        warningEl.textContent = state.rec.researchWarning;
        warningEl.classList.remove('hidden');
    } else if (warningEl) {
        warningEl.classList.add('hidden');
    }

    // Primary recommendation
    const primaryContainer = document.getElementById('rec-primary-result');
    if (primaryContainer && primary) {
        const artHtml = primary.art_url
            ? `<img class="rec-primary-art" src="${escapeHtml(primary.art_url)}" alt="${escapeHtml(primary.album)}"
                    data-artist="${escapeHtml(primary.artist)}"
                    onerror="this.outerHTML=artPlaceholderHtml(this.dataset.artist, true)">`
            : artPlaceholderHtml(primary.artist, true).replace('art-placeholder', 'art-placeholder rec-primary-art');

        const pitch = primary.pitch || {};
        primaryContainer.innerHTML = `
            <div class="rec-primary-layout">
                ${artHtml}
                <div class="rec-primary-pitch">
                    <div class="rec-pitch-album-title">${escapeHtml(primary.album)}</div>
                    <div class="rec-pitch-artist">${escapeHtml(primary.artist)}${primary.year ? ` (${primary.year})` : ''}</div>
                    ${pitch.hook ? `<div class="rec-pitch-hook">${escapeHtml(pitch.hook)}</div>` : ''}
                    ${pitch.context ? `
                        <div class="rec-pitch-section">
                            <div class="rec-pitch-section-label">The Story</div>
                            ${escapeHtml(pitch.context)}
                        </div>` : ''}
                    ${pitch.listening_guide ? `
                        <div class="rec-pitch-section">
                            <div class="rec-pitch-section-label">How to Listen</div>
                            ${escapeHtml(pitch.listening_guide)}
                        </div>` : ''}
                    ${pitch.connection ? `
                        <div class="rec-pitch-section rec-pitch-section--connection">
                            <div class="rec-pitch-section-label">Why This Album</div>
                            ${escapeHtml(pitch.connection)}
                        </div>` : ''}
                    <div class="rec-primary-actions">
                        ${primary.track_item_keys?.length ? `
                            <button class="btn btn-primary rec-play-btn" data-item-keys="${escapeHtml(primary.track_item_keys.join(','))}">${primary.source === 'qobuz' ? '&#9654; Speel via Qobuz' : '&#9654; Play Now'}</button>
                        ` : primary.playable === false ? `
                            <span class="rec-unavailable">Niet beschikbaar voor streaming</span>
                        ` : ''}
                        ${state.rec.sessionId ? `
                            <button class="rec-action-link" id="rec-show-another">Show Me Another</button>
                            <button class="rec-action-link rec-action-link--subtle" id="rec-start-over">Start over</button>
                        ` : ''}
                    </div>
                </div>
            </div>
        `;
    }

    // Secondary recommendations
    const secondaryContainer = document.getElementById('rec-secondary-cards');
    if (secondaryContainer) {
        secondaryContainer.innerHTML = secondaries.map(rec => {
            const artHtml = rec.art_url
                ? `<img class="rec-secondary-art" src="${escapeHtml(rec.art_url)}" alt="${escapeHtml(rec.album)}"
                        data-artist="${escapeHtml(rec.artist)}"
                        onerror="this.outerHTML=artPlaceholderHtml(this.dataset.artist)">`
                : artPlaceholderHtml(rec.artist).replace('art-placeholder', 'art-placeholder rec-secondary-art');

            return `
                <div class="rec-secondary-card">
                    <div class="rec-secondary-header">
                        ${artHtml}
                        <div class="rec-secondary-info">
                            <div class="rec-secondary-title">${escapeHtml(rec.album)}</div>
                            <div class="rec-secondary-artist">${escapeHtml(rec.artist)}${rec.year ? ` (${rec.year})` : ''}</div>
                            ${rec.track_item_keys?.length ? `
                                <div class="rec-secondary-actions">
                                    <button class="btn btn-secondary btn-sm rec-play-btn" data-item-keys="${escapeHtml(rec.track_item_keys.join(','))}">${rec.source === 'qobuz' ? '&#9654; Qobuz' : '&#9654; Play'}</button>
                                </div>
                            ` : rec.playable === false ? `
                                <div class="rec-secondary-actions">
                                    <span class="rec-unavailable rec-unavailable--sm">Niet beschikbaar</span>
                                </div>
                            ` : ''}
                        </div>
                    </div>
                    <div class="rec-secondary-pitch">${escapeHtml(rec.pitch?.short_pitch || rec.pitch?.full_text || '')}</div>
                </div>
            `;
        }).join('');
    }

    // Discovery bridge (show in library mode with active session only)
    const bridgeEl = document.getElementById('rec-discovery-bridge');
    if (bridgeEl) {
        bridgeEl.classList.toggle('hidden', state.rec.mode !== 'library' || !state.rec.sessionId);
    }

    // Update cost display in shared app footer
    const costDisplay = document.getElementById('cost-display');
    if (costDisplay) {
        if (state.rec.estimatedCost > 0) {
            costDisplay.textContent = `${state.rec.tokenCount.toLocaleString()} tokens ($${state.rec.estimatedCost.toFixed(4)})`;
        } else if (state.rec.tokenCount > 0) {
            costDisplay.textContent = `${state.rec.tokenCount.toLocaleString()} tokens`;
        } else {
            costDisplay.textContent = '';
        }
    }
}

export function resetRecState() {
    state.rec.step = 'prompt';
    state.rec.prompt = '';
    state.rec.loading = false;
    state.rec.selectedGenres = [];
    state.rec.selectedDecades = [];
    state.rec.questions = [];
    state.rec.answers = [];
    state.rec.answerTexts = [];
    state.rec.sessionId = null;
    state.rec.recommendations = [];
    state.rec.tokenCount = 0;
    state.rec.estimatedCost = 0;
    state.rec.researchWarning = null;
    state.rec.resultId = null;
    state.rec.filterAnalysisPromise = null;
    // Preserve mode and familiarityPref; clear filter info banner
    const infoBanner = document.getElementById('rec-filter-info');
    if (infoBanner) infoBanner.classList.add('hidden');
    renderRecFilterChips();
    updateRecStep();
}

export function setupRecEventListeners() {
    // Familiarity preference pills — restore from localStorage
    const familiarityPills = document.getElementById('rec-familiarity-pills');
    if (familiarityPills) {
        try {
            const saved = localStorage.getItem('roonsage-familiarity-pref');
            if (saved && ['any', 'comfort', 'rediscover', 'hidden_gems'].includes(saved)) {
                state.rec.familiarityPref = saved;
                familiarityPills.querySelectorAll('.chip').forEach(btn => {
                    const isSelected = btn.dataset.familiarity === saved;
                    btn.classList.toggle('selected', isSelected);
                    btn.setAttribute('aria-checked', isSelected ? 'true' : 'false');
                });
            }
        } catch (e) { /* private browsing */ }

        familiarityPills.addEventListener('click', (e) => {
            const btn = e.target.closest('.chip[data-familiarity]');
            if (!btn) return;
            state.rec.familiarityPref = btn.dataset.familiarity;
            familiarityPills.querySelectorAll('.chip').forEach(b => {
                const isSelected = b === btn;
                b.classList.toggle('selected', isSelected);
                b.setAttribute('aria-checked', isSelected ? 'true' : 'false');
            });
            try { localStorage.setItem('roonsage-familiarity-pref', state.rec.familiarityPref); } catch (e) { /* private browsing */ }
        });
    }

    // Mode buttons
    document.querySelectorAll('.rec-mode-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            state.rec.mode = btn.dataset.recMode;
            document.querySelectorAll('.rec-mode-btn').forEach(b => {
                b.classList.toggle('active', b === btn);
                b.setAttribute('aria-pressed', b === btn ? 'true' : 'false');
            });
            updateRecAlbumPreview();
        });
    });

    // Setup Next → generate
    const setupNext = document.getElementById('rec-setup-next');
    if (setupNext) {
        setupNext.addEventListener('click', () => handleRecGenerate());
    }

    // Refine Next → apply filter suggestions and go to setup
    const refineNext = document.getElementById('rec-refine-next');
    if (refineNext) {
        refineNext.addEventListener('click', () => handleRefineNext());
    }

    // Prompt pills
    const pillContainer = document.getElementById('rec-prompt-pills');
    if (pillContainer) {
        pillContainer.addEventListener('click', e => {
            const pill = e.target.closest('.prompt-pill');
            if (!pill) return;
            document.getElementById('rec-prompt-input').value = pill.textContent.trim();
            state.rec.prompt = pill.textContent.trim();
        });
    }

    // Shuffle button
    const shuffleBtn = document.getElementById('rec-prompt-shuffle');
    if (shuffleBtn) {
        shuffleBtn.addEventListener('click', () => shufflePromptPills('rec-prompt-pills', REC_PROMPT_GROUPS));
    }

    // Prompt Next
    const promptNext = document.getElementById('rec-prompt-next');
    if (promptNext) {
        promptNext.addEventListener('click', () => {
            handlePromptSubmit();
        });
    }

    // Questions - event delegation (recommend flow)
    const recQuestionsContainer = document.getElementById('rec-questions-container');
    if (recQuestionsContainer) {
        setupQuestionEventHandlers(recQuestionsContainer, state.rec, renderRecQuestions);
    }

    // Recommend filter chips - event delegation
    const recGenreChips = document.getElementById('rec-genre-chips');
    if (recGenreChips) {
        recGenreChips.addEventListener('click', e => {
            const chip = e.target.closest('.chip');
            if (!chip) return;
            const genre = chip.dataset.genre;
            if (state.rec.selectedGenres.includes(genre)) {
                state.rec.selectedGenres = state.rec.selectedGenres.filter(g => g !== genre);
            } else {
                state.rec.selectedGenres.push(genre);
            }
            renderRecFilterChips();
            updateRecAlbumPreview();
        });
    }

    const recDecadeChips = document.getElementById('rec-decade-chips');
    if (recDecadeChips) {
        recDecadeChips.addEventListener('click', e => {
            const chip = e.target.closest('.chip');
            if (!chip) return;
            const decade = chip.dataset.decade;
            if (state.rec.selectedDecades.includes(decade)) {
                state.rec.selectedDecades = state.rec.selectedDecades.filter(d => d !== decade);
            } else {
                state.rec.selectedDecades.push(decade);
            }
            renderRecFilterChips();
            updateRecAlbumPreview();
        });
    }

    // Genre/decade toggle all
    const recGenreToggle = document.getElementById('rec-genre-toggle-all');
    if (recGenreToggle) {
        recGenreToggle.addEventListener('click', () => {
            const allSelected = state.availableGenres.length > 0 &&
                state.rec.selectedGenres.length === state.availableGenres.length;
            state.rec.selectedGenres = allSelected ? [] : state.availableGenres.map(g => g.name);
            renderRecFilterChips();
            updateRecAlbumPreview();
        });
    }

    const recDecadeToggle = document.getElementById('rec-decade-toggle-all');
    if (recDecadeToggle) {
        recDecadeToggle.addEventListener('click', () => {
            const allSelected = state.availableDecades.length > 0 &&
                state.rec.selectedDecades.length === state.availableDecades.length;
            state.rec.selectedDecades = allSelected ? [] : state.availableDecades.map(d => d.name);
            renderRecFilterChips();
            updateRecAlbumPreview();
        });
    }

    // Step progress bar navigation (click completed steps to go back)
    document.querySelectorAll('#playlist-steps .step').forEach(stepEl => {
        stepEl.addEventListener('click', () => {
            if (stepEl.classList.contains('completed')) {
                state.step = stepEl.dataset.step;
                updateStep();
            }
        });
    });
    document.querySelectorAll('#rec-steps .step').forEach(stepEl => {
        stepEl.addEventListener('click', () => {
            if (stepEl.classList.contains('completed')) {
                setRecStep(stepEl.dataset.step);
            }
        });
    });

    // Results actions - event delegation
    document.getElementById('rec-primary-result')?.addEventListener('click', e => {
        handleRecResultAction(e);
    });
    document.getElementById('rec-secondary-cards')?.addEventListener('click', e => {
        handleRecResultAction(e);
    });

    // Show me another
    document.addEventListener('click', e => {
        if (e.target.id === 'rec-show-another') {
            handleRecGenerate();
        }
        if (e.target.id === 'rec-start-over') {
            resetRecState();
            history.replaceState(null, '', '#recommend-album');
        }
        if (e.target.id === 'rec-try-discovery') {
            handleRecSwitchToDiscovery();
        }
    });

    // Restart confirmation modal buttons
    document.getElementById('rec-restart-confirm')?.addEventListener('click', () => {
        const navHash = pendingNavHash;
        dismissRecRestartModal();
        hideStepLoading();
        resetRecState();
        if (navHash) {
            location.hash = '#' + navHash;
        } else {
            history.replaceState(null, '', '#recommend-album');
        }
    });
    document.getElementById('rec-restart-cancel')?.addEventListener('click', dismissRecRestartModal);
    document.getElementById('rec-restart-cancel-x')?.addEventListener('click', dismissRecRestartModal);

    // Playlist restart confirmation modal buttons
    document.getElementById('playlist-restart-confirm')?.addEventListener('click', () => {
        const navHash = pendingNavHash;
        dismissPlaylistRestartModal();
        setLoading(false);
        resetPlaylistState();
        if (navHash) {
            location.hash = '#' + navHash;
        } else {
            history.replaceState(null, '', '#' + hashForCurrentState());
        }
    });
    document.getElementById('playlist-restart-cancel')?.addEventListener('click', dismissPlaylistRestartModal);
    document.getElementById('playlist-restart-cancel-x')?.addEventListener('click', dismissPlaylistRestartModal);
}

export function handleRecResultAction(e) {
    const playBtn = e.target.closest('.rec-play-btn');
    if (playBtn) {
        const keys = playBtn.dataset.itemKeys.split(',');
        // Store rating keys for the play queue flow, then open client picker
        state._pendingRatingKeys = keys;
        const modal = document.getElementById('client-picker-modal');
        modal.classList.remove('hidden');
        lockScroll();
        focusManager.openModal(modal);
        refreshClientList();
        return;
    }

}
