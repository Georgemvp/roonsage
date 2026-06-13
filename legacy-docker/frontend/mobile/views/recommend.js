import { apiCall, createPlayQueue } from '../../modules/api.js';
import { esc, toast } from '../util.js';
import { getDefaultZoneId } from '../roon.js';

const FAMILIARITY = [
    { v: 'any', label: 'Alles' },
    { v: 'comfort', label: 'Vertrouwd' },
    { v: 'rediscover', label: 'Herontdek' },
    { v: 'hidden_gems', label: 'Verborgen parels' },
];

let _fam = 'any';
let _recs = [];
let _busy = false;

export function render() {
    const fam = FAMILIARITY.map((f) =>
        `<button data-fam="${f.v}" class="rec-fam px-md py-sm rounded-full glass-panel font-label-caps text-label-caps active:scale-95 transition-transform ${f.v === _fam ? 'viola-gradient text-on-primary' : 'text-text-muted'}">${esc(f.label)}</button>`).join('');
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Album-aanbeveling</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Beschrijf een stemming of moment; de AI pitcht albums uit je smaak.</p>
        </section>

        <textarea id="rec-prompt" rows="3" placeholder="bijv. 'een rustige zondagochtend met koffie'"
            class="w-full bg-surface-glass border border-white/5 rounded-2xl p-4 font-body-lg text-body-lg text-text-primary placeholder:text-text-muted/60 resize-none focus:outline-none focus:ring-1 focus:ring-primary/50"></textarea>

        <div class="flex flex-col gap-sm">
            <span class="font-label-caps text-label-caps text-text-muted">Bekendheid</span>
            <div class="flex flex-wrap gap-xs">${fam}</div>
        </div>

        <button id="rec-go" class="w-full h-14 rounded-full viola-gradient text-on-primary font-title-md text-title-md flex items-center justify-center gap-2 active:scale-95 transition-transform shadow-[0_4px_24px_rgba(211,187,255,0.25)]">
            <span class="material-symbols-outlined" style="font-variation-settings:'FILL' 1;">album</span> Beveel aan
        </button>

        <div id="rec-status" class="hidden glass-panel rounded-xl p-md items-center gap-md">
            <span class="material-symbols-outlined animate-spin text-primary">progress_activity</span>
            <span id="rec-status-text" class="font-body-sm text-body-sm text-text-primary">Bezig…</span>
        </div>
        <section id="rec-results" class="hidden flex-col gap-gutter"></section>
    </div>`;
}

export function mount(root) {
    root.querySelector('#rec-go')?.addEventListener('click', run);
    root.querySelectorAll('.rec-fam').forEach((b) => b.addEventListener('click', () => {
        _fam = b.dataset.fam;
        root.querySelectorAll('.rec-fam').forEach((x) => {
            const on = x.dataset.fam === _fam;
            x.classList.toggle('viola-gradient', on);
            x.classList.toggle('text-on-primary', on);
            x.classList.toggle('text-text-muted', !on);
        });
    }));
}

async function run() {
    if (_busy) return;
    const prompt = document.getElementById('rec-prompt')?.value.trim();
    if (!prompt) { toast('Beschrijf eerst een stemming', 'error'); return; }
    _busy = true;
    const statusEl = document.getElementById('rec-status');
    const statusText = document.getElementById('rec-status-text');
    const resultsEl = document.getElementById('rec-results');
    const goBtn = document.getElementById('rec-go');
    statusEl.classList.remove('hidden'); statusEl.classList.add('flex');
    resultsEl.classList.add('hidden');
    if (goBtn) goBtn.disabled = true;

    try {
        // 1) Get a session + (skipped) clarifying questions.
        statusText.textContent = 'Vraag analyseren…';
        const q = await apiCall('/recommend/questions', { method: 'POST', body: JSON.stringify({ prompt }) });
        const sessionId = q.session_id;
        const answers = (q.questions || []).map(() => null);
        const answerTexts = (q.questions || []).map(() => '');

        // 2) Stream the recommendation generation (questions left unanswered).
        statusText.textContent = 'Albums kiezen…';
        await streamGenerate({
            session_id: sessionId, answers, answer_texts: answerTexts,
            mode: 'library', genres: [], decades: [], familiarity_pref: _fam, use_taste_profile: true,
        }, statusText);

        renderResults();
    } catch (e) {
        toast(e.message || 'Aanbeveling mislukt', 'error');
    } finally {
        _busy = false;
        if (goBtn) goBtn.disabled = false;
        statusEl.classList.add('hidden'); statusEl.classList.remove('flex');
    }
}

async function streamGenerate(body, statusText) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 180000);
    _recs = [];
    try {
        const response = await fetch('/api/recommend/generate', {
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body), signal: controller.signal,
        });
        if (!response.ok) {
            const err = await response.json().catch(() => ({}));
            throw new Error(err.detail || err.error || `HTTP ${response.status}`);
        }
        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });
            const lines = buffer.split('\n');
            buffer = lines.pop() || '';
            let evt = '', data = '';
            for (const line of lines) {
                if (line.startsWith('event: ')) { evt = line.slice(7).trim(); continue; }
                if (line.startsWith('data: ')) { data += line.slice(6); continue; }
                if (line === '' && data) {
                    let parsed; try { parsed = JSON.parse(data); } catch { data = ''; evt = ''; continue; }
                    if (evt === 'error' && parsed.message) throw new Error(parsed.message);
                    if (parsed.step && statusText) statusText.textContent = parsed.step;
                    if (parsed.recommendations) _recs = parsed.recommendations;
                    data = ''; evt = '';
                }
            }
        }
    } finally {
        clearTimeout(timer);
    }
}

function renderResults() {
    const el = document.getElementById('rec-results');
    if (!el) return;
    if (!_recs.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Geen aanbevelingen ontvangen.</p>`; el.classList.remove('hidden'); el.classList.add('flex'); return; }
    const primary = _recs.find((r) => r.rank === 'primary') || _recs[0];
    const rest = _recs.filter((r) => r !== primary);

    el.innerHTML = `${card(primary, true)}${rest.map((r) => card(r, false)).join('')}`;
    el.classList.remove('hidden'); el.classList.add('flex');
    el.querySelectorAll('.rec-play').forEach((b) => b.addEventListener('click', () => play(b)));
}

