// =============================================================================
// Now Playing — persistent bottom bar with polling & transport controls
// =============================================================================

import { apiCall } from './api.js';
import { escapeHtml } from './utils.js';

const POLL_INTERVAL = 15000; // ms
let _pollTimer = null;
let _currentZoneId = null;
let _zones = [];

// ── Public API ────────────────────────────────────────────────────────────────
export function startNowPlaying() {
    if (_pollTimer) return; // already running
    _poll();
    _pollTimer = setInterval(_poll, POLL_INTERVAL);
}

export function stopNowPlaying() {
    if (_pollTimer) clearInterval(_pollTimer);
    _pollTimer = null;
}

// ── Polling ───────────────────────────────────────────────────────────────────
async function _poll() {
    try {
        const data = await apiCall('/roon/zones');
        _zones = (data.zones || []).filter(z => z.now_playing);
        _render(_zones);
    } catch (e) {
        // silently ignore connection errors during polling
    }
}

// ── Render ────────────────────────────────────────────────────────────────────
function _render(zones) {
    const bar = document.getElementById('now-playing-bar');
    if (!bar) return;

    if (!zones.length) {
        bar.classList.add('now-playing-bar--hidden');
        return;
    }

    // Pick active zone or first zone with now_playing
    let zone = zones.find(z => z.zone_id === _currentZoneId) || zones[0];
    _currentZoneId = zone.zone_id;

    const np = zone.now_playing;
    const isPlaying = zone.state === 'playing';
    const artist = np?.one_line?.line2 || np?.two_line?.line2 || '';
    const title  = np?.one_line?.line1 || np?.two_line?.line1 || 'Unknown';
    const album  = np?.two_line?.line3 || '';
    const artKey = np?.image_key;
    const artSrc = artKey ? `/api/art/${artKey}?width=56&height=56` : null;

    // Progress
    const pos   = zone.now_playing?.seek_position ?? 0;
    const dur   = zone.now_playing?.length ?? 0;
    const pct   = dur > 0 ? Math.min(100, (pos / dur) * 100) : 0;

    // Zone switcher HTML
    const zoneSwitcher = zones.length > 1
        ? `<select id="np-zone-select" class="np-zone-select" aria-label="Select zone">
            ${zones.map(z =>
                `<option value="${escapeHtml(z.zone_id)}"${z.zone_id === _currentZoneId ? ' selected' : ''}>${escapeHtml(z.display_name || z.zone_id)}</option>`
            ).join('')}
           </select>`
        : `<span class="np-zone-name">${escapeHtml(zone.display_name || zone.zone_id)}</span>`;

    const elapsed = dur > 0 ? Math.round(pos) : 0;
    const eMin = Math.floor(elapsed / 60);
    const eSec = String(elapsed % 60).padStart(2, '0');
    const dMin = Math.floor(dur / 60);
    const dSec = String(Math.round(dur % 60)).padStart(2, '0');

    bar.innerHTML = `
        <!-- Left: track info -->
        <div class="np-track-col">
            <div class="np-art-col">
                ${artSrc
                    ? `<img src="${artSrc}" alt="" onerror="this.style.display='none'">`
                    : `<div class="np-art-placeholder">♪</div>`}
            </div>
            <div class="np-info-col">
                <div class="np-title-col" title="${escapeHtml(title)}">${escapeHtml(title)}</div>
                <div class="np-artist-col">${escapeHtml(artist || album || '')}${zones.length > 1 ? ` · ${zoneSwitcher}` : (zone.display_name ? ` · <span style="opacity:.6">${escapeHtml(zone.display_name)}</span>` : '')}</div>
            </div>
        </div>

        <!-- Centre: transport + progress -->
        <div class="np-controls-col">
            <div class="np-buttons-col">
                <button class="np-btn-col" data-action="previous" aria-label="Previous" title="Previous">
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="19 20 9 12 19 4 19 20"/><line x1="5" y1="19" x2="5" y2="5"/></svg>
                </button>
                <button class="np-btn-col np-btn-col--play" data-action="${isPlaying ? 'pause' : 'play'}" aria-label="${isPlaying ? 'Pause' : 'Play'}">
                    ${isPlaying
                        ? `<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><rect x="6" y="4" width="4" height="16"/><rect x="14" y="4" width="4" height="16"/></svg>`
                        : `<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>`}
                </button>
                <button class="np-btn-col" data-action="next" aria-label="Next" title="Next">
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="5 4 15 12 5 20 5 4"/><line x1="19" y1="5" x2="19" y2="19"/></svg>
                </button>
                <button class="np-btn-col" data-action="more_like_this" aria-label="More like this" title="More like this" style="opacity:.6;font-size:0.85rem">
                    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 18V5"/><path d="M15 13a4 4 0 01-3-4 4 4 0 01-3 4"/><path d="M17 6.5A3 3 0 1012 5a3 3 0 10-5 1.5"/></svg>
                </button>
            </div>
            <div class="np-progress-col" role="progressbar" aria-valuenow="${Math.round(pct)}" aria-valuemin="0" aria-valuemax="100" aria-label="Track progress">
                <span class="np-time-col">${eMin}:${eSec}</span>
                <div class="np-bar-col" id="np-seek-bar">
                    <div class="np-bar-fill-col" style="width:${pct}%"></div>
                </div>
                <span class="np-time-col" style="text-align:right">${dMin}:${dSec}</span>
            </div>
        </div>

        <!-- Right: volume -->
        <div class="np-right-col">
            ${zones.length > 1 ? `<select id="np-zone-select" class="np-zone-select-col" aria-label="Select zone">${zones.map(z => `<option value="${escapeHtml(z.zone_id)}"${z.zone_id === _currentZoneId ? ' selected' : ''}>${escapeHtml(z.display_name || z.zone_id)}</option>`).join('')}</select>` : ''}
            <button class="np-btn-col" style="opacity:.6;font-size:0.85rem" title="Volume" aria-label="Volume">
                <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"/><path d="M15.54 8.46a5 5 0 010 7.07"/></svg>
            </button>
            <div class="np-vol-track-col" id="np-vol-track" title="Volume">
                <div class="np-vol-fill-col" style="width:80%"></div>
            </div>
        </div>
    `;
    bar.classList.remove('now-playing-bar--hidden');

    // Update sidebar zone indicator
    const sidebarZoneName = document.getElementById('sidebar-zone-name');
    const sidebarZoneDot  = document.getElementById('sidebar-zone-dot');
    if (sidebarZoneName) sidebarZoneName.textContent = zone.display_name || zone.zone_id || 'Active';
    if (sidebarZoneDot)  sidebarZoneDot.classList.remove('rs-zone-dot--inactive');

    // Zone selector change
    bar.querySelector('#np-zone-select')?.addEventListener('change', e => {
        _currentZoneId = e.target.value;
        _poll();
    });

    // Transport buttons
    bar.querySelectorAll('.np-btn[data-action]').forEach(btn => {
        btn.addEventListener('click', () => _handleAction(btn.dataset.action, zone, np));
    });
}

// ── Transport ─────────────────────────────────────────────────────────────────
async function _handleAction(action, zone, np) {
    if (action === 'more_like_this') {
        _seedFromNowPlaying(np);
        return;
    }
    try {
        await apiCall('/roon/transport', {
            method: 'POST',
            body: JSON.stringify({ zone_id: zone.zone_id, action }),
        });
        // Refresh immediately
        setTimeout(_poll, 400);
    } catch (e) {
        console.error('Transport error:', e);
    }
}

function _seedFromNowPlaying(np) {
    if (!np) return;
    const title  = np.one_line?.line1 || np.two_line?.line1 || '';
    const artist = np.one_line?.line2 || np.two_line?.line2 || '';
    const query  = [artist, title].filter(Boolean).join(' ');

    // Navigate to seed view and pre-fill the search
    location.hash = 'playlist-seed';
    requestAnimationFrame(() => {
        const input = document.getElementById('track-search-input');
        const btn   = document.getElementById('search-tracks-btn');
        if (input && btn) {
            input.value = query;
            btn.click();
        }
    });
}
