// =============================================================================
// Scheduled Playlists — settings section
// =============================================================================

import { apiCall } from './api.js';

let _initialized = false;

// ---------------------------------------------------------------------------
// Public init
// ---------------------------------------------------------------------------

export async function initSchedulerSection() {
    if (!_initialized) {
        _bindEvents();
        _initialized = true;
    }
    await _loadSchedules();
}

// ---------------------------------------------------------------------------
// Cron preset → human label
// ---------------------------------------------------------------------------

const CRON_LABELS = {
    '0 7 * * *':   'Every morning at 7:00',
    '0 7 * * 1-5': 'Weekdays at 7:00',
    '0 18 * * 5':  'Friday evening at 18:00',
    '0 10 * * 0':  'Every Sunday at 10:00',
    '0 12 * * *':  'Every day at noon',
};

function _cronLabel(expr) {
    return CRON_LABELS[expr] || expr;
}

// ---------------------------------------------------------------------------
// Load & render
// ---------------------------------------------------------------------------

async function _loadSchedules() {
    const container = document.getElementById('schedules-list');
    if (!container) return;

    try {
        const schedules = await apiCall('/schedules');
        _renderSchedules(schedules, container);
    } catch (e) {
        container.innerHTML = `<p style="font-size:0.85rem;color:#e55;">Could not load schedules: ${_esc(e.message)}</p>`;
    }
}

function _renderSchedules(schedules, container) {
    if (!schedules.length) {
        container.innerHTML = '<p style="font-size:0.85rem;opacity:0.55;">No schedules yet. Create one below.</p>';
        return;
    }

    container.innerHTML = schedules.map(s => {
        const status = s.last_status;
        const statusIcon = !s.last_status
            ? ''
            : status === 'success'
                ? '<span class="sched-status sched-status--ok" title="Last run succeeded">✓</span>'
                : `<span class="sched-status sched-status--err" title="${_esc(s.last_error || 'Failed')}">✗</span>`;

        const lastRun = s.last_run
            ? new Date(s.last_run).toLocaleString()
            : 'Never';

        const enabledLabel = s.enabled ? 'Enabled' : 'Disabled';
        const enabledClass = s.enabled ? 'badge badge--amber' : 'badge';

        return `
        <div class="sched-card" data-id="${s.id}">
            <div class="sched-card-header">
                <span class="sched-card-name">${_esc(s.name)}</span>
                <span class="${enabledClass}">${enabledLabel}</span>
                ${statusIcon}
            </div>
            <div class="sched-card-meta">
                <span title="Cron: ${_esc(s.schedule)}">🕐 ${_esc(_cronLabel(s.schedule))}</span>
                <span>Last run: ${lastRun}</span>
                ${s.zone_name ? `<span>▶ ${_esc(s.zone_name)}</span>` : ''}
                ${s.save_to_qobuz ? '<span>💾 Qobuz</span>' : ''}
            </div>
            <div class="sched-card-prompt">${_esc(s.prompt)}</div>
            <div class="sched-card-actions">
                <button class="btn btn-outline btn-sm sched-run-btn" data-id="${s.id}" title="Run now">Run now</button>
                <button class="btn btn-outline btn-sm sched-toggle-btn" data-id="${s.id}" data-enabled="${s.enabled}">
                    ${s.enabled ? 'Disable' : 'Enable'}
                </button>
                <button class="btn btn-outline btn-sm sched-delete-btn" data-id="${s.id}" title="Delete">Delete</button>
            </div>
        </div>`;
    }).join('');

    // Bind per-card buttons
    container.querySelectorAll('.sched-run-btn').forEach(btn => {
        btn.addEventListener('click', () => _runNow(+btn.dataset.id, btn));
    });
    container.querySelectorAll('.sched-toggle-btn').forEach(btn => {
        btn.addEventListener('click', () => _toggle(+btn.dataset.id, btn));
    });
    container.querySelectorAll('.sched-delete-btn').forEach(btn => {
        btn.addEventListener('click', () => _delete(+btn.dataset.id));
    });
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

async function _runNow(id, btn) {
    const orig = btn.textContent;
    btn.textContent = 'Starting…';
    btn.disabled = true;
    try {
        await apiCall(`/schedules/${id}/run`, { method: 'POST' });
        btn.textContent = 'Started ✓';
        setTimeout(() => { btn.textContent = orig; btn.disabled = false; }, 2500);
    } catch (e) {
        btn.textContent = 'Error';
        btn.title = e.message;
        setTimeout(() => { btn.textContent = orig; btn.disabled = false; }, 3000);
    }
}

async function _toggle(id, btn) {
    try {
        const result = await apiCall(`/schedules/${id}/toggle`, { method: 'PATCH' });
        // Re-render list to reflect new state
        await _loadSchedules();
    } catch (e) {
        alert(`Could not toggle schedule: ${e.message}`);
    }
}

async function _delete(id) {
    if (!confirm('Delete this scheduled playlist?')) return;
    try {
        await apiCall(`/schedules/${id}`, { method: 'DELETE' });
        await _loadSchedules();
    } catch (e) {
        alert(`Delete failed: ${e.message}`);
    }
}

// ---------------------------------------------------------------------------
// Create form
// ---------------------------------------------------------------------------

function _bindEvents() {
    document.getElementById('schedules-add-btn')?.addEventListener('click', () => {
        document.getElementById('schedules-form')?.classList.remove('hidden');
        document.getElementById('schedules-add-btn')?.classList.add('hidden');
    });

    document.getElementById('sched-cancel-btn')?.addEventListener('click', _hideForm);

    document.getElementById('sched-preset')?.addEventListener('change', e => {
        const cronGroup = document.getElementById('sched-cron-group');
        if (e.target.value === 'custom') {
            cronGroup?.classList.remove('hidden');
        } else {
            cronGroup?.classList.add('hidden');
        }
    });

    document.getElementById('sched-save-btn')?.addEventListener('click', _createSchedule);
}

function _hideForm() {
    document.getElementById('schedules-form')?.classList.add('hidden');
    document.getElementById('schedules-add-btn')?.classList.remove('hidden');
    document.getElementById('sched-error')?.classList.add('hidden');
    // Reset form
    ['sched-name', 'sched-prompt', 'sched-zone', 'sched-cron'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.value = '';
    });
    const trackCount = document.getElementById('sched-track-count');
    if (trackCount) trackCount.value = '25';
    const preset = document.getElementById('sched-preset');
    if (preset) preset.value = '0 7 * * *';
    document.getElementById('sched-cron-group')?.classList.add('hidden');
    const qobuz = document.getElementById('sched-save-qobuz');
    if (qobuz) qobuz.checked = true;
}

