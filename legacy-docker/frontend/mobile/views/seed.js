import { searchTracks, analyzeTrack, generatePlaylistStream, createPlayQueue } from '../../modules/api.js';
import { esc, artUrl, toast } from '../util.js';
import { getDefaultZoneId } from '../roon.js';

let _seed = null;
let _dimensions = [];
let _selected = new Set();
let _count = 25;
let _tracks = [];
let _searchTimer = null;
let _busy = false;

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Seed Song</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Kies een track; de AI bouwt een playlist in dezelfde sfeer.</p>
        </section>

        <section class="glass-panel rounded-xl p-md flex flex-col gap-sm" id="seed-slot">
            <span class="font-label-caps text-label-caps text-primary opacity-60">SEED TRACK</span>
            <div id="seed-selected" class="hidden items-center gap-md">
                <div class="flex-1 min-w-0">
                    <p id="seed-sel-title" class="font-title-md text-title-md truncate"></p>
                    <p id="seed-sel-artist" class="font-body-sm text-body-sm text-text-muted truncate"></p>
                </div>
                <button id="seed-clear" class="text-text-muted active:scale-90 transition-transform"><span class="material-symbols-outlined">close</span></button>
            </div>
            <div id="seed-picker" class="flex flex-col gap-sm">
                <div class="flex items-center gap-sm bg-surface-charcoal rounded-full px-md py-xs">
                    <span class="material-symbols-outlined text-text-muted text-[20px]">search</span>
                    <input id="seed-input" class="w-full bg-transparent border-none focus:ring-0 text-text-primary font-body-sm text-body-sm" placeholder="Zoek een track…">
                </div>
                <div id="seed-suggest" class="flex flex-col gap-1"></div>
            </div>
        </section>

        <section id="seed-dims-wrap" class="hidden flex-col gap-sm">
            <h2 class="font-title-md text-title-md text-text-primary">Wat wil je behouden?</h2>
            <p class="font-body-sm text-body-sm text-text-muted">Kies de eigenschappen die de playlist moet volgen.</p>
            <div id="seed-dims" class="flex flex-col gap-xs"></div>
        </section>

        <section class="flex flex-col gap-sm">
            <span class="font-label-caps text-label-caps text-text-muted">Aantal tracks</span>
            <div id="seed-counts" class="grid grid-cols-3 gap-sm">
                ${[15, 25, 50].map((n) => `<button data-n="${n}" class="seed-count py-sm rounded-xl border font-title-md text-title-md active:scale-95 transition-transform ${n === _count ? 'bg-primary/20 border-primary/30 text-primary' : 'bg-surface-glass border-white/5 text-text-primary'}">${n}</button>`).join('')}
            </div>
        </section>

        <button id="seed-go" class="w-full h-14 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform shadow-[0_4px_24px_rgba(211,187,255,0.25)]">
            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">auto_awesome</span>
            Genereer
        </button>

        <div id="seed-status" class="hidden glass-panel rounded-xl p-md items-center gap-md">
            <span class="material-symbols-outlined animate-spin text-primary">progress_activity</span>
            <span id="seed-status-text" class="font-body-sm text-body-sm text-text-primary">Bezig…</span>
        </div>
        <section id="seed-results" class="hidden flex-col gap-sm"></section>
    </div>`;
}

export function mount(root) {
    const input = root.querySelector('#seed-input');
    const suggest = root.querySelector('#seed-suggest');
    const selectedEl = root.querySelector('#seed-selected');
    const pickerEl = root.querySelector('#seed-picker');

    input.addEventListener('input', () => {
        const q = input.value.trim();
        if (_searchTimer) clearTimeout(_searchTimer);
        if (!q) { suggest.innerHTML = ''; return; }
        _searchTimer = setTimeout(async () => {
            let data; try { data = await searchTracks(q); } catch { return; }
            const items = (Array.isArray(data) ? data : data?.results || []).slice(0, 6);
            suggest.innerHTML = items.map((t, i) =>
                `<button class="seed-opt text-left p-sm rounded-lg active:bg-surface-charcoal" data-idx="${i}">
                    <p class="font-body-sm text-body-sm text-text-primary truncate">${esc(t.title || '')}</p>
                    <p class="font-label-caps text-[10px] text-text-muted truncate">${esc(t.artist || '')}</p>
                </button>`).join('');
            suggest.querySelectorAll('.seed-opt').forEach((btn) => btn.addEventListener('click', () => {
                pickSeed(items[Number(btn.dataset.idx)], { selectedEl, pickerEl, suggest, input });
            }));
        }, 300);
    });

    root.querySelector('#seed-clear')?.addEventListener('click', () => {
        _seed = null; _dimensions = []; _selected.clear();
        selectedEl.classList.add('hidden'); selectedEl.classList.remove('flex');
        pickerEl.classList.remove('hidden');
        root.querySelector('#seed-dims-wrap').classList.add('hidden');
    });

    root.querySelectorAll('.seed-count').forEach((b) => b.addEventListener('click', () => {
        _count = Number(b.dataset.n);
        root.querySelectorAll('.seed-count').forEach((x) => {
            const on = Number(x.dataset.n) === _count;
            x.classList.toggle('bg-primary/20', on); x.classList.toggle('border-primary/30', on); x.classList.toggle('text-primary', on);
            x.classList.toggle('bg-surface-glass', !on); x.classList.toggle('border-white/5', !on); x.classList.toggle('text-text-primary', !on);
        });
    }));

    root.querySelector('#seed-go')?.addEventListener('click', run);
}

export function unmount() { if (_searchTimer) clearTimeout(_searchTimer); }

async function pickSeed(t, els) {
    _seed = { item_key: t.item_key, title: t.title, artist: t.artist, album: t.album, year: t.year, genres: t.genres, duration_ms: t.duration_ms };
    document.getElementById('seed-sel-title').textContent = t.title || '';
    document.getElementById('seed-sel-artist').textContent = t.artist || '';
    els.selectedEl.classList.remove('hidden'); els.selectedEl.classList.add('flex');
    els.pickerEl.classList.add('hidden');
    els.suggest.innerHTML = ''; els.input.value = '';

    const dimsWrap = document.getElementById('seed-dims-wrap');
    const dimsEl = document.getElementById('seed-dims');
    dimsWrap.classList.remove('hidden'); dimsWrap.classList.add('flex');
    dimsEl.innerHTML = `<div class="flex justify-center py-md"><span class="material-symbols-outlined animate-spin text-primary">progress_activity</span></div>`;

    let data;
    try { data = await analyzeTrack(_seed); } catch (e) { dimsEl.innerHTML = `<p class="font-body-sm text-body-sm text-error">Analyse mislukt.</p>`; return; }
    _dimensions = data?.dimensions || [];
    _selected = new Set(_dimensions.map((d) => d.id)); // select all by default
    renderDims(dimsEl);
}

function renderDims(el) {
    if (!_dimensions.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen eigenschappen gevonden.</p>`; return; }
    el.innerHTML = _dimensions.map((d) => `
        <button class="seed-dim text-left glass-panel rounded-xl p-md flex items-start gap-md active:scale-[0.99] transition-transform" data-id="${esc(d.id)}">
            <span class="seed-check material-symbols-outlined ${_selected.has(d.id) ? 'text-primary' : 'text-text-muted'}" style="font-variation-settings:'FILL' ${_selected.has(d.id) ? 1 : 0};">${_selected.has(d.id) ? 'check_circle' : 'radio_button_unchecked'}</span>
            <div class="min-w-0">
                <p class="font-body-lg text-body-lg text-text-primary">${esc(d.label || d.id)}</p>
                ${d.description ? `<p class="font-body-sm text-body-sm text-text-muted mt-0.5">${esc(d.description)}</p>` : ''}
            </div>
        </button>`).join('');
    el.querySelectorAll('.seed-dim').forEach((btn) => btn.addEventListener('click', () => {
        const id = btn.dataset.id;
        if (_selected.has(id)) _selected.delete(id); else _selected.add(id);
        const on = _selected.has(id);
        const chk = btn.querySelector('.seed-check');
        chk.textContent = on ? 'check_circle' : 'radio_button_unchecked';
        chk.style.fontVariationSettings = `'FILL' ${on ? 1 : 0}`;
        chk.classList.toggle('text-primary', on);
        chk.classList.toggle('text-text-muted', !on);
    }));
}

