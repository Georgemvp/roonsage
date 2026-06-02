import { apiCall, createPlayQueue } from '../../modules/api.js';
import { esc, artUrl, toast, dedupeTracks } from '../util.js';
import { getDefaultZoneId } from '../roon.js';

// Fetch more than needed, drop near-duplicate versions, then trim to `count`.
async function fetchCircadianTracks(hour, count) {
    const data = await apiCall(`/circadian/playlist?hour=${hour}&limit=${Math.min(150, count * 3)}`);
    const unique = dedupeTracks(data?.results || []);
    return unique.slice(0, count);
}

const BLOCK_META = {
    morning:   { label: 'Ochtend',  icon: 'wb_sunny',   hours: '06–12' },
    afternoon: { label: 'Middag',   icon: 'wb_cloudy',  hours: '12–18' },
    evening:   { label: 'Avond',    icon: 'nights_stay', hours: '18–24' },
};

let _profile = null;
let _count = 25;
let _todayPlaylists = [];

export function render() {
    const hour = new Date().getHours();
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Circadian</h1>
            <p class="font-body-sm text-body-sm text-text-muted">AI-gemaakte playlists voor ochtend, middag en avond — plus muziek afgestemd op dit uur.</p>
        </section>

        <!-- Today's AI playlists -->
        <section class="flex flex-col gap-sm">
            <h2 class="font-label-caps text-label-caps text-text-muted">VANDAAG</h2>
            <div id="circ-today" class="flex flex-col gap-sm">
                <p class="font-body-sm text-body-sm text-text-muted px-xs">Playlists laden…</p>
            </div>
        </section>

        <!-- Audio-feature hourly profile -->
        <section id="circ-vibe" class="glass-panel rounded-xl p-md flex items-center justify-between">
            <div class="space-y-base">
                <p class="font-label-caps text-label-caps text-text-muted">HUIDIG UUR • ${String(hour).padStart(2, '0')}:00</p>
                <h2 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">—</h2>
                <p class="font-body-sm text-body-sm text-tertiary">&nbsp;</p>
            </div>
            <div class="w-12 h-12 flex items-center justify-center rounded-full bg-primary-container/20 text-primary viola-glow">
                <span class="material-symbols-outlined text-[28px]" style="font-variation-settings:'FILL' 1;">schedule</span>
            </div>
        </section>

        <section class="glass-panel rounded-xl p-md flex flex-col gap-md">
            <h3 class="font-title-md text-title-md text-text-primary">Genereer voor nu</h3>
            <div id="circ-count" class="grid grid-cols-3 gap-sm">
                ${[15, 25, 50].map((n) => `
                    <button data-n="${n}" class="circ-count-btn py-sm rounded-xl border font-title-md text-title-md active:scale-95 transition-transform ${n === _count ? 'bg-primary/20 border-primary/30 text-primary' : 'bg-surface-glass border-white/5 text-text-primary'}">${n}</button>`).join('')}
            </div>
            <button id="circ-play" class="w-full py-md rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-xs active:scale-95 transition-transform">
                <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">play_arrow</span>
                Speel dit uur
            </button>
        </section>

        <section class="flex flex-col gap-sm">
            <h2 class="font-title-md text-title-md text-text-primary">Preview dit uur</h2>
            <div id="circ-preview" class="flex flex-col gap-xs"><p class="font-body-sm text-body-sm text-text-muted">Tracks voor dit uur verschijnen hier.</p></div>
        </section>
    </div>`;
}

export async function mount(root) {
    root.querySelectorAll('.circ-count-btn').forEach((btn) => {
        btn.addEventListener('click', () => {
            _count = Number(btn.dataset.n);
            root.querySelectorAll('.circ-count-btn').forEach((b) => {
                const on = Number(b.dataset.n) === _count;
                b.classList.toggle('bg-primary/20', on);
                b.classList.toggle('border-primary/30', on);
                b.classList.toggle('text-primary', on);
                b.classList.toggle('bg-surface-glass', !on);
                b.classList.toggle('border-white/5', !on);
                b.classList.toggle('text-text-primary', !on);
            });
        });
    });
    const playBtn = root.querySelector('#circ-play');
    if (playBtn) playBtn.addEventListener('click', () => play(playBtn));

    loadTodayPlaylists();
    loadPreview();
    apiCall('/circadian/profile').catch(() => null).then((p) => { _profile = p; renderVibe(); });
}

async function loadTodayPlaylists() {
    const el = document.getElementById('circ-today');
    if (!el) return;
    const data = await apiCall('/circadian-auto/today').catch(() => null);
    const playlists = data?.playlists || [];
    _todayPlaylists = playlists;

    if (!playlists.length) {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted px-xs">Nog geen playlists voor vandaag gegenereerd.</p>`;
        return;
    }

    const hour = new Date().getHours();
    const activeBlock = hour < 12 ? 'morning' : hour < 18 ? 'afternoon' : 'evening';

    el.innerHTML = playlists.map((p) => {
        const meta = BLOCK_META[p.time_block] || { label: p.time_block, icon: 'music_note', hours: '' };
        const isActive = p.time_block === activeBlock;
        const trackCount = p.track_count ?? 0;
        const art = p.art_item_key ? `<img src="/api/art/${p.art_item_key}?width=96&height=96" alt="" class="w-full h-full object-cover" onerror="this.style.display='none'">` : '';

        return `
        <div class="glass-panel rounded-xl overflow-hidden${isActive ? ' ring-1 ring-primary/40' : ''}">
            <div class="flex items-center gap-md p-md">
                <div class="circ-block-header flex-1 flex items-center gap-md min-w-0 cursor-pointer active:opacity-70 transition-opacity" data-result-id="${esc(p.result_id || '')}">
                    <div class="w-14 h-14 rounded-lg bg-surface-container-high overflow-hidden flex-shrink-0 flex items-center justify-center">
                        ${art || `<span class="material-symbols-outlined text-text-muted text-[28px]" style="font-variation-settings:'FILL' 1;">${meta.icon}</span>`}
                    </div>
                    <div class="flex-1 min-w-0">
                        <div class="flex items-center gap-xs mb-xs">
                            <p class="font-label-caps text-[10px] ${isActive ? 'text-primary' : 'text-text-muted'}">${meta.label.toUpperCase()} • ${meta.hours}</p>
                            ${isActive ? '<span class="w-1.5 h-1.5 rounded-full bg-primary animate-pulse"></span>' : ''}
                        </div>
                        <p class="font-title-md text-text-primary truncate">${esc(p.playlist_title || meta.label)}</p>
                        <p class="font-body-sm text-body-sm text-text-muted">${trackCount} tracks</p>
                    </div>
                    <span class="circ-chevron material-symbols-outlined text-text-muted text-[20px] transition-transform flex-shrink-0">expand_more</span>
                </div>
                <button class="circ-block-play w-10 h-10 flex items-center justify-center rounded-full viola-gradient text-on-primary active:scale-95 transition-transform flex-shrink-0" data-result-id="${esc(p.result_id || '')}" data-label="${esc(meta.label)}">
                    <span class="material-symbols-outlined text-[20px]" style="font-variation-settings:'FILL' 1;">play_arrow</span>
                </button>
            </div>
            <div class="circ-tracklist hidden border-t border-white/5" data-result-id="${esc(p.result_id || '')}">
                <div class="circ-tracks-inner px-md py-sm flex flex-col">
                    <p class="font-body-sm text-body-sm text-text-muted py-sm">Laden…</p>
                </div>
            </div>
        </div>`;
    }).join('');

    el.querySelectorAll('.circ-block-play').forEach((btn) => {
        btn.addEventListener('click', () => playBlock(btn));
    });
    el.querySelectorAll('.circ-block-header').forEach((header) => {
        header.addEventListener('click', () => toggleTracklist(header));
    });
}

