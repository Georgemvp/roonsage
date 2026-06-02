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
    btn.textContent = 'Saving...';
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
            let html = `<strong>${savedCount} of ${savedCount + unmatchedCount} tracks saved to Qobuz</strong> as "${escapeHtml(result.playlist_name || playlistName)}"`;

            if (unmatchedCount > 0 && result.unmatched_details?.length > 0) {
                const items = result.unmatched_details
                    .map(u => `<li>${escapeHtml(u.artist)} — ${escapeHtml(u.title)}</li>`)
                    .join('');
                html += `<details><summary>${unmatchedCount} track${unmatchedCount !== 1 ? 's' : ''} not found on Qobuz</summary><ul>${items}</ul></details>`;
            }

            resultEl.innerHTML = html;
            resultEl.classList.add('success');
        } else {
            resultEl.textContent = result.error || 'Save failed';
            resultEl.classList.add('error');
        }
    } catch (err) {
        resultEl.classList.remove('hidden');
        resultEl.textContent = err.message || 'Save to Qobuz failed';
        resultEl.classList.add('error');
    } finally {
        btn.disabled = false;
        btn.textContent = '▶ Save to Qobuz';
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

                // Fire-and-forget: generate AI description for this playlist result
                if (state.playlist?.length) {
                    apiCall('/background-ai/describe-playlist', {
                        method: 'POST',
                        body: JSON.stringify({
                            title: state.playlistTitle || state.playlistName || '',
                            tracks: state.playlist.map(t => ({
                                artist: t.artist, title: t.title,
                                album: t.album, year: t.year,
                            })),
                            origin: state.lastRequest?.prompt || '',
                            result_id: response.result_id,
                        }),
                    }).catch(() => null);
                }
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

        // Populate Last.fm settings status indicator (fire-and-forget)
        apiCall('/intelligence/lastfm/status')
            .then(lf => {
                const dot = document.querySelector('#lastfm-settings-status .status-dot');
                const txt = document.querySelector('#lastfm-settings-status .status-text');
                if (lf.can_scrobble) {
                    if (dot) dot.style.background = '#4caf50';
                    if (txt) txt.textContent = `Connected as ${lf.username}`;
                } else if (lf.configured) {
                    if (dot) dot.style.background = '#e5a00d';
                    if (txt) txt.textContent = `API configured — not authorized`;
                }
            })
            .catch(() => {});

        // Restore import status labels on page load (fire-and-forget)
        for (const source of ['lastfm', 'listenbrainz']) {
            const elId = source === 'lastfm' ? 'lastfm-import-status' : 'lb-import-status';
            apiCall(`/intelligence/${source}/import-status`)
                .then(data => {
                    const el = document.getElementById(elId);
                    if (!el) return;
                    const count = (data.total_imported || 0).toLocaleString();
                    if (data.status === 'complete' && data.total_imported > 0) {
                        el.textContent = `✓ Klaar — ${count} tracks geïmporteerd`;
                    } else if (data.status === 'running' || data.is_running) {
                        el.textContent = `Bezig… ${count} tracks geïmporteerd`;
                    } else if (data.status === 'error') {
                        el.textContent = `✗ Fout: ${data.error_message || 'onbekend'}`;
                    }
                })
                .catch(() => {});
        }

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
    const ollamaModelFast = document.getElementById('ollama-model-fast')?.value ?? '';

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
        updates.fast_model = ollamaModelFast;
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
    const qobuzEmail = document.getElementById('qobuz-email')?.value.trim() ?? '';
    const qobuzPassword = document.getElementById('qobuz-password')?.value.trim();
    if (qobuzEmail) updates.qobuz_email = qobuzEmail;
    if (qobuzPassword) updates.qobuz_password = qobuzPassword;

    // ListenBrainz settings (saved via validate endpoint — store in user config if filled)
    const lbToken = document.getElementById('lb-token')?.value.trim();
    const lbUsername = document.getElementById('lb-username')?.value.trim();
    // Only send token if user actually typed something (not the masked placeholder dots)
    if (lbToken && !/^•+/.test(lbToken)) updates.listenbrainz_token = lbToken;
    if (lbUsername) updates.listenbrainz_username = lbUsername;

    // Notifications — saved via dedicated endpoint, not the main config endpoint
    await _saveNotificationSettings();

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
        btn.textContent = 'Validating...';
    }
    try {
        const data = await apiCall('/qobuz/validate', {
            method: 'POST',
            body: JSON.stringify({ email, password }),
        });
        if (statusEl) {
            statusEl.classList.toggle('connected', !!data.available);
            statusEl.querySelector('.status-text').textContent = data.available
                ? `Connected to Qobuz as ${data.user_display || email}${data.subscription ? ' (' + data.subscription + ')' : ''} ✓`
                : (data.error || 'Connection failed');
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
                        qobuzPwField.placeholder = '••••••••••••  (saved)';
                    }
                } catch (saveErr) {
                    console.warn('Qobuz credentials validated but could not be saved:', saveErr);
                }
            }
        }
    } catch (err) {
        if (statusEl) {
            statusEl.classList.remove('connected');
            statusEl.querySelector('.status-text').textContent = 'Validation failed: ' + err.message;
        }
    } finally {
        if (btn) {
            btn.disabled = false;
            btn.textContent = 'Validate';
        }
    }
}

