/**
 * RoonSage — ES module entry point
 *
 * Imports all feature modules and runs the DOMContentLoaded init.
 * No logic lives here — everything is in frontend/modules/*.js.
 */

import { state }                          from './modules/state.js';
import { focusManager }                   from './modules/focus.js';
import { artPlaceholderHtml }             from './modules/utils.js';
import { fetchSetupStatus }               from './modules/api.js';
import { viewFromHash, modeFromHash, loadSavedResult } from './modules/router.js';
import { renderHistoryFeed }              from './modules/history.js';
import {
    updateView, updateMode, updateStep,
    hideError, hideSuccess, hideSuccessModal, dismissSuccessModal,
    setLoading
} from './modules/ui.js';
import { checkLibraryStatus }             from './modules/library.js';
import { setupEventListeners }            from './modules/events.js';
import { loadSettings, loadNotificationSettings, initNotificationButtons } from './modules/playlist.js';
import {
    dismissClientPicker, dismissPlayChoice, dismissPlaySuccess, setSaveMode
} from './modules/instant-queue.js';
import { setupRecEventListeners, initRecommendView, renderPromptPills, PLAYLIST_PROMPT_GROUPS } from './modules/recommend.js';
import { setupHistoryEventListeners }     from './modules/history.js';
import { enterSetupWizard }               from './modules/setup-wizard.js';
import { startNowPlaying }                from './modules/nowplaying.js';
import { initPlaylistsView }              from './modules/playlists.js';
import { initTasteView }                  from './modules/taste.js';
import { initTemplates }                  from './modules/templates.js';
import { initSchedulerSection }           from './modules/scheduler.js';

// =============================================================================
// Initialization
// =============================================================================

document.addEventListener('DOMContentLoaded', async () => {
    // macOS + Safari: by default, Tab only focuses form inputs and elements
    // with explicit tabindex — buttons, links, and other native controls are
    // skipped. Observe the DOM and add tabindex="0" to any button or link
    // that lacks one, making them keyboard-navigable regardless of the
    // system "Keyboard navigation" preference.
    const ensureTabIndex = (root) => {
        root.querySelectorAll('button:not([tabindex]), a[href]:not([tabindex])').forEach(el => {
            el.setAttribute('tabindex', '0');
        });
    };
    ensureTabIndex(document);
    let tabIndexPending = false;
    new MutationObserver(() => {
        if (!tabIndexPending) {
            tabIndexPending = true;
            requestAnimationFrame(() => {
                ensureTabIndex(document.body);
                tabIndexPending = false;
            });
        }
    }).observe(document.body, { childList: true, subtree: true });

    setupEventListeners();
    setupRecEventListeners();
    setupHistoryEventListeners();
    initTemplates();
    initNotificationButtons();
    state.view = viewFromHash();
    state.mode = modeFromHash();
    if (!location.hash) {
        history.replaceState(null, '', '#home');
    }
    updateView();
    updateMode();
    updateStep();
    renderPromptPills('playlist-prompt-pills', 'playlist-prompt-shuffle', PLAYLIST_PROMPT_GROUPS);

    // Load initial config
    try {
        await loadSettings();
        loadNotificationSettings();  // fire-and-forget; populates notification fields

        // Check setup wizard status (only on home view with no deep link)
        const initHash = location.hash.slice(1);
        if (state.view === 'home' && !initHash.startsWith('result/')) {
            try {
                const setupStatus = await fetchSetupStatus();
                // Persist Qobuz availability for the source mode UI — must be set
                // BEFORE enterSetupWizard() because that function returns early and
                // the line below would otherwise never execute during wizard sessions.
                state.qobuzAvailable = !!setupStatus.qobuz_available;
                state.qobuzSaveAvailable = !!setupStatus.qobuz_save_available;
                if (!setupStatus.setup_complete) {
                    enterSetupWizard(setupStatus);
                    return; // Wizard handles its own lifecycle
                }
            } catch (e) {
                // Setup endpoint unavailable — skip wizard, continue normally
                console.warn('Setup status check failed:', e);
            }
        }

        // Reveal home content + footer now that setup check is done
        document.querySelector('#home-view .home-content')?.classList.remove('home-content--loading');
        document.querySelector('.app-footer')?.classList.remove('app-footer--loading');

        // Check library cache status after config is loaded
        if (state.config?.roon_connected) {
            await checkLibraryStatus();
        }
    } catch (error) {
        // Settings will show as not configured
        console.error('Initialization error:', error);
    } finally {
        document.getElementById('app-loading')?.remove();
        // Don't reveal home content if setup wizard took over
        if (!state.setup.active) {
            document.querySelector('#home-view .home-content')?.classList.remove('home-content--loading');
            document.querySelector('.app-footer')?.classList.remove('app-footer--loading');
        }
    }

    // Initialize views AFTER config is loaded
    if (state.view === 'recommend') {
        initRecommendView();
    } else if (state.view === 'home') {
        renderHistoryFeed();
    } else if (state.view === 'playlists') {
        initPlaylistsView();
    } else if (state.view === 'taste') {
        initTasteView();
    }

    // Start Now Playing polling (persistent — runs on all views)
    startNowPlaying();

    // Wire "Save for Arc" button in results view
    _wireArcButton();

    // Handle direct navigation to a saved result (e.g., bookmarked URL)
    const initHash = location.hash.slice(1);
    if (initHash.startsWith('result/')) {
        const resultId = initHash.split('/')[1];
        if (resultId) {
            loadSavedResult(resultId);
        }
    }

    // Restore save mode from localStorage
    let initialMode = 'replace_queue';
    try {
        const savedMode = localStorage.getItem('roonsage-save-mode');
        if (savedMode === 'replace_queue' || savedMode === 'play_now' || savedMode === 'queue_next') {
            initialMode = savedMode;
        }
    } catch (e) { /* private browsing / storage disabled */ }
    setSaveMode(initialMode);
});

