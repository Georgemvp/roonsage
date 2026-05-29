import { generatePlaylistStream, createPlayQueue } from '../../modules/api.js';
import { esc, artUrl, toast } from '../util.js';
import { getDefaultZoneId } from '../roon.js';

const TEMPLATES = [
    { icon: 'coffee', label: 'Chill', prompt: 'Relaxte, warme tracks om tot rust te komen' },
    { icon: 'psychology', label: 'Focus', prompt: 'Instrumentale focusmuziek voor diep werk' },
    { icon: 'fitness_center', label: 'Workout', prompt: 'Energieke, drijvende tracks voor een work-out' },
    { icon: 'bedtime', label: 'Sleep', prompt: 'Rustige, ambient muziek om bij in slaap te vallen' },
];

const COUNTS = [15, 25, 50];

let _count = 25;
let _tracks = [];
let _busy = false;

export function render() {
    const tmpl = TEMPLATES.map((t) => `
        <button data-prompt="${esc(t.prompt)}" class="gen-tmpl px-4 py-2 rounded-full bg-surface-charcoal border border-white/10 font-body-sm text-body-sm text-on-surface active:scale-95 transition-transform flex items-center gap-2">
            <span class="material-symbols-outlined text-[16px] text-primary">${t.icon}</span> ${t.label}
        </button>`).join('');
    const counts = COUNTS.map((n) => `
        <button data-n="${n}" class="gen-count py-sm rounded-xl border font-title-md text-title-md active:scale-95 transition-transform ${n === _count ? 'bg-primary/20 border-primary/30 text-primary' : 'bg-surface-glass border-white/5 text-text-primary'}">${n}</button>`).join('');

    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Genereer playlist</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Beschrijf de sfeer — de AI kiest tracks uit je bibliotheek.</p>
        </section>

        <textarea id="gen-prompt" rows="4" placeholder="Waar ben je naar op zoek?"
            class="w-full bg-surface-glass border border-white/5 rounded-2xl p-4 font-body-lg text-body-lg text-text-primary placeholder:text-text-muted/60 resize-none focus:outline-none focus:ring-1 focus:ring-primary/50"></textarea>

        <div class="flex flex-wrap gap-xs">${tmpl}</div>

        <div class="flex flex-col gap-sm">
            <span class="font-label-caps text-label-caps text-text-muted">Aantal tracks</span>
            <div id="gen-counts" class="grid grid-cols-3 gap-sm">${counts}</div>
        </div>

        <button id="gen-go" class="w-full h-14 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform shadow-[0_4px_24px_rgba(211,187,255,0.25)]">
            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">auto_awesome</span>
            Genereer
        </button>

        <div id="gen-status" class="hidden glass-panel rounded-xl p-md flex items-center gap-md">
            <span class="material-symbols-outlined animate-spin text-primary">progress_activity</span>
            <span id="gen-status-text" class="font-body-sm text-body-sm text-text-primary">Bezig…</span>
        </div>

        <section id="gen-results" class="hidden flex-col gap-sm"></section>
    </div>`;
}

export function mount(root) {
    root.querySelector('#gen-go')?.addEventListener('click', run);
    root.querySelectorAll('.gen-tmpl').forEach((b) =>
        b.addEventListener('click', () => { root.querySelector('#gen-prompt').value = b.dataset.prompt; }));
    root.querySelectorAll('.gen-count').forEach((b) =>
        b.addEventListener('click', () => setCount(root, Number(b.dataset.n))));
}

function setCount(root, n) {
    _count = n;
    root.querySelectorAll('.gen-count').forEach((b) => {
        const on = Number(b.dataset.n) === _count;
        b.classList.toggle('bg-primary/20', on);
        b.classList.toggle('border-primary/30', on);
        b.classList.toggle('text-primary', on);
        b.classList.toggle('bg-surface-glass', !on);
        b.classList.toggle('border-white/5', !on);
        b.classList.toggle('text-text-primary', !on);
    });
}

function run() {
    if (_busy) return;
    const prompt = document.getElementById('gen-prompt')?.value.trim();
    if (!prompt) { toast('Beschrijf eerst je playlist', 'error'); return; }

    _busy = true;
    const statusEl = document.getElementById('gen-status');
    const statusText = document.getElementById('gen-status-text');
    const resultsEl = document.getElementById('gen-results');
    const goBtn = document.getElementById('gen-go');
    statusEl.classList.remove('hidden');
    statusEl.classList.add('flex');
    resultsEl.classList.add('hidden');
    if (goBtn) goBtn.disabled = true;

    const request = {
        prompt,
        genres: [],
        decades: [],
        track_count: _count,
        exclude_live: true,
        source_mode: 'library',
        use_taste_profile: true,
    };

    generatePlaylistStream(
        request,
        (p) => { if (statusText && p.step) statusText.textContent = stepLabel(p.step); },
        (resp) => {
            _busy = false;
            if (goBtn) goBtn.disabled = false;
            statusEl.classList.add('hidden');
            statusEl.classList.remove('flex');
            _tracks = resp.tracks || [];
            renderResults(resp);
        },
        (err) => {
            _busy = false;
            if (goBtn) goBtn.disabled = false;
            statusEl.classList.add('hidden');
            statusEl.classList.remove('flex');
            toast(err.message || 'Genereren mislukt', 'error');
        },
    );
}

function stepLabel(step) {
    const map = {
        analyzing: 'Analyseren…', filtering: 'Bibliotheek filteren…',
        generating: 'Tracks kiezen…', curating: 'Cureren…', finalizing: 'Afronden…',
    };
    return map[step] || 'Bezig…';
}

function renderResults(resp) {
    const el = document.getElementById('gen-results');
    if (!el) return;
    const tracks = resp.tracks || [];
    if (!tracks.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen tracks gevonden — probeer een andere omschrijving.</p>`; el.classList.remove('hidden'); el.classList.add('flex'); return; }

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
        <button id="gen-play" class="w-full h-12 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform">
            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">play_arrow</span>
            Speel ${tracks.length} tracks
        </button>
        <div class="flex flex-col gap-xs mt-sm">${rows}</div>`;
    el.classList.remove('hidden');
    el.classList.add('flex');
    el.querySelector('#gen-play')?.addEventListener('click', (e) => playAll(e.currentTarget));
}

async function playAll(btn) {
    const keys = _tracks.map((t) => t.item_key).filter(Boolean);
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
