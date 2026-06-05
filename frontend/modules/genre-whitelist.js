// =============================================================================
// Genre Whitelist — Settings toggle + custom list editor
// =============================================================================
//
// SoulSync-style filter: when enabled, only tags on the whitelist pass through
// during enrichment. Defaults to ~180 curated genres; the textarea lets you
// override.

import { apiCall } from './api.js';

let _wired = false;
let _state = null;  // last server snapshot

export async function initGenreWhitelist() {
    const toggle = document.getElementById('gw-enabled');
    if (!toggle) return;                      // settings page not in the DOM yet
    if (_wired) {
        await _refresh();                      // already wired — just sync state
        return;
    }
    _wired = true;

    const saveBtn  = document.getElementById('gw-save-btn');
    const resetBtn = document.getElementById('gw-reset-btn');
    const textarea = document.getElementById('gw-textarea');

    toggle.addEventListener('change', () => _save({ enabled: toggle.checked }));
    saveBtn?.addEventListener('click', () => _save({
        enabled: toggle.checked,
        genres: _parseTextarea(textarea?.value || ''),
    }));
    resetBtn?.addEventListener('click', () => _save({
        enabled: toggle.checked,
        genres: null,
    }));

    await _refresh();
}

async function _refresh() {
    try {
        _state = await apiCall('/genre-whitelist');
        _apply(_state);
    } catch (e) {
        _status(`Kon whitelist niet laden: ${e.message}`, true);
    }
}

function _apply(data) {
    const toggle   = document.getElementById('gw-enabled');
    const textarea = document.getElementById('gw-textarea');
    const reset    = document.getElementById('gw-reset-btn');
    if (toggle)   toggle.checked = !!data.enabled;
    if (textarea) textarea.value = (data.active || []).join('\n');
    if (reset)    reset.disabled = !data.is_custom;
    _status(data.is_custom
        ? `Custom whitelist actief (${(data.active || []).length} genres)`
        : `Defaults actief (${(data.defaults || []).length} genres)`);
}

async function _save(payload) {
    _status('Saving…');
    try {
        _state = await apiCall('/genre-whitelist', {
            method: 'POST',
            body: JSON.stringify(payload),
        });
        _apply(_state);
    } catch (e) {
        _status(`Fout: ${e.message}`, true);
    }
}

function _parseTextarea(raw) {
    const out = raw
        .split('\n')
        .map(s => s.trim())
        .filter(Boolean);
    return out.length ? out : null;            // null clears the override
}

function _status(text, isError = false) {
    const el = document.getElementById('gw-status');
    if (!el) return;
    el.textContent = text;
    el.classList.toggle('genre-whitelist-status--err', isError);
}
