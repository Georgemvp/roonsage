// =============================================================================
// DJ Set Templates tab
// =============================================================================
//
// Renders the templates grid inside #dj-templates-pane. Clicking a card
// hits /api/dj-templates/{id}/build, hands the result off to the builder
// module (via _showTemplateResult), and switches back to the Builder tab.
// The schedule (⏰) button on each card opens a modal that creates an
// automation of type build_dj_set_qobuz running on a cron.

import { apiCall } from './api.js';
import { showSuccess } from './ui.js';
import { showTemplateBuildResult, switchDJTab } from './dj-set.js';

let _initialized = false;
let _templates = [];
let _selectedTemplate = null;

function _esc(s) {
    return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function _curveLabel(c) {
    return ({
        flat: 'Gelijkmatig', ramp_up: 'Oplopend', ramp_down: 'Aflopend',
        peak: 'Piek', valley: 'Dal', crescendo: 'Crescendo',
        sunrise: 'Zonsopgang', explosion: 'Explosie', afterparty: 'Afterparty',
        wave: 'Golf', marathon: 'Marathon', rollercoaster: 'Achtbaan',
    }[c]) || c;
}

function _renderCard(t) {
    const moodLine = t.start_mood
        ? `${_esc(t.start_mood)}${t.end_mood && t.end_mood !== t.start_mood ? ` → ${_esc(t.end_mood)}` : ''}`
        : '';
    const meta = [
        `${Math.round(t.start_bpm)}–${Math.round(t.end_bpm)} BPM`,
        _curveLabel(t.energy_curve),
        `${t.duration_minutes} min`,
    ].filter(Boolean).join(' · ');
    const builtinBadge = t.is_builtin ? '' : '<span class="dj-template-builtin-badge">eigen</span>';
    const deleteBtn = t.is_builtin
        ? ''
        : `<button class="template-card-delete" data-dj-delete="${_esc(t.id)}" title="Verwijderen">✕</button>`;
    return `
        <button type="button" class="template-card" data-dj-template="${_esc(t.id)}" title="${_esc(t.description || t.name)}">
            <button class="dj-template-schedule" data-dj-schedule="${_esc(t.id)}" title="Plan dagelijks op Qobuz">⏰</button>
            ${deleteBtn}
            <span class="template-card-icon">${_esc(t.icon || '🎚️')}</span>
            <span class="template-card-name">${_esc(t.name)}${builtinBadge}</span>
            ${t.description ? `<span class="template-card-desc">${_esc(t.description)}</span>` : ''}
            <span class="template-card-meta">${_esc(meta)}</span>
            ${moodLine ? `<span class="template-card-meta" style="color:var(--text-muted);">${moodLine}</span>` : ''}
        </button>
    `;
}

function _renderGrid() {
    const grid = document.getElementById('dj-templates-grid');
    if (!grid) return;
    if (!_templates.length) {
        grid.innerHTML = '<p class="auto-loading">Geen DJ templates gevonden.</p>';
        return;
    }
    const byCategory = new Map();
    _templates.forEach(t => {
        const c = t.category || 'General';
        if (!byCategory.has(c)) byCategory.set(c, []);
        byCategory.get(c).push(t);
    });
    const sections = [];
    for (const [cat, list] of byCategory.entries()) {
        sections.push(`
            <div>
                <h4 class="dj-templates-category">${_esc(cat)}</h4>
                <div class="template-grid">
                    ${list.map(_renderCard).join('')}
                </div>
            </div>
        `);
    }
    grid.innerHTML = sections.join('');
}

async function _loadTemplates() {
    const grid = document.getElementById('dj-templates-grid');
    if (grid) grid.innerHTML = '<p class="auto-loading">Laden…</p>';
    try {
        _templates = await apiCall('/dj-templates');
        _renderGrid();
    } catch (err) {
        if (grid) grid.innerHTML = `<p style="color:var(--error);">Fout: ${_esc(err.message)}</p>`;
    }
}

async function _buildFromTemplate(templateId) {
    const status = document.getElementById('dj-templates-status');
    if (status) { status.textContent = 'DJ set wordt gebouwd…'; status.style.color = ''; }
    try {
        const data = await apiCall(`/dj-templates/${encodeURIComponent(templateId)}/build`, {
            method: 'POST',
        });
        if (status) status.textContent = '';
        const tpl = _templates.find(t => t.id === templateId);
        // Hand the result over to dj-set.js for rendering & playback wiring.
        showTemplateBuildResult(data, tpl);
        switchDJTab('builder');
        showSuccess(`▶ DJ set van ${data.returned} tracks klaar.`);
    } catch (err) {
        if (status) {
            status.textContent = '✗ ' + (err.message || 'Build mislukt');
            status.style.color = '#f44336';
        }
    }
}

async function _deleteTemplate(templateId) {
    if (!confirm('Weet je zeker dat je deze DJ template wilt verwijderen?')) return;
    try {
        await apiCall(`/dj-templates/${encodeURIComponent(templateId)}`, { method: 'DELETE' });
        await _loadTemplates();
    } catch (err) {
        alert('Verwijderen mislukt: ' + err.message);
    }
}

// ---------------------------------------------------------------------------
// Schedule-as-automation modal
// ---------------------------------------------------------------------------

function _openScheduleModal(templateId) {
    const tpl = _templates.find(t => t.id === templateId);
    if (!tpl) return;
    _selectedTemplate = tpl;
    const modal = document.getElementById('dj-auto-modal');
    if (!modal) return;
    const nameEl = document.getElementById('dj-auto-name');
    const cronEl = document.getElementById('dj-auto-cron');
    const plName = document.getElementById('dj-auto-playlist-name');
    const zoneEl = document.getElementById('dj-auto-zone');
    const tplEl  = document.getElementById('dj-auto-modal-tpl');
    const result = document.getElementById('dj-auto-result');
    if (tplEl) tplEl.innerHTML = `Template: <strong>${_esc(tpl.icon || '')} ${_esc(tpl.name)}</strong> — ${_esc(tpl.category)}`;
    if (nameEl) nameEl.value = `Dagelijks: ${tpl.name}`;
    if (plName) plName.value = tpl.name;
    if (zoneEl) zoneEl.value = '';
    if (cronEl) cronEl.value = '0 6 * * *';
    if (result) { result.textContent = ''; result.style.color = ''; }
    modal.classList.remove('hidden');
}

function _closeScheduleModal() {
    document.getElementById('dj-auto-modal')?.classList.add('hidden');
}

async function _submitScheduleModal() {
    if (!_selectedTemplate) return;
    const name = (document.getElementById('dj-auto-name')?.value || '').trim();
    const cron = (document.getElementById('dj-auto-cron')?.value || '').trim();
    const plName = (document.getElementById('dj-auto-playlist-name')?.value || '').trim();
    const zone = (document.getElementById('dj-auto-zone')?.value || '').trim();
    const result = document.getElementById('dj-auto-result');
    const submitBtn = document.getElementById('dj-auto-create');

    if (!name) { if (result) { result.textContent = 'Naam is verplicht.'; result.style.color = '#f44336'; } return; }
    if (!cron) { if (result) { result.textContent = 'Cron-expressie is verplicht.'; result.style.color = '#f44336'; } return; }

    const cfg = {
        dj_template_id: _selectedTemplate.id,
        qobuz_playlist_name: plName || _selectedTemplate.name,
    };
    if (zone) cfg.zone_name = zone;

    if (submitBtn) { submitBtn.disabled = true; submitBtn.textContent = 'Bezig…'; }
    if (result) { result.textContent = ''; result.style.color = ''; }
    try {
        await apiCall('/automations', {
            method: 'POST',
            body: JSON.stringify({
                name,
                trigger_type: 'schedule',
                trigger_config: { cron },
                action_type: 'build_dj_set_qobuz',
                action_config: cfg,
                cooldown_seconds: 3600,
            }),
        });
        if (result) {
            result.textContent = '✓ Automation aangemaakt. De Qobuz playlist wordt aangemaakt op de eerstvolgende uitvoering.';
            result.style.color = '#4caf50';
        }
        setTimeout(_closeScheduleModal, 1800);
    } catch (err) {
        if (result) { result.textContent = '✗ ' + (err.message || 'Aanmaken mislukt'); result.style.color = '#f44336'; }
    } finally {
        if (submitBtn) { submitBtn.disabled = false; submitBtn.textContent = 'Plan dagelijks'; }
    }
}

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

export async function initDJTemplatesPane() {
    if (!_initialized) {
        // Delegated click handlers on the grid container
        document.getElementById('dj-templates-grid')?.addEventListener('click', (ev) => {
            const schedBtn = ev.target.closest('[data-dj-schedule]');
            if (schedBtn) {
                ev.stopPropagation();
                _openScheduleModal(schedBtn.dataset.djSchedule);
                return;
            }
            const delBtn = ev.target.closest('[data-dj-delete]');
            if (delBtn) {
                ev.stopPropagation();
                _deleteTemplate(delBtn.dataset.djDelete);
                return;
            }
            const card = ev.target.closest('[data-dj-template]');
            if (card) {
                _buildFromTemplate(card.dataset.djTemplate);
            }
        });

        document.getElementById('dj-auto-modal-close')?.addEventListener('click', _closeScheduleModal);
        document.getElementById('dj-auto-cancel')?.addEventListener('click', _closeScheduleModal);
        document.getElementById('dj-auto-create')?.addEventListener('click', _submitScheduleModal);

        _initialized = true;
    }
    await _loadTemplates();
}
