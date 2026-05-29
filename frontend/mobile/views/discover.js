import { apiCall } from '../../modules/api.js';
import { esc, artUrl, toast } from '../util.js';
import { playAlbum, playAlbumByName } from '../roon.js';

const DESKTOP = (hash) => `/#${hash}`;

// Discovery tools that aren't ported to mobile yet deep-link into the desktop SPA.
const TOOLS = [
    { icon: 'travel_explore', title: 'Advanced Search', sub: 'Klank & betekenis', href: '#/search' },
    { icon: 'alt_route', title: 'Song Paths', sub: 'Brug tussen tracks', href: '#/songpaths' },
    { icon: 'science', title: 'Song Alchemy', sub: 'Vector-mix', href: '#/alchemy' },
    { icon: 'map', title: 'Music Map', sub: '2D bibliotheek', href: '#/musicmap' },
    { icon: 'fingerprint', title: 'Sonic Fingerprint', sub: 'Je audio-DNA', href: '#/fingerprint' },
    { icon: 'schedule', title: 'Circadian', sub: 'Ritme per uur', href: '#/circadian' },
];

export function render() {
    const tools = TOOLS.map((t) => `
        <a href="${t.href}" class="glass-panel rounded-xl p-md flex flex-col gap-1 active:scale-95 transition-transform">
            <span class="material-symbols-outlined text-primary mb-1" style="font-size:26px;">${t.icon}</span>
            <h3 class="font-title-md text-title-md text-on-background leading-tight">${t.title}</h3>
            <p class="font-label-caps text-label-caps text-text-muted">${t.sub}</p>
        </a>`).join('');

    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Discover</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Verken je bibliotheek en vind verborgen parels.</p>
        </section>

        <section class="grid grid-cols-2 gap-gutter">${tools}</section>

        <section class="flex flex-col gap-sm">
            <h2 class="font-title-md text-title-md text-text-primary">Favorieten in je bibliotheek</h2>
            <div id="disc-favorites" class="flex overflow-x-auto hide-scrollbar gap-gutter pb-2 -mx-margin-mobile px-margin-mobile">${railSkeleton()}</div>
        </section>

        <section class="flex flex-col gap-sm">
            <h2 class="font-title-md text-title-md text-text-primary">Genre explorer</h2>
            <div id="disc-genre" class="flex overflow-x-auto hide-scrollbar gap-gutter pb-2 -mx-margin-mobile px-margin-mobile">${railSkeleton()}</div>
        </section>

        <section class="flex flex-col gap-sm">
            <h2 class="font-title-md text-title-md text-text-primary">Trending op ListenBrainz</h2>
            <div id="disc-lb" class="flex overflow-x-auto hide-scrollbar gap-gutter pb-2 -mx-margin-mobile px-margin-mobile">${railSkeleton()}</div>
        </section>
    </div>`;
}

function railSkeleton() {
    return Array.from({ length: 4 }).map(() => `
        <div class="flex-shrink-0 w-32 flex flex-col gap-2">
            <div class="w-32 h-32 rounded-[16px] bg-surface-container-low animate-pulse"></div>
            <div class="h-3 w-24 rounded bg-surface-container-low animate-pulse"></div>
        </div>`).join('');
}

export async function mount() {
    let data;
    try {
        data = await apiCall('/discovery/sections');
    } catch {
        ['disc-favorites', 'disc-genre', 'disc-lb'].forEach((id) => emptyRail(id, 'Kon discovery niet laden.'));
        return;
    }
    renderRail('disc-favorites', data.favorites_in_library, true);
    renderGenreRail('disc-genre', data.genre_explorer);
    renderRail('disc-lb', data.lb_top_releases, false);
}

function renderGenreRail(id, genres) {
    const el = document.getElementById(id);
    if (!el) return;
    if (!Array.isArray(genres) || !genres.length) { emptyRail(id, 'Geen genres.'); return; }
    el.innerHTML = genres.slice(0, 20).map((g) => `
        <div class="flex-shrink-0 w-36 glass-panel rounded-xl p-md flex flex-col gap-1">
            <span class="material-symbols-outlined text-primary" style="font-size:24px;">graphic_eq</span>
            <h4 class="font-title-md text-body-lg font-semibold text-text-primary truncate">${esc(g.genre || '')}</h4>
            <p class="font-label-caps text-label-caps text-text-muted">${(g.track_count || 0).toLocaleString('nl-NL')} tracks</p>
        </div>`).join('');
}

function emptyRail(id, msg) {
    const el = document.getElementById(id);
    if (el) el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">${esc(msg)}</p>`;
}

function renderRail(id, items, playable) {
    const el = document.getElementById(id);
    if (!el) return;
    if (!Array.isArray(items) || !items.length) {
        emptyRail(id, 'Niets gevonden.');
        return;
    }
    el.innerHTML = items.slice(0, 15).map((it) => {
        const key = it.parent_item_key || it.album_item_key || '';
        const src = artUrl(it.image_key, 200, 200);
        const album = it.album || it.release || it.title || '';
        const artist = it.artist || it.artist_name || '';
        const canPlay = playable && (album && artist || key);
        return `
        <div class="flex-shrink-0 w-32 flex flex-col gap-2">
            <button class="disc-card relative w-32 h-32 rounded-[16px] overflow-hidden bg-surface-container-low flex items-center justify-center active:scale-95 transition-transform" ${canPlay ? `data-key="${esc(key)}" data-album="${esc(album)}" data-artist="${esc(artist)}"` : 'disabled'}>
                ${src
                    ? `<img src="${src}" alt="" loading="lazy" class="w-full h-full object-cover" onerror="this.style.display='none'">`
                    : `<span class="material-symbols-outlined text-text-muted">album</span>`}
                ${canPlay ? `<span class="absolute inset-0 bg-black/30 flex items-center justify-center opacity-0 hover:opacity-100 transition-opacity"><span class="material-symbols-outlined text-white" style="font-variation-settings:'FILL' 1; font-size:36px;">play_circle</span></span>` : ''}
            </button>
            <div>
                <h4 class="font-body-sm text-body-sm font-semibold text-on-background truncate">${esc(album)}</h4>
                <p class="font-label-caps text-label-caps text-text-muted truncate mt-1">${esc(artist)}</p>
            </div>
        </div>`;
    }).join('');

    el.querySelectorAll('.disc-card[data-album]').forEach((btn) => {
        btn.addEventListener('click', () => play(btn));
    });
}

async function play(btn) {
    const { album, artist, key } = btn.dataset;
    btn.classList.add('opacity-60');
    try {
        // Prefer text-based resolution (stable); fall back to the cached browse key.
        if (album && artist) await playAlbumByName(artist, album);
        else if (key) await playAlbum(key);
        else { toast('Niet afspeelbaar', 'error'); return; }
        toast('Album gestart');
    } catch (e) {
        // Last resort: try the (possibly stale) browse key if name lookup failed.
        if (key) {
            try { await playAlbum(key); toast('Album gestart'); return; }
            catch (_) { /* fall through */ }
        }
        toast(e.message || 'Afspelen mislukt', 'error');
    } finally {
        btn.classList.remove('opacity-60');
    }
}
