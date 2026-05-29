import { apiCall } from '../../modules/api.js';
import { esc, toast } from '../util.js';

const TRIGGER_LABEL = {
    schedule: 'Schema', cron: 'Cron', time_of_day: 'Tijdstip',
    zone_state: 'Zone-status', focus_mode: 'Focus', manual: 'Handmatig',
};
const ACTION_LABEL = {
    generate_playlist: 'Genereer playlist', build_dj_set: 'Bouw DJ-set',
    play_playlist: 'Speel playlist', notify: 'Notificatie',
};

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-xl">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Automations</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Getriggerde muziek-workflows.</p>
        </section>

        <section class="flex flex-col gap-md">
            <div class="flex justify-between items-end">
                <h3 class="font-label-caps text-label-caps text-primary tracking-widest">ACTIEVE FLOWS</h3>
                <span id="auto-count" class="font-label-caps text-[10px] text-text-muted"></span>
            </div>
            <div id="auto-list" class="flex flex-col gap-gutter"></div>
        </section>

        <section class="flex flex-col gap-md">
            <h3 class="font-label-caps text-label-caps text-text-muted tracking-widest">RECENTE ACTIVITEIT</h3>
            <div id="auto-log" class="glass-card rounded-xl overflow-hidden"></div>
        </section>
    </div>`;
}

export async function mount() {
    await Promise.all([loadList(), loadLog()]);
}

function triggerLabel(t) { return TRIGGER_LABEL[t] || t || ''; }
function actionLabel(a) { return ACTION_LABEL[a] || a || ''; }

async function loadList() {
    const el = document.getElementById('auto-list');
    const countEl = document.getElementById('auto-count');
    if (!el) return;
    const list = await apiCall('/automations').catch(() => []);
    const running = list.filter((a) => a.enabled).length;
    if (countEl) countEl.textContent = `${running} ACTIEF`;
    if (!list.length) {
        el.innerHTML = `<div class="glass-card rounded-xl p-lg text-center"><p class="font-body-sm text-body-sm text-text-muted">Nog geen automations. Maak ze aan in de desktop-app.</p></div>`;
        return;
    }
    el.innerHTML = list.map((a) => `
        <div class="glass-card rounded-xl p-md flex flex-col gap-sm ${a.enabled ? '' : 'opacity-60'}" data-id="${esc(a.id)}">
            <div class="flex justify-between items-start gap-md">
                <div class="min-w-0">
                    <h4 class="font-title-md text-body-lg font-bold text-text-primary truncate">${esc(a.name || 'Naamloos')}</h4>
                    <div class="flex items-center gap-xs mt-base text-text-muted">
                        <span class="material-symbols-outlined text-[16px]">bolt</span>
                        <p class="font-body-sm text-body-sm">${esc(triggerLabel(a.trigger_type))}</p>
                    </div>
                </div>
                <button class="auto-toggle relative inline-flex h-6 w-11 items-center rounded-full transition-colors flex-shrink-0 ${a.enabled ? 'bg-primary/30' : 'bg-surface-container-highest'}" data-id="${esc(a.id)}" data-on="${a.enabled ? '1' : '0'}">
                    <span class="inline-block h-4 w-4 transform rounded-full transition-transform ${a.enabled ? 'translate-x-6 bg-primary' : 'translate-x-1 bg-on-surface-variant'}"></span>
                </button>
            </div>
            <div class="flex items-center gap-sm p-sm bg-surface-container-lowest rounded-lg border border-white/5">
                <span class="material-symbols-outlined text-primary">auto_awesome</span>
                <span class="font-body-sm text-body-sm text-text-primary truncate">${esc(actionLabel(a.action_type))}</span>
            </div>
            <div class="flex justify-end">
                <button class="auto-run font-label-caps text-label-caps text-primary flex items-center gap-1" data-id="${esc(a.id)}"><span class="material-symbols-outlined text-[16px]" style="font-variation-settings:'FILL' 1;">play_arrow</span> NU UITVOEREN</button>
            </div>
        </div>`).join('');
    el.querySelectorAll('.auto-toggle').forEach((b) => b.addEventListener('click', () => toggle(b)));
    el.querySelectorAll('.auto-run').forEach((b) => b.addEventListener('click', () => run(b)));
}

async function loadLog() {
    const el = document.getElementById('auto-log');
    if (!el) return;
    const rows = await apiCall('/automations/log?limit=20').catch(() => []);
    if (!rows.length) { el.innerHTML = `<p class="p-md font-body-sm text-body-sm text-text-muted">Nog geen activiteit.</p>`; return; }
    el.innerHTML = `<div class="divide-y divide-white/5">${rows.map((r) => {
        const ok = r.status !== 'failed' && r.status !== 'error';
        const when = r.triggered_at ? new Date(r.triggered_at).toLocaleString('nl-NL', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '';
        return `
        <div class="p-md flex items-center gap-md">
            <div class="w-2 h-2 rounded-full ${ok ? 'bg-green-400' : 'bg-error'} flex-shrink-0"></div>
            <div class="min-w-0 flex-1">
                <p class="font-body-sm text-text-primary truncate">${esc(actionLabel(r.action_type))}</p>
                <p class="text-[10px] text-text-muted">${esc(when)}${r.status ? ' · ' + esc(r.status) : ''}</p>
            </div>
        </div>`;
    }).join('')}</div>`;
}

async function toggle(btn) {
    const id = btn.dataset.id;
    try {
        await apiCall(`/automations/${encodeURIComponent(id)}/toggle`, { method: 'PATCH' });
        await loadList();
    } catch (e) {
        toast(e.message || 'Wisselen mislukt', 'error');
    }
}

async function run(btn) {
    const id = btn.dataset.id;
    btn.disabled = true;
    try {
        await apiCall(`/automations/${encodeURIComponent(id)}/run`, { method: 'POST' });
        toast('Uitgevoerd');
        setTimeout(loadLog, 1200);
    } catch (e) {
        toast(e.message || 'Uitvoeren mislukt', 'error');
    } finally {
        btn.disabled = false;
    }
}
