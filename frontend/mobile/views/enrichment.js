import { apiCall } from '../../modules/api.js';
import { esc, toast } from '../util.js';

let _timer = null;

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Enrichment</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Verrijk je bibliotheek met MusicBrainz & Last.fm-metadata.</p>
        </section>

        <section class="glass-panel rounded-xl p-lg flex flex-col items-center gap-md relative overflow-hidden">
            <div class="relative w-48 h-48">
                <svg class="w-full h-full -rotate-90" viewBox="0 0 100 100">
                    <circle cx="50" cy="50" r="42" fill="transparent" stroke="rgba(255,255,255,0.05)" stroke-width="8"/>
                    <circle id="enr-ring" cx="50" cy="50" r="42" fill="transparent" stroke="#d3bbff" stroke-width="8" stroke-linecap="round" stroke-dasharray="263.9" stroke-dashoffset="263.9" style="transition:stroke-dashoffset 0.6s ease"/>
                </svg>
                <div class="absolute inset-0 flex flex-col items-center justify-center">
                    <span id="enr-pct" class="font-display-lg text-headline-lg-mobile text-primary">—</span>
                    <span class="font-label-caps text-label-caps text-text-muted">VERRIJKT</span>
                </div>
            </div>
            <div class="flex gap-sm w-full">
                <button id="enr-run" class="flex-1 h-12 viola-gradient text-on-primary font-label-caps rounded-full flex items-center justify-center gap-xs active:scale-95 transition-transform">
                    <span class="material-symbols-outlined text-[20px]">play_arrow</span> Start
                </button>
                <button id="enr-pause" class="w-12 h-12 bg-surface-glass border border-white/10 text-text-primary rounded-full flex items-center justify-center active:scale-95 transition-transform">
                    <span class="material-symbols-outlined">pause</span>
                </button>
            </div>
            <p id="enr-counts" class="font-body-sm text-body-sm text-text-muted"></p>
        </section>

        <section id="enr-services" class="grid grid-cols-2 gap-gutter"></section>

        <section id="enr-failed" class="hidden"></section>

        <section class="flex flex-col gap-sm">
            <h2 class="font-label-caps text-label-caps text-text-muted">LAST.FM TAG CLOUD</h2>
            <div id="enr-tags" class="glass-panel rounded-xl p-lg flex flex-wrap gap-md justify-center items-center"></div>
        </section>

        <section id="enr-vibes" class="hidden flex flex-col gap-sm">
            <div class="flex items-center justify-between">
                <h2 class="font-label-caps text-label-caps text-text-muted">AI VIBE TAGS</h2>
                <span id="enr-vibes-count" class="font-label-caps text-label-caps text-primary"></span>
            </div>
            <div class="glass-panel rounded-xl p-lg flex flex-col gap-lg">
                <div>
                    <p class="font-label-caps text-[10px] text-text-muted mb-sm">CONTEXTEN</p>
                    <div id="enr-vibes-contexts" class="flex flex-wrap gap-sm"></div>
                </div>
                <div>
                    <p class="font-label-caps text-[10px] text-text-muted mb-sm">MOODS</p>
                    <div id="enr-vibes-moods" class="flex flex-wrap gap-sm"></div>
                </div>
            </div>
            <h2 class="font-label-caps text-label-caps text-text-muted mt-xs">RECENT GETAGD</h2>
            <div id="enr-vibes-recent" class="glass-panel rounded-xl divide-y divide-white/5"></div>
        </section>
    </div>`;
}

export async function mount() {
    await refresh();
    document.getElementById('enr-run')?.addEventListener('click', start);
    document.getElementById('enr-pause')?.addEventListener('click', pauseResume);
    loadTags();
    loadVibes();
    _timer = setInterval(refresh, 4000);
}

export function unmount() {
    if (_timer) clearInterval(_timer);
    _timer = null;
}

async function refresh() {
    const s = await apiCall('/enrichment/status').catch(() => null);
    if (!s) return;
    const total = s.total_tracks || 0;
    const done = s.enriched_total ?? s.complete ?? 0;
    const pct = total ? Math.round((done / total) * 100) : 0;

    const ring = document.getElementById('enr-ring');
    const C = 2 * Math.PI * 42;
    if (ring) ring.style.strokeDashoffset = String(C - (pct / 100) * C);
    const pctEl = document.getElementById('enr-pct');
    if (pctEl) pctEl.textContent = `${pct}%`;
    const counts = document.getElementById('enr-counts');
    if (counts) counts.textContent = `${done.toLocaleString('nl-NL')} / ${total.toLocaleString('nl-NL')} tracks${s.pending ? ` · ${s.pending} wachtrij` : ''}`;

    const pauseBtn = document.getElementById('enr-pause');
    if (pauseBtn) {
        const icon = pauseBtn.querySelector('.material-symbols-outlined');
        if (icon) icon.textContent = s.worker_paused ? 'play_arrow' : 'pause';
    }

    renderServices(s);
    renderFailed(s);
}

function serviceCard(name, count, pct, chips) {
    return `
    <div class="glass-panel rounded-xl p-md flex flex-col gap-sm">
        <div class="flex justify-between items-start">
            <div>
                <h3 class="font-title-md text-text-primary">${esc(name)}</h3>
                <p class="font-body-sm text-text-muted">${count.toLocaleString('nl-NL')} tracks</p>
            </div>
            <span class="font-label-caps text-primary">${pct}%</span>
        </div>
        <div class="h-1.5 w-full bg-white/5 rounded-full overflow-hidden">
            <div class="h-full viola-gradient rounded-full" style="width:${pct}%"></div>
        </div>
        <div class="flex flex-wrap gap-xs">${chips.map((c) => `<span class="px-sm py-1 rounded-full bg-surface-charcoal border border-white/5 font-label-caps text-[10px] text-text-muted">${esc(c)}</span>`).join('')}</div>
    </div>`;
}

function renderServices(s) {
    const el = document.getElementById('enr-services');
    if (!el) return;
    const total = s.total_tracks || 1;
    const mb = s.mb_matches || 0;
    const lf = s.lastfm_matches || 0;
    el.innerHTML =
        serviceCard('MusicBrainz', mb, Math.round((mb / total) * 100), ['LABELS', 'RELEASE DATES', 'CATALOG #']) +
        serviceCard('Last.fm', lf, Math.round((lf / total) * 100), ['TAGS', 'PLAYCOUNTS', 'SIMILAR']);
}

function renderFailed(s) {
    const el = document.getElementById('enr-failed');
    if (!el) return;
    if (!s.failed) { el.classList.add('hidden'); el.innerHTML = ''; return; }
    el.classList.remove('hidden');
    el.innerHTML = `
        <div class="glass-panel rounded-xl p-md flex items-center justify-between border border-error-container/30 bg-error-container/5">
            <div class="flex items-center gap-md">
                <span class="material-symbols-outlined text-error">warning</span>
                <div>
                    <h3 class="font-body-lg text-text-primary">${s.failed} tracks mislukt</h3>
                    <p class="font-body-sm text-text-muted">Probeer opnieuw</p>
                </div>
            </div>
            <button id="enr-retry" class="px-md py-sm bg-surface-charcoal border border-white/10 rounded-full font-label-caps text-text-primary active:scale-95 transition-transform">Retry</button>
        </div>`;
    el.querySelector('#enr-retry')?.addEventListener('click', retry);
}

async function loadTags() {
    const el = document.getElementById('enr-tags');
    if (!el) return;
    const data = await apiCall('/enrichment/tags?limit=18').catch(() => null);
    const tags = data?.tags || [];
    if (!tags.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Nog geen tags.</p>`; return; }
    const max = tags[0]?.count || 1;
    el.innerHTML = tags.map((t) => {
        const size = 12 + Math.round((t.count / max) * 14); // 12–26px
        const strong = t.count >= max * 0.5;
        return `<span class="${strong ? 'text-primary font-bold' : 'text-text-primary/70 font-medium'}" style="font-size:${size}px;line-height:1">${esc(t.name)}</span>`;
    }).join('');
}

