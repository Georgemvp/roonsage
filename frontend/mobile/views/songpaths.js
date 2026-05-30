import { apiCall, searchTracks, createPlayQueue } from '../../modules/api.js';
import { esc, toast } from '../util.js';
import { getDefaultZoneId } from '../roon.js';

const MOODS = ['calm', 'energetic', 'happy', 'melancholic', 'aggressive', 'dreamy', 'groovy', 'dark'];

const METHOD_INFO = {
    greedy: {
        label: 'DIRECT',
        desc: 'Kiest stap voor stap de best passende volgende track op tempo, energie en toonaard. Snel en voorspelbaar — goed als je een korte, stijlvaste brug wil.',
    },
    graph: {
        label: 'SLIM PAD',
        desc: 'Berekent het soepelste traject door je hele bibliotheek in één keer. Beter bij grotere stijlverschillen en geeft meer muzikale variatie.',
    },
    hybrid: {
        label: 'RIJKSTE MATCH',
        desc: 'Vergelijkt hoe muziek écht klinkt — klankkleur, sfeer en textuur samen. Levert de rijkste brug, maar duurt iets langer.',
    },
};

let _from = null;
let _to = null;
let _steps = 10;
let _method = 'greedy';
let _mood = null;
let _path = [];
let _searchTimers = {};