// =============================================================================
// Save for Arc — results view integration
// =============================================================================

function _wireArcButton() {
    const btn = document.getElementById('save-for-arc-btn');
    if (!btn) return;

    btn.addEventListener('click', () => {
        const modal = document.getElementById('arc-global-modal');
        const nameInput = document.getElementById('arc-global-name');
        const resultEl  = document.getElementById('arc-global-result');
        const saveBtn   = document.getElementById('arc-global-save');
        if (!modal) return;

        // Pre-fill with playlist title
        if (nameInput) nameInput.value = state.playlistTitle || state.playlistName || 'My Playlist';
        if (resultEl)  { resultEl.textContent = ''; resultEl.className = 'arc-modal-result hidden'; }
        if (saveBtn)   { saveBtn.disabled = false; saveBtn.textContent = 'Opslaan'; }
        modal.classList.remove('hidden');

        saveBtn?.addEventListener('click', async function _save() {
            const name = nameInput?.value.trim() || 'My Playlist';
            const addFav = document.getElementById('arc-global-favorites')?.checked ?? true;
            saveBtn.disabled = true;
            saveBtn.textContent = 'Opslaan…';
            resultEl.className = 'arc-modal-result';
            resultEl.textContent = '';
            try {
                const { apiCall: ac } = await import('./modules/api.js');
                const resp = await ac('/qobuz/prepare-for-arc', {
                    method: 'POST',
                    body: JSON.stringify({
                        item_keys: state.playlist.map(t => t.item_key).filter(Boolean),
                        name,
                        add_to_favorites: addFav,
                    }),
                });
                resultEl.className = 'arc-modal-result arc-modal-result--success';
                resultEl.textContent = `✓ Opgeslagen als Qobuz-playlist — beschikbaar in Roon Arc (${resp.saved || 0} tracks, ${resp.skipped || 0} geskipt)`;
                saveBtn.textContent = 'Opgeslagen';
            } catch (e) {
                resultEl.className = 'arc-modal-result arc-modal-result--error';
                resultEl.textContent = 'Fout: ' + e.message;
                saveBtn.disabled = false;
                saveBtn.textContent = 'Opslaan';
            }
            // Remove one-time listener after first save attempt
            saveBtn.removeEventListener('click', _save);
        }, { once: true });
    });

    document.getElementById('arc-global-close')?.addEventListener('click', () => {
        document.getElementById('arc-global-modal')?.classList.add('hidden');
    });
    document.getElementById('arc-global-cancel')?.addEventListener('click', () => {
        document.getElementById('arc-global-modal')?.classList.add('hidden');
    });
    document.getElementById('arc-global-modal')?.addEventListener('click', e => {
        if (e.target === document.getElementById('arc-global-modal')) {
            document.getElementById('arc-global-modal').classList.add('hidden');
        }
    });
}

// Expose dismissArcModal for inline usage
window.dismissArcModal = () => document.getElementById('arc-global-modal')?.classList.add('hidden');

// Refresh button for playlists view
document.addEventListener('click', e => {
    if (e.target?.id === 'playlists-refresh-btn') {
        initPlaylistsView();
    }
});

// Show arc button when playlist results are shown (whenever state.playlist changes)
const _originalUpdatePlaylist = window._originalUpdatePlaylist;
// Hook into hash changes to show/hide save-for-arc btn
window.addEventListener('hashchange', () => {
    const arcBtn = document.getElementById('save-for-arc-btn');
    if (arcBtn) arcBtn.classList.toggle('hidden', !state.playlist?.length);
});

// =============================================================================
// Globals for inline HTML event handlers (onclick="...", etc.)
// =============================================================================

window.artPlaceholderHtml  = artPlaceholderHtml;
window.hideError           = hideError;
window.hideSuccess         = hideSuccess;
window.hideSuccessModal    = hideSuccessModal;
window.dismissSuccessModal = dismissSuccessModal;
window.dismissClientPicker = dismissClientPicker;
window.dismissPlayChoice   = dismissPlayChoice;
window.dismissPlaySuccess  = dismissPlaySuccess;
