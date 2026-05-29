import { apiCall } from '../../modules/api.js';
import { esc, artUrl, toast } from '../util.js';

// Features that aren't ported to the mobile shell yet deep-link into the
// desktop SPA via its hash routes. Swap these to `#/<route>` as views land.
const DESKTOP = (hash) => `/#${hash}`;

const QUICK_ACTIONS = [
    { icon: 'auto_awesome', label: 'Generate Playlist', href: '#/generate' },
    { icon: 'music_note', label: 'Seed Song', href: '#/seed' },
    { icon: 'album', label: 'Recommend Album', href: '#/recommend' },
    { icon: 'speaker_group', label: 'DJ Set', href: '#/djset' },
    { icon: 'alt_route', label: 'Song Path', href: DESKTOP('song-paths') },
    { icon: 'fingerprint', label: 'Sonic Fingerprint', href: '#/fingerprint' },
];

const FEATURES = [
    { icon: 'radar', tint: 'primary', title: 'My Taste', sub: 'Genre radar & habits', href: '#/taste' },
    { icon: 'smart_toy', tint: 'secondary', title: 'Automations', sub: 'Triggered workflows', href: '#/automations' },
    { icon: 'visibility', tint: 'tertiary', title: 'Artist Watchlist', sub: 'Track new releases', href: '#/watchlist' },
    { icon: 'schedule', tint: 'primary', title: 'Circadian Rhythm', sub: 'Time-based mood', href: '#/circadian' },
    { icon: 'travel_explore', tint: 'tertiary', title: 'Discovery Tools', sub: 'Find hidden gems', href: '#/discover' },
    { icon: 'database', tint: 'secondary', title: 'Enrichment', sub: 'Enhance library data', href: '#/enrichment' },
    { icon: 'speaker', tint: 'primary', title: 'Afspelen', sub: 'Standaard zone', href: '#/playback' },
];

let _pollTimer = null;
let _zone = null; // currently displayed zone

export function render() {
    const quick = QUICK_ACTIONS.map((a) => `
        <a href="${a.href}" class="flex-shrink-0 flex items-center gap-2 bg-surface-charcoal border border-surface-glass rounded-full px-4 py-2 active:scale-95 transition-transform">
            <span class="material-symbols-outlined text-primary text-[18px]">${a.icon}</span>
            <span class="font-body-sm text-body-sm text-on-background whitespace-nowrap">${a.label}</span>
        </a>`).join('');

    const features = FEATURES.map((f) => `
        <a href="${f.href}" class="bg-surface-charcoal border border-surface-glass rounded-xl p-md flex flex-col gap-2 relative overflow-hidden active:scale-95 transition-transform">
            <div class="absolute top-0 right-0 w-24 h-24 bg-${f.tint}/10 rounded-full blur-2xl -mr-8 -mt-8 pointer-events-none"></div>
            <span class="material-symbols-outlined text-${f.tint} mb-1" style="font-size:28px;">${f.icon}</span>
            <h3 class="font-title-md text-title-md text-on-background leading-tight">${f.title}</h3>
            <p class="font-label-caps text-label-caps text-text-muted mt-auto">${f.sub}</p>
        </a>`).join('');

    return `
    <div class="flex flex-col gap-lg px-margin-mobile pt-md">
        <!-- Now Playing -->
        <section class="flex flex-col gap-sm">
            <h2 class="font-title-md text-title-md text-text-primary">Nu aan het spelen</h2>
            <div id="rs-np" data-href="#/nowplaying" class="relative bg-surface-charcoal rounded-xl overflow-hidden border border-white/5 shadow-lg p-md cursor-pointer">
                <div class="absolute inset-0 bg-gradient-to-br from-primary/10 to-transparent pointer-events-none"></div>
                <div class="flex items-center gap-md relative z-10">
                    <div class="w-20 h-20 rounded-lg overflow-hidden flex-shrink-0 bg-surface-container-low flex items-center justify-center">
                        <span class="material-symbols-outlined text-text-muted">music_note</span>
                    </div>
                    <div class="flex-1 min-w-0">
                        <h3 class="font-title-md text-title-md text-on-background line-clamp-1">Niets aan het spelen</h3>
                        <p class="font-body-sm text-body-sm text-text-muted line-clamp-1">—</p>
                    </div>
                </div>
            </div>
        </section>

        <!-- Quick Actions -->
        <section class="flex overflow-x-auto hide-scrollbar gap-sm pb-2 -mx-margin-mobile px-margin-mobile">
            ${quick}
        </section>

        <!-- Recently Played -->
        <section class="flex flex-col gap-sm">
            <div class="flex justify-between items-end">
                <h2 class="font-title-md text-title-md text-text-primary">Recent gespeeld</h2>
                <a class="font-label-caps text-label-caps text-primary" href="${DESKTOP('taste')}">Meer</a>
            </div>
            <div id="rs-recent" class="flex overflow-x-auto hide-scrollbar gap-gutter pb-4 -mx-margin-mobile px-margin-mobile">
                ${recentSkeleton()}
            </div>
        </section>

        <!-- All Features -->
        <section class="flex flex-col gap-sm">
            <h2 class="font-title-md text-title-md text-text-primary">All Features</h2>
            <div class="grid grid-cols-2 gap-gutter">${features}</div>
        </section>
    </div>`;
}

