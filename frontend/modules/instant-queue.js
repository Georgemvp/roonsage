// instant-queue.js — Instant Queue / Play Now Handlers
// =============================================================================

import { state } from './state.js';
import { fetchRoonZones, createPlayQueue } from './api.js';
import { focusManager } from './focus.js';
import { setLoading, showError } from './ui.js';
import { escapeHtml } from './utils.js';
import { setPendingNavHash } from './events.js';

// =============================================================================
// Instant Queue — Play Now Handlers (005)
// =============================================================================

export function lockScroll() {
    if (document.body.classList.contains('no-scroll')) return;
    const scrollbarWidth = window.innerWidth - document.documentElement.clientWidth;
    document.body.style.paddingRight = scrollbarWidth + 'px';
    document.body.classList.add('no-scroll');
}

export function unlockScroll() {
    document.body.classList.remove('no-scroll');
    document.body.style.paddingRight = '';
}

export function removeNoScrollIfNoModals() {
    const openModal = document.querySelector(
        '.modal-overlay:not(.hidden), .success-modal:not(.hidden), .sync-modal:not(.hidden), .bottom-sheet:not(.hidden), .loading-overlay:not(.hidden), .step-loading-overlay:not(.hidden)'
    );
    if (!openModal) {
        unlockScroll();
    }
}

export function dismissModal(id, afterDismiss) {
    const modal = document.getElementById(id);
    modal.classList.add('hidden');
    removeNoScrollIfNoModals();
    focusManager.closeModal(modal);
    if (afterDismiss) afterDismiss();
}

export function dismissClientPicker() { dismissModal('client-picker-modal'); }
export function dismissPlayChoice() { dismissModal('play-choice-modal', () => { state._pendingClientId = null; }); }
export function dismissPlaySuccess() { dismissModal('play-success-modal'); }
export function dismissRecRestartModal() { setPendingNavHash(null); dismissModal('rec-restart-modal'); }
export function dismissPlaylistRestartModal() { setPendingNavHash(null); dismissModal('playlist-restart-modal'); }

export function openRecRestartModal() {
    const modal = document.getElementById('rec-restart-modal');
    modal.classList.remove('hidden');
    lockScroll();
    focusManager.openModal(modal);
}

export function openPlaylistRestartModal() {
    const modal = document.getElementById('playlist-restart-modal');
    modal.classList.remove('hidden');
    lockScroll();
    focusManager.openModal(modal);
}

export function getClientStatusText(client) {
    if (client.state === 'playing') {
        return { text: 'Playing', cls: 'status-playing' };
    }
    return { text: 'Idle', cls: 'status-idle' };
}

export function populateClientList(clients) {
    const listEl = document.getElementById('client-list');
    const emptyState = document.getElementById('client-empty-state');

    const hintEl = document.getElementById('client-picker-hint');

    if (!clients.length) {
        listEl.innerHTML = '';
        emptyState.classList.remove('hidden');
        hintEl.classList.add('hidden');
        return;
    }

    emptyState.classList.add('hidden');
    hintEl.classList.remove('hidden');
    listEl.innerHTML = clients.map(client => {
        const status = getClientStatusText(client);
        const outputsText = (client.outputs && client.outputs.length > 1) ? escapeHtml(client.outputs.join(', ')) : '';
        return `
        <div class="client-item" data-client-id="${escapeHtml(client.zone_id)}"
             role="option" tabindex="0"
             aria-label="${escapeHtml(client.display_name)} — ${status.text}">
            <div class="client-status-dot ${client.state === 'playing' ? 'playing' : 'idle'}" aria-hidden="true"></div>
            <div class="client-info">
                <div class="client-name">${escapeHtml(client.display_name)}</div>
                ${outputsText ? `<span class="client-platform">${outputsText}</span>` : ''}
                <div class="client-status-text ${status.cls}">${status.text}</div>
            </div>
        </div>`;
    }).join('');

    listEl.querySelectorAll('.client-item').forEach(item => {
        item.addEventListener('click', () => handleClientSelect(item.dataset.clientId));
        item.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                handleClientSelect(item.dataset.clientId);
            }
        });
    });
}

export async function refreshClientList() {
    const listEl = document.getElementById('client-list');
    const emptyState = document.getElementById('client-empty-state');
    emptyState.querySelector('p').textContent = 'No Roon zones found. Make sure Roon is running.';
    emptyState.classList.add('hidden');
    listEl.innerHTML = '<div class="client-loading"><div class="spinner"></div><p>Finding devices...</p></div>';

    try {
        const clients = await fetchRoonZones();
        state.roonZones = clients;
        populateClientList(clients);
    } catch (error) {
        // Show error inline in the picker so user can retry with refresh button
        listEl.innerHTML = '';
        emptyState.querySelector('p').textContent = 'Failed to find zones. Check that Roon is running.';
        emptyState.classList.remove('hidden');
    }
}

