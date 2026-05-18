import { state } from './state.js';
import { apiCall, fetchLibraryStats, fetchLibraryStatus, triggerLibrarySync } from './api.js';
import { focusManager } from './focus.js';
import { setLoading, showError, showSuccess } from './ui.js';
import { lockScroll, removeNoScrollIfNoModals } from './instant-queue.js';

export let syncPollInterval = null;

export function showSyncModal(reason = 'first-time') {
    const modal = document.getElementById('sync-modal');
    const title = document.getElementById('sync-modal-title');
    const desc = document.getElementById('sync-modal-description');

    if (reason === 'upgrade') {
        title.textContent = 'Updating Your Library';
        desc.textContent = 'A new version needs to refresh your track cache. This may take a minute...';
    } else {
        title.textContent = 'Syncing Your Library';
        desc.textContent = 'Building your local track cache for faster access...';
    }

    modal.classList.remove('hidden');
    lockScroll();
    focusManager.openModal(modal);
}

export function hideSyncModal() {
    const modal = document.getElementById('sync-modal');
    modal.classList.add('hidden');
    removeNoScrollIfNoModals();
    focusManager.closeModal(modal);
}

export function updateSyncProgress(phase, current, total) {
    const fill = document.getElementById('sync-progress-fill');
    const text = document.getElementById('sync-progress-text');
    const bar = fill?.parentElement;

    if (phase === 'fetching_albums') {
        // Indeterminate — browsing for album metadata (fast, no count available)
        fill.style.width = '0%';
        text.textContent = 'Fetching album metadata…';
        if (bar) bar.setAttribute('aria-valuenow', '0');
    } else if (phase === 'fetching') {
        // Determinate — album-by-album track scan (the slow phase)
        const percent = total > 0 ? (current / total) * 100 : 0;
        fill.style.width = `${percent}%`;
        text.textContent = total > 0
            ? `Scanning albums for tracks: ${current.toLocaleString()} / ${total.toLocaleString()}`
            : 'Fetching tracks from Roon…';
        if (bar) bar.setAttribute('aria-valuenow', Math.round(percent).toString());
    } else if (phase === 'processing') {
        // Processing tracks into the cache
        const percent = total > 0 ? (current / total) * 100 : 0;
        fill.style.width = `${percent}%`;
        text.textContent = `Processing tracks: ${current.toLocaleString()} / ${total.toLocaleString()}`;
        if (bar) bar.setAttribute('aria-valuenow', Math.round(percent).toString());
    } else {
        // Unknown or null phase - show generic message
        fill.style.width = '0%';
        text.textContent = 'Syncing...';
        if (bar) bar.setAttribute('aria-valuenow', '0');
    }
}

export function formatRelativeTime(isoString) {
    if (!isoString) return 'Never';

    const date = new Date(isoString);
    const now = new Date();
    const diffMs = now - date;
    const diffMins = Math.floor(diffMs / 60000);
    const diffHours = Math.floor(diffMins / 60);
    const diffDays = Math.floor(diffHours / 24);

    if (diffMins < 1) return 'Just now';
    if (diffMins < 60) return `${diffMins} min${diffMins !== 1 ? 's' : ''} ago`;
    if (diffHours < 24) return `${diffHours} hour${diffHours !== 1 ? 's' : ''} ago`;
    if (diffDays < 7) return `${diffDays} day${diffDays !== 1 ? 's' : ''} ago`;

    return date.toLocaleDateString();
}