function recentSkeleton() {
    return Array.from({ length: 4 }).map(() => `
        <div class="flex-shrink-0 w-32 flex flex-col gap-2">
            <div class="w-32 h-32 rounded-[16px] bg-surface-container-low animate-pulse"></div>
            <div class="h-3 w-24 rounded bg-surface-container-low animate-pulse"></div>
        </div>`).join('');
}

export async function mount() {
    const card = document.getElementById('rs-np');
    if (card) {
        card.addEventListener('click', (e) => {
            if (e.target.closest('#rs-np-toggle')) return; // play/pause handled separately
            location.hash = card.dataset.href || '#/nowplaying';
        });
    }
    await loadNowPlaying();
    loadRecent();
    _pollTimer = setInterval(loadNowPlaying, 5000);
}

export function unmount() {
    if (_pollTimer) clearInterval(_pollTimer);
    _pollTimer = null;
}

async function loadNowPlaying() {
    const el = document.getElementById('rs-np');
    if (!el) return;
    let zones;
    try {
        zones = await apiCall('/roon/zones');
    } catch {
        return; // keep last render on transient errors
    }
    const list = (Array.isArray(zones) ? zones : zones?.zones || []).filter((z) => z.now_playing);
    if (!list.length) {
        _zone = null;
        return;
    }
    // Prefer a playing zone, else the first with audio.
    const zone = list.find((z) => z.state === 'playing') || list[0];
    _zone = zone;
    const np = zone.now_playing;
    const title = np.one_line?.line1 || np.two_line?.line1 || 'Onbekend';
    const artist = np.one_line?.line2 || np.two_line?.line2 || '';
    const isPlaying = zone.state === 'playing';
    const src = artUrl(np.image_key, 160, 160);

    el.innerHTML = `
        <div class="absolute inset-0 bg-gradient-to-br from-primary/10 to-transparent pointer-events-none"></div>
        <div class="flex items-center gap-md relative z-10">
            <div class="w-20 h-20 rounded-lg overflow-hidden flex-shrink-0 bg-surface-container-low flex items-center justify-center">
                ${src
                    ? `<img src="${src}" alt="" class="w-full h-full object-cover" onerror="this.replaceWith(Object.assign(document.createElement('span'),{className:'material-symbols-outlined text-text-muted',textContent:'music_note'}))">`
                    : `<span class="material-symbols-outlined text-text-muted">music_note</span>`}
            </div>
            <div class="flex-1 min-w-0">
                <h3 class="font-title-md text-title-md text-on-background line-clamp-1">${esc(title)}</h3>
                <p class="font-body-sm text-body-sm text-text-muted line-clamp-1">${esc(artist || zone.display_name || '')}</p>
            </div>
            <button id="rs-np-toggle" class="w-12 h-12 rounded-full bg-primary text-on-primary flex items-center justify-center flex-shrink-0 shadow-[0_0_16px_rgba(211,187,255,0.4)] active:scale-95 transition-transform" aria-label="${isPlaying ? 'Pauzeer' : 'Speel'}">
                <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1; font-size:28px;">${isPlaying ? 'pause' : 'play_arrow'}</span>
            </button>
        </div>`;

    const toggle = document.getElementById('rs-np-toggle');
    if (toggle) toggle.addEventListener('click', () => transport(isPlaying ? 'pause' : 'play'));
}

async function transport(action) {
    if (!_zone) return;
    try {
        await apiCall('/roon/transport', {
            method: 'POST',
            body: JSON.stringify({ zone_id: _zone.zone_id, action }),
        });
        setTimeout(loadNowPlaying, 400);
    } catch (e) {
        toast('Bediening mislukt', 'error');
        console.error('transport error', e);
    }
}

async function loadRecent() {
    const el = document.getElementById('rs-recent');
    if (!el) return;
    let data;
    try {
        data = await apiCall('/listening/history?days=14&limit=12');
    } catch {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen recente activiteit.</p>`;
        return;
    }
    const events = Array.isArray(data) ? data : data?.events || [];
    if (!events.length) {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen recente activiteit.</p>`;
        return;
    }
    // De-dupe consecutive same-track entries for a cleaner rail.
    const seen = new Set();
    const items = [];
    for (const ev of events) {
        const key = `${ev.track_title || ev.title}|${ev.artist}`;
        if (seen.has(key)) continue;
        seen.add(key);
        items.push(ev);
        if (items.length >= 10) break;
    }
    el.innerHTML = items.map((ev) => {
        const src = artUrl(ev.image_key || ev.art_key, 160, 160);
        const title = ev.track_title || ev.title || ev.track || '';
        return `
        <div class="flex-shrink-0 w-32 flex flex-col gap-2">
            <div class="w-32 h-32 rounded-[16px] overflow-hidden bg-surface-container-low flex items-center justify-center">
                ${src
                    ? `<img src="${src}" alt="" loading="lazy" class="w-full h-full object-cover" onerror="this.style.display='none'">`
                    : `<span class="material-symbols-outlined text-text-muted">album</span>`}
            </div>
            <div>
                <h4 class="font-body-sm text-body-sm font-semibold text-on-background truncate">${esc(title)}</h4>
                <p class="font-label-caps text-label-caps text-text-muted truncate mt-1">${esc(ev.artist || '')}</p>
            </div>
        </div>`;
    }).join('');
}
