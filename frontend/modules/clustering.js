// =============================================================================
// Sonic Clustering (v13.0)
// =============================================================================
//
// Self-contained mountable component. Exposes:
//   mountClusteringPanel(rootEl)        -> attaches a status + run button panel
//   renderClusterSummaryCards(rootEl)   -> renders one card per cluster
//   fetchClusterData()                  -> raw data for the Music Map (F2)
//   getClusteringStatus()               -> {status, n_clusters, ...}
//
// The Music Map view (F2) is responsible for laying these primitives out.
// Until F2 ships, this module is loadable from devtools for ad-hoc use.

import { apiCall } from './api.js';

// ---- API helpers ----

export async function getClusteringStatus() {
    return apiCall('/clustering/status');
}

export async function runClustering() {
    return apiCall('/clustering/run', { method: 'POST' });
}

export async function fetchClusterSummary() {
    return apiCall('/clustering/summary');
}

export async function fetchClusterData() {
    return apiCall('/clustering/data');
}

export async function fetchClusterTracks(clusterId, limit = 200) {
    return apiCall(`/clustering/cluster/${clusterId}/tracks?limit=${limit}`);
}

// ---- Rendering ----

function fmtNum(n, digits = 1) {
    if (n === null || n === undefined || Number.isNaN(n)) return '—';
    return Number(n).toFixed(digits);
}

function fmtTime(s) {
    if (!s) return '—';
    try { return new Date(s).toLocaleString(); } catch { return s; }
}

export function renderStatusBlock(status) {
    const phase = status?.status || 'idle';
    const cls = `cluster-status cluster-status--${phase}`;
    return `
      <div class="${cls}">
        <strong>Status:</strong> ${phase}
        ${status?.n_tracks ? ` · ${status.n_tracks} tracks` : ''}
        ${status?.n_clusters ? ` · ${status.n_clusters} clusters` : ''}
        ${status?.n_noise ? ` · ${status.n_noise} outliers` : ''}
        <div class="cluster-status-meta">
          last run: ${fmtTime(status?.finished_at)}
          ${status?.error_message ? `<div class="cluster-error">${status.error_message}</div>` : ''}
        </div>
      </div>
    `;
}

function renderSummaryCard(s) {
    if (s.is_noise) {
        return `
          <div class="cluster-card cluster-card--noise" data-cluster-id="${s.cluster_id}">
            <div class="cluster-card-title">Outliers (cluster ${s.cluster_id})</div>
            <div class="cluster-card-stat">${s.track_count} tracks</div>
            <div class="cluster-card-meta">tracks that didn't fit any cluster</div>
          </div>
        `;
    }
    return `
      <div class="cluster-card" data-cluster-id="${s.cluster_id}">
        <div class="cluster-card-title">
          Cluster ${s.cluster_id}
          ${s.dominant_genre ? `<span class="cluster-card-genre">${s.dominant_genre}</span>` : ''}
        </div>
        <div class="cluster-card-stat">${s.track_count} tracks</div>
        <div class="cluster-card-meta">
          <span title="Average BPM">${fmtNum(s.avg_bpm, 0)} BPM</span>
          <span title="Average energy">E ${fmtNum(s.avg_energy, 2)}</span>
          <span title="Average valence">V ${fmtNum(s.avg_valence, 2)}</span>
          <span title="Average danceability">D ${fmtNum(s.avg_danceability, 2)}</span>
        </div>
      </div>
    `;
}

export async function renderClusterSummaryCards(rootEl) {
    rootEl.innerHTML = '<div class="cluster-loading">Loading cluster summary…</div>';
    try {
        const data = await fetchClusterSummary();
        if (!data.summaries.length) {
            rootEl.innerHTML = '<div class="cluster-empty">No clusters yet. Run clustering to generate them.</div>';
            return;
        }
        rootEl.innerHTML = `<div class="cluster-card-grid">${data.summaries.map(renderSummaryCard).join('')}</div>`;
    } catch (err) {
        rootEl.innerHTML = `<div class="cluster-error">Failed to load clusters: ${err.message}</div>`;
    }
}

export async function mountClusteringPanel(rootEl, { onComplete } = {}) {
    rootEl.innerHTML = `
      <div class="clustering-panel">
        <div class="clustering-panel-header">
          <h3>Sonic Clustering</h3>
          <button id="cluster-run-btn" class="btn btn-primary btn-sm">Run clustering</button>
        </div>
        <div id="cluster-status-block"></div>
        <div id="cluster-summary-block"></div>
      </div>
    `;

    const statusBlock = rootEl.querySelector('#cluster-status-block');
    const summaryBlock = rootEl.querySelector('#cluster-summary-block');
    const runBtn = rootEl.querySelector('#cluster-run-btn');

    let pollTimer = null;

    async function refresh() {
        const status = await getClusteringStatus();
        statusBlock.innerHTML = renderStatusBlock(status);
        if (status.status === 'running') {
            runBtn.disabled = true;
            runBtn.textContent = 'Clustering…';
        } else {
            runBtn.disabled = false;
            runBtn.textContent = 'Run clustering';
        }
        if (status.status === 'complete' || status.status === 'failed' || status.status === 'idle') {
            await renderClusterSummaryCards(summaryBlock);
            if (status.status === 'complete' && onComplete) onComplete(status);
        }
        return status;
    }

    runBtn.addEventListener('click', async () => {
        try {
            await runClustering();
            await refresh();
            if (pollTimer) clearInterval(pollTimer);
            pollTimer = setInterval(async () => {
                const s = await refresh();
                if (s.status !== 'running') {
                    clearInterval(pollTimer);
                    pollTimer = null;
                }
            }, 2000);
        } catch (err) {
            statusBlock.innerHTML = `<div class="cluster-error">Run failed: ${err.message}</div>`;
        }
    });

    await refresh();
    return { refresh, destroy: () => { if (pollTimer) clearInterval(pollTimer); } };
}