export function updateFooterLibraryStatus(status) {
    const container = document.getElementById('footer-library-status');
    const trackCount = document.getElementById('footer-track-count');
    const trackSeparator = document.getElementById('footer-track-separator');
    const syncTime = document.getElementById('footer-sync-time');

    if (!status || (status.track_count === 0 && !status.is_syncing)) {
        container.classList.add('hidden');
        return;
    }

    container.classList.remove('hidden');
    // Show track count, or hide it during sync when count is 0
    if (status.track_count > 0) {
        trackCount.textContent = `${status.track_count.toLocaleString()} tracks`;
        trackCount.style.display = '';
        trackSeparator.style.display = '';
    } else if (status.is_syncing) {
        trackCount.style.display = 'none';
        trackSeparator.style.display = 'none';
    }

    if (status.is_syncing) {
        // Show percentage during both the album-scan (fetching) and processing phases
        const p = status.sync_progress;
        if (p && p.total > 0 && (p.phase === 'fetching' || p.phase === 'processing')) {
            const pct = Math.round((p.current / p.total) * 100);
            syncTime.textContent = `Syncing ${pct}%`;
        } else {
            syncTime.textContent = 'Syncing...';
        }
    } else {
        syncTime.textContent = formatRelativeTime(status.synced_at);
    }
}

export async function checkLibraryStatus() {
    try {
        const status = await fetchLibraryStatus();

        // Update footer status
        updateFooterLibraryStatus(status);

        // Upgrade resync: schema migration requires re-sync — blocking
        if (status.needs_resync && status.roon_connected) {
            showSyncModal('upgrade');
            if (status.is_syncing && status.sync_progress) {
                updateSyncProgress(status.sync_progress.phase, status.sync_progress.current, status.sync_progress.total);
            } else if (!status.is_syncing) {
                // Backend auto-resync hasn't started yet — trigger it
                updateSyncProgress('fetching_albums', 0, 0);
                try {
                    await triggerLibrarySync();
                } catch { /* sync may already be in progress (409) */ }
            }
            startSyncPolling();
        // First-time sync: no tracks ever — blocking
        } else if (status.track_count === 0 && status.roon_connected && !status.is_syncing && !status.synced_at) {
            await startFirstTimeSync();
        // Any other sync in progress (manual refresh, stale re-sync) — background only
        } else if (status.is_syncing) {
            startSyncPolling();
        // Cache empty after a previous sync (error, etc.) — trigger silently
        } else if (status.track_count === 0 && status.roon_connected && status.synced_at) {
            try {
                await triggerLibrarySync();
            } catch { /* sync may already be in progress (409) */ }
            startSyncPolling();
        }

        return status;
    } catch (error) {
        console.error('Failed to check library status:', error);
        return null;
    }
}

export async function startFirstTimeSync() {
    showSyncModal();
    updateSyncProgress('fetching_albums', 0, 0);

    try {
        await triggerLibrarySync();
        // Always poll for progress
        startSyncPolling();
    } catch (error) {
        console.error('Sync failed:', error);
        hideSyncModal();
        showError('Failed to sync library: ' + error.message);
    }
}

export function startSyncPolling() {
    if (syncPollInterval) return;

    syncPollInterval = setInterval(async () => {
        try {
            const status = await fetchLibraryStatus();

            if (status.is_syncing && status.sync_progress) {
                updateSyncProgress(status.sync_progress.phase, status.sync_progress.current, status.sync_progress.total);
                // Update footer with progress percentage for background syncs
                updateFooterLibraryStatus(status);
            } else if (!status.is_syncing) {
                // Sync completed
                stopSyncPolling();
                hideSyncModal();
                updateFooterLibraryStatus(status);

                if (status.error) {
                    showError('Sync failed: ' + status.error);
                }
            }
        } catch (error) {
            console.error('Error polling sync status:', error);
        }
    }, 1000);
}

export function stopSyncPolling() {
    if (syncPollInterval) {
        clearInterval(syncPollInterval);
        syncPollInterval = null;
    }
}

export async function handleRefreshLibrary() {
    try {
        const status = await fetchLibraryStatus();

        if (status.is_syncing) {
            showSuccess('Sync already in progress');
            return;
        }

        await triggerLibrarySync();
        startSyncPolling();

        // Update footer to show syncing
        const syncTime = document.getElementById('footer-sync-time');
        if (syncTime) {
            syncTime.textContent = 'Syncing...';
        }
    } catch (error) {
        if (error.message.includes('409')) {
            showSuccess('Sync already in progress');
        } else {
            showError('Failed to start sync: ' + error.message);
        }
    }
}
