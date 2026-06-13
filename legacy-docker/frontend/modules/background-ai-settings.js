/**
 * Background AI Settings Dashboard
 * Unified control panel for all background AI enrichment tasks.
 * Renders inside #background-ai-section in the Settings view.
 */

import { apiCall }    from './api.js';
import { escapeHtml } from './utils.js';

// ── Task definitions (display + trigger mapping) ─────────────────────────────

const TASKS = [
    {
        id:           'vibe_tagging',
        label:        'Vibe & Context Tagging',
        desc:         'Tagt tracks met luistercontexten en stemmingen.',
        schedule:     'Continu (overdag elke 90s)',
        trigger:      '/background-ai/start-vibes',
        triggerLabel: 'Nu starten',
    },
    {
        id:           'lyrics_themes',
        label:        'Lyrics Thema-extractie',
        desc:         'Extraheert thema\'s, emotioneel verloop en taal uit songteksten.',
        schedule:     'Continu (overdag elke 2min)',
        trigger:      '/background-ai/start-lyrics-themes',
        triggerLabel: 'Nu starten',
    },
    {
        id:           'discovery_descriptions',
        label:        'Discovery Omschrijvingen',
        desc:         'Schrijft AI-teksten voor Deep Cuts, Forgotten Favorites en Genre Explorer.',
        schedule:     'Dagelijks',
        trigger:      null,
        triggerLabel: null,
    },
    {
        id:           'cluster_labels',
        label:        'Cluster AI Labels',
        desc:         'Benoemt sonic clusters met levendige namen en beschrijvingen.',
        schedule:     'Na clustering',
        trigger:      '/background-ai/generate-cluster-labels',
        triggerLabel: 'Genereren',
    },
    {
        id:           'template_suggestions',
        label:        'Template Suggesties',
        desc:         'Stelt 3 nieuwe playlist-templates voor op basis van je luisterpatronen.',
        schedule:     'Wekelijks',
        trigger:      '/background-ai/generate-template-suggestions',
        triggerLabel: 'Genereren',
    },
    {
        id:           'song_path_narratives',
        label:        'Pad Narratieven',
        desc:         'Beschrijft de sonische reis bij elke Song Path (automatisch bij gebruik).',
        schedule:     'Op aanvraag',
        trigger:      null,
        triggerLabel: null,
    },
];

// ── Polling ───────────────────────────────────────────────────────────────────

const POLL_FAST = 3_000;
const POLL_SLOW = 15_000;

let _pollTimer  = null;
let _sectionEl  = null;

export function initBackgroundAiSettings(sectionId) {
    _sectionEl = document.getElementById(sectionId);
    if (!_sectionEl) return;

    // Delegate clicks for trigger buttons
    _sectionEl.addEventListener('click', _onClick);

    // Delegate toggle changes
    _sectionEl.addEventListener('change', _onToggle);

    _schedulePoll(0);
}

function _schedulePoll(delay) {
    clearTimeout(_pollTimer);
    _pollTimer = setTimeout(_doPoll, delay);
}

async function _doPoll() {
    try {
        const status = await apiCall('/background-ai/status');
        _render(status);
        const anyRunning = Object.values(status.tasks || {})
            .some(t => t.task?.status === 'running' || t.task?.status === 'queued');
        _schedulePoll(anyRunning ? POLL_FAST : POLL_SLOW);
    } catch (_) {
        _schedulePoll(POLL_SLOW);
    }
}

// ── Event handlers ────────────────────────────────────────────────────────────

async function _onClick(e) {
    const btn = e.target.closest('[data-task-trigger]');
    if (!btn || btn.disabled) return;

    const taskId  = btn.dataset.taskTrigger;
    const taskDef = TASKS.find(t => t.id === taskId);
    if (!taskDef?.trigger) return;

    const origText = btn.textContent;
    btn.disabled   = true;
    btn.textContent = '…';

    try {
        await apiCall(taskDef.trigger, { method: 'POST' });
        _schedulePoll(500);   // fast repoll to show 'running' immediately
    } catch (err) {
        btn.textContent = '✗';
        setTimeout(() => { btn.textContent = origText; btn.disabled = false; }, 2500);
    }
}

async function _onToggle(e) {
    if (e.target.id !== 'bg-ai-toggle') return;
    const enabled = e.target.checked;
    try {
        await apiCall('/background-ai/config', {
            method: 'POST',
            body: JSON.stringify({ enabled }),
        });
        _schedulePoll(300);
    } catch (_) {
        // revert toggle on failure
        e.target.checked = !enabled;
    }
}

// ── Renderer ─────────────────────────────────────────────────────────────────

