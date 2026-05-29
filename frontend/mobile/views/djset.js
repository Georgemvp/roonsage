import { apiCall, createPlayQueue } from '../../modules/api.js';
import { esc, toast } from '../util.js';
import { getDefaultZoneId } from '../roon.js';

const CURVES = [
    { v: 'ramp_up', icon: 'trending_up', label: 'Rise' },
    { v: 'peak', icon: 'analytics', label: 'Peak' },
    { v: 'flat', icon: 'trending_flat', label: 'Steady' },
    { v: 'ramp_down', icon: 'trending_down', label: 'Wind down' },
];

const cfg = {
    duration_minutes: 60,
    start_bpm: 118,
    end_bpm: 126,
    energy_curve: 'ramp_up',
    max_per_artist: 2,
    exclude_live: true,
    skip_recent: false,
};
let _tracks = [];
let _busy = false;

export function render() {
    const curves = CURVES.map((c) => `
        <button data-curve="${c.v}" class="dj-curve glass-panel p-md rounded-xl flex flex-col items-center gap-xs active:scale-95 transition-transform ${c.v === cfg.energy_curve ? 'border-primary/50 bg-primary/10' : ''}">
            <span class="material-symbols-outlined ${c.v === cfg.energy_curve ? 'text-primary' : 'text-text-muted'}">${c.icon}</span>
            <span class="font-label-caps text-label-caps ${c.v === cfg.energy_curve ? 'text-primary' : ''}">${c.label}</span>
        </button>`).join('');

    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">DJ Set Builder</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Beatmatched, harmonisch gemixte set uit je bibliotheek.</p>
        </section>

        <section class="flex flex-col gap-md">
            <div class="flex justify-between items-end">
                <span class="font-label-caps text-label-caps text-text-muted uppercase">BPM-bereik</span>
                <span id="dj-bpm-val" class="text-primary font-title-md text-title-md">${cfg.start_bpm} — ${cfg.end_bpm}</span>
            </div>
            <div class="glass-panel p-md rounded-xl flex flex-col gap-md">
                <label class="flex flex-col gap-1">
                    <span class="font-body-sm text-body-sm text-text-muted">Start BPM</span>
                    <input id="dj-start-bpm" type="range" min="60" max="180" value="${cfg.start_bpm}" class="w-full">
                </label>
                <label class="flex flex-col gap-1">
                    <span class="font-body-sm text-body-sm text-text-muted">Eind BPM</span>
                    <input id="dj-end-bpm" type="range" min="60" max="180" value="${cfg.end_bpm}" class="w-full">
                </label>
            </div>
        </section>

        <section class="flex flex-col gap-md">
            <span class="font-label-caps text-label-caps text-text-muted uppercase">Energiecurve</span>
            <div id="dj-curves" class="grid grid-cols-4 gap-sm">${curves}</div>
        </section>

        <section class="flex flex-col gap-md">
            <div class="flex justify-between items-end">
                <span class="font-label-caps text-label-caps text-text-muted uppercase">Duur</span>
                <span id="dj-dur-val" class="text-primary font-title-md text-title-md">${cfg.duration_minutes} min</span>
            </div>
            <input id="dj-duration" type="range" min="15" max="180" step="15" value="${cfg.duration_minutes}" class="w-full">
        </section>

        <section class="glass-panel rounded-xl divide-y divide-white/10">
            ${toggleRow('dj-max-artist', 'Max 2 tracks per artiest', cfg.max_per_artist === 2)}
            ${toggleRow('dj-no-live', 'Live-versies overslaan', cfg.exclude_live)}
            ${toggleRow('dj-skip-recent', 'Recent gespeeld overslaan', cfg.skip_recent)}
        </section>

        <button id="dj-build" class="w-full h-14 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform shadow-[0_4px_24px_rgba(211,187,255,0.25)]">
            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">auto_awesome</span>
            Bouw set
        </button>

        <div id="dj-status" class="hidden glass-panel rounded-xl p-md items-center gap-md">
            <span class="material-symbols-outlined animate-spin text-primary">progress_activity</span>
            <span class="font-body-sm text-body-sm text-text-primary">Set bouwen…</span>
        </div>

        <section id="dj-results" class="hidden flex-col gap-sm"></section>
    </div>`;
}

function toggleRow(id, label, on) {
    return `
    <button data-toggle="${id}" class="dj-toggle flex items-center justify-between p-md w-full text-left">
        <span class="font-body-lg text-body-lg text-on-surface">${label}</span>
        <span class="dj-switch relative w-12 h-6 rounded-full border transition-colors ${on ? 'bg-primary/20 border-primary/30' : 'bg-white/10 border-white/10'}" data-on="${on ? '1' : '0'}">
            <span class="absolute top-1 w-4 h-4 rounded-full transition-all ${on ? 'right-1 bg-primary' : 'left-1 bg-white/40'}"></span>
        </span>
    </button>`;
}

export function mount(root) {
    const sBpm = root.querySelector('#dj-start-bpm');
    const eBpm = root.querySelector('#dj-end-bpm');
    const bpmVal = root.querySelector('#dj-bpm-val');
    const syncBpm = () => {
        cfg.start_bpm = Number(sBpm.value);
        cfg.end_bpm = Number(eBpm.value);
        if (bpmVal) bpmVal.textContent = `${cfg.start_bpm} — ${cfg.end_bpm}`;
    };
    sBpm?.addEventListener('input', syncBpm);
    eBpm?.addEventListener('input', syncBpm);

    const dur = root.querySelector('#dj-duration');
    const durVal = root.querySelector('#dj-dur-val');
    dur?.addEventListener('input', () => { cfg.duration_minutes = Number(dur.value); if (durVal) durVal.textContent = `${cfg.duration_minutes} min`; });

    root.querySelectorAll('.dj-curve').forEach((b) => b.addEventListener('click', () => selectCurve(root, b.dataset.curve)));
    root.querySelectorAll('.dj-toggle').forEach((b) => b.addEventListener('click', () => toggle(b)));
    root.querySelector('#dj-build')?.addEventListener('click', build);
}

function selectCurve(root, curve) {
    cfg.energy_curve = curve;
    root.querySelectorAll('.dj-curve').forEach((b) => {
        const on = b.dataset.curve === curve;
        b.classList.toggle('border-primary/50', on);
        b.classList.toggle('bg-primary/10', on);
        const icon = b.querySelector('.material-symbols-outlined');
        const lbl = b.querySelector('.font-label-caps');
        if (icon) { icon.classList.toggle('text-primary', on); icon.classList.toggle('text-text-muted', !on); }
        if (lbl) lbl.classList.toggle('text-primary', on);
    });
}

function toggle(btn) {
    const sw = btn.querySelector('.dj-switch');
    const on = sw.dataset.on !== '1';
    sw.dataset.on = on ? '1' : '0';
    sw.classList.toggle('bg-primary/20', on);
    sw.classList.toggle('border-primary/30', on);
    sw.classList.toggle('bg-white/10', !on);
    sw.classList.toggle('border-white/10', !on);
    const dot = sw.querySelector('span');
    dot.classList.toggle('right-1', on);
    dot.classList.toggle('bg-primary', on);
    dot.classList.toggle('left-1', !on);
    dot.classList.toggle('bg-white/40', !on);

    if (btn.dataset.toggle === 'dj-max-artist') cfg.max_per_artist = on ? 2 : null;
    if (btn.dataset.toggle === 'dj-no-live') cfg.exclude_live = on;
    if (btn.dataset.toggle === 'dj-skip-recent') cfg.skip_recent = on;
}

async function build() {
    if (_busy) return;
    _busy = true;
    const statusEl = document.getElementById('dj-status');
    const resultsEl = document.getElementById('dj-results');
    const buildBtn = document.getElementById('dj-build');
    statusEl.classList.remove('hidden'); statusEl.classList.add('flex');
    resultsEl.classList.add('hidden');
    if (buildBtn) buildBtn.disabled = true;

    try {
        const data = await apiCall('/audio-features/dj-set', {
            method: 'POST',
            body: JSON.stringify({ ...cfg, genres: [] }),
        });
        _tracks = data.tracks || [];
        renderResults(data);
    } catch (e) {
        toast(e.message || 'Set bouwen mislukt', 'error');
    } finally {
        _busy = false;
        if (buildBtn) buildBtn.disabled = false;
        statusEl.classList.add('hidden'); statusEl.classList.remove('flex');
    }
}

function renderResults(data) {
    const el = document.getElementById('dj-results');
    if (!el) return;
    const tracks = data.tracks || [];
    if (!tracks.length) {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen geschikte tracks gevonden. Verruim het BPM-bereik of analyseer meer audio.</p>`;
        el.classList.remove('hidden'); el.classList.add('flex');
        return;
    }
    const rows = tracks.map((t, i) => `
        <div class="flex items-center gap-md p-sm rounded-lg">
            <span class="font-body-sm text-body-sm text-text-muted w-5 text-center flex-shrink-0">${i + 1}</span>
            <div class="flex-1 min-w-0">
                <p class="font-body-lg text-body-lg text-text-primary truncate">${esc(t.title || '')}</p>
                <p class="font-body-sm text-body-sm text-text-muted truncate">${esc(t.artist || '')}</p>
            </div>
            <div class="flex flex-col items-end flex-shrink-0">
                <span class="font-label-caps text-label-caps text-primary">${t.bpm != null ? Math.round(t.bpm) : '—'} BPM</span>
                ${t.camelot ? `<span class="font-label-caps text-[10px] text-text-muted">${esc(t.camelot)}</span>` : ''}
            </div>
        </div>`).join('');

    el.innerHTML = `
        <div class="flex justify-between items-end">
            <h2 class="font-title-md text-title-md text-text-primary">${tracks.length} tracks</h2>
            <span class="font-body-sm text-body-sm text-text-muted">pool: ${data.total_matching ?? '—'}</span>
        </div>
        <button id="dj-play" class="w-full h-12 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform">
            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">play_arrow</span>
            Speel set
        </button>
        <div class="flex flex-col gap-xs mt-sm">${rows}</div>`;
    el.classList.remove('hidden'); el.classList.add('flex');
    el.querySelector('#dj-play')?.addEventListener('click', (e) => playSet(e.currentTarget));
}

async function playSet(btn) {
    const keys = _tracks.map((t) => t.item_key).filter(Boolean);
    if (!keys.length) { toast('Geen afspeelbare tracks', 'error'); return; }
    btn.disabled = true;
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        const resp = await createPlayQueue(keys, zoneId, 'replace');
        toast(resp?.success ? `${resp.tracks_queued ?? keys.length} tracks gestart` : 'Set gestart');
    } catch (e) {
        toast(e.message || 'Afspelen mislukt', 'error');
    } finally {
        btn.disabled = false;
    }
}