async function playBlock(btn) {
    const resultId = btn.dataset.resultId;
    const label = btn.dataset.label || 'playlist';
    if (!resultId) { toast('Geen playlist beschikbaar', 'error'); return; }
    btn.disabled = true;
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        const result = await apiCall(`/results/${resultId}`).catch(() => null);
        const tracks = (result?.snapshot?.tracks || []);
        const keys = tracks.map((t) => t.item_key).filter(Boolean);
        if (!keys.length) { toast('Geen tracks in playlist', 'error'); return; }
        await createPlayQueue(keys, zoneId, 'replace');
        toast(`${label} gestart — ${keys.length} tracks`);
    } catch (e) {
        toast(e.message || 'Afspelen mislukt', 'error');
    } finally {
        btn.disabled = false;
    }
}

async function toggleTracklist(header) {
    const resultId = header.dataset.resultId;
    if (!resultId) return;
    const panel = header.closest('.glass-panel');
    const tracklist = panel?.querySelector('.circ-tracklist');
    const chevron = header.querySelector('.circ-chevron');
    if (!tracklist) return;

    const isOpen = !tracklist.classList.contains('hidden');
    tracklist.classList.toggle('hidden', isOpen);
    if (chevron) chevron.style.transform = isOpen ? '' : 'rotate(180deg)';
    if (isOpen) return;

    const inner = tracklist.querySelector('.circ-tracks-inner');
    if (!inner || inner.dataset.loaded) return;
    inner.dataset.loaded = '1';

    const result = await apiCall(`/results/${resultId}`).catch(() => null);
    const tracks = result?.snapshot?.tracks || [];
    if (!tracks.length) {
        inner.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted py-sm">Geen tracks gevonden.</p>`;
        return;
    }
    inner.innerHTML = tracks.map((t, i) => {
        const src = t.art_url || (t.item_key ? `/api/art/${t.item_key}?width=64&height=64` : '');
        return `
        <div class="flex items-center gap-md py-sm border-b border-white/5 last:border-0">
            <span class="font-label-caps text-[10px] text-text-muted w-5 text-right flex-shrink-0">${i + 1}</span>
            <div class="w-8 h-8 rounded bg-surface-container-high overflow-hidden flex-shrink-0 flex items-center justify-center">
                ${src ? `<img src="${src}" alt="" loading="lazy" class="w-full h-full object-cover" onerror="this.style.display='none'">` : '<span class="material-symbols-outlined text-text-muted text-[16px]">music_note</span>'}
            </div>
            <div class="flex-1 min-w-0">
                <p class="font-body-sm text-text-primary truncate">${esc(t.title || '')}</p>
                <p class="font-label-caps text-[10px] text-text-muted truncate">${esc(t.artist || '')}</p>
            </div>
        </div>`;
    }).join('');
}