function _render(status) {
    if (!_sectionEl) return;

    const enabled       = !!status.enabled;
    const isFree        = !!status.is_free_provider;
    const provider      = status.provider ?? '—';
    const tasks         = status.tasks || {};

    // Toggle
    const toggle = _sectionEl.querySelector('#bg-ai-toggle');
    if (toggle) {
        toggle.checked  = enabled;
        toggle.disabled = !isFree;
        toggle.title    = isFree
            ? (enabled ? 'Background AI uitschakelen' : 'Background AI inschakelen')
            : 'Niet beschikbaar voor betaalde providers';
    }

    // Provider badge
    const provBadge = _sectionEl.querySelector('#bg-ai-provider-badge');
    if (provBadge) {
        provBadge.textContent = provider;
        provBadge.dataset.free = isFree ? '1' : '0';
    }

    // Paid-provider warning
    const paidBanner = _sectionEl.querySelector('#bg-ai-paid-banner');
    if (paidBanner) paidBanner.style.display = isFree ? 'none' : '';

    // Disabled-but-free banner (free provider, user toggled off)
    const offBanner = _sectionEl.querySelector('#bg-ai-off-banner');
    if (offBanner) offBanner.style.display = (isFree && !enabled) ? '' : 'none';

    // Active task widget
    const activeTask = Object.values(tasks)
        .find(t => t.task?.status === 'running' || t.task?.status === 'queued');
    const activeEl = _sectionEl.querySelector('#bg-ai-active-task');
    if (activeEl) {
        if (activeTask && enabled) {
            activeEl.style.display = 'flex';
            const lbl  = activeEl.querySelector('#bg-ai-active-label');
            const fill = activeEl.querySelector('#bg-ai-active-fill');
            const pct  = activeEl.querySelector('#bg-ai-active-pct');
            if (lbl) lbl.textContent = activeTask.label;
            const p = activeTask.task?.progress_pct ?? 0;
            if (fill) fill.style.width = p + '%';
            if (pct) {
                const done  = activeTask.task?.completed;
                const total = activeTask.task?.total;
                pct.textContent = (done != null && total != null)
                    ? `${done.toLocaleString('nl-NL')} / ${total.toLocaleString('nl-NL')} (${p}%)`
                    : `${p}%`;
            }
        } else {
            activeEl.style.display = 'none';
        }
    }

    // Task list
    const list = _sectionEl.querySelector('#bg-ai-task-list');
    if (!list) return;

    list.innerHTML = TASKS.map(def => {
        const t          = tasks[def.id];
        const taskRec    = t?.task;
        const prog       = t?.progress ?? {};

        // Derive display status
        let state;
        if (taskRec?.status === 'running')  state = 'running';
        else if (taskRec?.status === 'queued')  state = 'queued';
        else if (taskRec?.status === 'failed')  state = 'failed';
        else if (prog.total > 0 && prog.done >= prog.total) state = 'complete';
        else if (prog.done > 0) state = 'partial';
        else state = 'idle';

        const badgeLabels = {
            running:  'Bezig',
            queued:   'Wacht',
            failed:   'Fout',
            complete: 'Klaar',
            partial:  'Gedeeltelijk',
            idle:     'Gepland',
        };

        const pct = (prog.total > 0)
            ? Math.min(100, Math.round((prog.done / prog.total) * 100))
            : (state === 'complete' ? 100 : 0);

        const progressText = (prog.total != null)
            ? `${(prog.done ?? 0).toLocaleString('nl-NL')} / ${prog.total.toLocaleString('nl-NL')}`
            : (prog.done > 0 ? `${prog.done.toLocaleString('nl-NL')} items` : '');

        const canTrigger = def.trigger && enabled && isFree;
        const isRunning  = state === 'running' || state === 'queued';

        const triggerBtn = canTrigger
            ? `<button class="btn btn-sm bg-ai-task-btn"
                  data-task-trigger="${escapeHtml(def.id)}"
                  ${isRunning ? 'disabled' : ''}>
                 ${escapeHtml(def.triggerLabel)}
               </button>`
            : '';

        return `
        <div class="bg-ai-task-card ${isRunning ? 'bg-ai-task-card--running' : ''}">
          <div class="bg-ai-task-top">
            <span class="bg-ai-task-name">${escapeHtml(def.label)}</span>
            <span class="bg-ai-task-meta">
              <span class="bg-ai-task-schedule">${escapeHtml(def.schedule)}</span>
              <span class="bg-ai-task-badge" data-state="${escapeHtml(state)}">${escapeHtml(badgeLabels[state] ?? state)}</span>
            </span>
          </div>
          <div class="bg-ai-task-bar-wrap" title="${pct}%">
            <div class="bg-ai-task-bar-fill" style="width:${pct}%"></div>
          </div>
          <div class="bg-ai-task-bottom">
            <span class="bg-ai-task-count">${escapeHtml(progressText)}</span>
            ${triggerBtn}
          </div>
        </div>`;
    }).join('');
}
