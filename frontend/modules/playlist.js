// playlist.js — Playlist Refinement, Save, Settings
// =============================================================================

import { state } from './state.js';
import { apiCall, generatePlaylistStream, fetchConfig, updateConfig, fetchLibraryStats } from './api.js';
import { escapeHtml } from './utils.js';
import {
    setLoading, showError, showSuccess, showSuccessModal,
    updatePlaylist, updateSettings, updateFilters,
    updateConfigRequiredUI, updateFooter, validateCustomProviderInputs,
    updateStep, updateTrackLimitButtons, updateAlbumLimitButtons
} from './ui.js';
import { handlePlayNow } from './instant-queue.js';
import { markHistoryStale } from './history.js';
import { showTimedStepLoading, showStepLoading, hideStepLoading, updateStepProgress, PLAYLIST_STEPS, PLAYLIST_STEP_MAP } from './loading.js';

// =============================================================================
// Playlist Refinement (iterative generation)
// =============================================================================

export function handleRefinePlaylist() {
    const panel = document.getElementById('refine-panel');
    const btn = document.getElementById('refine-playlist-btn');
    if (!panel || !btn) return;
    const isOpen = !panel.classList.contains('hidden');
    panel.classList.toggle('hidden', isOpen);
    btn.setAttribute('aria-expanded', String(!isOpen));
    if (!isOpen) {
        document.getElementById('refine-input')?.focus();
    }
}

export async function handleSaveToQobuz() {
    if (!state.playlist || state.playlist.length === 0) return;

    const btn = document.getElementById('save-to-qobuz-btn');
    const resultEl = document.getElementById('qobuz-save-result');
    if (!btn || !resultEl) return;

    // Disable button during save
    btn.disabled = true;
    btn.textContent = 'Opslaan...';
    resultEl.classList.add('hidden');
    resultEl.className = 'qobuz-save-result hidden';

    try {
        const tracks = state.playlist.map(t => ({
            artist: t.artist || '',
            title: t.title || '',
        }));

        const playlistName = state.playlistTitle || state.playlistName || 'RoonSage Playlist';
        const description = state.narrative || '';

        const result = await apiCall('/qobuz/playlist/save', {
            method: 'POST',
            body: JSON.stringify({
                name: playlistName,
                tracks,
                description,
                is_public: false,
            }),
        });

        resultEl.classList.remove('hidden');

        if (result.success) {
            const unmatchedCount = result.tracks_unmatched || 0;
            const savedCount = result.tracks_saved || 0;
            let html = `<strong>${savedCount} van ${savedCount + unmatchedCount} tracks opgeslagen in Qobuz</strong> als "${escapeHtml(result.playlist_name || playlistName)}"`;

            if (unmatchedCount > 0 && result.unmatched_details?.length > 0) {
                const items = result.unmatched_details
                    .map(u => `<li>${escapeHtml(u.artist)} — ${escapeHtml(u.title)}</li>`)
                    .join('');
                html += `<details><summary>${unmatchedCount} track${unmatchedCount !== 1 ? 's' : ''} niet gevonden op Qobuz</summary><ul>${items}</ul></details>`;
            }

            resultEl.innerHTML = html;
            resultEl.classList.add('success');
        } else {
            resultEl.textContent = result.error || 'Opslaan mislukt';
            resultEl.classList.add('error');
        }
    } catch (err) {
        resultEl.classList.remove('hidden');
        resultEl.textContent = err.message || 'Opslaan in Qobuz mislukt';
        resultEl.classList.add('error');
    } finally {
        btn.disabled = false;
        btn.textContent = '▶ Opslaan in Qobuz';
    }
}

