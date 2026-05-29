import { apiCall, createPlayQueue } from '../../modules/api.js';
import { esc, toast, dedupeTracks } from '../util.js';
import { getDefaultZoneId } from '../roon.js';

const MODES = {
    clap: {
        status: '/clap/status', search: '/clap/search', title: 'Sonic Matches',
        placeholder: "bijv. 'donkere atmosferische synths met zware bas'",
        chips: ['dark atmospheric synths', 'lo-fi beats for rainy days', 'distorted electric guitar solo'],
        disabledMsg: 'CLAP-zoeken staat uit. Zet CLAP_ENABLED=true en analyseer je audio.',
    },
    lyrics: {
        status: '/lyrics/status', search: '/lyrics/search', title: 'Meaning Matches',
        placeholder: "bijv. 'nummers over reizen en loslaten'",
        chips: ['songs about travel and moving on', 'overcoming fear of failure', 'nostalgia for the 90s'],
        disabledMsg: 'Songtekst-zoeken staat uit. Zet LYRICS_SEARCH_ENABLED=true en analyseer je teksten.',
    },
};

let _mode = 'clap';
let _results = [];

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col items-center text-center gap-sm">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Advanced Discovery</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Beschrijf de klank of de betekenis die je zoekt.</p>
            <div class="inline-flex rounded-full bg-surface-charcoal p-1 mt-xs">
                <button data-mode="clap" class="srch-tab font-label-caps text-label-caps px-lg py-sm rounded-full transition-all flex items-center gap-xs">
                    <span class="material-symbols-outlined text-[16px]">graphic_eq</span> SONIC MATCH
                </button>
                <button data-mode="lyrics" class="srch-tab font-label-caps text-label-caps px-lg py-sm rounded-full transition-all flex items-center gap-xs">
                    <span class="material-symbols-outlined text-[16px]">notes</span> MEANING MATCH
                </button>
            </div>
        </section>

        <section class="flex flex-col gap-sm">
            <div class="glass-panel rounded-full flex items-center px-lg py-sm">
                <span class="material-symbols-outlined text-primary mr-sm">search</span>
                <input id="srch-input" type="search" class="w-full bg-transparent border-none focus:ring-0 text-text-primary font-body-lg text-body-lg placeholder-text-muted/50" />
                <button id="srch-go" class="bg-primary/20 text-primary rounded-full w-10 h-10 flex items-center justify-center ml-sm active:scale-95 transition-transform shrink-0">
                    <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">auto_awesome</span>
                </button>
            </div>
            <div id="srch-chips" class="flex flex-wrap justify-center gap-sm"></div>
        </section>

        <section class="pt-md border-t border-surface-charcoal">
            <h2 id="srch-title" class="font-title-md text-title-md text-text-primary mb-md">Sonic Matches</h2>
            <div id="srch-results" class="flex flex-col gap-xs"><p class="font-body-sm text-body-sm text-text-muted">Typ een omschrijving en tik op zoeken.</p></div>
        </section>
    </div>`;
}

export async function mount(root) {
    root.querySelectorAll('.srch-tab').forEach((b) => b.addEventListener('click', () => setMode(root, b.dataset.mode)));
    root.querySelector('#srch-go')?.addEventListener('click', () => run(root));
    root.querySelector('#srch-input')?.addEventListener('keydown', (e) => { if (e.key === 'Enter') run(root); });
    setMode(root, _mode);
}

function setMode(root, mode) {
    _mode = mode;
    const cfg = MODES[mode];
    root.querySelectorAll('.srch-tab').forEach((b) => {
        const on = b.dataset.mode === mode;
        b.classList.toggle('viola-gradient', on);
        b.classList.toggle('text-white', on);
        b.classList.toggle('text-text-muted', !on);
    });
    root.querySelector('#srch-input').placeholder = cfg.placeholder;
    root.querySelector('#srch-title').textContent = cfg.title;
    root.querySelector('#srch-chips').innerHTML = cfg.chips.map((c) =>
        `<button class="srch-chip glass-panel px-sm py-xs rounded-full font-body-sm text-body-sm text-text-muted active:scale-95 transition-transform">${esc(c)}</button>`).join('');
    root.querySelectorAll('.srch-chip').forEach((el) => el.addEventListener('click', () => {
        root.querySelector('#srch-input').value = el.textContent;
        run(root);
    }));
    // Reset results panel on mode switch.
    root.querySelector('#srch-results').innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Typ een omschrijving en tik op zoeken.</p>`;
}

async function run(root) {
    const cfg = MODES[_mode];
    const query = root.querySelector('#srch-input').value.trim();
    const el = root.querySelector('#srch-results');
    if (!query) { toast('Typ eerst een omschrijving', 'error'); return; }
    el.innerHTML = `<div class="flex justify-center py-lg"><span class="material-symbols-outlined animate-spin text-primary">progress_activity</span></div>`;

    // Guard: feature may be disabled on the server.
    const status = await apiCall(cfg.status).catch(() => null);
    if (status && status.enabled === false) {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">${esc(cfg.disabledMsg)}</p>`;
        return;
    }

    let data;
    try {
        data = await apiCall(cfg.search, { method: 'POST', body: JSON.stringify({ query, limit: 25 }) });
    } catch (e) {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-error">${esc(e.message || 'Zoeken mislukt')}</p>`;
        return;
    }
    _results = dedupeTracks(data?.results || []);
    renderResults(el);
}

function renderResults(el) {
    if (!_results.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Niets gevonden.</p>`; return; }
    const rows = _results.map((t) => {
        const score = t.similarity != null ? Math.round(t.similarity * 100) : (t.score != null ? Math.round(t.score * 100) : null);
        return `
        <div class="flex items-center gap-md p-sm rounded-lg active:bg-surface-charcoal transition-colors">
            <div class="w-10 h-10 rounded bg-surface-container-high flex items-center justify-center flex-shrink-0">
                <span class="material-symbols-outlined text-text-muted text-[20px]">${_mode === 'clap' ? 'graphic_eq' : 'notes'}</span>
            </div>
            <div class="flex-1 min-w-0">
                <p class="font-body-lg text-body-lg text-text-primary truncate">${esc(t.title || '')}</p>
                <p class="font-body-sm text-body-sm text-text-muted truncate">${esc(t.artist || '')}</p>
            </div>
            ${score != null ? `<span class="font-label-caps text-label-caps text-primary bg-primary/10 px-2 py-1 rounded flex-shrink-0">${score}%</span>` : ''}
        </div>`;
    }).join('');
    el.innerHTML = `
        <button id="srch-play" class="w-full h-12 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform mb-sm">
            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">play_arrow</span>
            Speel ${_results.length} tracks
        </button>
        <div class="flex flex-col gap-xs">${rows}</div>`;
    el.querySelector('#srch-play')?.addEventListener('click', (e) => playAll(e.currentTarget));
}

async function playAll(btn) {
    const keys = _results.map((t) => t.item_key).filter(Boolean);
    if (!keys.length) { toast('Geen afspeelbare tracks', 'error'); return; }
    btn.disabled = true;
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        const resp = await createPlayQueue(keys, zoneId, 'replace');
        toast(resp?.success ? `${resp.tracks_queued ?? keys.length} tracks gestart` : 'Afspelen gestart');
    } catch (e) {
        toast(e.message || 'Afspelen mislukt', 'error');
    } finally {
        btn.disabled = false;
    }
}
