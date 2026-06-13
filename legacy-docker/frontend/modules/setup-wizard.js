// =============================================================================
// Setup Wizard
// =============================================================================

import { state } from './state.js';
import { apiCall, fetchSetupStatus, validateRoon, validateAI, completeSetup } from './api.js';
import { focusManager } from './focus.js';
import { updateView, setLoading } from './ui.js';
import { checkLibraryStatus, formatRelativeTime } from './library.js';
import { loadSettings } from './playlist.js';
import { renderHistoryFeed } from './history.js';

export const SETUP_AI_HINTS = {
    gemini: 'Get a free key at <a href="https://aistudio.google.com/apikey" target="_blank" rel="noopener">aistudio.google.com/apikey</a>',
    anthropic: 'Get a key at <a href="https://console.anthropic.com/settings/keys" target="_blank" rel="noopener">console.anthropic.com</a>',
    openai: 'Get a key at <a href="https://platform.openai.com/api-keys" target="_blank" rel="noopener">platform.openai.com</a>',
    ollama: 'Make sure Ollama is running on your network',
    custom: 'Any OpenAI-compatible API endpoint',
};

export function enterSetupWizard(status) {
    state.setup.active = true;
    state.setup.status = status;
    document.getElementById('app-loading')?.remove();
    const wizard = document.getElementById('setup-wizard');
    const homeContent = document.querySelector('#home-view .home-content');
    wizard.classList.remove('hidden');
    if (homeContent) homeContent.classList.add('hidden');
    renderSetupState(status);
    setupWizardEventListeners();
}

export function exitSetupWizard() {
    state.setup.active = false;
    if (state.setup.syncPollInterval) {
        clearInterval(state.setup.syncPollInterval);
        state.setup.syncPollInterval = null;
    }
    const wizard = document.getElementById('setup-wizard');
    const homeContent = document.querySelector('#home-view .home-content');
    wizard.classList.add('hidden');
    if (homeContent) {
        homeContent.classList.remove('hidden', 'home-content--loading');
    }
    document.querySelector('.app-footer')?.classList.remove('app-footer--loading');

    // Run normal init
    loadSettings().then(() => {
        if (state.config?.roon_connected) checkLibraryStatus();
    }).catch(() => {});
    renderHistoryFeed();
}

export function renderSetupState(status) {
    // Data dir warning
    const dataWarning = document.getElementById('setup-data-warning');
    if (!status.data_dir_writable) {
        dataWarning.classList.remove('hidden');
        document.getElementById('setup-data-fix').textContent =
            `Run: sudo chown ${status.process_uid}:${status.process_gid} ${status.data_dir}`;
    } else {
        dataWarning.classList.add('hidden');
    }

    // Step 1: Roon
    if (status.roon_connected) {
        setStepDone('roon', `Connected to Roon Core`);
    } else {
        setStepForm('roon');
        if (status.roon_from_env) {
            const hostInput = document.getElementById('setup-roon-host');
            if (hostInput && !hostInput.value) hostInput.value = '';
        }
    }

    // Step 2: AI
    if (status.llm_configured) {
        const providerLabel = {
            gemini: 'Gemini', anthropic: 'Claude', openai: 'OpenAI',
            ollama: 'Ollama', custom: 'Custom',
        }[status.llm_provider] || status.llm_provider;
        setStepDone('ai', `Using ${providerLabel}`);
    } else {
        setStepForm('ai');
    }

    // Step 3: Sync
    if (status.library_synced && !status.is_syncing) {
        const syncedWhen = status.synced_at ? ` · synced ${formatRelativeTime(status.synced_at)}` : '';
        setStepDone('sync', `${status.track_count.toLocaleString()} tracks${syncedWhen}`);
    } else if (status.is_syncing) {
        showSyncProgress(status);
        startSetupSyncPolling();
    } else if (status.roon_connected && status.llm_configured) {
        // Auto-trigger sync
        triggerSetupSync();
    } else {
        setStepForm('sync');
        document.getElementById('setup-sync-waiting').classList.remove('hidden');
        document.getElementById('setup-sync-progress-wrap').classList.add('hidden');
    }

    // Step 4: Get Started
    const allDone = status.roon_connected && status.llm_configured &&
        status.library_synced && !status.is_syncing;
    const getStartedBtn = document.getElementById('setup-get-started-btn');
    getStartedBtn.disabled = !allDone;
    if (allDone) {
        document.getElementById('setup-step-ready').classList.add('setup-step--done');
        const num = document.querySelector('#setup-step-ready .setup-step-number');
        if (num) num.textContent = '✓';
    }
}