export async function handlePlayNow() {
    if (!state.playlist.length) {
        showError('No tracks to play');
        return;
    }

    // Show client picker modal with loading spinner while fetching
    const modal = document.getElementById('client-picker-modal');
    modal.classList.remove('hidden');
    lockScroll();
    focusManager.openModal(modal);

    await refreshClientList();
}

export function handleClientSelect(clientId) {
    const client = state.roonZones.find(c => c.zone_id === clientId);
    if (!client) return;

    dismissClientPicker();

    // Queue Next always appends without interrupting playback
    if (state.saveMode === 'queue_next') {
        executePlayQueue(clientId, 'append');
        return;
    }

    // Play Now and Replace Queue both replace the queue; if already playing,
    // show the choice modal so the user can confirm or queue next instead.
    if (client.is_playing) {
        state._pendingClientId = clientId;
        const choiceModal = document.getElementById('play-choice-modal');
        choiceModal.classList.remove('hidden');
        lockScroll();
        focusManager.openModal(choiceModal);
    } else {
        executePlayQueue(clientId, 'replace');
    }
}

export async function executePlayQueue(clientId, mode) {
    const choiceModal = document.getElementById('play-choice-modal');
    if (!choiceModal.classList.contains('hidden')) {
        dismissPlayChoice();
    }
    state._pendingClientId = null;
    if (!clientId) {
        showError('No device selected');
        return;
    }
    setLoading(true, 'Sending to device...');

    try {
        const itemKeys = state._pendingRatingKeys || state.playlist.map(t => t.item_key);
        state._pendingRatingKeys = null;
        const response = await createPlayQueue(itemKeys, clientId, mode);

        setLoading(false);
        if (response.success) {
            const message = `${response.tracks_queued} tracks sent to ${response.zone_name}`;
            document.getElementById('play-success-message').textContent = message;
            const playSuccessModal = document.getElementById('play-success-modal');
            playSuccessModal.classList.remove('hidden');
            lockScroll();
            focusManager.openModal(playSuccessModal);
        } else {
            let errorMsg = response.error || 'Failed to start playback';
            if (response.error_code === 'not_found') {
                errorMsg = "Device couldn't be reached. Try starting playback on the device first, then re-open the picker.";
            }
            showError(errorMsg);
        }
    } catch (error) {
        setLoading(false);
        showError(error.message);
    }
}

export function handlePlaySuccessNewPlaylist() {
    dismissPlaySuccess();
    resetPlaylistState();
}

export function toggleSaveModeDropdown() {
    const dropdown = document.getElementById('save-mode-dropdown');
    const btn = document.getElementById('save-mode-dropdown-btn');
    const isHidden = dropdown.classList.contains('hidden');

    dropdown.classList.toggle('hidden');
    btn.setAttribute('aria-expanded', isHidden ? 'true' : 'false');

    if (isHidden) {
        const closeHandler = (e) => {
            if (!dropdown.contains(e.target) && e.target !== btn && !btn.contains(e.target)) {
                dropdown.classList.add('hidden');
                btn.setAttribute('aria-expanded', 'false');
                document.removeEventListener('click', closeHandler);
            }
        };
        setTimeout(() => document.addEventListener('click', closeHandler), 0);
    }
}

export function setSaveMode(mode) {
    state.saveMode = mode;

    // Update dropdown active states
    const dropdown = document.getElementById('save-mode-dropdown');
    dropdown.classList.add('hidden');
    document.getElementById('save-mode-dropdown-btn').setAttribute('aria-expanded', 'false');

    dropdown.querySelectorAll('.save-mode-option').forEach(opt => {
        const isActive = opt.dataset.mode === mode;
        opt.classList.toggle('active', isActive);
        opt.querySelector('.save-mode-check').innerHTML = isActive ? '&#10003;' : '';
    });

    const saveBtn = document.getElementById('save-playlist-btn');

    if (mode === 'play_now') {
        saveBtn.innerHTML = '<span class="btn-label-long">Play Now</span><span class="btn-label-short">Play</span>';
    } else if (mode === 'queue_next') {
        saveBtn.innerHTML = '<span class="btn-label-long">Queue Next</span><span class="btn-label-short">Next</span>';
    } else {
        // replace_queue (default)
        saveBtn.innerHTML = '<span class="btn-label-long">Queue to Roon</span><span class="btn-label-short">Queue</span>';
    }

    // Persist to localStorage
    try { localStorage.setItem('roonsage-save-mode', mode); } catch (e) { /* private browsing */ }
}