export function render() {
    const moods = MOODS.map((m) =>
        `<button data-mood="${m}" class="sp-mood shrink-0 px-md py-xs rounded-full glass-panel font-label-caps text-label-caps text-text-muted active:scale-95 transition-transform capitalize">${m}</button>`
    ).join('');

    const methodBtns = Object.entries(METHOD_INFO).map(([key, info]) =>
        `<button data-method="${key}" class="sp-method flex-1 px-md py-sm rounded-full glass-panel font-label-caps text-label-caps active:scale-95 transition-transform">${info.label}</button>`
    ).join('');

    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Song Paths</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Bouw de soepelste sonische brug tussen twee tracks.</p>
        </section>

        ${slot('from', 'START TRACK')}
        <div class="flex justify-center text-primary"><span class="material-symbols-outlined">more_vert</span></div>
        ${slot('to', 'EIND TRACK')}

        <section class="flex flex-col gap-sm">
            <div class="flex justify-between items-center">
                <label class="font-title-md text-title-md">Stappen</label>
                <span id="sp-steps-val" class="font-body-lg text-body-lg text-primary font-bold">${_steps} tracks</span>
            </div>
            <input id="sp-steps" type="range" min="5" max="25" step="5" value="${_steps}" class="w-full">
        </section>

        <section class="flex flex-col gap-sm">
            <span class="font-title-md text-title-md">Methode</span>
            <div class="flex gap-sm">${methodBtns}</div>
            <p id="sp-method-desc" class="font-body-sm text-body-sm text-text-muted">${METHOD_INFO[_method].desc}</p>
        </section>

        <section class="flex flex-col gap-sm">
            <span class="font-title-md text-title-md">Stemming (optioneel)</span>
            <div id="sp-moods" class="flex gap-sm overflow-x-auto hide-scrollbar -mx-margin-mobile px-margin-mobile pb-1">${moods}</div>
        </section>

        <button id="sp-find" class="w-full h-14 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform shadow-[0_4px_24px_rgba(211,187,255,0.25)]">
            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">route</span>
            Vind pad
        </button>

        <section id="sp-result" class="flex flex-col gap-sm"></section>
    </div>`;
}

function slot(which, label) {
    return `
    <section class="glass-panel rounded-xl p-md flex flex-col gap-sm" data-slot="${which}">
        <span class="font-label-caps text-label-caps text-primary opacity-60">${label}</span>
        <div class="sp-selected hidden items-center gap-md">
            <div class="flex-1 min-w-0">
                <p class="sp-sel-title font-title-md text-title-md truncate"></p>
                <p class="sp-sel-artist font-body-sm text-body-sm text-text-muted truncate"></p>
            </div>
            <button class="sp-clear text-text-muted active:scale-90 transition-transform"><span class="material-symbols-outlined">close</span></button>
        </div>
        <div class="sp-picker flex flex-col gap-sm">
            <div class="flex items-center gap-sm bg-surface-charcoal rounded-full px-md py-xs">
                <span class="material-symbols-outlined text-text-muted text-[20px]">search</span>
                <input class="sp-input w-full bg-transparent border-none focus:ring-0 text-text-primary font-body-sm text-body-sm" placeholder="Zoek een track…">
            </div>
            <div class="sp-suggest flex flex-col gap-1"></div>
        </div>
    </section>`;
}

export function mount(root) {
    root.querySelectorAll('[data-slot]').forEach((slotEl) => wireSlot(slotEl));

    const stepsEl = root.querySelector('#sp-steps');
    stepsEl?.addEventListener('input', () => {
        _steps = Number(stepsEl.value);
        root.querySelector('#sp-steps-val').textContent = `${_steps} tracks`;
    });

    const methodDesc = root.querySelector('#sp-method-desc');
    root.querySelectorAll('.sp-method').forEach((b) => b.addEventListener('click', () => {
        _method = b.dataset.method;
        root.querySelectorAll('.sp-method').forEach((x) => {
            const on = x.dataset.method === _method;
            x.classList.toggle('viola-gradient', on);
            x.classList.toggle('text-on-primary', on);
        });
        if (methodDesc) methodDesc.textContent = METHOD_INFO[_method]?.desc ?? '';
    }));
    root.querySelector(`.sp-method[data-method="${_method}"]`)?.classList.add('viola-gradient', 'text-on-primary');

    root.querySelectorAll('.sp-mood').forEach((b) => b.addEventListener('click', () => {
        _mood = (_mood === b.dataset.mood) ? null : b.dataset.mood;
        root.querySelectorAll('.sp-mood').forEach((x) => {
            const on = x.dataset.mood === _mood;
            x.classList.toggle('viola-gradient', on);
            x.classList.toggle('text-on-primary', on);
            x.classList.toggle('text-text-muted', !on);
        });
    }));

    root.querySelector('#sp-find')?.addEventListener('click', findPath);
}

export function unmount() {
    Object.values(_searchTimers).forEach((t) => clearTimeout(t));
}

function wireSlot(slotEl) {
    const which = slotEl.dataset.slot;
    const input = slotEl.querySelector('.sp-input');
    const suggest = slotEl.querySelector('.sp-suggest');
    const selectedEl = slotEl.querySelector('.sp-selected');
    const pickerEl = slotEl.querySelector('.sp-picker');

    input.addEventListener('input', () => {
        const q = input.value.trim();
        if (_searchTimers[which]) clearTimeout(_searchTimers[which]);
        if (!q) { suggest.innerHTML = ''; return; }
        _searchTimers[which] = setTimeout(async () => {
            let data;
            try { data = await searchTracks(q); } catch { return; }
            const items = (Array.isArray(data) ? data : data?.results || []).slice(0, 6);
            suggest.innerHTML = items.map((t, i) =>
                `<button class="sp-opt text-left p-sm rounded-lg active:bg-surface-charcoal" data-idx="${i}">
                    <p class="font-body-sm text-body-sm text-text-primary truncate">${esc(t.title || '')}</p>
                    <p class="font-label-caps text-[10px] text-text-muted truncate">${esc(t.artist || '')}</p>
                </button>`
            ).join('');
            suggest.querySelectorAll('.sp-opt').forEach((btn) => btn.addEventListener('click', () => {
                const t = items[Number(btn.dataset.idx)];
                const sel = { item_key: t.item_key, title: t.title, artist: t.artist };
                if (which === 'from') _from = sel; else _to = sel;
                selectedEl.querySelector('.sp-sel-title').textContent = sel.title || '';
                selectedEl.querySelector('.sp-sel-artist').textContent = sel.artist || '';
                selectedEl.classList.remove('hidden'); selectedEl.classList.add('flex');
                pickerEl.classList.add('hidden');
                suggest.innerHTML = ''; input.value = '';
            }));
        }, 300);
    });

    slotEl.querySelector('.sp-clear')?.addEventListener('click', () => {
        if (which === 'from') _from = null; else _to = null;
        selectedEl.classList.add('hidden'); selectedEl.classList.remove('flex');
        pickerEl.classList.remove('hidden');
    });
}

async function findPath() {
    if (!_from || !_to) { toast('Kies beide tracks', 'error'); return; }
    const btn = document.getElementById('sp-find');
    const el = document.getElementById('sp-result');
    btn.disabled = true;
    el.innerHTML = `<div class="flex justify-center py-lg"><span class="material-symbols-outlined animate-spin text-primary">progress_activity</span></div>`;
    try {
        const body = { from_track_id: _from.item_key, to_track_id: _to.item_key, max_steps: _steps, method: _method };
        if (_mood) body.mood = _mood;
        const result = await apiCall('/song-path', { method: 'POST', body: JSON.stringify(body) });
        _path = result.path || [];
        renderPath(el, result);
    } catch (e) {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-error">${esc(e.message || 'Pad zoeken mislukt')}</p>`;
    } finally {
        btn.disabled = false;
    }
}