// Describe the current hour from its dominant audio features.
function renderVibe() {
    const el = document.getElementById('circ-vibe');
    if (!el || !_profile?.hours) return;
    const hour = new Date().getHours();
    const f = _profile.hours[String(hour)] || _profile.hours[hour];
    if (!f) return;

    const energy = f.energy ?? 0;
    const valence = f.valence ?? 0;
    let label, icon;
    if (energy >= 0.7) { label = 'Peak Energy'; icon = 'bolt'; }
    else if (energy <= 0.4) { label = 'Calm & Mellow'; icon = 'nightlight'; }
    else if (valence >= 0.55) { label = 'Bright & Upbeat'; icon = 'wb_sunny'; }
    else { label = 'Focused Flow'; icon = 'water_drop'; }

    const parts = [];
    parts.push(`${Math.round(energy * 100)}% energie`);
    if (valence >= 0.55) parts.push('hoge valentie');
    else if (valence <= 0.35) parts.push('lage valentie');
    if (f.acousticness >= 0.6) parts.push('akoestisch');

    const hourStr = String(hour).padStart(2, '0');
    el.innerHTML = `
        <div class="space-y-base">
            <p class="font-label-caps text-label-caps text-text-muted">HUIDIG UUR • ${hourStr}:00</p>
            <h2 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">${esc(label)}</h2>
            <p class="font-body-sm text-body-sm text-tertiary">${esc(parts.join(' • '))}</p>
        </div>
        <div class="w-12 h-12 flex items-center justify-center rounded-full bg-primary-container/20 text-primary viola-glow">
            <span class="material-symbols-outlined text-[28px]" style="font-variation-settings:'FILL' 1;">${icon}</span>
        </div>`;
}

async function loadPreview() {
    const el = document.getElementById('circ-preview');
    if (!el) return;
    const hour = new Date().getHours();
    let results;
    try {
        results = await fetchCircadianTracks(hour, 10);
    } catch {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen preview beschikbaar (audio-analyse nodig).</p>`;
        return;
    }
    if (!results.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen tracks voor dit uur.</p>`; return; }
    el.innerHTML = results.map((t) => {
        const src = t.art_url || artUrl(t.image_key, 96, 96);
        return `
        <div class="flex items-center gap-md p-sm rounded-lg">
            <div class="w-10 h-10 rounded bg-surface-container-high overflow-hidden flex items-center justify-center flex-shrink-0">
                ${src ? `<img src="${src}" alt="" loading="lazy" class="w-full h-full object-cover" onerror="this.style.display='none'">` : `<span class="material-symbols-outlined text-text-muted text-[20px]">music_note</span>`}
            </div>
            <div class="flex-1 min-w-0">
                <p class="font-body-lg text-body-lg text-text-primary truncate">${esc(t.title || '')}</p>
                <p class="font-body-sm text-body-sm text-text-muted truncate">${esc(t.artist || '')}</p>
            </div>
        </div>`;
    }).join('');
}

async function play(btn) {
    btn.disabled = true;
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        const tracks = await fetchCircadianTracks(new Date().getHours(), _count);
        const keys = tracks.map((t) => t.item_key).filter(Boolean);
        if (!keys.length) { toast('Geen tracks voor dit uur', 'error'); return; }
        const resp = await createPlayQueue(keys, zoneId, 'replace');
        toast(resp?.success ? `${resp.tracks_queued ?? keys.length} tracks gestart` : `${keys.length} tracks gestart`);
    } catch (e) {
        toast(e.message || 'Afspelen mislukt', 'error');
    } finally {
        btn.disabled = false;
    }
}