// ---------------------------------------------------------------------------
// Notification settings helpers
// ---------------------------------------------------------------------------

const _NOTIF_EVENT_IDS = [
    'playlist_generated',
    'library_sync_complete',
    'library_sync_failed',
    'lb_sync_complete',
];

/** Load notification config from the API and populate the form fields. */
export async function loadNotificationSettings() {
    try {
        const cfg = await apiCall('/notifications/config');

        const discordEl = document.getElementById('notif-discord-url');
        const tgTokenEl = document.getElementById('notif-tg-token');
        const tgChatEl  = document.getElementById('notif-tg-chat');
        const webhookEl = document.getElementById('notif-webhook-url');

        if (discordEl && cfg.discord_webhook_url) discordEl.value = cfg.discord_webhook_url;
        if (tgChatEl  && cfg.telegram_chat_id)    tgChatEl.value  = cfg.telegram_chat_id;
        if (webhookEl && cfg.webhook_url)          webhookEl.value = cfg.webhook_url;
        // Leave password-type token field blank if configured (show placeholder)
        if (tgTokenEl && cfg.telegram_configured) {
            tgTokenEl.placeholder = '••••••••••••  (opgeslagen)';
        }

        // Checkboxes
        const enabled = new Set(cfg.enabled_events || []);
        for (const evt of _NOTIF_EVENT_IDS) {
            const cb = document.getElementById(`notif-evt-${evt}`);
            if (cb) cb.checked = enabled.has(evt);
        }
    } catch (_) {
        // Best-effort; don't block rest of settings load
    }
}

/** Collect notification form values and POST to /api/notifications/config. */
async function _saveNotificationSettings() {
    const updates = {};

    const discordUrl = document.getElementById('notif-discord-url')?.value.trim();
    const tgToken    = document.getElementById('notif-tg-token')?.value.trim();
    const tgChat     = document.getElementById('notif-tg-chat')?.value.trim();
    const webhookUrl = document.getElementById('notif-webhook-url')?.value.trim();

    if (discordUrl !== undefined) updates.discord_webhook_url = discordUrl;
    if (tgToken)                  updates.telegram_bot_token  = tgToken;
    if (tgChat  !== undefined)    updates.telegram_chat_id    = tgChat;
    if (webhookUrl !== undefined) updates.webhook_url         = webhookUrl;

    const enabledEvents = _NOTIF_EVENT_IDS.filter(evt => {
        const cb = document.getElementById(`notif-evt-${evt}`);
        return cb?.checked;
    });
    updates.enabled_events = enabledEvents;

    if (Object.keys(updates).length === 0) return;

    try {
        await apiCall('/notifications/config', {
            method: 'POST',
            body: JSON.stringify(updates),
        });
    } catch (err) {
        console.warn('Could not save notification settings:', err);
    }
}

