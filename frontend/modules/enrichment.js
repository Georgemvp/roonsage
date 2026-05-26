// =============================================================================
// Enrichment View — dedicated page with per-source progress bars
// =============================================================================

import { apiCall } from './api.js';
import { escapeHtml } from './utils.js';

let _initialized = false;

export async function initEnrichmentView() {
    // Re-init every time so data stays fresh
    _initialized = true;
    await _loadEnrichmentData();
    _wireRunButton();
}

async function _loadEnrichmentData() {
    try {
        const status = await apiCall('/enrichment/status').catch(() => null);
        if (!status) {
            _setOverall(0, 'No enrichment data available.');
            return;
        }

        const total     = status.total     ?? 0;
        const enriched  = status.enriched  ?? 0;
        const pct       = total > 0 ? Math.round((enriched / total) * 100) : 0;
        const mbEnriched  = status.mb_enriched  ?? null;
        const lfEnriched  = status.lf_enriched  ?? null;
        const acidEnriched = status.acoustid_enriched ?? null;

        _setOverall(pct, `${enriched.toLocaleString()} of ${total.toLocaleString()} tracks enriched`);

        // Per-source bars — use overall counts as fallback
        _setSourceBar('mb',    mbEnriched   != null ? Math.round((mbEnriched   / total) * 100) : pct);
        _setSourceBar('lf',    lfEnriched   != null ? Math.round((lfEnriched   / total) * 100) : pct);
        _setSourceBar('acid',  acidEnriched != null ? Math.round((acidEnriched / total) * 100) : 0);
        _setSourceBar('qobuz', 0); // Qobuz enrichment not separately tracked yet

        // Missing metadata list
        await _loadMissingList();
    } catch (e) {
        console.warn('Enrichment view load failed:', e);
        _setOverall(0, 'Could not load enrichment data: ' + e.message);
    }
}

function _setOverall(pct, sub) {
    const barEl  = document.getElementById('enrich2-overall-bar');
    const pctEl  = document.getElementById('enrich2-overall-pct');
    const subEl  = document.getElementById('enrich2-overall-sub');
    if (barEl)  barEl.style.width  = `${pct}%`;
    if (pctEl)  pctEl.textContent  = `${pct}%`;
    if (subEl)  subEl.textContent  = sub;
}

function _setSourceBar(source, pct) {
    const barEl = document.getElementById(`enrich2-${source}-bar`);
    const pctEl = document.getElementById(`enrich2-${source}-pct`);
    if (barEl)  barEl.style.width  = `${pct}%`;
    if (pctEl)  pctEl.textContent  = `${pct}%`;
}

async function _loadMissingList() {
    const listEl  = document.getElementById('enrich2-missing-list');
    const countEl = document.getElementById('enrich2-missing-count');
    if (!listEl) return;

    try {
        const data = await apiCall('/enrichment/missing?limit=20').catch(() => null);
        const items = Array.isArray(data) ? data : (data?.tracks || data?.items || []);

        if (!items.length) {
            listEl.innerHTML = '<p style="color:var(--text-muted);padding:16px">No missing metadata found.</p>';
            if (countEl) countEl.textContent = '';
            return;
        }

        if (countEl) countEl.textContent = `${items.length} shown`;

        listEl.innerHTML = items.map(item => {
            const missing = item.missing_fields || item.missing || [];
            const tags = Array.isArray(missing)
                ? missing.map(f => `<span class="rs-enrich-missing-tag">${escapeHtml(f)}</span>`).join('')
                : '';
            const artHtml = item.image_key
                ? `<img src="/api/art/${item.image_key}?width=80&height=80" alt="" loading="lazy" onerror="this.style.display='none'">`
                : '';
            return `
                <div class="rs-enrich-missing-row">
                    <div class="rs-enrich-missing-art">${artHtml}</div>
                    <div class="rs-enrich-missing-info">
                        <div class="rs-enrich-missing-title">${escapeHtml(item.title || item.track || 'Unknown')}</div>
                        <div class="rs-enrich-missing-artist">${escapeHtml(item.artist || '')}</div>
                    </div>
                    ${tags ? `<div class="rs-enrich-missing-tags">${tags}</div>` : ''}
                    <button class="rs-enrich-missing-fix" data-track-id="${escapeHtml(String(item.id || ''))}">Fix</button>
                </div>
            `;
        }).join('');

        // Wire individual Fix buttons
        listEl.querySelectorAll('.rs-enrich-missing-fix').forEach(btn => {
            btn.addEventListener('click', async () => {
                const id = btn.dataset.trackId;
                if (!id) return;
                btn.disabled = true;
                btn.textContent = '…';
                try {
                    await apiCall(`/enrichment/enrich-single`, {
                        method: 'POST',
                        body: JSON.stringify({ track_id: id }),
                    });
                    btn.textContent = 'Done';
                } catch (e) {
                    btn.textContent = 'Err';
                    btn.disabled = false;
                }
            });
        });
    } catch (e) {
        listEl.innerHTML = '<p style="color:var(--text-muted);padding:16px">Could not load missing metadata list.</p>';
    }
}

function _wireRunButton() {
    const btn    = document.getElementById('enrich2-run-btn');
    const result = document.getElementById('enrich2-result');
    if (!btn) return;

    // Remove old listener by cloning
    const fresh = btn.cloneNode(true);
    btn.parentNode.replaceChild(fresh, btn);

    fresh.addEventListener('click', async () => {
        fresh.disabled = true;
        fresh.textContent = 'Running…';
        if (result) { result.textContent = ''; result.className = 'enrich-result'; }
        try {
            const resp = await apiCall('/enrichment/run', { method: 'POST', body: '{}' });
            const msg = resp?.message || resp?.status || 'Enrichment started.';
            if (result) { result.textContent = msg; result.className = 'enrich-result enrich-result--success'; }
            // Refresh stats after a short delay
            setTimeout(() => _loadEnrichmentData(), 2000);
        } catch (e) {
            if (result) { result.textContent = 'Error: ' + e.message; result.className = 'enrich-result enrich-result--error'; }
        } finally {
            fresh.disabled = false;
            fresh.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.07 4.93a10 10 0 0 1 0 14.14"/><path d="M4.93 4.93a10 10 0 0 0 0 14.14"/></svg> Run Enrichment`;
        }
    });
}