function card(r, primary) {
    if (!r) return '';
    const keys = (r.track_item_keys || []).join(',');
    const art = r.art_url
        ? `<img src="${esc(r.art_url)}" alt="" class="w-full h-full object-cover" onerror="this.style.display='none'">`
        : `<span class="material-symbols-outlined text-text-muted" style="font-size:${primary ? 48 : 28}px;">album</span>`;
    return `
    <div class="glass-card rounded-xl p-md flex ${primary ? 'flex-col' : 'flex-row items-center'} gap-md">
        <div class="${primary ? 'w-full aspect-square max-w-[220px] mx-auto' : 'w-16 h-16 flex-shrink-0'} rounded-lg overflow-hidden bg-surface-container-low flex items-center justify-center">${art}</div>
        <div class="flex-1 min-w-0">
            ${primary ? `<span class="font-label-caps text-label-caps text-primary">TOP-AANRADER</span>` : ''}
            <h3 class="font-title-md text-title-md text-text-primary ${primary ? '' : 'truncate'}">${esc(r.album || '')}</h3>
            <p class="font-body-sm text-body-sm text-text-muted truncate">${esc(r.artist || '')}${r.year ? ` (${r.year})` : ''}</p>
            ${primary && r.pitch ? `<p class="font-body-sm text-body-sm text-text-muted mt-sm">${esc(r.pitch)}</p>` : ''}
            ${keys ? `<button class="rec-play mt-sm inline-flex items-center gap-1 px-md py-xs rounded-full ${primary ? 'viola-gradient text-on-primary' : 'bg-primary/15 text-primary'} font-label-caps text-label-caps active:scale-95 transition-transform" data-keys="${esc(keys)}">
                <span class="material-symbols-outlined text-[16px]" style="font-variation-settings:'FILL' 1;">play_arrow</span> ${r.source === 'qobuz' ? 'Qobuz' : 'Speel'}
            </button>` : ''}
        </div>
    </div>`;
}

async function play(btn) {
    const keys = (btn.dataset.keys || '').split(',').filter(Boolean);
    if (!keys.length) { toast('Geen tracks', 'error'); return; }
    btn.disabled = true;
    try {
        const zoneId = await getDefaultZoneId();
        if (!zoneId) { toast('Geen zone gevonden', 'error'); return; }
        const resp = await createPlayQueue(keys, zoneId, 'replace');
        toast(resp?.success ? `${resp.tracks_queued ?? keys.length} tracks gestart` : 'Gestart');
    } catch (e) { toast(e.message || 'Afspelen mislukt', 'error'); }
    finally { btn.disabled = false; }
}
