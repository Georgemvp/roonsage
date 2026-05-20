// templates.js — Playlist Template Picker
// =============================================================================
// Fetches templates from /api/templates, renders a card grid above the prompt
// input in the Generate view, and handles one-click playlist generation.

import { state } from './state.js';
import { apiCall, fetchLibraryStats, generatePlaylistStream } from './api.js';
import { escapeHtml } from './utils.js';
import {
    setLoading, showError, updateFilters, updateStep, updateFilterPreview,
    updatePlaylist,
} from './ui.js';
import { showStepLoading, hideStepLoading, updateStepProgress, PLAYLIST_STEPS, PLAYLIST_STEP_MAP } from './loading.js';
import { generatePlaylistName } from './playlist.js';
import { markHistoryStale } from './history.js';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let _templates = [];        // Cached template list from the API
let _customModal = null;    // Custom template modal element reference

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

async function fetchTemplates() {
    try {
        _templates = await apiCall('/templates');
    } catch {
        _templates = [];
    }
    return _templates;
}

async function fetchTemplate(id) {
    return apiCall(`/templates/${id}`);
}

async function saveTemplate(payload) {
    return apiCall('/templates', {
        method: 'POST',
        body: JSON.stringify(payload),
    });
}

async function deleteTemplate(id) {
    const response = await fetch(`/api/templates/${id}`, { method: 'DELETE' });
    if (!response.ok && response.status !== 204) {
        const err = await response.json().catch(() => ({ detail: 'Delete failed' }));
        throw new Error(err.detail || 'Delete failed');
    }
}

// ---------------------------------------------------------------------------
// Template card renderer
// ---------------------------------------------------------------------------

function renderTemplateGrid() {
    const container = document.getElementById('template-grid');
    if (!container) return;

    const cards = _templates.map(t => `
        <button class="template-card" data-template-id="${escapeHtml(t.id)}"
                aria-label="Use template: ${escapeHtml(t.name)}" type="button">
            <span class="template-card-icon" aria-hidden="true">${escapeHtml(t.icon)}</span>
            <span class="template-card-name">${escapeHtml(t.name)}</span>
            <span class="template-card-desc">${escapeHtml(t.description)}</span>
            <span class="template-card-meta">${t.track_count} tracks</span>
            ${!t.is_builtin ? `<button class="template-card-delete" data-delete-id="${escapeHtml(t.id)}" aria-label="Delete template" title="Delete" type="button">✕</button>` : ''}
        </button>
    `).join('');

    // Add the "+" card for custom template creation
    const addCard = `
        <button class="template-card template-card--add" id="add-template-btn"
                aria-label="Create custom template" type="button">
            <span class="template-card-icon" aria-hidden="true">➕</span>
            <span class="template-card-name">Custom</span>
            <span class="template-card-desc">Create your own template</span>
        </button>
    `;

    container.innerHTML = cards + addCard;

    // Wire up delete buttons (stop propagation so card click doesn't fire)
    container.querySelectorAll('.template-card-delete').forEach(btn => {
        btn.addEventListener('click', async (e) => {
            e.stopPropagation();
            const id = btn.dataset.deleteId;
            if (!confirm(`Delete template "${id}"?`)) return;
            try {
                await deleteTemplate(id);
                _templates = _templates.filter(t => t.id !== id);
                renderTemplateGrid();
            } catch (err) {
                showError(err.message);
            }
        });
    });

    // Wire up template card clicks
    container.querySelectorAll('.template-card:not(.template-card--add)').forEach(card => {
        card.addEventListener('click', () => {
            const id = card.dataset.templateId;
            const template = _templates.find(t => t.id === id);
            if (template) handleTemplateSelect(template);
        });
    });

    // Wire up add card
    document.getElementById('add-template-btn')?.addEventListener('click', openCustomModal);
}

// ---------------------------------------------------------------------------
// One-click generation from a template
// ---------------------------------------------------------------------------

async function handleTemplateSelect(template) {
    // Set mode and prompt
    state.mode = 'prompt';
    state.prompt = template.prompt;
    state.trackCount = template.track_count;
    state.excludeLive = template.filters.exclude_live;
    state.sourceMode = template.filters.source_mode || 'library';
    state.qobuzPercentage = template.filters.qobuz_percentage || 30;
    state.questions = [];
    state.questionAnswers = [];
    state.questionTexts = [];
    state.filterAnalysisPromise = null;

    // Reset session costs
    state.sessionTokens = 0;
    state.sessionCost = 0;

    // Fill in the prompt textarea (so the user can see what's going on)
    const promptInput = document.getElementById('prompt-input');
    if (promptInput) promptInput.value = template.prompt;

    // Load library stats and pre-select genres/decades from the template
    setLoading(true, 'Loading library…');
    let stats;
    try {
        stats = await fetchLibraryStats();
    } catch {
        stats = { genres: [], decades: [] };
    } finally {
        setLoading(false);
    }

    state.availableGenres = stats.genres;
    state.availableDecades = stats.decades;

    // Pre-select template genres (if any specified), otherwise select all
    const templateGenres = template.filters.genres || [];
    if (templateGenres.length > 0) {
        const available = new Set(stats.genres.map(g => g.name));
        const matching = templateGenres.filter(g => available.has(g));
        state.selectedGenres = matching.length > 0 ? matching : stats.genres.map(g => g.name);
    } else {
        state.selectedGenres = stats.genres.map(g => g.name);
    }

    // Pre-select template decades (if any specified), otherwise select all
    const templateDecades = template.filters.decades || [];
    if (templateDecades.length > 0) {
        const available = new Set(stats.decades.map(d => d.name));
        const matching = templateDecades.filter(d => available.has(d));
        state.selectedDecades = matching.length > 0 ? matching : stats.decades.map(d => d.name);
    } else {
        state.selectedDecades = stats.decades.map(d => d.name);
    }

    // Move to filters step so the user can see and optionally adjust
    state.step = 'filters';
    updateStep();
    updateFilters();
    updateFilterPreview();

    // Auto-generate!
    _generateFromTemplate(template);
}

