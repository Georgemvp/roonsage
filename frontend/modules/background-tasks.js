// Poll background tasks every 5s, render compact task bar.
// Only shows when tasks are active. Hides entirely for paid providers.

import { apiCall }    from './api.js';
import { escapeHtml } from './utils.js';

let _pollInterval = null;

export function initBackgroundTaskBar(containerId) {
    const el = document.getElementById(containerId);
    if (!el) return;

    async function poll() {
        try {
            const res = await apiCall('/background-tasks');
            if (!res.enabled) {
                el.innerHTML = `<div class="bg-tasks-disabled">
                    Background AI uitgeschakeld — schakel over naar
                    Ollama voor gratis achtergrond-verrijking.
                </div>`;
                _updateDot(false);
                return;
            }

            const active = res.tasks.filter(t =>
                t.status === 'running' || t.status === 'queued'
            );
            const recent = res.tasks.filter(t =>
                t.status === 'done' || t.status === 'failed'
            );

            _updateDot(active.length > 0);

            if (active.length === 0 && recent.length === 0) {
                el.innerHTML = '';
                return;
            }

            el.innerHTML = `
                <div class="bg-tasks-bar">
                    <div class="bg-tasks-header">
                        <span class="dot ${active.length ? 'green' : 'gray'}"></span>
                        Background AI — ${escapeHtml(res.provider ?? '')}
                        <span class="task-count">${active.length} actief</span>
                    </div>
                    ${res.tasks.map(renderTask).join('')}
                </div>`;
        } catch (_) {
            /* silent — non-critical UI */
        }
    }

    function renderTask(t) {
        const pct = t.status === 'running' && t.total
            ? `${t.progress_pct}%` : '';
        const detail = t.status === 'done'
            ? `${t.elapsed_s}s` : pct;
        return `<div class="bg-task bg-task--${escapeHtml(t.status)}">
            <span class="bg-task-status">${escapeHtml(t.status)}</span>
            <span class="bg-task-label">${escapeHtml(t.label)}</span>
            <span class="bg-task-progress">${escapeHtml(detail)}</span>
        </div>`;
    }

    poll();
    _pollInterval = setInterval(poll, 5000);
}

function _updateDot(active) {
    const dot = document.getElementById('sidebar-tasks-dot');
    if (dot) dot.style.display = active ? '' : 'none';
}
