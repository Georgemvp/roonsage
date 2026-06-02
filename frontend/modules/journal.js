// =============================================================================
// Journal view — listening session summaries (v13.6)
// =============================================================================

import { apiCall } from './api.js';

let _initialised = false;

function _esc(s) {
    return String(s ?? '').replace(/[&<>"]/g, c => ({
        '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;',
    }[c]));
}

function _formatRange(start, end) {
    const s = new Date(start.replace(' ', 'T'));
    const e = new Date(end.replace(' ', 'T'));
    if (isNaN(s) || isNaN(e)) return `${start} → ${end}`;
    const date = s.toLocaleDateString('nl-NL', { weekday: 'short', day: 'numeric', month: 'short' });
    const fmt = (d) => d.toLocaleTimeString('nl-NL', { hour: '2-digit', minute: '2-digit' });
    return `${date} · ${fmt(s)} – ${fmt(e)}`;
}

function _moodArcLabel(arc) {
    return ({
        ascending: '↑ Energie stijgt', descending: '↓ Energie daalt',
        steady: '→ Stabiel', 'u-shaped': '∪ Dip in het midden',
        arch: '∩ Piek in het midden', volatile: '↕ Wisselend',
    }[arc]) || arc || '';
}

function _renderSparkline(curve) {
    if (!curve || !curve.length) return '';
    const w = 120, h = 28;
    const max = Math.max(...curve, 0.001);
    const pts = curve.map((v, i) => {
        const x = (i / Math.max(1, curve.length - 1)) * w;
        const y = h - (v / max) * (h - 4) - 2;
        return `${x.toFixed(1)},${y.toFixed(1)}`;
    }).join(' ');
    return `
      <svg width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" style="display:block;">
        <polyline fill="none" stroke="var(--color-accent,#e5a00d)" stroke-width="1.5" points="${pts}"/>
      </svg>
    `;
}

function _renderSession(s) {
    const genrePills = (s.genres || []).slice(0, 6).map(g =>
        `<span class="rs-disc-chip" style="padding:2px 8px;font-size:11px;">${_esc(g)}</span>`
    ).join('');
    const standouts = (s.standout_tracks || []).slice(0, 3).map(t =>
        `<li><strong>${_esc(t.artist)}</strong> — ${_esc(t.title)}</li>`
    ).join('');

    return `
      <article class="rs-bento-tile" style="padding:18px;display:flex;flex-direction:column;gap:10px;">
        <header style="display:flex;justify-content:space-between;align-items:baseline;flex-wrap:wrap;gap:8px;">
          <div>
            <div style="font-weight:600;font-size:1.02rem;">${_esc(_formatRange(s.started_at, s.ended_at))}</div>
            <div style="color:var(--text-muted);font-size:12px;">
              ${s.track_count} tracks · ${(s.total_duration_minutes || 0).toFixed(0)} min
              ${s.zone_name ? ` · ${_esc(s.zone_name)}` : ''}
              ${s.mood_arc ? ` · ${_esc(_moodArcLabel(s.mood_arc))}` : ''}
            </div>
          </div>
          ${_renderSparkline(s.energy_curve)}
        </header>
        ${genrePills ? `<div style="display:flex;flex-wrap:wrap;gap:6px;">${genrePills}</div>` : ''}
        ${s.summary_text
            ? `<p style="margin:0;line-height:1.45;color:var(--text-primary);">${_esc(s.summary_text)}</p>`
            : `<p style="margin:0;color:var(--text-muted);font-style:italic;">
                Nog geen samenvatting. Vereist een lokale LLM (Ollama/custom) en draait 1x per minuut in trickle-mode.
                <button class="btn btn-secondary btn-sm" data-summarize="${s.id}" style="margin-left:8px;">Nu samenvatten</button>
              </p>`}
        ${standouts ? `<details><summary style="cursor:pointer;color:var(--text-muted);font-size:12px;">Standout tracks</summary><ul style="margin:6px 0 0 18px;font-size:13px;">${standouts}</ul></details>` : ''}
      </article>
    `;
}

async function _refresh() {
    const feed = document.getElementById('journal-feed');
    const statsEl = document.getElementById('journal-stats');
    if (feed) feed.innerHTML = '<div style="color:var(--text-muted);">Laden…</div>';
    try {
        const [data, stats] = await Promise.all([
            apiCall('/sessions?limit=30'),
            apiCall('/sessions/stats'),
        ]);
        if (statsEl && stats) {
            statsEl.textContent =
                `${stats.total_sessions} sessies · ø ${stats.avg_duration_minutes} min · ø ${stats.avg_tracks} tracks`;
        }
        const sessions = data.sessions || [];
        if (!sessions.length) {
            feed.innerHTML = `
              <div class="cluster-empty">
                Nog geen sessies opgeslagen. Speel wat muziek af; sessies worden automatisch gedetecteerd zodra er een pauze
                van meer dan 30 minuten valt. Of klik "Sessies detecteren" om de eerste pass nu uit te voeren.
              </div>`;
            return;
        }
        feed.innerHTML = sessions.map(_renderSession).join('');
        feed.querySelectorAll('button[data-summarize]').forEach(btn => {
            btn.addEventListener('click', async () => {
                const id = btn.dataset.summarize;
                btn.disabled = true; btn.textContent = 'Bezig…';
                try {
                    await apiCall(`/sessions/${id}/summarize`, { method: 'POST' });
                    await _refresh();
                } catch (e) {
                    alert('Samenvatten mislukt: ' + e.message);
                    btn.disabled = false; btn.textContent = 'Nu samenvatten';
                }
            });
        });
    } catch (e) {
        if (feed) feed.innerHTML = `<div class="cluster-error">Laden mislukt: ${e.message}</div>`;
    }
}

export async function initJournalView() {
    if (!_initialised) {
        _initialised = true;
        document.getElementById('journal-refresh-btn')?.addEventListener('click', _refresh);
        document.getElementById('journal-detect-btn')?.addEventListener('click', async (e) => {
            const btn = e.currentTarget;
            const orig = btn.textContent;
            btn.disabled = true; btn.textContent = 'Detecteren…';
            try {
                const r = await apiCall('/sessions/detect', { method: 'POST' });
                btn.textContent = `+${r.inserted || 0} nieuw`;
                await _refresh();
            } catch (err) {
                alert('Detectie mislukt: ' + err.message);
            } finally {
                setTimeout(() => { btn.disabled = false; btn.textContent = orig; }, 1500);
            }
        });
    }
    await _refresh();
}