function _generateFromTemplate(template) {
    const allG = state.availableGenres.length > 0 &&
        state.selectedGenres.length === state.availableGenres.length;
    const allD = state.availableDecades.length > 0 &&
        state.selectedDecades.length === state.availableDecades.length;

    const request = {
        prompt: template.prompt,
        genres: allG ? [] : state.selectedGenres,
        decades: allD ? [] : state.selectedDecades,
        track_count: state.trackCount,
        exclude_live: state.excludeLive,
        max_tracks_to_ai: state.maxTracksToAI || 500,
        source_mode: state.sourceMode,
        qobuz_percentage: state.qobuzPercentage,
    };

    state.lastRequest = { ...request };

    showStepLoading(PLAYLIST_STEPS.map(s => ({ ...s })));

    generatePlaylistStream(
        request,
        (data) => {
            const mapped = PLAYLIST_STEP_MAP[data.step];
            if (mapped) updateStepProgress(mapped);
        },
        (response) => {
            updateStepProgress('__done__');

            state.sessionTokens += response.token_count || 0;
            state.sessionCost += response.estimated_cost || 0;
            state.playlist = response.tracks;
            state.tokenCount = state.sessionTokens;
            state.estimatedCost = state.sessionCost;

            if (response.playlist_title) state.playlistTitle = response.playlist_title;
            if (response.narrative) state.narrative = response.narrative;
            if (response.track_reasons) state.trackReasons = response.track_reasons;

            state.playlistName = state.playlistTitle || generatePlaylistName();
            state.selectedTrackKey = null;
            state.step = 'results';
            updateStep();
            updatePlaylist();
            window.scrollTo(0, 0);
            hideStepLoading();

            if (response.result_id) {
                history.replaceState(null, '', `#result/${response.result_id}`);
                markHistoryStale();
            }
        },
        (error) => {
            showError(error.message);
            hideStepLoading();
        }
    );
}

// ---------------------------------------------------------------------------
// Custom template modal
// ---------------------------------------------------------------------------

function openCustomModal(existingTemplate = null) {
    const modal = document.getElementById('template-modal');
    if (!modal) return;

    // Reset/populate form
    document.getElementById('tm-id').value = existingTemplate?.id || '';
    document.getElementById('tm-name').value = existingTemplate?.name || '';
    document.getElementById('tm-icon').value = existingTemplate?.icon || '🎵';
    document.getElementById('tm-description').value = existingTemplate?.description || '';
    document.getElementById('tm-prompt').value = existingTemplate?.prompt || '';
    document.getElementById('tm-track-count').value = existingTemplate?.track_count || 25;
    document.getElementById('tm-exclude-live').checked =
        existingTemplate?.filters?.exclude_live !== false;

    modal.classList.remove('hidden');
    modal.setAttribute('aria-hidden', 'false');
    document.getElementById('tm-name')?.focus();
}

function closeCustomModal() {
    const modal = document.getElementById('template-modal');
    if (!modal) return;
    modal.classList.add('hidden');
    modal.setAttribute('aria-hidden', 'true');
}

async function handleSaveCustomTemplate() {
    const id = document.getElementById('tm-id').value.trim();
    const name = document.getElementById('tm-name').value.trim();
    const icon = document.getElementById('tm-icon').value.trim() || '🎵';
    const description = document.getElementById('tm-description').value.trim();
    const prompt = document.getElementById('tm-prompt').value.trim();
    const trackCount = parseInt(document.getElementById('tm-track-count').value, 10) || 25;
    const excludeLive = document.getElementById('tm-exclude-live').checked;

    // Basic validation
    if (!id || !/^[a-z0-9][a-z0-9\-]{1,62}$/.test(id)) {
        showError('ID must be lowercase letters, numbers, and hyphens (e.g. my-playlist)');
        return;
    }
    if (!name) { showError('Name is required'); return; }
    if (!prompt || prompt.length < 10) { showError('Prompt must be at least 10 characters'); return; }

    try {
        const saved = await saveTemplate({
            id, name, icon, description, prompt,
            track_count: trackCount,
            filters: { exclude_live: excludeLive },
        });
        // Update local cache
        const idx = _templates.findIndex(t => t.id === saved.id);
        if (idx >= 0) _templates[idx] = saved;
        else _templates.push(saved);

        renderTemplateGrid();
        closeCustomModal();
    } catch (err) {
        showError(err.message || 'Failed to save template');
    }
}

// ---------------------------------------------------------------------------
// Initialisation
// ---------------------------------------------------------------------------

export async function initTemplates() {
    // Fetch templates on load
    await fetchTemplates();
    renderTemplateGrid();

    // Wire up modal close / save
    document.getElementById('tm-cancel')?.addEventListener('click', closeCustomModal);
    document.getElementById('tm-save')?.addEventListener('click', handleSaveCustomTemplate);
    document.getElementById('template-modal')?.addEventListener('click', (e) => {
        // Close if clicking backdrop (the modal overlay itself)
        if (e.target === e.currentTarget) closeCustomModal();
    });

    // ESC closes modal
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') closeCustomModal();
    });
}

export { fetchTemplates, renderTemplateGrid };
