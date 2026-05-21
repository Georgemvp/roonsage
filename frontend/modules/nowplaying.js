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

    bar.innerHTML = `
        <div class="np-art">
            ${artSrc
                ? `<img src="${artSrc}" alt="" class="np-art-img" onerror="this.style.display='none'">`
                : `<div class="np-art-placeholder">♪</div>`}
        </div>
        <div class="np-track-info">
            <div class="np-title" title="${escapeHtml(title)}">${escapeHtml(title)}</div>
            <div class="np-meta">
                ${artist ? `<span class="np-artist">${escapeHtml(artist)}</span>` : ''}
                ${album ? `<span class="np-sep">·</span><span class="np-album">${escapeHtml(album)}</span>` : ''}
                <span class="np-sep">·</span>
                ${zoneSwitcher}
            </div>
            <div class="np-progress" role="progressbar" aria-valuenow="${Math.round(pct)}" aria-valuemin="0" aria-valuemax="100" aria-label="Track progress">
                <div class="np-progress-fill" style="width:${pct}%"></div>
            </div>
        </div>
        <div class="np-controls">
            <button class="np-btn" data-action="previous" aria-label="Previous">⏮</button>
            <button class="np-btn np-btn--primary" data-action="${isPlaying ? 'pause' : 'play'}" aria-label="${isPlaying ? 'Pause' : 'Play'}">${isPlaying ? '⏸' : '▶'}</button>
            <button class="np-btn" data-action="next" aria-label="Next">⏭</button>
            <button class="np-btn np-btn--more" data-action="more_like_this" aria-label="More like this" title="More like this">🎵</button>
        </div>
    `;
    bar.classList.remove('now-playing-bar--hidden');

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
