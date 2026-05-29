import { apiCall, createPlayQueue } from '../../modules/api.js';
import { esc, toast } from '../util.js';
import { getDefaultZoneId } from '../roon.js';

let _points = [];        // {x, y, cluster_id, track}
let _bounds = null;       // {minX,maxX,minY,maxY}
let _view = { scale: 1, tx: 0, ty: 0 };
let _canvas = null, _ctx = null, _dpr = 1;
let _selected = null;
let _raf = null;

export function render() {
    return `
    <div class="flex flex-col" style="height: calc(100dvh - 64px - 76px);">
        <div class="px-margin-mobile pt-md pb-sm">
            <h1 class="font-title-md text-title-md text-text-primary">Music Map</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Een 2D-kaart van je bibliotheek. Tik op een punt om te spelen.</p>
        </div>
        <div class="relative flex-1 mx-margin-mobile mb-sm rounded-xl overflow-hidden glass-panel">
            <canvas id="mm-canvas" class="w-full h-full touch-none block"></canvas>
            <div id="mm-loading" class="absolute inset-0 flex items-center justify-center">
                <span class="material-symbols-outlined animate-spin text-primary">progress_activity</span>
            </div>
            <div id="mm-card" class="hidden absolute bottom-2 left-2 right-2 glass-panel rounded-xl p-sm flex items-center gap-md">
                <div class="flex-1 min-w-0">
                    <p id="mm-title" class="font-body-lg text-body-lg text-text-primary truncate"></p>
                    <p id="mm-artist" class="font-body-sm text-body-sm text-text-muted truncate"></p>
                </div>
                <button id="mm-play" class="w-10 h-10 rounded-full viola-gradient text-on-primary flex items-center justify-center active:scale-95 transition-transform flex-shrink-0">
                    <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">play_arrow</span>
                </button>
            </div>
        </div>
    </div>`;
}

export async function mount(root) {
    _canvas = root.querySelector('#mm-canvas');
    _ctx = _canvas.getContext('2d');
    _dpr = window.devicePixelRatio || 1;

    const status = await apiCall('/clustering/status').catch(() => null);
    if (!status || status.status !== 'complete') {
        root.querySelector('#mm-loading').innerHTML = `<p class="font-body-sm text-body-sm text-text-muted px-lg text-center">Clustering nog niet uitgevoerd. Draai dit eerst in de desktop-app (Music Map → Run).</p>`;
        return;
    }

    let data;
    try { data = await apiCall('/clustering/data?limit=2500'); }
    catch { root.querySelector('#mm-loading').innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Kon kaart niet laden.</p>`; return; }

    const tracks = data?.tracks || [];
    _points = tracks.filter((t) => t.x_2d != null && t.y_2d != null).map((t) => ({ x: t.x_2d, y: t.y_2d, cluster_id: t.cluster_id, track: t }));
    if (!_points.length) { root.querySelector('#mm-loading').innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen kaartdata.</p>`; return; }

    _bounds = _points.reduce((b, p) => ({
        minX: Math.min(b.minX, p.x), maxX: Math.max(b.maxX, p.x),
        minY: Math.min(b.minY, p.y), maxY: Math.max(b.maxY, p.y),
    }), { minX: Infinity, maxX: -Infinity, minY: Infinity, maxY: -Infinity });

    root.querySelector('#mm-loading').classList.add('hidden');
    resize();
    window.addEventListener('resize', resize);
    bindGestures();
    root.querySelector('#mm-play')?.addEventListener('click', playSelected);
    draw();
}

export function unmount() {
    window.removeEventListener('resize', resize);
    if (_raf) cancelAnimationFrame(_raf);
}

function resize() {
    if (!_canvas) return;
    const r = _canvas.getBoundingClientRect();
    _canvas.width = r.width * _dpr;
    _canvas.height = r.height * _dpr;
    draw();
}

// Map data coords -> base canvas coords (fit bounds with padding), then apply view transform.
function project(p, w, h) {
    const pad = 0.08;
    const bw = (_bounds.maxX - _bounds.minX) || 1;
    const bh = (_bounds.maxY - _bounds.minY) || 1;
    const nx = (p.x - _bounds.minX) / bw;
    const ny = (p.y - _bounds.minY) / bh;
    const baseX = (pad + nx * (1 - 2 * pad)) * w;
    const baseY = (pad + ny * (1 - 2 * pad)) * h;
    return [baseX * _view.scale + _view.tx, baseY * _view.scale + _view.ty];
}

function clusterColor(id) {
    if (id == null || id < 0) return 'rgba(149,142,156,0.4)'; // noise = outline gray
    const hue = (id * 47) % 360;
    return `hsla(${hue}, 70%, 70%, 0.85)`;
}

