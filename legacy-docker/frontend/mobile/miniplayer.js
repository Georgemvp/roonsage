// Global mini-player: polls the active Roon zone and shows a compact bar above
// the bottom nav on every screen except the full Now Playing view.
import { esc, artUrl } from './util.js';
import { getActiveZone, transport } from './roon.js';

let _zone = null;
let _timer = null;

function onNowPlaying() {
    return (location.hash || '').startsWith('#/nowplaying');
}

export function startMiniPlayer() {
    const bar = document.getElementById('rs-mini');
    if (!bar) return;

    bar.querySelector('#rs-mini-info')?.addEventListener('click', () => { location.hash = '#/nowplaying'; });
    bar.querySelector('#rs-mini-art')?.addEventListener('click', () => { location.hash = '#/nowplaying'; });
    bar.querySelector('#rs-mini-toggle')?.addEventListener('click', async (e) => {
        e.stopPropagation();
        if (!_zone) return;
        const playing = _zone.state === 'playing';
        try { await transport(_zone.zone_id, playing ? 'pause' : 'play'); setTimeout(refresh, 350); } catch (_) { /* ignore */ }
    });

    window.addEventListener('hashchange', applyVisibility);
    refresh();
    _timer = setInterval(refresh, 5000);
}

async function refresh() {
    _zone = await getActiveZone();
    const bar = document.getElementById('rs-mini');
    if (!bar) return;

    if (!_zone || !_zone.now_playing) { hide(bar); return; }
    const np = _zone.now_playing;
    const title = np.one_line?.line1 || np.two_line?.line1 || 'Onbekend';
    const artist = np.one_line?.line2 || np.two_line?.line2 || _zone.display_name || '';
    const src = artUrl(np.image_key, 88, 88);
    const playing = _zone.state === 'playing';

    bar.querySelector('#rs-mini-title').textContent = title;
    bar.querySelector('#rs-mini-artist').textContent = artist;
    const art = bar.querySelector('#rs-mini-art');
    art.innerHTML = src
        ? `<img src="${esc(src)}" alt="" class="w-full h-full object-cover" onerror="this.replaceWith(Object.assign(document.createElement('span'),{className:'material-symbols-outlined text-text-muted text-[20px]',textContent:'music_note'}))">`
        : `<span class="material-symbols-outlined text-text-muted text-[20px]">music_note</span>`;
    const icon = bar.querySelector('#rs-mini-toggle .material-symbols-outlined');
    if (icon) icon.textContent = playing ? 'pause' : 'play_arrow';

    applyVisibility();
}

function applyVisibility() {
    const bar = document.getElementById('rs-mini');
    if (!bar) return;
    if (_zone && _zone.now_playing && !onNowPlaying()) show(bar);
    else hide(bar);
}

function show(bar) {
    bar.classList.remove('hidden');
    bar.classList.add('flex');
    document.body.classList.add('rs-has-mini');
}
function hide(bar) {
    bar.classList.add('hidden');
    bar.classList.remove('flex');
    document.body.classList.remove('rs-has-mini');
}
