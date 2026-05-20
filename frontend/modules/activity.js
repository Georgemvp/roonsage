// =============================================================================
// Background Activity Monitor
// Polls enrichment and library-sync status; drives the global activity bar.
// =============================================================================

let _pollInterval = null;

/**
 * Start polling for background task status every 5 seconds.
 * Safe to call multiple times — only one interval runs at a time.
 */
export function startActivityMonitor() {
    if (_pollInterval) return;
    _updateActivityBar();
    _pollInterval = setInterval(_updateActivityBar, 5000);
}

/** Stop the polling interval (call when unmounting / logging out). */
export function stopActivityMonitor() {
    if (_pollInterval) {
        clearInterval(_pollInterval);
        _pollInterval = null;
    }
}

async function _updateActivityBar() {
    const bar       = document.getElementById('bg-activity-bar');
    const container = document.getElementById('bg-activity-items');
    if (!bar || !container) return;

    const items = [];

    // ── Enrichment status ───────────────────────────────────────────────────
    try {
        const res = await fetch('/api/enrichment/status');
        if (res.ok) {
            const data = await res.json();
            if (data.worker_state === 'running' && data.pending > 0) {
                const pct = data.completion_pct != null
                    ? `${Math.round(data.completion_pct)}%`
                    : '';
                items.push(`
                    <div class="bg-activity-item">
                        <span class="bg-activity-spinner" aria-hidden="true"></span>
                        <span class="bg-activity-label">Enriching metadata</span>
                        <span class="bg-activity-progress">${data.completed}/${data.total} ${pct}</span>
                    </div>`);
            }
        }
    } catch (_) { /* network error — ignore silently */ }

    // ── Library sync status ─────────────────────────────────────────────────
    try {
        const res = await fetch('/api/library/status');
        if (res.ok) {
            const data = await res.json();
            if (data.syncing) {
                const progress = data.sync_progress ? ` ${data.sync_progress}` : '';
                items.push(`
                    <div class="bg-activity-item">
                        <span class="bg-activity-spinner" aria-hidden="true"></span>
                        <span class="bg-activity-label">Syncing library</span>
                        <span class="bg-activity-progress">${progress}</span>
                    </div>`);
            }
        }
    } catch (_) { /* network error — ignore silently */ }

    // ── Update DOM ──────────────────────────────────────────────────────────
    if (items.length > 0) {
        container.innerHTML = items.join('');
        bar.classList.remove('hidden');
    } else {
        bar.classList.add('hidden');
    }
}
