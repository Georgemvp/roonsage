import { apiCall, createPlayQueue } from '../../modules/api.js';
import { esc, artUrl, toast } from '../util.js';
import { getDefaultZoneId } from '../roon.js';

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Artist Watchlist</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Volg je favoriete artiesten voor nieuwe releases.</p>
        </section>

        <section class="flex flex-col gap-sm">
            <div class="glass-panel rounded-full flex items-center px-md py-xs">
                <span class="material-symbols-outlined text-text-muted mr-sm">search</span>
                <input id="wl-add" type="text" placeholder="Artiest toevoegen…" class="w-full bg-transparent border-none focus:ring-0 text-text-primary font-body-lg text-body-lg placeholder-text-muted/60">
                <button id="wl-add-btn" class="text-primary active:scale-90 transition-transform ml-sm"><span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">add_circle</span></button>
            </div>
            <button id="wl-auto" class="w-full bg-surface-charcoal border border-white/10 rounded-full py-3 px-4 flex items-center justify-center gap-xs active:scale-95 transition-transform">
                <span class="material-symbols-outlined text-primary">psychology</span>
                <span class="font-title-md text-body-sm font-semibold text-primary">Auto-populate uit je smaak</span>
            </button>
        </section>

        <section class="flex flex-col gap-sm">
            <h2 class="font-title-md text-title-md text-text-primary">Nieuwe releases</h2>
            <div id="wl-releases" class="flex flex-col gap-xs"></div>
        </section>

        <section class="flex flex-col gap-sm">
            <div class="flex items-center justify-between">
                <h2 class="font-title-md text-title-md text-text-primary">Gevolgd</h2>
                <button id="wl-scan" class="font-label-caps text-label-caps text-primary flex items-center gap-1"><span class="material-symbols-outlined text-[16px]">sync</span> SCAN</button>
            </div>
            <div id="wl-artists" class="flex flex-col"></div>
        </section>
    </div>`;
}

export async function mount(root) {
    const addInput = root.querySelector('#wl-add');
    const add = () => addArtist(addInput);
    root.querySelector('#wl-add-btn')?.addEventListener('click', add);
    addInput?.addEventListener('keydown', (e) => { if (e.key === 'Enter') add(); });
    root.querySelector('#wl-auto')?.addEventListener('click', (e) => autoPopulate(e.currentTarget));
    root.querySelector('#wl-scan')?.addEventListener('click', (e) => scan(e.currentTarget));
    await Promise.all([loadArtists(), loadReleases()]);
}

async function loadArtists() {
    const el = document.getElementById('wl-artists');
    if (!el) return;
    const artists = await apiCall('/watchlist').catch(() => []);
    if (!artists.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Nog geen artiesten. Voeg er een toe of auto-populate.</p>`; return; }
    el.innerHTML = artists.map((a) => `
        <div class="flex items-center justify-between py-sm border-b border-surface-charcoal">
            <div class="flex items-center gap-md min-w-0">
                <div class="w-10 h-10 rounded-lg bg-surface-variant flex items-center justify-center flex-shrink-0"><span class="material-symbols-outlined text-text-muted text-[20px]">artist</span></div>
                <span class="font-body-lg text-body-lg text-text-primary truncate">${esc(a.artist_name)}</span>
            </div>
            <button class="wl-remove w-8 h-8 flex items-center justify-center rounded-full text-text-muted active:scale-90 transition-transform" data-name="${esc(a.artist_name)}"><span class="material-symbols-outlined">close</span></button>
        </div>`).join('');
    el.querySelectorAll('.wl-remove').forEach((btn) => btn.addEventListener('click', () => removeArtist(btn.dataset.name)));
}

async function loadReleases() {
    const el = document.getElementById('wl-releases');
    if (!el) return;
    const releases = await apiCall('/watchlist/new-releases').catch(() => []);
    if (!releases.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen nieuwe releases.</p>`; return; }
    el.innerHTML = releases.map((r) => {
        const src = artUrl(r.image_key || r.art_key, 96, 96);
        return `
        <div class="flex items-center gap-md p-sm rounded-lg glass-panel" data-id="${esc(r.id)}">
            <div class="w-12 h-12 rounded-md overflow-hidden bg-surface-container-low flex items-center justify-center flex-shrink-0">
                ${src ? `<img src="${src}" alt="" loading="lazy" class="w-full h-full object-cover" onerror="this.style.display='none'">` : `<span class="material-symbols-outlined text-text-muted">album</span>`}
            </div>
            <div class="flex-1 min-w-0">
                <p class="font-body-lg text-body-lg text-text-primary truncate">${esc(r.album_title || '')}</p>
                <p class="font-body-sm text-body-sm text-text-muted truncate">${esc(r.artist_name || '')}${r.release_date ? ' • ' + esc(r.release_date) : ''}</p>
            </div>
            ${r.item_key ? `<button class="wl-play text-primary active:scale-90 transition-transform" data-key="${esc(r.item_key)}"><span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">play_circle</span></button>` : ''}
            <button class="wl-dismiss text-text-muted active:scale-90 transition-transform" data-id="${esc(r.id)}"><span class="material-symbols-outlined">close</span></button>
        </div>`;
    }).join('');
    el.querySelectorAll('.wl-play').forEach((b) => b.addEventListener('click', () => playRelease(b.dataset.key)));
    el.querySelectorAll('.wl-dismiss').forEach((b) => b.addEventListener('click', () => dismiss(b.dataset.id, b)));
}

async function addArtist(input) {
    const name = (input.value || '').trim();
    if (!name) return;
    try {
        await apiCall('/watchlist', { method: 'POST', body: JSON.stringify({ artist_name: name }) });
        input.value = '';
        toast(`${name} toegevoegd`);
        await loadArtists();
    } catch (e) {
        toast(e.message || 'Toevoegen mislukt', 'error');
    }
}

async function removeArtist(name) {
    try {
        await apiCall(`/watchlist/${encodeURIComponent(name)}`, { method: 'DELETE' });
        await loadArtists();
    } catch (e) {
        toast(e.message || 'Verwijderen mislukt', 'error');
    }
}

async function autoPopulate(btn) {
    btn.disabled = true;
    try {
        const res = await apiCall('/watchlist/auto-populate', { method: 'POST' });
        toast(res?.count ? `${res.count} artiesten toegevoegd` : 'Al up-to-date');
        await loadArtists();
    } catch (e) {
        toast(e.message || 'Mislukt', 'error');
    } finally {
        btn.disabled = false;
    }
}

async function scan(btn) {
    btn.disabled = true;
    try {
        await apiCall('/watchlist/scan', { method: 'POST' });
        toast('Scan gestart');
        setTimeout(loadReleases, 1500);
    } catch (e) {
        toast(e.message || 'Scan mislukt', 'error');
    } finally {
        btn.disabled = false;
    }
}

async function dismiss(id, el) {
    try {
        await apiCall(`/watchlist/new-releases/${encodeURIComponent(id)}/dismiss`, { method: 'POST' });
        el.closest('[data-id]')?.remove();
    } catch (e) {
        toast(e.message || 'Mislukt', 'error');
    }
}

async function playRelease(key) {
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        await createPlayQueue([key], zoneId, 'replace');
        toast('Gestart');
    } catch (e) {
        toast(e.message || 'Afspelen mislukt', 'error');
    }
}