async function loadVibes() {
    const section = document.getElementById('enr-vibes');
    if (!section) return;
    const data = await apiCall('/background-ai/vibes-explore').catch(() => null);
    if (!data?.total_tagged) return;

    const countEl = document.getElementById('enr-vibes-count');
    if (countEl) countEl.textContent = `${data.total_tagged.toLocaleString('nl-NL')} tracks`;

    const ctxEl = document.getElementById('enr-vibes-contexts');
    if (ctxEl && data.top_contexts?.length) {
        const max = data.top_contexts[0].count;
        ctxEl.innerHTML = data.top_contexts.slice(0, 16).map((c) => {
            const bold = c.count >= max * 0.5;
            return `<span class="${bold ? 'text-[#a78bfa] font-semibold' : 'text-[#7c6dca]'} font-body-sm" style="font-size:${11 + Math.round((c.count / max) * 7)}px" title="${c.count} tracks">${esc(c.name)}</span>`;
        }).join('');
    }

    const moodEl = document.getElementById('enr-vibes-moods');
    if (moodEl && data.top_moods?.length) {
        const max = data.top_moods[0].count;
        moodEl.innerHTML = data.top_moods.slice(0, 12).map((m) => {
            const bold = m.count >= max * 0.5;
            return `<span class="${bold ? 'text-[#f472b6] font-semibold' : 'text-[#be6090]'} font-body-sm" style="font-size:${11 + Math.round((m.count / max) * 7)}px" title="${m.count} tracks">${esc(m.name)}</span>`;
        }).join('');
    }

    const recentEl = document.getElementById('enr-vibes-recent');
    if (recentEl && data.recent_tracks?.length) {
        recentEl.innerHTML = data.recent_tracks.slice(0, 15).map((t) => {
            const allTags = [...(t.contexts || []), ...(t.moods || [])].slice(0, 4);
            const chips = allTags.map((tag) => `<span class="px-xs py-0.5 rounded-full bg-white/5 border border-white/10 font-label-caps text-[9px] text-text-muted">${esc(tag)}</span>`).join('');
            return `
            <div class="px-md py-sm flex flex-col gap-xs">
                <div class="flex items-center justify-between">
                    <p class="font-body-sm text-text-primary truncate flex-1 mr-sm">${esc(t.title || '')}</p>
                    <p class="font-label-caps text-[10px] text-text-muted flex-shrink-0">${_relTime(t.updated_at)}</p>
                </div>
                <p class="font-body-sm text-[11px] text-text-muted truncate">${esc(t.artist || '')}</p>
                ${chips ? `<div class="flex flex-wrap gap-xs mt-xs">${chips}</div>` : ''}
            </div>`;
        }).join('');
    }

    section.classList.remove('hidden');
}

