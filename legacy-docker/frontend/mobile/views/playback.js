import { esc } from '../util.js';
import { getZones, getPreferredZoneId, setPreferredZoneId } from '../roon.js';

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">Afspelen</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Kies de Roon-zone die alle functies gebruiken om af te spelen. Geldt voor dit apparaat.</p>
        </section>

        <section class="flex flex-col gap-sm">
            <span class="font-label-caps text-label-caps text-text-muted">STANDAARD ZONE</span>
            <div id="pb-zones" class="flex flex-col gap-sm">
                <div class="flex justify-center py-lg"><span class="material-symbols-outlined animate-spin text-primary">progress_activity</span></div>
            </div>
        </section>
    </div>`;
}

export async function mount(root) {
    await renderZones(root);
}

async function renderZones(root) {
    const el = root.querySelector('#pb-zones');
    if (!el) return;
    const zones = await getZones();
    const pref = getPreferredZoneId();

    const autoRow = row({
        id: '', name: 'Automatisch', sub: 'Volg de actieve zone', icon: 'auto_mode',
        selected: !pref,
    });

    if (!zones.length) {
        el.innerHTML = autoRow + `<p class="font-body-sm text-body-sm text-text-muted mt-sm">Geen Roon-zones gevonden. Controleer de verbinding met je Roon Core.</p>`;
        bind(root, el, zones);
        return;
    }

    const rows = zones.map((z) => {
        const np = z.now_playing;
        const playing = z.state === 'playing';
        const sub = np
            ? `${playing ? '▶ ' : ''}${esc(np.one_line?.line1 || np.two_line?.line1 || 'speelt')}`
            : 'Inactief';
        return row({ id: z.zone_id, name: z.display_name || z.zone_id, sub, icon: 'speaker', selected: pref === z.zone_id, raw: true });
    }).join('');

    el.innerHTML = autoRow + rows;
    bind(root, el, zones);
}

function row({ id, name, sub, icon, selected, raw }) {
    const subHtml = raw ? sub : esc(sub);
    return `
    <button class="pb-zone glass-panel rounded-xl p-md flex items-center gap-md active:scale-[0.99] transition-transform ${selected ? 'border-primary/50 bg-primary/10' : ''}" data-id="${esc(id)}">
        <div class="w-10 h-10 rounded-lg bg-surface-container-high flex items-center justify-center flex-shrink-0">
            <span class="material-symbols-outlined ${selected ? 'text-primary' : 'text-text-muted'}">${icon}</span>
        </div>
        <div class="flex-1 min-w-0 text-left">
            <p class="font-body-lg text-body-lg text-text-primary truncate">${esc(name)}</p>
            <p class="font-body-sm text-body-sm text-text-muted truncate">${subHtml}</p>
        </div>
        <span class="material-symbols-outlined ${selected ? 'text-primary' : 'text-text-muted/40'}" style="font-variation-settings:'FILL' ${selected ? 1 : 0};">${selected ? 'check_circle' : 'radio_button_unchecked'}</span>
    </button>`;
}

function bind(root, el, zones) {
    el.querySelectorAll('.pb-zone').forEach((btn) => {
        btn.addEventListener('click', () => {
            setPreferredZoneId(btn.dataset.id || null);
            renderZones(root); // re-render to update selection state
        });
    });
}