export function setStepDone(stepName, text) {
    const step = document.getElementById(`setup-step-${stepName}`);
    const form = document.getElementById(`setup-${stepName}-form`);
    const done = document.getElementById(`setup-${stepName}-done`);
    const doneText = document.getElementById(`setup-${stepName}-done-text`);
    step.classList.add('setup-step--done');
    step.classList.remove('setup-step--error');
    if (form) form.classList.add('hidden');
    if (done) done.classList.remove('hidden');
    if (doneText) doneText.textContent = text;
    const num = step.querySelector('.setup-step-number');
    if (num) num.textContent = '✓';
}

export function setStepForm(stepName) {
    const step = document.getElementById(`setup-step-${stepName}`);
    const form = document.getElementById(`setup-${stepName}-form`);
    const done = document.getElementById(`setup-${stepName}-done`);
    step.classList.remove('setup-step--done', 'setup-step--error');
    if (form) form.classList.remove('hidden');
    if (done) done.classList.add('hidden');
}

export function setStepError(stepName, msg) {
    const step = document.getElementById(`setup-step-${stepName}`);
    step.classList.add('setup-step--error');
    step.classList.remove('setup-step--done');
    const errorEl = document.getElementById(`setup-${stepName}-error`);
    if (errorEl) {
        errorEl.textContent = msg;
        errorEl.classList.remove('hidden');
    }
}

export function clearStepError(stepName) {
    const step = document.getElementById(`setup-step-${stepName}`);
    step.classList.remove('setup-step--error');
    const errorEl = document.getElementById(`setup-${stepName}-error`);
    if (errorEl) errorEl.classList.add('hidden');
}

export function showSyncProgress(status) {
    setStepForm('sync');
    document.getElementById('setup-sync-waiting').classList.add('hidden');
    document.getElementById('setup-sync-progress-wrap').classList.remove('hidden');

    if (status.sync_progress) {
        const sp = status.sync_progress;
        const pct = sp.total > 0 ? Math.round((sp.current / sp.total) * 100) : 0;
        const fill = document.getElementById('setup-sync-progress-fill');
        fill.style.width = `${pct}%`;
        fill.parentElement.setAttribute('aria-valuenow', pct);

        let progressText;
        if (sp.phase === 'fetching_albums') {
            progressText = 'Fetching album metadata…';
        } else if (sp.phase === 'fetching') {
            progressText = sp.total > 0
                ? `Scanning albums for tracks: ${sp.current.toLocaleString()} / ${sp.total.toLocaleString()}`
                : 'Fetching tracks from Roon…';
        } else {
            progressText = sp.total > 0
                ? `Processing tracks: ${sp.current.toLocaleString()} / ${sp.total.toLocaleString()}`
                : 'Processing…';
        }
        document.getElementById('setup-sync-progress-text').textContent = progressText;
        document.getElementById('setup-sync-message').textContent = 'Syncing your library...';
    }
}

export async function triggerSetupSync() {
    try {
        await apiCall('/library/sync', { method: 'POST' });
    } catch (e) {
        // May already be syncing (409) — that's fine
        if (!e.message.includes('already in progress')) {
            setStepError('sync', e.message);
            return;
        }
    }
    startSetupSyncPolling();
}

export function startSetupSyncPolling() {
    if (state.setup.syncPollInterval) return;
    // Show progress immediately
    document.getElementById('setup-sync-waiting').classList.add('hidden');
    document.getElementById('setup-sync-progress-wrap').classList.remove('hidden');

    state.setup.syncPollInterval = setInterval(async () => {
        try {
            const libStatus = await apiCall('/library/status');
            if (libStatus.is_syncing) {
                showSyncProgress({
                    sync_progress: libStatus.sync_progress,
                    is_syncing: true,
                });
            } else if (libStatus.track_count > 0) {
                // Sync complete
                clearInterval(state.setup.syncPollInterval);
                state.setup.syncPollInterval = null;
                setStepDone('sync', `${libStatus.track_count.toLocaleString()} tracks synced`);
                // Update status and re-render step 4
                state.setup.status.library_synced = true;
                state.setup.status.track_count = libStatus.track_count;
                state.setup.status.is_syncing = false;
                renderSetupState(state.setup.status);
            } else if (libStatus.error) {
                clearInterval(state.setup.syncPollInterval);
                state.setup.syncPollInterval = null;
                setStepError('sync', libStatus.error);
            }
        } catch (e) {
            // Network error — keep polling
        }
    }, 2000);
}

let _setupListenersAttached = false;

