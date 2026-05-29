import { apiCall } from '../../modules/api.js';
import { esc, toast, dedupeTracks } from '../util.js';
import { getDefaultZoneId } from '../roon.js';

const LABELS = {
    bpm: 'Tempo', energy: 'Energie', danceability: 'Dans', valence: 'Stemming',
    instrumentalness: 'Instrumentaal', acousticness: 'Akoestisch',
};

let _limit = 25;

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <p class="font-label-caps text-label-caps text-primary tracking-widest uppercase opacity-80">Sonic DNA</p>
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Sonic Fingerprint</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Je muzikale DNA, berekend uit je meest gespeelde tracks.</p>
        </section>

        <section class="glass-panel rounded-xl p-md flex flex-col items-center gap-md">
            <div id="fp-radar" class="w-full max-w-[280px] aspect-square flex items-center justify-center">
                <span class="material-symbols-outlined animate-spin text-primary">progress_activity</span>
            </div>
            <p id="fp-source" class="font-body-sm text-body-sm text-text-muted"></p>
        </section>

        <section class="glass-panel rounded-xl p-md flex flex-col gap-md">
            <div class="flex justify-between items-center">
                <span class="font-label-caps text-label-caps text-text-muted">Aantal tracks</span>
                <span id="fp-limit-val" class="font-body-sm text-body-sm text-primary font-medium">${_limit}</span>
            </div>
            <input id="fp-limit" type="range" min="10" max="50" step="5" value="${_limit}" class="w-full" />
            <button id="fp-play" class="w-full py-sm rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-xs active:scale-95 transition-transform">
                <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">play_arrow</span>
                Speel fingerprint
            </button>
        </section>

        <section class="flex flex-col gap-sm">
            <h2 class="font-title-md text-title-md text-text-primary">DNA-matches</h2>
            <div id="fp-recs" class="flex flex-col gap-xs"></div>
        </section>
    </div>`;
}

export async function mount(root) {
    const slider = root.querySelector('#fp-limit');
    const val = root.querySelector('#fp-limit-val');
    if (slider) slider.addEventListener('input', () => { _limit = Number(slider.value); if (val) val.textContent = _limit; });
    const playBtn = root.querySelector('#fp-play');
    if (playBtn) playBtn.addEventListener('click', () => playFingerprint(playBtn));

    const [profile, recs] = await Promise.all([
        apiCall('/sonic-fingerprint/profile').catch(() => null),
        apiCall(`/sonic-fingerprint/recommendations?limit=20`).catch(() => null),
    ]);
    renderRadar(profile);
    renderRecs(recs);
}

function renderRadar(profile) {
    const el = document.getElementById('fp-radar');
    const srcEl = document.getElementById('fp-source');
    if (!el) return;
    if (!profile?.fingerprint?.length) {
        el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted text-center">Nog geen audio-analyse beschikbaar. Analyseer eerst je bibliotheek.</p>`;
        return;
    }
    const cols = profile.feature_columns || [];
    const vals = profile.fingerprint;
    const n = vals.length;
    const cx = 100, cy = 100, R = 80;
    const angle = (i) => (Math.PI * 2 * i) / n - Math.PI / 2;
    const pt = (i, r) => [cx + Math.cos(angle(i)) * R * r, cy + Math.sin(angle(i)) * R * r];

    const rings = [0.25, 0.5, 0.75, 1].map((r) =>
        `<polygon points="${vals.map((_, i) => pt(i, r).join(',')).join(' ')}" fill="none" stroke="rgba(255,255,255,0.07)" stroke-width="0.5"/>`).join('');
    const axes = vals.map((_, i) => {
        const [x, y] = pt(i, 1);
        return `<line x1="${cx}" y1="${cy}" x2="${x}" y2="${y}" stroke="rgba(255,255,255,0.07)" stroke-width="0.5"/>`;
    }).join('');
    const shape = `<polygon points="${vals.map((v, i) => pt(i, Math.max(0.05, v)).join(',')).join(' ')}" fill="rgba(211,187,255,0.18)" stroke="#d3bbff" stroke-width="1.5"/>`;
    const dots = vals.map((v, i) => { const [x, y] = pt(i, Math.max(0.05, v)); return `<circle cx="${x}" cy="${y}" r="2" fill="#d3bbff"/>`; }).join('');
    const labels = cols.map((c, i) => {
        const [x, y] = pt(i, 1.18);
        return `<text x="${x}" y="${y}" text-anchor="middle" dominant-baseline="middle" fill="rgba(235,234,229,0.6)" style="font-family:'DM Sans';font-size:7px;font-weight:700;">${esc(LABELS[c] || c)}</text>`;
    }).join('');

    el.innerHTML = `<svg viewBox="0 0 200 200" class="w-full h-full overflow-visible">${rings}${axes}${shape}${dots}${labels}</svg>`;
    if (srcEl) srcEl.textContent = profile.n_source_tracks ? `Gebaseerd op ${profile.n_source_tracks} top-tracks` : '';
}

function renderRecs(data) {
    const el = document.getElementById('fp-recs');
    if (!el) return;
    const results = dedupeTracks(data?.results || []);
    if (!results.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Nog geen aanbevelingen.</p>`; return; }
    el.innerHTML = results.slice(0, 20).map((t) => {
        const sim = t.similarity != null ? Math.round(t.similarity * 100) : null;
        return `
        <div class="flex items-center gap-md p-sm rounded-lg active:bg-surface-charcoal transition-colors">
            <div class="w-10 h-10 rounded bg-surface-container-high flex items-center justify-center flex-shrink-0">
                <span class="material-symbols-outlined text-text-muted text-[20px]">graphic_eq</span>
            </div>
            <div class="flex-1 min-w-0">
                <p class="font-body-lg text-body-lg text-text-primary truncate">${esc(t.title || '')}</p>
                <p class="font-body-sm text-body-sm text-text-muted truncate">${esc(t.artist || '')}</p>
            </div>
            ${sim != null ? `<div class="flex items-center gap-1 text-primary flex-shrink-0"><span class="material-symbols-outlined text-[16px]">water_drop</span><span class="font-label-caps text-label-caps">${sim}%</span></div>` : ''}
        </div>`;
    }).join('');
}

async function playFingerprint(btn) {
    btn.disabled = true;
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        await apiCall('/sonic-fingerprint/play', { method: 'POST', body: JSON.stringify({ zone_id: zoneId, limit: _limit }) });
        toast(`${_limit} tracks gestart`);
    } catch (e) {
        toast(e.message || 'Afspelen mislukt', 'error');
    } finally {
        btn.disabled = false;
    }
}