function transitionDot(dist) {
    if (dist == null) return '';
    let color;
    if (dist < 0.15) color = '#4caf50';
    else if (dist < 0.35) color = '#ffba3e';
    else color = '#ef5350';
    return `<span class="w-2 h-2 rounded-full flex-shrink-0" style="background:${color}" title="Overgang: ${dist.toFixed(2)}"></span>`;
}

function renderPath(el, result) {
    if (!_path.length) {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen pad gevonden tussen deze tracks.</p>`;
        return;
    }

    const got = _path.length;
    const req = result.requested_steps || _steps;
    const shortWarning = got < req
        ? `<div class="glass-panel rounded-xl p-sm flex items-start gap-sm">
            <span class="material-symbols-outlined text-secondary text-[18px] flex-shrink-0 mt-px">warning</span>
            <p class="font-body-sm text-body-sm text-text-muted">${got} van de ${req} gevraagde tracks gevonden. Analyseer meer tracks via <strong>Enrichment → Audio Features</strong> voor langere paden.</p>
           </div>`
        : '';

    const rows = _path.map((t, i) => {
        const isEndpoint = i === 0 || i === _path.length - 1;
        const dot = !isEndpoint && i < _path.length - 1 ? transitionDot(t.transition_dist) : '';
        return `
        <div class="flex items-center gap-md p-sm rounded-lg ${isEndpoint ? 'bg-primary/5' : ''}">
            <span class="font-body-sm text-body-sm text-text-muted w-5 text-center flex-shrink-0 font-mono">${i + 1}</span>
            <div class="flex-1 min-w-0">
                <p class="font-body-lg text-body-lg text-text-primary truncate font-semibold">${esc(t.title || '')}</p>
                <p class="font-body-sm text-body-sm text-text-muted truncate">${esc(t.artist || '')}${t.album ? ' · ' + esc(t.album) : ''}</p>
            </div>
            <div class="flex items-center gap-sm flex-shrink-0">
                ${t.camelot ? `<span class="font-label-caps text-[9px] px-1.5 py-0.5 rounded bg-primary/15 text-primary">${esc(t.camelot)}</span>` : ''}
                ${t.bpm != null ? `<span class="font-label-caps text-label-caps text-text-muted">${Math.round(t.bpm)}</span>` : ''}
                ${dot}
            </div>
        </div>`;
    }).join('');

    el.innerHTML = `
        <div class="flex justify-between items-end">
            <h2 class="font-title-md text-title-md text-text-primary">${got} tracks</h2>
            <span class="font-body-sm text-body-sm text-text-muted">${esc(result.method || '')}</span>
        </div>
        ${shortWarning}
        <button id="sp-play" class="w-full h-12 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform">
            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">play_arrow</span>
            Speel pad
        </button>
        <div class="flex flex-col gap-xs mt-sm">${rows}</div>`;
    el.querySelector('#sp-play')?.addEventListener('click', (e) => playPath(e.currentTarget));
}

async function playPath(btn) {
    const keys = _path.map((t) => t.item_key).filter(Boolean);
    if (!keys.length) return;
    btn.disabled = true;
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        const resp = await createPlayQueue(keys, zoneId, 'replace');
        toast(resp?.success ? `${resp.tracks_queued ?? keys.length} tracks gestart` : 'Pad gestart');
    } catch (e) {
        toast(e.message || 'Afspelen mislukt', 'error');
    } finally {
        btn.disabled = false;
    }
}