export function setupWizardEventListeners() {
    if (_setupListenersAttached) return;
    _setupListenersAttached = true;

    // Roon validation
    document.getElementById('setup-roon-btn').addEventListener('click', async () => {
        const host = document.getElementById('setup-roon-host').value.trim();
        const port = document.getElementById('setup-roon-port').value.trim() || '9330';

        if (!host) {
            setStepError('roon', 'Roon Core host is required');
            return;
        }

        clearStepError('roon');
        const btn = document.getElementById('setup-roon-btn');
        btn.disabled = true;
        btn.textContent = 'Connecting...';

        // After ~3 seconds the Roon Core will have shown RoonSage in its
        // Extensions list — nudge the user to enable it there.
        const hintTimer = setTimeout(() => {
            const errorEl = document.getElementById('setup-roon-error');
            if (errorEl && errorEl.classList.contains('hidden')) {
                errorEl.textContent = 'Waiting for approval — open Roon → Settings → Extensions and enable RoonSage.';
                errorEl.classList.remove('hidden');
            }
            btn.textContent = 'Waiting for Roon…';
        }, 3000);

        try {
            const result = await validateRoon(host, port);
            clearTimeout(hintTimer);
            if (result.success) {
                state.setup.status.roon_connected = true;
                setStepDone('roon', result.core_name
                    ? `Connected to ${result.core_name}` : 'Connected to Roon');
                // Auto-trigger sync if AI is also done
                if (state.setup.status.llm_configured && !state.setup.status.library_synced) {
                    state.setup.status.is_syncing = true;
                    triggerSetupSync();
                }
                renderSetupState(state.setup.status);
            } else if (result.needs_authorization) {
                setStepError('roon', result.error || 'Open Roon → Settings → Extensions and enable RoonSage, then retry.');
            } else {
                setStepError('roon', result.error || 'Connection failed');
            }
        } catch (e) {
            clearTimeout(hintTimer);
            setStepError('roon', e.message);
        } finally {
            clearTimeout(hintTimer);
            btn.disabled = false;
            btn.textContent = 'Connect';
        }
    });

    // AI provider dropdown change
    document.getElementById('setup-ai-provider').addEventListener('change', () => {
        const provider = document.getElementById('setup-ai-provider').value;
        const keyGroup = document.getElementById('setup-ai-key-group');
        const ollamaGroup = document.getElementById('setup-ai-ollama-group');
        const customGroup = document.getElementById('setup-ai-custom-group');
        const hintEl = document.getElementById('setup-ai-hint');

        keyGroup.classList.toggle('hidden', provider === 'ollama' || provider === 'custom');
        ollamaGroup.classList.toggle('hidden', provider !== 'ollama');
        customGroup.classList.toggle('hidden', provider !== 'custom');
        if (hintEl) hintEl.innerHTML = SETUP_AI_HINTS[provider] || '';
    });

    // AI validation
    document.getElementById('setup-ai-btn').addEventListener('click', async () => {
        const provider = document.getElementById('setup-ai-provider').value;
        const apiKey = document.getElementById('setup-ai-key')?.value.trim() || '';
        const ollamaUrl = document.getElementById('setup-ai-ollama-url')?.value.trim() || '';
        const customUrl = document.getElementById('setup-ai-custom-url')?.value.trim() || '';

        // Basic client-side validation
        if (['gemini', 'anthropic', 'openai'].includes(provider) && !apiKey) {
            setStepError('ai', 'API key is required');
            return;
        }
        if (provider === 'custom' && !customUrl) {
            setStepError('ai', 'API URL is required');
            return;
        }

        clearStepError('ai');
        const btn = document.getElementById('setup-ai-btn');
        btn.disabled = true;
        btn.textContent = 'Validating...';

        try {
            const result = await validateAI(provider, apiKey, ollamaUrl, customUrl);
            if (result.success) {
                state.setup.status.llm_configured = true;
                state.setup.status.llm_provider = provider;
                setStepDone('ai', `Using ${result.provider_name || provider}`);
                // Auto-trigger sync if Roon is also done
                if (state.setup.status.roon_connected && !state.setup.status.library_synced) {
                    state.setup.status.is_syncing = true;
                    triggerSetupSync();
                }
                renderSetupState(state.setup.status);
            } else {
                setStepError('ai', result.error || 'Validation failed');
            }
        } catch (e) {
            setStepError('ai', e.message);
        } finally {
            btn.disabled = false;
            btn.textContent = 'Validate';
        }
    });

    // Get Started
    document.getElementById('setup-get-started-btn').addEventListener('click', async () => {
        await completeSetup();
        exitSetupWizard();
    });

    // Skip Setup
    document.getElementById('setup-skip-btn').addEventListener('click', () => {
        exitSetupWizard();
    });
}