/** Send a test notification for a given channel. */
async function _testNotification(channel, resultElId) {
    const resultEl = document.getElementById(resultElId);
    if (resultEl) {
        resultEl.textContent = 'Versturen…';
        resultEl.style.color = 'var(--color-text-muted, #888)';
    }

    const body = { channel };
    if (channel === 'discord') {
        body.discord_webhook_url = document.getElementById('notif-discord-url')?.value.trim();
    } else if (channel === 'telegram') {
        body.telegram_bot_token = document.getElementById('notif-tg-token')?.value.trim();
        body.telegram_chat_id   = document.getElementById('notif-tg-chat')?.value.trim();
    } else if (channel === 'webhook') {
        body.webhook_url = document.getElementById('notif-webhook-url')?.value.trim();
    }

    try {
        const data = await apiCall('/notifications/test', {
            method: 'POST',
            body: JSON.stringify(body),
        });
        if (resultEl) {
            resultEl.textContent = data.success ? '✓ Verzonden!' : `✗ ${data.error || 'Mislukt'}`;
            resultEl.style.color = data.success ? '#4caf50' : '#f44336';
        }
    } catch (err) {
        if (resultEl) {
            resultEl.textContent = `✗ ${err.message}`;
            resultEl.style.color = '#f44336';
        }
    }
}

/** Wire up test-notification buttons (call once after DOM is ready). */
export function initNotificationButtons() {
    document.getElementById('test-discord-btn')
        ?.addEventListener('click', () => _testNotification('discord', 'test-discord-result'));
    document.getElementById('test-telegram-btn')
        ?.addEventListener('click', () => _testNotification('telegram', 'test-telegram-result'));
    document.getElementById('test-webhook-btn')
        ?.addEventListener('click', () => _testNotification('webhook', 'test-webhook-result'));
}

// =============================================================================
// Metadata Enrichment UI (v10.0)
// =============================================================================

let _enrichmentPollTimer = null;

/**
 * Fetch enrichment status and update the UI.
 * Returns the status object (or null on error).
 */
export async function loadEnrichmentStatus() {
    try {
        const data = await apiCall('/enrichment/status');
        _updateEnrichmentUI(data);
        return data;
    } catch (err) {
        console.warn('Could not load enrichment status:', err);
        return null;
    }
}

function _updateEnrichmentUI(data) {
    const total    = data.enriched_total ?? 0;
    const mb       = data.mb_matches    ?? 0;
    const lf       = data.lastfm_matches ?? 0;
    const pending  = data.pending       ?? 0;
    const complete = data.complete      ?? 0;
    const failed   = data.failed        ?? 0;
    const running  = data.worker_running ?? false;
    const paused   = data.worker_paused  ?? false;

    // Stats
    _setText('enrich-total',   total);
    _setText('enrich-mb',      mb);
    _setText('enrich-lf',      lf);
    _setText('enrich-pending', pending);
    _setText('enrich-failed',  failed);

    // Worker state label (with mode badge when MB is skipped)
    const skipMb = data.skip_mb ?? false;
    const modeBadge = skipMb ? ' · Last.fm only' : '';
    const stateLabel = paused ? '⏸ Gepauzeerd' : (running ? `▶ Actief${modeBadge}` : '⏹ Gestopt');
    _setText('enrich-worker-state', stateLabel);

    // Progress bar
    const queued = complete + pending + failed;
    const pct = queued > 0 ? Math.round(complete / queued * 100) : (total > 0 ? 100 : 0);
    const bar = document.getElementById('enrich-progress-bar');
    if (bar) bar.style.width = pct + '%';

    // Progress text
    const progressText = queued > 0
        ? `${complete} van ${queued} tracks verrijkt (${pct}%)`
        : (total > 0 ? `${total} tracks verrijkt` : 'Nog niet gestart');
    _setText('enrich-progress-text', progressText);

    // Buttons
    const allBtn    = document.getElementById('enrich-all-btn');
    const pauseBtn  = document.getElementById('enrich-pause-btn');
    const resumeBtn = document.getElementById('enrich-resume-btn');

    if (allBtn)    allBtn.disabled  = running && !paused;
    if (pauseBtn) {
        pauseBtn.disabled = !running || paused;
        pauseBtn.style.display = '';
    }
    if (resumeBtn) {
        resumeBtn.style.display = paused ? 'inline-block' : 'none';
    }
}