async function _createSchedule() {
    const errorEl = document.getElementById('sched-error');
    const name = document.getElementById('sched-name')?.value.trim();
    const prompt = document.getElementById('sched-prompt')?.value.trim();
    const trackCount = parseInt(document.getElementById('sched-track-count')?.value || '25', 10);
    const preset = document.getElementById('sched-preset')?.value;
    const customCron = document.getElementById('sched-cron')?.value.trim();
    const schedule = preset === 'custom' ? customCron : preset;
    const zoneName = document.getElementById('sched-zone')?.value.trim() || null;
    const saveToQobuz = document.getElementById('sched-save-qobuz')?.checked ?? true;

    // Validate
    const errors = [];
    if (!name) errors.push('Name is required.');
    if (!prompt) errors.push('Prompt is required.');
    if (!schedule) errors.push('Schedule / cron expression is required.');

    if (errors.length) {
        if (errorEl) {
            errorEl.textContent = errors.join(' ');
            errorEl.classList.remove('hidden');
        }
        return;
    }
    errorEl?.classList.add('hidden');

    const saveBtn = document.getElementById('sched-save-btn');
    if (saveBtn) { saveBtn.textContent = 'Creating…'; saveBtn.disabled = true; }

    try {
        await apiCall('/schedules', {
            method: 'POST',
            body: JSON.stringify({
                name,
                prompt,
                schedule,
                track_count: trackCount,
                zone_name: zoneName,
                save_to_qobuz: saveToQobuz,
                enabled: true,
            }),
        });
        _hideForm();
        await _loadSchedules();
    } catch (e) {
        if (errorEl) {
            errorEl.textContent = e.message;
            errorEl.classList.remove('hidden');
        }
    } finally {
        if (saveBtn) { saveBtn.textContent = 'Create Schedule'; saveBtn.disabled = false; }
    }
}

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
