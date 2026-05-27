// =============================================================================
// Moods — mood-tagged discovery section (v13.2)
// =============================================================================
// Lists every mood the backend has assigned to library tracks and lets the
// user one-click a mood-themed playlist on the active Roon zone.

import { apiCall } from './api.js';
import { escapeHtml } from './utils.js';
import { getCurrentZoneId } from './nowplaying.js';

// Visual order so the cards aren't randomly arranged across refreshes.
const MOOD_ORDER = [
    'calm', 'dreamy', 'romantic', 'melancholic', 'mysterious', 'dark',
    'playful', 'happy', 'groovy', 'energetic', 'epic', 'aggressive',
];

const MOOD_EMOJI = {
    calm: '🌿',
    energetic: '⚡',
    happy: '☀️',
    melancholic: '🌧️',
    aggressive: '🔥',
    dreamy: '☁️',
    groovy: '🎷',
    dark: '🌑',
    romantic: '💗',
    epic: '🏔️',
    playful: '🎈',
    mysterious: '🔮',
};


// ── Public: render the section into a parent container ──────────────────────

export async function renderMoodsSection(container) {
    if (!container) return;
    container.innerHTML = `
        <section class="rs-section" aria-labelledby="discovery-moods-heading">
            <div class="rs-section-header">
                <h3 class="rs-section-title" id="discovery-moods-heading">Moods</h3>
                <span class="discovery-section-badge" id="moods-badge">…</span>
            </div>
            <p class="discovery-section-desc">
                Auto-tagged from CLAP audio embeddings. Click a mood to play it.
            </p>
            <div id="moods-grid" class="moods-grid"></div>
            <div id="moods-empty" style="display:none;color:var(--text-muted);font-size:0.9rem"></div>
        </section>
    `;

    const grid  = container.querySelector('#moods-grid');
    const badge = container.querySelector('#moods-badge');
    const empty = container.querySelector('#moods-empty');

    let data;
    try {
        data = await apiCall('/mood/tags');
    } catch (e) {
        empty.style.display = 'block';
        empty.textContent = `Could not load mood tags: ${e.message}`;
        badge.textContent = '0';
        return;
    }

    const moods = data?.moods || [];
    badge.textContent = moods.length;

    if (!moods.length) {
        empty.style.display = 'block';
        empty.innerHTML = `
            No mood tags yet. Run mood tagging from the analysis settings
            (requires <code>CLAP_ENABLED=true</code> and at least 24 CLAP
            embeddings).
            <button id="moods-generate-btn" class="btn btn-secondary btn-sm" style="margin-left:8px">
                Run mood tagger
            </button>
        `;
        const btn = empty.querySelector('#moods-generate-btn');
        btn?.addEventListener('click', () => _triggerGenerate(btn));
        return;
    }

    // Sort by canonical visual order; unknown moods drift to the end.
    const byMood = new Map(moods.map(m => [m.mood, m.track_count]));
    const ordered = [
        ...MOOD_ORDER.filter(m => byMood.has(m)),
        ...moods.map(m => m.mood).filter(m => !MOOD_ORDER.includes(m)),
    ];

    grid.innerHTML = ordered.map(mood => {
        const count = byMood.get(mood) || 0;
        const emoji = MOOD_EMOJI[mood] || '🎵';
        return `
            <button class="mood-card" data-mood="${escapeHtml(mood)}"
                    aria-label="Play ${escapeHtml(mood)} mood (${count} tracks)">
                <span class="mood-card-emoji" aria-hidden="true">${emoji}</span>
                <span class="mood-card-name">${escapeHtml(mood)}</span>
                <span class="mood-card-count">${count} tracks</span>
            </button>
        `;
    }).join('');

    grid.querySelectorAll('.mood-card').forEach(btn => {
        btn.addEventListener('click', () => _playMood(btn));
    });
}


// ── Internals ──────────────────────────────────────────────────────────────

async function _triggerGenerate(btn) {
    const orig = btn.textContent;
    btn.disabled = true;
    btn.textContent = 'Starting…';
    try {
        await apiCall('/mood/generate', { method: 'POST' });
        btn.textContent = 'Started — refresh in a few minutes';
    } catch (e) {
        btn.textContent = '✗';
        btn.title = e.message;
        setTimeout(() => { btn.textContent = orig; btn.disabled = false; }, 3000);
    }
}

async function _playMood(btn) {
    const mood = btn.dataset.mood;
    const orig = btn.innerHTML;
    btn.disabled = true;
    btn.classList.add('mood-card-loading');

    try {
        const zoneId = await _resolveZoneId();
        if (!zoneId) {
            _flash(btn, '✗ No active zone', orig);
            return;
        }

        // Pull a generous pool, then trim to 30 for instant playback.
        const data = await apiCall(`/mood/tracks?mood=${encodeURIComponent(mood)}&limit=120`);
        const tracks = data?.tracks || [];
        if (!tracks.length) {
            _flash(btn, 'No tracks', orig);
            return;
        }
        const trackNumbers = Array.from({ length: Math.min(30, tracks.length) }, (_, i) => i + 1);

        await apiCall('/library/filter/curate', {
            method: 'POST',
            body: JSON.stringify({
                session_id: data.session_id,
                track_numbers: trackNumbers,
                zone_id: zoneId,
                append: false,
            }),
        });
        _flash(btn, `▶ ${mood}`, orig);
    } catch (e) {
        _flash(btn, '✗', orig, e.message);
    } finally {
        btn.disabled = false;
        btn.classList.remove('mood-card-loading');
    }
}

async function _resolveZoneId() {
    let zoneId = getCurrentZoneId();
    if (zoneId) return zoneId;
    try {
        const zones = await apiCall('/roon/zones');
        const list = Array.isArray(zones) ? zones : (zones?.zones || []);
        return list[0]?.zone_id || null;
    } catch {
        return null;
    }
}

function _flash(btn, text, orig, title) {
    btn.innerHTML = `<span class="mood-card-flash">${escapeHtml(text)}</span>`;
    if (title) btn.title = title;
    setTimeout(() => { btn.innerHTML = orig; }, 2200);
}
