// =============================================================================
// State Management
// =============================================================================

export const state = {
    // Current view and mode
    view: 'home', // 'home' | 'create' | 'recommend' | 'settings'
    mode: 'prompt', // 'prompt' | 'seed'
    step: 'input',  // 'input' | 'refine' | 'dimensions' | 'filters' | 'results'

    // Prompt flow
    prompt: '',

    // Refine questions (prompt mode)
    questions: [],          // ClarifyingQuestion[] from /recommend/questions
    questionAnswers: [],    // (string|null)[] — selected option per question
    questionTexts: [],      // string[] — free-text additions per question
    filterAnalysisPromise: null,  // cached promise from parallel filter analysis

    // Seed track flow
    seedTrack: null,
    dimensions: [],
    selectedDimensions: [],
    additionalNotes: '',

    // Filters
    availableGenres: [],
    availableDecades: [],
    selectedGenres: [],
    selectedDecades: [],
    trackCount: 25,
    excludeLive: true,
    maxTracksToAI: 500,  // 0 = no limit
    minRating: 0,  // 0 = any, 2/4/6/8 = 1/2/3/4 stars minimum

    // Results
    playlist: [],
    playlistName: '',
    tokenCount: 0,
    estimatedCost: 0,

    // Curator narrative
    playlistTitle: '',      // Generated title with date
    narrative: '',          // 2-3 sentence curator note
    trackReasons: {},       // { item_key: "reason string" }
    userRequest: '',        // Original user prompt for display

    // Cost tracking (accumulated across analysis + generation)
    sessionTokens: 0,
    sessionCost: 0,

    // UI state
    loading: false,
    error: null,

    // Config
    config: null,

    // Cached filter preview (for local cost recalculation)
    lastFilterPreview: null,  // { matching_tracks, tracks_to_send }

    // Refinement — stores the last generation request so it can be replayed with additional_notes
    lastRequest: null,

    // Source mode (Qobuz integration)
    sourceMode: 'library',     // 'library' | 'hybrid' | 'qobuz'
    qobuzPercentage: 30,       // % of Qobuz tracks in hybrid mode (10-70)
    qobuzAvailable: false,     // populated from /api/setup/status
    qobuzSaveAvailable: false, // populated from /api/qobuz/save-status

    // Results UX — selection
    selectedTrackKey: null,    // Currently selected track in detail panel

    // Instant Queue (005) — Play Now
    roonZones: [],             // Never cached — fetched fresh each time
    _pendingClientId: null,    // Client ID awaiting play choice modal selection

    // Instant Queue (005) — Update Existing
    saveMode: 'replace_queue', // 'replace_queue' | 'play_now' | 'queue_next'

    // Recommendation (006)
    rec: {
        mode: 'library',       // 'library' | 'discovery'
        step: 'prompt',        // 'prompt' | 'refine' | 'setup' | 'results'
        prompt: '',
        selectedGenres: [],
        selectedDecades: [],
        familiarityPref: 'any', // 'any' | 'comfort' | 'rediscover' | 'hidden_gems'
        questions: [],
        answers: [],           // Selected option per question (null = skipped)
        answerTexts: [],       // Free-text additions per question
        sessionId: null,
        recommendations: [],
        tokenCount: 0,
        estimatedCost: 0,
        researchWarning: null,
        resultId: null,
        maxAlbumsToAI: 2500,
        loading: false,
        filterAnalysisPromise: null,
    },

    // Setup wizard
    setup: {
        active: false,
        status: null,
        syncPollInterval: null,
    },
};

// =============================================================================
// Filter Helpers
// =============================================================================

export function allGenresSelected() {
    return state.availableGenres.length > 0 &&
        state.selectedGenres.length === state.availableGenres.length;
}

export function allDecadesSelected() {
    return state.availableDecades.length > 0 &&
        state.selectedDecades.length === state.availableDecades.length;
}