function _setText(id, value) {
    const el = document.getElementById(id);
    if (el) el.textContent = value;
}

/** Start (or resume) enrichment and begin polling for progress. */
async function _startEnrichment() {
    const resultEl = document.getElementById('enrich-action-result');
    if (resultEl) { resultEl.textContent = 'Bezig met starten…'; resultEl.style.color = ''; }

    try {
        const data = await apiCall('/enrichment/start', { method: 'POST' });
        if (resultEl) {
            resultEl.textContent = data.message || 'Gestart.';
            resultEl.style.color = '#4caf50';
        }
        await loadEnrichmentStatus();
        _startEnrichmentPolling();
    } catch (err) {
        if (resultEl) { resultEl.textContent = '✗ ' + err.message; resultEl.style.color = '#f44336'; }
    }
}

async function _pauseEnrichment() {
    const resultEl = document.getElementById('enrich-action-result');
    try {
        await apiCall('/enrichment/pause', { method: 'POST' });
        if (resultEl) { resultEl.textContent = 'Worker gepauzeerd.'; resultEl.style.color = ''; }
        await loadEnrichmentStatus();
        _stopEnrichmentPolling();
    } catch (err) {
        if (resultEl) { resultEl.textContent = '✗ ' + err.message; resultEl.style.color = '#f44336'; }
    }
}

async function _resumeEnrichment() {
    const resultEl = document.getElementById('enrich-action-result');
    try {
        await apiCall('/enrichment/resume', { method: 'POST' });
        if (resultEl) { resultEl.textContent = 'Worker hervat.'; resultEl.style.color = '#4caf50'; }
        await loadEnrichmentStatus();
        _startEnrichmentPolling();
    } catch (err) {
        if (resultEl) { resultEl.textContent = '✗ ' + err.message; resultEl.style.color = '#f44336'; }
    }
}

function _startEnrichmentPolling(intervalMs = 5000) {
    _stopEnrichmentPolling();
    _enrichmentPollTimer = setInterval(async () => {
        const data = await loadEnrichmentStatus();
        // Stop polling when worker is idle (not running or paused)
        if (!data || (!data.worker_running && !data.worker_paused)) {
            _stopEnrichmentPolling();
        }
    }, intervalMs);
}

function _stopEnrichmentPolling() {
    if (_enrichmentPollTimer !== null) {
        clearInterval(_enrichmentPollTimer);
        _enrichmentPollTimer = null;
    }
}

/** Wire up enrichment buttons (call once after DOM is ready). */
export function initEnrichmentButtons() {
    document.getElementById('enrich-all-btn')
        ?.addEventListener('click', _startEnrichment);
    document.getElementById('enrich-pause-btn')
        ?.addEventListener('click', _pauseEnrichment);
    document.getElementById('enrich-resume-btn')
        ?.addEventListener('click', _resumeEnrichment);

    // Load current status immediately
    loadEnrichmentStatus().then(data => {
        // If worker is already running, start polling
        if (data?.worker_running && !data?.worker_paused) {
            _startEnrichmentPolling();
        }
    });
}
