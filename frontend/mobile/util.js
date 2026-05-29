// Shared helpers for the mobile shell.

export function esc(str) {
    return String(str ?? '')
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

export function artUrl(key, w = 96, h = 96) {
    return key ? `/api/art/${key}?width=${w}&height=${h}` : null;
}

export function fmtTime(seconds) {
    if (!seconds || seconds < 0) return '0:00';
    const m = Math.floor(seconds / 60);
    const s = Math.floor(seconds % 60);
    return `${m}:${String(s).padStart(2, '0')}`;
}

// Collapse near-duplicate tracks: same song via remasters / alternate versions
// (e.g. "[Piano Version]", "(2021 Stereo Remaster)", "- Live") have near-identical
// audio features, so similarity-ranked lists bunch them together. We keep the first.
function _normTitle(title) {
    return String(title || '')
        .toLowerCase()
        .replace(/\s*[\[(][^\])]*[\])]\s*/g, ' ')          // strip (...) and [...]
        .replace(/\s*-\s*(remaster(ed)?|mono|stereo|live|version|mix|edit|take|demo|acoustic|piano|guitar|instrumental).*/i, '')
        .replace(/[^a-z0-9]+/g, ' ')
        .trim();
}

export function dedupeTracks(list, keyFields = ['title', 'artist']) {
    const seen = new Set();
    const out = [];
    for (const t of list || []) {
        const title = _normTitle(t[keyFields[0]] ?? t.track_title ?? t.track);
        const artist = String(t[keyFields[1]] ?? t.artist_name ?? '').toLowerCase().split(',')[0].trim();
        const key = `${title}|${artist}`;
        if (!title || seen.has(key)) continue;
        seen.add(key);
        out.push(t);
    }
    return out;
}

let _toastTimer = null;
export function toast(message, kind = 'info') {
    let el = document.getElementById('rs-toast');
    if (!el) {
        el = document.createElement('div');
        el.id = 'rs-toast';
        el.className = 'fixed left-1/2 -translate-x-1/2 bottom-24 z-[100] px-md py-sm rounded-full glass-panel font-body-sm text-body-sm shadow-lg transition-all duration-300 opacity-0 pointer-events-none max-w-[90%] text-center';
        document.body.appendChild(el);
    }
    el.textContent = message;
    el.classList.toggle('text-error', kind === 'error');
    el.classList.toggle('text-primary', kind !== 'error');
    el.style.opacity = '1';
    el.style.transform = 'translate(-50%, 0)';
    if (_toastTimer) clearTimeout(_toastTimer);
    _toastTimer = setTimeout(() => {
        el.style.opacity = '0';
        el.style.transform = 'translate(-50%, 8px)';
    }, 2600);
}