function _relTime(ts) {
    if (!ts) return '';
    try {
        const diff = Math.round((Date.now() - new Date(ts).getTime()) / 60000);
        if (diff < 1) return 'zojuist';
        if (diff < 60) return `${diff}m`;
        if (diff < 1440) return `${Math.round(diff / 60)}u`;
        return `${Math.round(diff / 1440)}d`;
    } catch { return ''; }
}

async function start() {
    try {
        await apiCall('/enrichment/start', { method: 'POST', body: '{}' });
        toast('Enrichment gestart');
        setTimeout(refresh, 600);
    } catch (e) { toast(e.message || 'Mislukt', 'error'); }
}

async function pauseResume() {
    const s = await apiCall('/enrichment/status').catch(() => null);
    try {
        if (s?.worker_paused) { await apiCall('/enrichment/resume', { method: 'POST', body: '{}' }); toast('Hervat'); }
        else { await apiCall('/enrichment/pause', { method: 'POST', body: '{}' }); toast('Gepauzeerd'); }
        setTimeout(refresh, 600);
    } catch (e) { toast(e.message || 'Mislukt', 'error'); }
}

async function retry() {
    try {
        await apiCall('/enrichment/retry-failed', { method: 'POST', body: '{}' });
        toast('Mislukte tracks opnieuw in wachtrij');
        setTimeout(refresh, 600);
    } catch (e) { toast(e.message || 'Mislukt', 'error'); }
}