function draw() {
    if (!_ctx || !_canvas) return;
    const w = _canvas.width, h = _canvas.height;
    _ctx.clearRect(0, 0, w, h);
    for (const p of _points) {
        const [x, y] = project(p, w, h);
        if (x < -10 || y < -10 || x > w + 10 || y > h + 10) continue;
        _ctx.beginPath();
        _ctx.arc(x, y, (p === _selected ? 6 : 2.5) * _dpr, 0, Math.PI * 2);
        _ctx.fillStyle = p === _selected ? '#d3bbff' : clusterColor(p.cluster_id);
        _ctx.fill();
        if (p === _selected) { _ctx.lineWidth = 2 * _dpr; _ctx.strokeStyle = '#fff'; _ctx.stroke(); }
    }
}

function bindGestures() {
    let dragging = false, lastX = 0, lastY = 0, moved = 0;
    let pinchDist = 0;

    const getXY = (e) => {
        const r = _canvas.getBoundingClientRect();
        const t = e.touches ? e.touches[0] : e;
        return [(t.clientX - r.left) * _dpr, (t.clientY - r.top) * _dpr];
    };

    _canvas.addEventListener('touchstart', (e) => {
        if (e.touches.length === 2) {
            pinchDist = dist2(e.touches);
        } else {
            dragging = true; moved = 0;
            [lastX, lastY] = getXY(e);
        }
    }, { passive: true });

    _canvas.addEventListener('touchmove', (e) => {
        if (e.touches.length === 2) {
            const d = dist2(e.touches);
            if (pinchDist) zoomAt(d / pinchDist, _canvas.width / 2, _canvas.height / 2);
            pinchDist = d;
        } else if (dragging) {
            const [x, y] = getXY(e);
            _view.tx += x - lastX; _view.ty += y - lastY;
            moved += Math.abs(x - lastX) + Math.abs(y - lastY);
            lastX = x; lastY = y;
            scheduleDraw();
        }
    }, { passive: true });

    _canvas.addEventListener('touchend', (e) => {
        if (dragging && moved < 8 * _dpr) selectAt(lastX, lastY);
        dragging = false; pinchDist = 0;
    });

    // Mouse fallback (desktop testing)
    _canvas.addEventListener('mousedown', (e) => { dragging = true; moved = 0; [lastX, lastY] = getXY(e); });
    window.addEventListener('mousemove', (e) => {
        if (!dragging) return;
        const [x, y] = getXY(e);
        _view.tx += x - lastX; _view.ty += y - lastY; moved += Math.abs(x - lastX) + Math.abs(y - lastY);
        lastX = x; lastY = y; scheduleDraw();
    });
    window.addEventListener('mouseup', (e) => { if (dragging && moved < 6) { const [x, y] = getXY(e); selectAt(x, y); } dragging = false; });
    _canvas.addEventListener('wheel', (e) => { e.preventDefault(); const [x, y] = getXY(e); zoomAt(e.deltaY < 0 ? 1.1 : 0.9, x, y); }, { passive: false });
}

function dist2(touches) {
    const dx = touches[0].clientX - touches[1].clientX;
    const dy = touches[0].clientY - touches[1].clientY;
    return Math.hypot(dx, dy);
}

function zoomAt(factor, cx, cy) {
    const newScale = Math.min(12, Math.max(0.5, _view.scale * factor));
    const k = newScale / _view.scale;
    _view.tx = cx - (cx - _view.tx) * k;
    _view.ty = cy - (cy - _view.ty) * k;
    _view.scale = newScale;
    scheduleDraw();
}

function selectAt(px, py) {
    const w = _canvas.width, h = _canvas.height;
    let best = null, bestD = (16 * _dpr) ** 2;
    for (const p of _points) {
        const [x, y] = project(p, w, h);
        const d = (x - px) ** 2 + (y - py) ** 2;
        if (d < bestD) { bestD = d; best = p; }
    }
    _selected = best;
    const card = document.getElementById('mm-card');
    if (best) {
        document.getElementById('mm-title').textContent = best.track.title || '';
        document.getElementById('mm-artist').textContent = best.track.artist || '';
        card.classList.remove('hidden'); card.classList.add('flex');
    } else {
        card.classList.add('hidden'); card.classList.remove('flex');
    }
    draw();
}

function scheduleDraw() {
    if (_raf) return;
    _raf = requestAnimationFrame(() => { _raf = null; draw(); });
}

async function playSelected() {
    if (!_selected) return;
    const key = _selected.track.item_key;
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        await createPlayQueue([key], zoneId, 'replace');
        toast('Gestart');
    } catch (e) { toast(e.message || 'Afspelen mislukt', 'error'); }
}
