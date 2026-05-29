import { apiCall, searchTracks } from '../../modules/api.js';
import { esc, artUrl, toast } from '../util.js';
import { playAlbum, getDefaultZoneId } from '../roon.js';

let _searchTimer = null;

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Library</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Zoek in je Roon-bibliotheek.</p>
        </section>

        <div class="glass-panel rounded-full flex items-center px-md py-sm">
            <span class="material-symbols-outlined text-primary mr-sm">search</span>
            <input id="lib-search" type="search" inputmode="search" placeholder="Zoek tracks, artiesten, albums…"
                class="w-full bg-transparent border-none focus:ring-0 text-text-primary font-body-lg text-body-lg placeholder-text-muted/60" />
        </div>

        <div id="lib-results" class="flex flex-col gap-xs">
            <p class="font-body-sm text-body-sm text-text-muted">Begin met typen om te zoeken.</p>
        </div>
    </div>`;
}

export async function mount(root) {
    const input = root.querySelector('#lib-search');
    if (!input) return;
    input.addEventListener('input', () => {
        const q = input.value.trim();
        if (_searchTimer) clearTimeout(_searchTimer);
        if (!q) {
            results().innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Begin met typen om te zoeken.</p>`;
            return;
        }
        _searchTimer = setTimeout(() => runSearch(q), 300);
    });
}

export function unmount() {
    if (_searchTimer) clearTimeout(_searchTimer);
}

function results() {
    return document.getElementById('lib-results');
}

async function runSearch(q) {
    const el = results();
    if (!el) return;
    el.innerHTML = `<div class="flex justify-center py-lg"><span class="material-symbols-outlined animate-spin text-primary">progress_activity</span></div>`;
    let data;
    try {
        data = await searchTracks(q);
    } catch (e) {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-error">Zoeken mislukt.</p>`;
        return;
    }
    const items = Array.isArray(data) ? data : data?.results || data?.tracks || [];
    if (!items.length) {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Niets gevonden voor "${esc(q)}".</p>`;
        return;
    }
    el.innerHTML = items.slice(0, 40).map((t, i) => {
        const title = t.title || t.track_title || t.name || '';
        const artist = t.artist || t.artist_name || '';
        const album = t.album || '';
        const src = t.art_url || artUrl(t.image_key, 96, 96);
        const key = t.item_key || t.parent_item_key || '';
        return `
        <div class="flex items-center gap-md p-sm rounded-lg active:bg-surface-charcoal transition-colors" data-key="${esc(key)}" data-idx="${i}">
            <div class="w-12 h-12 rounded-md overflow-hidden bg-surface-container-low flex items-center justify-center flex-shrink-0">
                ${src ? `<img src="${src}" alt="" loading="lazy" class="w-full h-full object-cover" onerror="this.style.display='none'">` : `<span class="material-symbols-outlined text-text-muted">music_note</span>`}
            </div>
            <div class="flex-1 min-w-0">
                <p class="font-body-lg text-body-lg text-text-primary truncate">${esc(title)}</p>
                <p class="font-body-sm text-body-sm text-text-muted truncate">${esc([artist, album].filter(Boolean).join(' • '))}</p>
            </div>
            <button class="lib-play w-9 h-9 rounded-full flex items-center justify-center text-primary active:scale-90 transition-transform" aria-label="Speel">
                <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">play_circle</span>
            </button>
        </div>`;
    }).join('');

    el.querySelectorAll('.lib-play').forEach((btn) => {
        btn.addEventListener('click', (ev) => {
            const row = ev.currentTarget.closest('[data-key]');
            playItem(items[Number(row.dataset.idx)]);
        });
    });
}

async function playItem(t) {
    const key = t.item_key || t.parent_item_key;
    if (!key) { toast('Geen afspeelbare sleutel', 'error'); return; }
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        // Tracks queue directly; album-level keys play the album.
        if (t.item_key) {
            await apiCall('/queue', { method: 'POST', body: JSON.stringify({ zone_id: zoneId, item_keys: [key] }) });
        } else {
            await playAlbum(key, zoneId);
        }
        toast('Toegevoegd aan wachtrij');
    } catch (e) {
        toast(e.message || 'Afspelen mislukt', 'error');
    }
}
