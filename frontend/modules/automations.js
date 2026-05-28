// =============================================================================
// Automations — trigger-action workflow engine UI
// =============================================================================

import { apiCall } from './api.js';

let _initialized = false;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function _esc(str) {
    return String(str ?? '')
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

const TRIGGER_LABELS = {
    schedule:        'Schedule (cron)',
    track_played:    'Track finished playing',
    zone_started:    'Zone started playing',
    library_synced:  'Library sync complete',
    lb_synced:       'ListenBrainz sync complete',
    watchlist_match: 'New watchlist release',
};

const ACTION_LABELS = {
    generate_playlist:  'Generate playlist',
    play_template:      'Play template',
    sync_library:       'Sync library',
    sync_listenbrainz:  'Sync ListenBrainz',
    scan_watchlist:     'Scan watchlist',
    send_notification:  'Send notification',
    run_maintenance:    'Run maintenance',
    volume_set:         'Set volume',
};

function _triggerLabel(t) { return TRIGGER_LABELS[t] || t; }
function _actionLabel(a)  { return ACTION_LABELS[a]  || a; }

function _describeConfig(cfg) {
    if (!cfg || !Object.keys(cfg).length) return '';
    if (cfg.cron)    return `cron: ${cfg.cron}`;
    if (cfg.prompt)  return `"${String(cfg.prompt).slice(0, 48)}…"`;
    if (cfg.message) return `"${String(cfg.message).slice(0, 48)}"`;
    if (cfg.zone_name) return `zone: ${cfg.zone_name}`;
    return '';
}

function _statusBadge(status) {
    if (!status) return '<span class="auto-badge auto-badge--neutral">never run</span>';
    if (status === 'success') return '<span class="auto-badge auto-badge--ok">✓ ok</span>';
    return '<span class="auto-badge auto-badge--err">✗ failed</span>';
}

function _fmt(iso) {
    if (!iso) return '—';
    try {
        return new Date(iso).toLocaleString(undefined, { dateStyle: 'short', timeStyle: 'short' });
    } catch { return iso.slice(0, 16); }
}

// ---------------------------------------------------------------------------
// Init / refresh
// ---------------------------------------------------------------------------

export async function initAutomationsView() {
    if (!_initialized) {
        _bindEvents();
        _initialized = true;
    }
    await Promise.all([_loadAutomations(), _loadLog()]);
}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

async function _loadAutomations() {
    const container = document.getElementById('automations-list');
    if (!container) return;
    container.innerHTML = '<div class="rs-loading"><div class="rs-spinner"></div><span class="rs-loading-text">Loading…</span></div>';
    try {
        const list = await apiCall('/automations');
        _renderAutomations(list, container);
    } catch (e) {
        container.innerHTML = `<p class="auto-error">Could not load automations: ${_esc(e.message)}</p>`;
    }
}

async function _loadLog() {
    const tbody = document.getElementById('auto-log-body');
    if (!tbody) return;
    try {
        const rows = await apiCall('/automations/log?limit=50');
        _renderLog(rows, tbody);
    } catch { /* non-critical */ }
}

// ---------------------------------------------------------------------------
// Renderers
// ---------------------------------------------------------------------------

function _renderAutomations(list, container) {
    if (!list || !list.length) {
        container.innerHTML = `
            <div class="rs-empty">
                <p>No automations yet.</p>
                <p>Use <strong>From Preset</strong> to add one in seconds, or create a custom automation below.</p>
            </div>`;
        return;
    }

    container.innerHTML = list.map(a => {
        const tCfg = _describeConfig(a.trigger_config);
        const aCfg = _describeConfig(a.action_config);
        const lastRun = a.last_triggered
            ? new Date(a.last_triggered).toLocaleString('nl-NL', { dateStyle: 'short', timeStyle: 'short' })
            : 'nog niet';
        const runCount = a.run_count || 0;
        const triggerText = `${_esc(_triggerLabel(a.trigger_type))}${tCfg ? ' · ' + _esc(tCfg) : ''}`;
        const actionText  = `${_esc(_actionLabel(a.action_type))}${aCfg ? ' · ' + _esc(aCfg) : ''}`;

        return `
        <div class="rs-auto-row ${a.enabled ? '' : 'rs-auto-row--disabled'}" data-id="${a.id}" style="display:block;padding:0">
            <div style="display:flex;align-items:center;gap:8px;padding:12px 16px">
                <div style="flex:1;display:flex;align-items:center;gap:10px;flex-wrap:wrap;min-width:0">
                    <span class="rs-auto-text" style="font-weight:600">${_esc(a.name || 'Naamloze automation')}</span>
                    <span class="rs-auto-run-meta">${runCount}× · ${_esc(lastRun)}</span>
                    ${_statusBadge(a.last_status)}
                </div>
                <div style="display:flex;align-items:center;gap:8px;flex-shrink:0">
                    <button class="auto-run-btn rs-btn rs-btn--secondary" data-id="${a.id}" title="Run now" style="font-size:0.8rem;padding:4px 8px">▶</button>
                    <button class="auto-delete-btn rs-btn rs-btn--danger" data-id="${a.id}" title="Delete" style="font-size:0.8rem;padding:4px 8px">✕</button>
                    <button class="rs-auto-toggle auto-toggle-btn ${a.enabled ? 'on' : ''}"
                            data-id="${a.id}" aria-label="${a.enabled ? 'Disable' : 'Enable'} automation"></button>
                </div>
            </div>
            <div class="rs-auto-flow">
                <div class="rs-auto-flow-if">
                    <span class="rs-auto-flow-label rs-auto-flow-label--if">Als</span>
                    <span class="rs-auto-flow-text">${triggerText}</span>
                </div>
                <div class="rs-auto-flow-arrow">→</div>
                <div class="rs-auto-flow-then">
                    <span class="rs-auto-flow-label rs-auto-flow-label--then">Dan</span>
                    <span class="rs-auto-flow-text">${actionText}</span>
                </div>
            </div>
        </div>`;
    }).join('');

    // Bind card buttons
    container.querySelectorAll('.auto-toggle-btn').forEach(btn => {
        btn.addEventListener('click', () => _toggleAutomation(+btn.dataset.id));
    });
    container.querySelectorAll('.auto-run-btn').forEach(btn => {
        btn.addEventListener('click', () => _runAutomation(+btn.dataset.id, btn));
    });
    container.querySelectorAll('.auto-delete-btn').forEach(btn => {
        btn.addEventListener('click', () => _deleteAutomation(+btn.dataset.id));
    });
}

function _renderLog(rows, tbody) {
    if (!rows || !rows.length) {
        tbody.innerHTML = '<tr><td colspan="6" class="auto-log-empty">No runs yet.</td></tr>';
        return;
    }
    tbody.innerHTML = rows.map(r => `
        <tr>
            <td>${_fmt(r.triggered_at)}</td>
            <td>${_esc(r.automation_name || r.automation_id)}</td>
            <td>${_esc(_triggerLabel(r.trigger_type))}</td>
            <td>${_esc(_actionLabel(r.action_type))}</td>
            <td>${r.status === 'success'
                ? '<span class="auto-badge auto-badge--ok">success</span>'
                : '<span class="auto-badge auto-badge--err">failed</span>'}</td>
            <td>${r.duration_ms != null ? r.duration_ms + ' ms' : '—'}</td>
        </tr>
        ${r.error_message ? `<tr class="auto-log-error-row"><td colspan="6">⚠ ${_esc(r.error_message)}</td></tr>` : ''}`
    ).join('');
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

async function _toggleAutomation(id) {
    try {
        await apiCall(`/automations/${id}/toggle`, { method: 'PATCH' });
        await _loadAutomations();
    } catch (e) {
        alert('Could not toggle automation: ' + (e.message || e));
    }
}

async function _runAutomation(id, btn) {
    btn.disabled = true;
    btn.textContent = '…';
    try {
        const result = await apiCall(`/automations/${id}/run`, { method: 'POST' });
        const msg = result.status === 'success'
            ? `✓ Done in ${result.duration_ms}ms`
            : `✗ Failed: ${result.error || 'unknown error'}`;
        alert(msg);
        await Promise.all([_loadAutomations(), _loadLog()]);
    } catch (e) {
        alert('Run failed: ' + (e.message || e));
    } finally {
        btn.disabled = false;
        btn.textContent = '▶';
    }
}

async function _deleteAutomation(id) {
    if (!confirm('Delete this automation?')) return;
    try {
        await apiCall(`/automations/${id}`, { method: 'DELETE' });
        await _loadAutomations();
    } catch (e) {
        alert('Could not delete: ' + (e.message || e));
    }
}

// ---------------------------------------------------------------------------
// Preset installer
// ---------------------------------------------------------------------------

async function _showPresets() {
    const overlay = document.getElementById('auto-preset-overlay');
    const grid    = document.getElementById('auto-preset-grid');
    if (!overlay || !grid) return;

    grid.innerHTML = '<div class="rs-loading"><div class="rs-spinner"></div><span class="rs-loading-text">Loading presets…</span></div>';
    overlay.classList.remove('hidden');

    try {
        const presets = await apiCall('/automations/presets');
        grid.innerHTML = presets.map((p, i) => `
            <div class="auto-preset-card">
                <div class="auto-preset-name">${_esc(p.name)}</div>
                <div class="auto-preset-desc">${_esc(p.description || '')}</div>
                <div class="auto-preset-meta">
                    <span class="auto-meta-chip auto-meta-chip--trigger">⚡ ${_esc(_triggerLabel(p.trigger.type))}</span>
                    <span class="auto-meta-chip auto-meta-chip--action">▶ ${_esc(_actionLabel(p.action.type))}</span>
                </div>
                <button class="rs-btn rs-btn--primary auto-preset-install-btn" data-idx="${i}">Install</button>
            </div>`).join('');

        // Bind install buttons
        grid.querySelectorAll('.auto-preset-install-btn').forEach(btn => {
            btn.addEventListener('click', async () => {
                const preset = presets[+btn.dataset.idx];
                btn.disabled = true;
                btn.textContent = 'Installing…';
                try {
                    await apiCall('/automations', {
                        method: 'POST',
                        body: JSON.stringify({
                            name: preset.name,
                            trigger_type: preset.trigger.type,
                            trigger_config: { ...preset.trigger },
                            action_type: preset.action.type,
                            action_config: { ...preset.action },
                        }),
                    });
                    btn.textContent = '✓ Installed';
                    btn.classList.replace('rs-btn--primary', 'rs-btn--secondary');
                    await _loadAutomations();
                } catch (e) {
                    btn.disabled = false;
                    btn.textContent = 'Install';
                    alert('Could not install preset: ' + (e.message || e));
                }
            });
        });
    } catch (e) {
        grid.innerHTML = `<p class="auto-error">Could not load presets: ${_esc(e.message)}</p>`;
    }
}

// ---------------------------------------------------------------------------
// YAML export / import
// ---------------------------------------------------------------------------

async function _exportYaml() {
    try {
        const list = await apiCall('/automations');
        const lines = ['automations:'];
        list.forEach(a => {
            lines.push(`  - name: ${JSON.stringify(a.name)}`);
            lines.push(`    trigger_type: ${a.trigger_type}`);
            lines.push(`    trigger_config: ${JSON.stringify(a.trigger_config)}`);
            lines.push(`    action_type: ${a.action_type}`);
            lines.push(`    action_config: ${JSON.stringify(a.action_config)}`);
            lines.push(`    enabled: ${a.enabled}`);
            lines.push(`    cooldown_seconds: ${a.cooldown_seconds}`);
        });
        const blob = new Blob([lines.join('\n')], { type: 'text/yaml' });
        const url  = URL.createObjectURL(blob);
        const a    = document.createElement('a');
        a.href = url; a.download = 'automations.yaml'; a.click();
        URL.revokeObjectURL(url);
    } catch (e) {
        alert('Export failed: ' + (e.message || e));
    }
}

// ---------------------------------------------------------------------------
// Create form
// ---------------------------------------------------------------------------

function _getTriggerFields(triggerType) {
    if (triggerType === 'schedule') {
        return `<div class="auto-form-row">
            <label>Cron expression</label>
            <input id="auto-new-cron" type="text" class="auto-form-input" placeholder="0 7 * * 1-5" />
            <small>minute hour dom month dow — e.g. "0 7 * * 1-5" = weekdays at 7:00</small>
        </div>`;
    }
    return '<p class="auto-form-hint">No extra configuration needed for this trigger.</p>';
}

function _getActionFields(actionType) {
    switch (actionType) {
        case 'generate_playlist':
            return `<div class="auto-form-row">
                <label>Prompt</label>
                <input id="auto-new-prompt" type="text" class="auto-form-input" placeholder="Calm morning music" />
            </div>
            <div class="auto-form-row">
                <label>Track count</label>
                <input id="auto-new-track-count" type="number" class="auto-form-input" value="20" min="5" max="100" />
            </div>
            <div class="auto-form-row">
                <label>Zone name (optional)</label>
                <input id="auto-new-zone" type="text" class="auto-form-input" placeholder="Living Room" />
            </div>`;
        case 'volume_set':
            return `<div class="auto-form-row">
                <label>Zone name</label>
                <input id="auto-new-zone" type="text" class="auto-form-input" placeholder="Living Room" />
            </div>
            <div class="auto-form-row">
                <label>Volume level (0–100)</label>
                <input id="auto-new-vol-level" type="number" class="auto-form-input" value="40" min="0" max="100" />
            </div>`;
        case 'send_notification':
            return `<div class="auto-form-row">
                <label>Message</label>
                <input id="auto-new-notif-msg" type="text" class="auto-form-input" placeholder="RoonSage automation triggered" />
            </div>`;
        case 'play_template':
            return `<div class="auto-form-row">
                <label>Template ID</label>
                <input id="auto-new-tpl-id" type="number" class="auto-form-input" placeholder="1" min="1" />
            </div>
            <div class="auto-form-row">
                <label>Zone name</label>
                <input id="auto-new-zone" type="text" class="auto-form-input" placeholder="Living Room" />
            </div>`;
        case 'build_dj_set_qobuz':
            return `<div class="auto-form-row">
                <label>DJ template ID</label>
                <select id="auto-new-dj-tpl" class="auto-form-select"><option value="">Laden…</option></select>
                <small>Eerste run maakt een nieuwe Qobuz playlist; vervolgens wordt diezelfde playlist elke keer overschreven.</small>
            </div>
            <div class="auto-form-row">
                <label>Qobuz playlist naam (alleen 1e run)</label>
                <input id="auto-new-dj-playlist-name" type="text" class="auto-form-input" placeholder="Daily DJ Set" />
            </div>
            <div class="auto-form-row">
                <label>Bestaande Qobuz playlist ID (optioneel)</label>
                <input id="auto-new-dj-playlist-id" type="text" class="auto-form-input" placeholder="leeg = nieuw aanmaken" />
            </div>
            <div class="auto-form-row">
                <label>Zone (optioneel auto-play)</label>
                <input id="auto-new-zone" type="text" class="auto-form-input" placeholder="Living Room" />
            </div>`;
        default:
            return '<p class="auto-form-hint">No extra configuration needed for this action.</p>';
    }
}

async function _populateDJTemplateSelect() {
    const sel = document.getElementById('auto-new-dj-tpl');
    if (!sel) return;
    try {
        const list = await apiCall('/dj-templates');
        sel.innerHTML = list.map(t =>
            `<option value="${t.id}">${t.icon || '🎚️'} ${t.name} — ${t.category}</option>`
        ).join('') || '<option value="">(geen DJ templates)</option>';
    } catch {
        sel.innerHTML = '<option value="">(kon DJ templates niet laden)</option>';
    }
}

function _buildTriggerConfig(triggerType) {
    const cfg = {};
    if (triggerType === 'schedule') {
        cfg.cron = (document.getElementById('auto-new-cron')?.value || '').trim();
        if (!cfg.cron) throw new Error('Cron expression is required for schedule trigger.');
    }
    return cfg;
}

function _buildActionConfig(actionType) {
    const cfg = {};
    switch (actionType) {
        case 'generate_playlist':
            cfg.prompt      = (document.getElementById('auto-new-prompt')?.value || 'Relaxing background music').trim();
            cfg.track_count = parseInt(document.getElementById('auto-new-track-count')?.value || '20', 10);
            const zone = (document.getElementById('auto-new-zone')?.value || '').trim();
            if (zone) cfg.zone_name = zone;
            break;
        case 'volume_set':
            cfg.zone_name = (document.getElementById('auto-new-zone')?.value || '').trim();
            cfg.level     = parseInt(document.getElementById('auto-new-vol-level')?.value || '40', 10);
            break;
        case 'send_notification':
            cfg.message = (document.getElementById('auto-new-notif-msg')?.value || 'Automation triggered').trim();
            break;
        case 'play_template':
            cfg.template_id = parseInt(document.getElementById('auto-new-tpl-id')?.value || '1', 10);
            const z = (document.getElementById('auto-new-zone')?.value || '').trim();
            if (z) cfg.zone_name = z;
            break;
        case 'build_dj_set_qobuz': {
            const tpl = (document.getElementById('auto-new-dj-tpl')?.value || '').trim();
            if (!tpl) throw new Error('Kies een DJ template.');
            cfg.dj_template_id = tpl;
            const plName = (document.getElementById('auto-new-dj-playlist-name')?.value || '').trim();
            if (plName) cfg.qobuz_playlist_name = plName;
            const plId = (document.getElementById('auto-new-dj-playlist-id')?.value || '').trim();
            if (plId) cfg.qobuz_playlist_id = plId;
            const zn = (document.getElementById('auto-new-zone')?.value || '').trim();
            if (zn) cfg.zone_name = zn;
            break;
        }
    }
    return cfg;
}

// ---------------------------------------------------------------------------
// Event bindings
// ---------------------------------------------------------------------------

function _bindEvents() {
    // Trigger type change → update trigger config fields
    const triggerSel = document.getElementById('auto-new-trigger');
    const actionSel  = document.getElementById('auto-new-action');
    const triggerCfg = document.getElementById('auto-new-trigger-cfg');
    const actionCfg  = document.getElementById('auto-new-action-cfg');

    triggerSel?.addEventListener('change', () => {
        if (triggerCfg) triggerCfg.innerHTML = _getTriggerFields(triggerSel.value);
    });
    actionSel?.addEventListener('change', () => {
        if (actionCfg) actionCfg.innerHTML = _getActionFields(actionSel.value);
        if (actionSel.value === 'build_dj_set_qobuz') _populateDJTemplateSelect();
    });
    // Initialise with defaults
    if (triggerCfg && triggerSel) triggerCfg.innerHTML = _getTriggerFields(triggerSel.value);
    if (actionCfg  && actionSel)  actionCfg.innerHTML  = _getActionFields(actionSel.value);

    // Create form submit
    document.getElementById('auto-create-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        const btn     = document.getElementById('auto-create-submit');
        const nameVal = document.getElementById('auto-new-name')?.value.trim();
        const trigger = triggerSel?.value;
        const action  = actionSel?.value;

        if (!nameVal) { alert('Please enter a name.'); return; }

        try {
            const triggerConfig = _buildTriggerConfig(trigger);
            const actionConfig  = _buildActionConfig(action);
            btn.disabled = true;
            btn.textContent = 'Creating…';
            await apiCall('/automations', {
                method: 'POST',
                body: JSON.stringify({
                    name: nameVal,
                    trigger_type: trigger,
                    trigger_config: triggerConfig,
                    action_type: action,
                    action_config: actionConfig,
                    cooldown_seconds: parseInt(document.getElementById('auto-new-cooldown')?.value || '300', 10),
                }),
            });
            e.target.reset();
            if (triggerCfg) triggerCfg.innerHTML = _getTriggerFields(triggerSel?.value || 'schedule');
            if (actionCfg)  actionCfg.innerHTML  = _getActionFields(actionSel?.value  || 'generate_playlist');
            await _loadAutomations();
        } catch (err) {
            alert('Could not create automation: ' + (err.message || err));
        } finally {
            btn.disabled = false;
            btn.textContent = 'Create Automation';
        }
    });

    // Preset overlay
    document.getElementById('auto-preset-btn')?.addEventListener('click', _showPresets);
    document.getElementById('auto-preset-close')?.addEventListener('click', () => {
        document.getElementById('auto-preset-overlay')?.classList.add('hidden');
    });
    document.getElementById('auto-preset-overlay')?.addEventListener('click', (e) => {
        if (e.target === e.currentTarget) e.currentTarget.classList.add('hidden');
    });

    // Export YAML
    document.getElementById('auto-export-btn')?.addEventListener('click', _exportYaml);

    // Refresh log
    document.getElementById('auto-log-refresh')?.addEventListener('click', _loadLog);
}
