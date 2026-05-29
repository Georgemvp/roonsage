import { esc, artUrl, fmtTime, toast } from '../util.js';
import { getActiveZone, getZones, transport, setVolume } from '../roon.js';

let _timer = null;
let _zone = null;
let _zoneList = [];
let _forcedZoneId = null;
let _volTimer = null;
let _volInteractingUntil = 0;

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg min-h-[80vh]">
        <div class="flex items-center justify-between">
            <button id="np-back" class="w-10 h-10 flex items-center justify-center rounded-full glass-panel active:scale-95 transition-transform" aria-label="Terug">
                <span class="material-symbols-outlined">keyboard_arrow_down</span>
            </button>
            <div class="flex flex-col items-center">
                <span class="font-label-caps text-label-caps text-text-muted uppercase tracking-widest">Speelt van</span>
                <span id="np-zone" class="font-body-sm text-body-sm text-text-primary mt-0.5">—</span>
            </div>
            <div class="w-10 h-10"></div>
        </div>

        <div id="np-body" class="flex flex-col gap-lg items-center">
            <div class="w-full max-w-[340px] aspect-square rounded-[24px] overflow-hidden bg-surface-charcoal flex items-center justify-center viola-glow">
                <span class="material-symbols-outlined text-text-muted" style="font-size:64px;">music_note</span>
            </div>
            <div class="w-full text-center">
                <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Niets aan het spelen</h1>
                <h2 class="font-title-md text-title-md text-text-muted mt-1">—</h2>
            </div>
        </div>
    </div>`;
}

export async function mount(root) {
    const back = root.querySelector('#np-back');
    if (back) back.addEventListener('click', () => history.back());
    await refresh();
    _timer = setInterval(refresh, 4000);
}

export function unmount() {
    if (_timer) clearInterval(_timer);
    _timer = null;
}

async function doVolume(action, value) {
    if (!_zone) return;
    _volInteractingUntil = Date.now() + 2500; // pause poll-driven re-render while adjusting
    clearTimeout(_volTimer);
    _volTimer = setTimeout(async () => {
        try {
            await setVolume(_zone.display_name, action, value);
            if (action === 'toggle_mute') setTimeout(refresh, 350);
        } catch (e) {
            toast('Volume mislukt', 'error');
        }
    }, 150);
}

async function refresh() {
    // Don't rebuild the DOM (and reset the slider) while the user is dragging volume.
    if (Date.now() < _volInteractingUntil) return;
    _zoneList = await getZones();
    _zone = (_forcedZoneId && _zoneList.find((z) => z.zone_id === _forcedZoneId)) || (await getActiveZone());
    const body = document.getElementById('np-body');
    const zoneEl = document.getElementById('np-zone');
    if (!body) return;

    if (!_zone || !_zone.now_playing) {
        if (zoneEl) zoneEl.textContent = _zone?.display_name || '—';
        return;
    }

    const np = _zone.now_playing;
    const title = np.three_line?.line1 || np.two_line?.line1 || np.one_line?.line1 || 'Onbekend';
    const artist = np.three_line?.line2 || np.two_line?.line2 || np.one_line?.line2 || '';
    const album = np.three_line?.line3 || np.two_line?.line3 || '';
    const isPlaying = _zone.state === 'playing';
    const src = artUrl(np.image_key, 600, 600);
    const pos = np.seek_position ?? 0;
    const dur = np.length ?? 0;
    const pct = dur > 0 ? Math.min(100, (pos / dur) * 100) : 0;

    if (zoneEl) zoneEl.textContent = _zone.display_name || _zone.zone_id || '';

    body.innerHTML = `
        <div class="w-full max-w-[340px] aspect-square rounded-[24px] overflow-hidden bg-surface-charcoal flex items-center justify-center viola-glow relative">
            ${src
                ? `<img src="${src}" alt="" class="w-full h-full object-cover" onerror="this.replaceWith(Object.assign(document.createElement('span'),{className:'material-symbols-outlined text-text-muted',style:'font-size:64px',textContent:'music_note'}))">`
                : `<span class="material-symbols-outlined text-text-muted" style="font-size:64px;">music_note</span>`}
            <div class="absolute inset-0 border border-white/10 rounded-[24px] pointer-events-none"></div>
        </div>

        <div class="w-full">
            <div class="flex justify-between items-start gap-md">
                <div class="min-w-0 flex-1">
                    <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary truncate">${esc(title)}</h1>
                    <h2 class="font-title-md text-title-md text-text-muted mt-1 truncate">${esc(artist)}</h2>
                    ${album ? `<p class="font-body-sm text-body-sm text-text-muted/70 mt-0.5 truncate">${esc(album)}</p>` : ''}
                </div>
            </div>

            <div class="mt-lg">
                <div class="h-1.5 w-full bg-surface-charcoal rounded-full overflow-hidden">
                    <div class="h-full viola-gradient rounded-full transition-all" style="width:${pct}%"></div>
                </div>
                <div class="flex justify-between font-label-caps text-label-caps text-text-muted mt-1">
                    <span>${fmtTime(pos)}</span>
                    <span>${fmtTime(dur)}</span>
                </div>
            </div>

            <div class="flex items-center justify-between mt-lg">
                <button data-act="shuffle" class="np-ctl text-text-muted active:scale-90 transition-transform p-2" aria-label="Shuffle">
                    <span class="material-symbols-outlined text-[24px]">shuffle</span>
                </button>
                <div class="flex items-center gap-lg">
                    <button data-act="previous" class="np-ctl text-text-primary active:scale-90 transition-transform p-2" aria-label="Vorige">
                        <span class="material-symbols-outlined text-[36px]" style="font-variation-settings:'FILL' 1;">skip_previous</span>
                    </button>
                    <button data-act="${isPlaying ? 'pause' : 'play'}" class="np-ctl w-20 h-20 flex items-center justify-center rounded-full viola-gradient text-on-primary active:scale-95 transition-transform shadow-[0_0_24px_rgba(211,187,255,0.3)]" aria-label="${isPlaying ? 'Pauzeer' : 'Speel'}">
                        <span class="material-symbols-outlined text-[40px]" style="font-variation-settings:'FILL' 1;">${isPlaying ? 'pause' : 'play_arrow'}</span>
                    </button>
                    <button data-act="next" class="np-ctl text-text-primary active:scale-90 transition-transform p-2" aria-label="Volgende">
                        <span class="material-symbols-outlined text-[36px]" style="font-variation-settings:'FILL' 1;">skip_next</span>
                    </button>
                </div>
                <button data-act="repeat" class="np-ctl text-text-muted active:scale-90 transition-transform p-2" aria-label="Herhaal">
                    <span class="material-symbols-outlined text-[24px]">repeat</span>
                </button>
            </div>

            ${_zone.volume != null ? volumeBar(_zone.volume) : ''}

            ${_zoneList.filter((z) => z.now_playing).length > 1 ? zonePicker() : ''}
        </div>`;

    body.querySelectorAll('.np-ctl').forEach((btn) => {
        btn.addEventListener('click', () => doAction(btn.dataset.act));
    });
    const picker = body.querySelector('#np-zone-select');
    if (picker) picker.addEventListener('change', (e) => switchZone(e.target.value));

    const mute = body.querySelector('#np-mute');
    if (mute) mute.addEventListener('click', () => doVolume('toggle_mute', null));
    const vol = body.querySelector('#np-vol');
    if (vol) {
        const label = body.querySelector('#np-vol-val');
        vol.addEventListener('input', () => {
            if (label) label.textContent = vol.value;
            doVolume('set', parseInt(vol.value, 10));
        });
    }
}

function volumeBar(volume) {
    return `
        <div class="mt-lg flex items-center gap-md">
            <button id="np-mute" class="text-text-muted active:scale-90 transition-transform" aria-label="Demp">
                <span class="material-symbols-outlined">${volume === 0 ? 'volume_off' : 'volume_up'}</span>
            </button>
            <input id="np-vol" type="range" min="0" max="100" value="${volume}" class="flex-1">
            <span id="np-vol-val" class="font-label-caps text-label-caps text-text-muted w-7 text-right">${volume}</span>
        </div>`;
}

function zonePicker() {
    const opts = _zoneList.filter((z) => z.now_playing).map((z) =>
        `<option value="${esc(z.zone_id)}"${z.zone_id === _zone.zone_id ? ' selected' : ''}>${esc(z.display_name || z.zone_id)}</option>`
    ).join('');
    return `
        <div class="mt-lg glass-panel rounded-xl p-md flex items-center justify-between gap-md">
            <div class="flex items-center gap-sm">
                <span class="material-symbols-outlined text-primary">speaker_group</span>
                <span class="font-body-sm text-body-sm">Zone</span>
            </div>
            <select id="np-zone-select" class="bg-surface-charcoal border border-white/10 rounded-lg py-2 px-3 font-body-sm text-body-sm text-text-primary focus:outline-none">${opts}</select>
        </div>`;
}

function switchZone(zoneId) {
    _forcedZoneId = zoneId;
    const z = _zoneList.find((x) => x.zone_id === zoneId);
    if (z) { _zone = z; refresh(); }
}

async function doAction(action) {
    if (!_zone) return;
    try {
        await transport(_zone.zone_id, action);
        setTimeout(refresh, 350);
    } catch (e) {
        toast('Bediening mislukt', 'error');
        console.error('transport error', e);
    }
}
