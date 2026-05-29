import { apiCall, searchTracks } from '../../modules/api.js';
import { esc, toast, dedupeTracks } from '../util.js';
import { getDefaultZoneId } from '../roon.js';

let _add = [];      // [{item_key, title, artist}]
let _subtract = [];
let _weight = 0.5;
let _limit = 25;
let _results = [];
let _searchTimers = {};

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Song Alchemy</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Meng tracks: tel sferen op die je wilt, trek af wat je wilt vermijden.</p>
        </section>

        ${pickerSection('add', 'Meer hiervan', 'add_circle', 'text-primary')}
        ${pickerSection('subtract', 'Minder hiervan', 'remove_circle', 'text-secondary')}

        <section class="glass-panel rounded-xl p-md flex flex-col gap-md">
            <div class="flex justify-between items-center">
                <span class="font-label-caps text-label-caps text-text-muted">Aftrek-gewicht</span>
                <span id="al-weight-val" class="font-label-caps text-label-caps text-primary">${_weight.toFixed(2)}</span>
            </div>
            <input id="al-weight" type="range" min="0" max="1" step="0.05" value="${_weight}" class="w-full">
            <div class="flex justify-between items-center">
                <span class="font-label-caps text-label-caps text-text-muted">Aantal tracks</span>
                <span id="al-limit-val" class="font-label-caps text-label-caps text-primary">${_limit}</span>
            </div>
            <input id="al-limit" type="range" min="5" max="100" step="5" value="${_limit}" class="w-full">
        </section>

        <div class="flex gap-sm">
            <button id="al-mix" class="flex-1 h-14 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform shadow-[0_4px_24px_rgba(211,187,255,0.25)]">
                <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">science</span> Mix
            </button>
            <button id="al-surprise" class="w-14 h-14 rounded-full bg-surface-charcoal border border-white/10 text-primary flex items-center justify-center active:scale-95 transition-transform" aria-label="Verras me">
                <span class="material-symbols-outlined">casino</span>
            </button>
        </div>

        <div id="al-status" class="hidden glass-panel rounded-xl p-md items-center gap-md">
            <span class="material-symbols-outlined animate-spin text-primary">progress_activity</span>
            <span class="font-body-sm text-body-sm text-text-primary">Mengen…</span>
        </div>
        <section id="al-results" class="hidden flex-col gap-sm"></section>
    </div>`;
}

function pickerSection(which, label, icon, tint) {
    return `
    <section class="flex flex-col gap-sm" data-pick="${which}">
        <div class="flex items-center gap-xs">
            <span class="material-symbols-outlined ${tint}">${icon}</span>
            <h2 class="font-title-md text-title-md">${label}</h2>
        </div>
        <div class="al-chips flex flex-wrap gap-xs"></div>
        <div class="flex items-center gap-sm bg-surface-charcoal rounded-full px-md py-xs">
            <span class="material-symbols-outlined text-text-muted text-[20px]">search</span>
            <input class="al-input w-full bg-transparent border-none focus:ring-0 text-text-primary font-body-sm text-body-sm" placeholder="Track zoeken…">
        </div>
        <div class="al-suggest flex flex-col gap-1"></div>
    </section>`;
}

export function mount(root) {
    root.querySelectorAll('[data-pick]').forEach((sec) => wirePicker(sec));

    const w = root.querySelector('#al-weight');
    w?.addEventListener('input', () => { _weight = Number(w.value); root.querySelector('#al-weight-val').textContent = _weight.toFixed(2); });
    const lim = root.querySelector('#al-limit');
    lim?.addEventListener('input', () => { _limit = Number(lim.value); root.querySelector('#al-limit-val').textContent = _limit; });

    root.querySelector('#al-mix')?.addEventListener('click', mix);
    root.querySelector('#al-surprise')?.addEventListener('click', (e) => surprise(e.currentTarget));
}

export function unmount() { Object.values(_searchTimers).forEach((t) => clearTimeout(t)); }

function listFor(which) { return which === 'add' ? _add : _subtract; }

function wirePicker(sec) {
    const which = sec.dataset.pick;
    const input = sec.querySelector('.al-input');
    const suggest = sec.querySelector('.al-suggest');
    const chips = sec.querySelector('.al-chips');
    renderChips(which, chips);

    input.addEventListener('input', () => {
        const q = input.value.trim();
        if (_searchTimers[which]) clearTimeout(_searchTimers[which]);
        if (!q) { suggest.innerHTML = ''; return; }
        _searchTimers[which] = setTimeout(async () => {
            let data; try { data = await searchTracks(q); } catch { return; }
            const items = (Array.isArray(data) ? data : data?.results || []).slice(0, 6);
            suggest.innerHTML = items.map((t, i) =>
                `<button class="al-opt text-left p-sm rounded-lg active:bg-surface-charcoal" data-idx="${i}">
                    <p class="font-body-sm text-body-sm text-text-primary truncate">${esc(t.title || '')}</p>
                    <p class="font-label-caps text-[10px] text-text-muted truncate">${esc(t.artist || '')}</p>
                </button>`).join('');
            suggest.querySelectorAll('.al-opt').forEach((btn) => btn.addEventListener('click', () => {
                const t = items[Number(btn.dataset.idx)];
                const list = listFor(which);
                if (!list.some((x) => x.item_key === t.item_key)) list.push({ item_key: t.item_key, title: t.title, artist: t.artist });
                suggest.innerHTML = ''; input.value = '';
                renderChips(which, chips);
            }));
        }, 300);
    });
}

function renderChips(which, chips) {
    const list = listFor(which);
    chips.innerHTML = list.map((t, i) => `
        <span class="inline-flex items-center gap-1 pl-md pr-xs py-xs rounded-full glass-panel font-body-sm text-body-sm">
            ${esc(t.title || '')}
            <button class="al-chip-x text-text-muted active:scale-90" data-which="${which}" data-i="${i}"><span class="material-symbols-outlined text-[16px]">close</span></button>
        </span>`).join('');
    chips.querySelectorAll('.al-chip-x').forEach((b) => b.addEventListener('click', () => {
        listFor(b.dataset.which).splice(Number(b.dataset.i), 1);
        renderChips(which, chips);
    }));
}

async function mix() {
    if (!_add.length) { toast('Voeg minstens één track toe bij "Meer hiervan"', 'error'); return; }
    const statusEl = document.getElementById('al-status');
    const resultsEl = document.getElementById('al-results');
    const btn = document.getElementById('al-mix');
    statusEl.classList.remove('hidden'); statusEl.classList.add('flex');
    resultsEl.classList.add('hidden');
    if (btn) btn.disabled = true;
    try {
        const data = await apiCall('/alchemy/mix', {
            method: 'POST',
            body: JSON.stringify({
                add: _add.map((t) => t.item_key),
                subtract: _subtract.map((t) => t.item_key),
                limit: _limit, subtract_weight: _weight,
            }),
        });
        _results = dedupeTracks(data.results || []);
        renderResults();
    } catch (e) {
        toast(e.message || 'Mix mislukt', 'error');
    } finally {
        if (btn) btn.disabled = false;
        statusEl.classList.add('hidden'); statusEl.classList.remove('flex');
    }
}

function renderResults() {
    const el = document.getElementById('al-results');
    if (!el) return;
    if (!_results.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen resultaten.</p>`; el.classList.remove('hidden'); el.classList.add('flex'); return; }
    const rows = _results.map((t, i) => `
        <div class="flex items-center gap-md p-sm rounded-lg">
            <span class="font-body-sm text-body-sm text-text-muted w-5 text-center flex-shrink-0">${i + 1}</span>
            <div class="flex-1 min-w-0">
                <p class="font-body-lg text-body-lg text-text-primary truncate">${esc(t.title || '')}</p>
                <p class="font-body-sm text-body-sm text-text-muted truncate">${esc(t.artist || '')}</p>
            </div>
        </div>`).join('');
    el.innerHTML = `
        <h2 class="font-title-md text-title-md text-text-primary">${_results.length} tracks</h2>
        <button id="al-play" class="w-full h-12 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform">
            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">play_arrow</span> Speel mix
        </button>
        <div class="flex flex-col gap-xs mt-sm">${rows}</div>`;
    el.classList.remove('hidden'); el.classList.add('flex');
    el.querySelector('#al-play')?.addEventListener('click', (e) => playMix(e.currentTarget));
}

async function playMix(btn) {
    btn.disabled = true;
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        await apiCall('/alchemy/play', {
            method: 'POST',
            body: JSON.stringify({
                add: _add.map((t) => t.item_key), subtract: _subtract.map((t) => t.item_key),
                limit: _limit, subtract_weight: _weight, zone_id: zoneId, mode: 'replace',
            }),
        });
        toast('Mix gestart');
    } catch (e) { toast(e.message || 'Afspelen mislukt', 'error'); }
    finally { btn.disabled = false; }
}

async function surprise(btn) {
    btn.disabled = true;
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        const data = await apiCall('/alchemy/surprise', { method: 'POST', body: JSON.stringify({ zone_id: zoneId, limit: _limit, play: true }) });
        if (data?.error) { toast(data.error, 'error'); return; }
        _results = dedupeTracks(data.results || []);
        renderResults();
        toast('Verrassingsmix gestart');
    } catch (e) { toast(e.message || 'Mislukt', 'error'); }
    finally { btn.disabled = false; }
}
