// =============================================================================
// Step-Based Loading Overlay (shared by playlist + album flows)
// =============================================================================

import { escapeHtml } from './utils.js';
import { lockScroll, removeNoScrollIfNoModals } from './instant-queue.js';

/** Playlist generation: maps fine-grained SSE step IDs to consolidated visible steps */
export const PLAYLIST_STEP_MAP = {
    fetching: 'preparing',
    filtering: 'preparing',
    preparing: 'preparing',
    ai_working: 'ai_working',
    parsing: 'matching',
    matching: 'matching',
    narrative: 'narrative',
};

export const PLAYLIST_STEPS = [
    { id: 'preparing', text: 'Preparing your library...', status: 'active' },
    { id: 'ai_working', text: 'AI is curating your playlist...', status: 'pending' },
    { id: 'matching', text: 'Matching tracks to your library...', status: 'pending' },
    { id: 'narrative', text: 'Writing playlist story...', status: 'pending' },
];

// --- Step timing: enforce minimum dwell per step so they don't flash by ---
const _stepTiming = { lastStepTime: 0, queue: [], timer: null };
const MIN_STEP_MS = 500;

function _processStepQueue() {
    if (_stepTiming.timer) return;
    if (_stepTiming.queue.length === 0) return;

    const elapsed = Date.now() - _stepTiming.lastStepTime;
    if (elapsed < MIN_STEP_MS) {
        _stepTiming.timer = setTimeout(() => {
            _stepTiming.timer = null;
            _processStepQueue();
        }, MIN_STEP_MS - elapsed);
        return;
    }

    const next = _stepTiming.queue.shift();
    if (next.type === 'hide') {
        _applyHideStepLoading();
        _stepTiming.queue = [];
    } else {
        _applyStepUpdate(next.id);
        _stepTiming.lastStepTime = Date.now();
        if (_stepTiming.queue.length > 0) {
            _processStepQueue();
        }
    }
}

function _applyStepUpdate(activeStep) {
    const items = document.querySelectorAll('.step-progress-item');
    let foundActive = false;
    items.forEach(item => {
        const id = item.dataset.progressId;
        if (id === activeStep) {
            foundActive = true;
            item.className = 'step-progress-item active';
            item.querySelector('.step-progress-icon').innerHTML = '<div class="step-progress-spinner"></div>';
        } else if (!foundActive) {
            item.className = 'step-progress-item completed';
            item.querySelector('.step-progress-icon').innerHTML = '<span style="color:var(--success)">&#10003;</span>';
        }
    });
}

function _applyHideStepLoading() {
    const overlay = document.getElementById('step-loading-overlay');
    if (overlay) overlay.classList.add('hidden');
    removeNoScrollIfNoModals();
}

// --- Public API ---

export function showTimedStepLoading(steps, intervalMs = 2000) {
    showStepLoading(steps);
    let stepIndex = 0;
    const stepIds = steps.map(s => s.id);
    const timerId = setInterval(() => {
        stepIndex++;
        if (stepIndex < stepIds.length) {
            updateStepProgress(stepIds[stepIndex]);
        } else {
            clearInterval(timerId);
        }
    }, intervalMs);
    return {
        finish() {
            clearInterval(timerId);
            for (let i = stepIndex + 1; i < stepIds.length; i++) {
                updateStepProgress(stepIds[i]);
            }
            hideStepLoading();
        }
    };
}

export function showStepLoading(steps) {
    const overlay = document.getElementById('step-loading-overlay');
    const list = document.getElementById('step-progress-list');
    if (!overlay || !list) return;

    // Reset timing state for fresh overlay
    _stepTiming.lastStepTime = Date.now();
    _stepTiming.queue = [];
    clearTimeout(_stepTiming.timer);
    _stepTiming.timer = null;

    list.innerHTML = steps.map(s => `
        <div class="step-progress-item ${s.status}" data-progress-id="${s.id}">
            <div class="step-progress-icon">
                ${s.status === 'completed' ? '<span style="color:var(--success)">&#10003;</span>' :
                  s.status === 'active' ? '<div class="step-progress-spinner"></div>' :
                  '<span style="color:var(--text-muted)">&#9675;</span>'}
            </div>
            <span class="step-progress-text">${escapeHtml(s.text)}</span>
        </div>
    `).join('');

    overlay.classList.remove('hidden');
    lockScroll();
}

export function updateStepProgress(activeStep) {
    _stepTiming.queue.push({ type: 'step', id: activeStep });
    _processStepQueue();
}

export function hideStepLoading() {
    _stepTiming.queue.push({ type: 'hide' });
    _processStepQueue();
}