export function handleRefineSubmit() {
    const refinementText = document.getElementById('refine-input')?.value.trim();
    if (!refinementText) {
        document.getElementById('refine-input')?.focus();
        return;
    }
    if (!state.lastRequest) return;

    const request = {
        ...state.lastRequest,
        additional_notes: refinementText,
    };

    // Collapse the refinement panel while generating
    document.getElementById('refine-panel')?.classList.add('hidden');
    document.getElementById('refine-playlist-btn')?.setAttribute('aria-expanded', 'false');

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

            // Update lastRequest so subsequent refinements stack correctly
            state.lastRequest = request;

            // Clear input for next refinement
            const refineInput = document.getElementById('refine-input');
            if (refineInput) refineInput.value = '';

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

export function generatePlaylistName() {
    const date = new Date().toLocaleDateString('en-US', { month: 'short', day: 'numeric' });

    if (state.mode === 'prompt') {
        const words = state.prompt.split(' ').slice(0, 3).join(' ');
        return `${words}... (${date})`;
    } else {
        return `Like ${state.seedTrack.title} (${date})`;
    }
}

export async function handleSavePlaylist() {
    // All queue modes go through the zone-picker flow.
    // The save-mode dropdown controls queue behaviour (replace_queue / play_now / queue_next);
    // handleClientSelect() reads state.saveMode when calling executePlayQueue().
    if (!state.playlist.length) {
        showError('Playlist is empty');
        return;
    }
    await handlePlayNow();
}

export async function loadSettings() {
    try {
        state.config = await fetchConfig();

        // Set max tracks/albums to AI based on model's context limit
        if (state.config.max_tracks_to_ai) {
            state.maxTracksToAI = Math.min(state.maxTracksToAI, state.config.max_tracks_to_ai);
            updateTrackLimitButtons();
        }
        if (state.config.max_albums_to_ai) {
            state.rec.maxAlbumsToAI = Math.min(state.rec.maxAlbumsToAI, state.config.max_albums_to_ai);
            updateAlbumLimitButtons();
        }

        updateSettings();
        updateFooter();
        updateConfigRequiredUI();

        // Show library stats if connected — fire-and-forget so it never
        // blocks the loading spinner from being removed.
        if (state.config.roon_connected) {
            const statsSection = document.getElementById('library-stats-section');
            statsSection.style.display = 'block';

            fetchLibraryStats().then(stats => {
                // Cache genre/decade data so other views don't need a separate fetch
                state.availableGenres = stats.genres;
                state.availableDecades = stats.decades;
                document.getElementById('library-stats').innerHTML = `
                    <p><strong>Total Tracks:</strong> ${stats.total_tracks.toLocaleString()}</p>
                    <p><strong>Genres:</strong> ${stats.genres.length}</p>
                    <p><strong>Decades:</strong> ${stats.decades.map(d => d.name).join(', ')}</p>
                `;
            }).catch(() => {
                // Ignore library stats errors — sync modal handles the
                // empty-cache case via checkLibraryStatus()
            });
        }
    } catch (error) {
        showError('Failed to load settings: ' + error.message);
    }
}

export async function handleSaveSettings() {
    const updates = {};

    const roonHost = document.getElementById('roon-host').value.trim();
    const roonPortStr = document.getElementById('roon-port').value.trim();
    const roonPort = parseInt(roonPortStr) || 9330;
    const musicLibrary = document.getElementById('music-library').value.trim();
    const llmProvider = document.getElementById('llm-provider').value;
    const llmApiKey = document.getElementById('llm-api-key').value.trim();

    // Ollama settings
    const ollamaUrl = document.getElementById('ollama-url').value.trim();
    const ollamaModelAnalysis = document.getElementById('ollama-model-analysis').value;
    const ollamaModelGeneration = document.getElementById('ollama-model-generation').value;

    // Custom provider settings
    const customUrl = document.getElementById('custom-url').value.trim();
    const customApiKey = document.getElementById('custom-api-key').value.trim();
    const customModel = document.getElementById('custom-model').value.trim();
    const customContextWindow = parseInt(document.getElementById('custom-context-window').value) || 32768;

    if (roonHost) updates.roon_host = roonHost;
    if (roonPort) updates.roon_port = roonPort;
    if (musicLibrary) updates.music_library = musicLibrary;
    if (llmProvider) updates.llm_provider = llmProvider;

    // Set provider-specific settings
    if (llmProvider === 'ollama') {
        if (ollamaUrl) updates.ollama_url = ollamaUrl;
        if (ollamaModelAnalysis) updates.model_analysis = ollamaModelAnalysis;
        if (ollamaModelGeneration) updates.model_generation = ollamaModelGeneration;
    } else if (llmProvider === 'custom') {
        // Validate custom provider inputs
        const validationErrors = validateCustomProviderInputs();
        if (validationErrors.length > 0) {
            showError(validationErrors.join('. '));
            return;
        }
        if (customUrl) updates.custom_url = customUrl;
        if (customApiKey) updates.llm_api_key = customApiKey;
        if (customModel) {
            updates.model_analysis = customModel;
            updates.model_generation = customModel;  // Same model for both
        }
        updates.custom_context_window = customContextWindow;
    } else {
        // Cloud providers need API key
        if (llmApiKey) updates.llm_api_key = llmApiKey;
    }

    // Qobuz playlist save settings (app_id is auto-extracted, no field for it)
    const qobuzEmail = document.getElementById('qobuz-email')?.value.trim();
    const qobuzPassword = document.getElementById('qobuz-password')?.value.trim();
    if (qobuzEmail) updates.qobuz_email = qobuzEmail;
    if (qobuzPassword) updates.qobuz_password = qobuzPassword;

    // ListenBrainz settings (saved via validate endpoint — store in user config if filled)
    const lbToken = document.getElementById('lb-token')?.value.trim();
    const lbUsername = document.getElementById('lb-username')?.value.trim();
    if (lbToken) updates.listenbrainz_token = lbToken;
    if (lbUsername) updates.listenbrainz_username = lbUsername;

    if (Object.keys(updates).length === 0) {
        showError('No settings to update');
        return;
    }

    setLoading(true, 'Saving settings...');

    try {
        state.config = await updateConfig(updates);
        updateSettings();
        updateFooter();
        updateConfigRequiredUI();
        updateTrackLimitButtons();  // Refresh track limits based on new model
        updateAlbumLimitButtons();  // Refresh album limits based on new model
        showSuccess('Settings saved!');

        // Clear password fields after save
        // roon token handled internally
        document.getElementById('llm-api-key').value = '';
        const qobuzPwField = document.getElementById('qobuz-password');
        if (qobuzPwField) qobuzPwField.value = '';

        // Reload library stats
        if (state.config.roon_connected) {
            loadSettings();
        }
    } catch (error) {
        showError('Failed to save settings: ' + error.message);
    } finally {
        setLoading(false);
    }
}

export async function handleValidateQobuz() {
    const btn = document.getElementById('validate-qobuz-btn');
    const statusEl = document.getElementById('qobuz-settings-status');

    // Read the currently filled-in fields (app_id is auto-extracted by backend)
    const email = document.getElementById('qobuz-email')?.value.trim() || '';
    const password = document.getElementById('qobuz-password')?.value || '';

    if (btn) {
        btn.disabled = true;
        btn.textContent = 'Valideren...';
    }
    try {
        const res = await fetch('/api/qobuz/validate', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ email, password }),
        });
        const data = await res.json();
        if (statusEl) {
            statusEl.classList.toggle('connected', !!data.available);
            statusEl.querySelector('.status-text').textContent = data.available
                ? `Verbonden met Qobuz als ${data.user_display || email}${data.subscription ? ' (' + data.subscription + ')' : ''} ✓`
                : (data.error || 'Verbinding mislukt');
        }

        // On success, persist the credentials
        if (data.available) {
            const updates = {};
            if (email) updates.qobuz_email = email;
            if (password) updates.qobuz_password = password;
            if (Object.keys(updates).length > 0) {
                try {
                    state.config = await updateConfig(updates);
                    updateSettings();
                    // Clear password field after successful save
                    const qobuzPwField = document.getElementById('qobuz-password');
                    if (qobuzPwField) {
                        qobuzPwField.value = '';
                        qobuzPwField.placeholder = '••••••••••••  (opgeslagen)';
                    }
                } catch (saveErr) {
                    console.warn('Qobuz credentials validated but could not be saved:', saveErr);
                }
            }
        }
    } catch (err) {
        if (statusEl) {
            statusEl.classList.remove('connected');
            statusEl.querySelector('.status-text').textContent = 'Validatie mislukt: ' + err.message;
        }
    } finally {
        if (btn) {
            btn.disabled = false;
            btn.textContent = 'Valideren';
        }
    }
}