function run() {
    if (_busy) return;
    if (!_seed) { toast('Kies eerst een track', 'error'); return; }
    _busy = true;
    const statusEl = document.getElementById('seed-status');
    const statusText = document.getElementById('seed-status-text');
    const resultsEl = document.getElementById('seed-results');
    const goBtn = document.getElementById('seed-go');
    statusEl.classList.remove('hidden'); statusEl.classList.add('flex');
    resultsEl.classList.add('hidden');
    if (goBtn) goBtn.disabled = true;

    const request = {
        genres: [], decades: [], track_count: _count, exclude_live: true,
        source_mode: 'library', use_taste_profile: true,
        seed_track: { item_key: _seed.item_key, selected_dimensions: [..._selected] },
    };

    generatePlaylistStream(request,
        (p) => { if (statusText && p.step) statusText.textContent = p.step; },
        (resp) => {
            _busy = false; if (goBtn) goBtn.disabled = false;
            statusEl.classList.add('hidden'); statusEl.classList.remove('flex');
            _tracks = resp.tracks || [];
            renderResults(resp);
        },
        (err) => {
            _busy = false; if (goBtn) goBtn.disabled = false;
            statusEl.classList.add('hidden'); statusEl.classList.remove('flex');
            toast(err.message || 'Genereren mislukt', 'error');
        });
}

function renderResults(resp) {
    const el = document.getElementById('seed-results');
    if (!el) return;
    const tracks = resp.tracks || [];
    if (!tracks.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen tracks gevonden.</p>`; el.classList.remove('hidden'); el.classList.add('flex'); return; }
    const rows = tracks.map((t, i) => {
        const src = t.art_url || artUrl(t.image_key, 96, 96);
        return `
        <div class="flex items-center gap-md p-sm rounded-lg">
            <span class="font-body-sm text-body-sm text-text-muted w-5 text-center flex-shrink-0">${i + 1}</span>
            <div class="w-10 h-10 rounded overflow-hidden bg-surface-container-high flex items-center justify-center flex-shrink-0">
                ${src ? `<img src="${src}" alt="" loading="lazy" class="w-full h-full object-cover" onerror="this.style.display='none'">` : `<span class="material-symbols-outlined text-text-muted text-[20px]">music_note</span>`}
            </div>
            <div class="flex-1 min-w-0">
                <p class="font-body-lg text-body-lg text-text-primary truncate">${esc(t.title || '')}</p>
                <p class="font-body-sm text-body-sm text-text-muted truncate">${esc(t.artist || '')}</p>
            </div>
        </div>`;
    }).join('');
    el.innerHTML = `
        <div class="flex flex-col gap-base">
            <h2 class="font-title-md text-title-md text-text-primary">${esc(resp.playlist_title || 'Playlist')}</h2>
            ${resp.narrative ? `<p class="font-body-sm text-body-sm text-text-muted">${esc(resp.narrative)}</p>` : ''}
        </div>
        <button id="seed-play" class="w-full h-12 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform">
            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">play_arrow</span> Speel ${tracks.length} tracks
        </button>
        <div class="flex flex-col gap-xs mt-sm">${rows}</div>`;
    el.classList.remove('hidden'); el.classList.add('flex');
    el.querySelector('#seed-play')?.addEventListener('click', (e) => playAll(e.currentTarget));
}

async function playAll(btn) {
    const keys = _tracks.map((t) => t.item_key).filter(Boolean);
    if (!keys.length) return;
    btn.disabled = true;
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        const resp = await createPlayQueue(keys, zoneId, 'replace');
        toast(resp?.success ? `${resp.tracks_queued ?? keys.length} tracks gestart` : 'Gestart');
    } catch (e) { toast(e.message || 'Afspelen mislukt', 'error'); }
    finally { btn.disabled = false; }
}
