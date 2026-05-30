// =============================================================================
// DJ Set view — beatmatched, harmonically-mixed set builder
// =============================================================================

import { apiCall } from './api.js';
import { ensureChartJS } from './taste.js';
import { showSuccess } from './ui.js';

let _initialized = false;
let _lastResult = null;
let _lastPayload = null;
let _savedId = null;
let _curveChart = null;
let _selectedGenres = new Set();
let _bpmUserEdited = false;

// Pre-fetch genres + Chart.js as soon as the module loads.
const _genresFetch = apiCall('/library/stats').catch(() => null);
const _chartJsPreload = ensureChartJS().catch(() => null);

// Energy rank per mood (1 = calmest, 18 = most energetic).
const MOOD_ENERGY_RANK = {
    meditatief: 1, rustig: 2, dromerig: 3, zacht: 4, melancholisch: 5,
    romantisch: 6, chill: 7, nostalgisch: 8, serieus: 9, donker: 10,
    blij: 11, vrolijk: 12, intens: 13, energiek: 14, krachtig: 15,
    feestelijk: 16, opgewonden: 17, euforisch: 18,
};

const CURVE_DIRECTION = {
    ramp_up: 'up', crescendo: 'up', sunrise: 'up', explosion: 'up', marathon: 'up',
    ramp_down: 'down', afterparty: 'down',
    flat: 'any', peak: 'any', valley: 'any', wave: 'any', rollercoaster: 'any',
};

const MOOD_BPM = {
    meditatief:    { center: 65,  spread: 10 },
    rustig:        { center: 72,  spread: 10 },
    zacht:         { center: 78,  spread: 10 },
    dromerig:      { center: 82,  spread: 12 },
    melancholisch: { center: 78,  spread: 12 },
    romantisch:    { center: 82,  spread: 10 },
    chill:         { center: 90,  spread: 12 },
    nostalgisch:   { center: 90,  spread: 12 },
    serieus:       { center: 100, spread: 10 },
    donker:        { center: 105, spread: 15 },
    blij:          { center: 112, spread: 10 },
    vrolijk:       { center: 116, spread: 10 },
    intens:        { center: 122, spread: 15 },
    energiek:      { center: 122, spread: 12 },
    krachtig:      { center: 130, spread: 15 },
    feestelijk:    { center: 128, spread: 12 },
    opgewonden:    { center: 130, spread: 12 },
    euforisch:     { center: 145, spread: 15 },
};

function _filterEndMoods() {
    const startMood = document.getElementById('dj-start-mood')?.value || '';
    const curve     = document.getElementById('dj-curve')?.value      || 'ramp_up';
    const endSelect = document.getElementById('dj-end-mood');
    if (!endSelect) return;

    const direction  = CURVE_DIRECTION[curve] || 'any';
    const startRank  = MOOD_ENERGY_RANK[startMood] ?? 0;
    const currentEnd = endSelect.value;

    endSelect.querySelectorAll('option[value]').forEach(opt => {
        const val = opt.value;
        if (!val) return;
        const rank = MOOD_ENERGY_RANK[val] ?? 0;
        let allowed = true;
        if (direction === 'up'   && startMood) allowed = rank > startRank;
        if (direction === 'down' && startMood) allowed = rank < startRank;
        opt.hidden   = !allowed;
        opt.disabled = !allowed;
    });

    const selectedOpt = endSelect.querySelector(`option[value="${currentEnd}"]`);
    if (currentEnd && selectedOpt?.hidden) endSelect.value = '';
}

function _suggestBpm() {
    if (_bpmUserEdited) return;
    const startMood = document.getElementById('dj-start-mood')?.value || '';
    const endMood   = document.getElementById('dj-end-mood')?.value   || '';
    const curve     = document.getElementById('dj-curve')?.value      || 'ramp_up';
    const hint      = document.getElementById('dj-bpm-hint');

    const startProfile = MOOD_BPM[startMood];
    if (!startProfile) {
        if (hint) hint.textContent = '';
        return;
    }

    const endProfile = endMood && MOOD_BPM[endMood] ? MOOD_BPM[endMood] : null;
    const endCenter  = endProfile ? endProfile.center : startProfile.center;

    let startBpm, endBpm;
    if (curve === 'flat') {
        const mid = Math.round((startProfile.center + endCenter) / 2);
        startBpm = endBpm = mid;
    } else if (curve === 'ramp_down') {
        startBpm = Math.max(startProfile.center, endCenter) + Math.round(startProfile.spread * 0.5);
        endBpm   = Math.min(startProfile.center, endCenter) - Math.round(startProfile.spread * 0.5);
    } else {
        startBpm = startProfile.center - Math.round(startProfile.spread * 0.5);
        endBpm   = endCenter + Math.round((endProfile?.spread ?? startProfile.spread) * 0.5);
    }

    startBpm = Math.max(40, Math.min(220, startBpm));
    endBpm   = Math.max(40, Math.min(220, endBpm));

    document.getElementById('dj-start-bpm').value = startBpm;
    document.getElementById('dj-end-bpm').value   = endBpm;

    if (hint) hint.textContent = `Automatisch ingesteld op basis van mood · klik op een veld om zelf aan te passen`;
}

function _esc(s) {
    return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function _updateEstimatedOutput() {
    const dur = parseInt(document.getElementById('dj-duration')?.value, 10) || 60;
    const startBpm = parseFloat(document.getElementById('dj-start-bpm')?.value) || 110;
    const endBpm   = parseFloat(document.getElementById('dj-end-bpm')?.value)   || 128;
    const avgBpm = (startBpm + endBpm) / 2;
    // ~3.5 min per track on average — adjust with BPM (faster sets pack slightly more).
    const avgSec = Math.max(150, Math.min(300, 60 * (avgBpm / 30)));
    const estTracks = Math.max(1, Math.round((dur * 60) / avgSec));
    const durEl = document.getElementById('dj-est-duration');
    const trkEl = document.getElementById('dj-est-tracks');
    if (durEl) durEl.textContent = dur >= 60 ? `${Math.floor(dur / 60)}u ${dur % 60 ? `${dur % 60}m` : ''}`.trim() : `${dur} min`;
    if (trkEl) trkEl.textContent = `~${estTracks}`;
}

function _updateGenreCountLabel() {
    const el = document.getElementById('dj-genre-selected-count');
    if (!el) return;
    el.textContent = _selectedGenres.size > 0
        ? `(${_selectedGenres.size} geselecteerd)`
        : '(optioneel — alles als niets geselecteerd)';
}

async function _loadGenres() {
    const cloud = document.getElementById('dj-genre-cloud');
    if (!cloud) return;
    try {
        const data = await _genresFetch;
        const genres = data?.genres || [];
        if (!genres.length) {
            cloud.innerHTML = '<span style="color:var(--text-muted);font-size:0.85em;">Geen genres gevonden.</span>';
            return;
        }
        cloud.innerHTML = genres.map(g => `
            <button type="button"
                class="rs-chip${_selectedGenres.has(g.name) ? ' sel' : ''}"
                data-dj-genre="${_esc(g.name)}"
                title="${g.count} tracks"
            >${_esc(g.name)} <span class="rs-chip-count">${g.count}</span></button>
        `).join('');
        cloud.querySelectorAll('[data-dj-genre]').forEach(btn => {
            btn.addEventListener('click', () => {
                const genre = btn.dataset.djGenre;
                if (_selectedGenres.has(genre)) {
                    _selectedGenres.delete(genre);
                    btn.classList.remove('sel');
                } else {
                    _selectedGenres.add(genre);
                    btn.classList.add('sel');
                }
                _updateGenreCountLabel();
            });
        });
    } catch {
        cloud.innerHTML = '<span style="color:var(--text-muted);font-size:0.85em;">Genres konden niet worden geladen.</span>';
    }
}

async function _openZoneModal() {
    if (!_lastResult?.tracks?.length) return;
    const modal = document.getElementById('dj-zone-modal');
    const list  = document.getElementById('dj-zone-list');
    if (!modal || !list) return;
    list.innerHTML = '<div style="color:var(--text-muted);padding:1rem 0;">Laden…</div>';
    modal.classList.remove('hidden');
    try {
        const zones = await apiCall('/roon/zones');
        if (!zones.length) {
            list.innerHTML = '<div style="color:var(--text-muted);padding:1rem 0;">Geen zones gevonden.</div>';
            return;
        }
        list.innerHTML = zones.map(z => `
            <div class="client-item" data-zone-id="${_esc(z.zone_id)}" role="option" tabindex="0"
                 aria-label="${_esc(z.display_name)}">
                <div class="client-status-dot ${z.state === 'playing' ? 'playing' : ''}" aria-hidden="true"></div>
                <div class="client-info">
                    <div class="client-name">${_esc(z.display_name)}</div>
                    <div class="client-status-text">${z.state === 'playing' ? 'Speelt af' : 'Inactief'}</div>
                </div>
            </div>
        `).join('');
        list.querySelectorAll('.client-item').forEach(item => {
            const handler = () => {
                modal.classList.add('hidden');
                _playOnZone(item.dataset.zoneId);
            };
            item.addEventListener('click', handler);
            item.addEventListener('keydown', e => {
                if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); handler(); }
            });
        });
    } catch (err) {
        list.innerHTML = `<div style="color:var(--error);padding:1rem 0;">Fout: ${_esc(err.message)}</div>`;
    }
}

async function _playOnZone(zoneId) {
    const itemKeys = _lastResult.tracks.map(t => t.item_key);
    const status = document.getElementById('dj-status');
    if (status) { status.textContent = 'Versturen naar Roon…'; status.style.color = ''; }
    try {
        await apiCall('/queue', {
            method: 'POST',
            body: JSON.stringify({ item_keys: itemKeys, zone_id: zoneId, mode: 'replace' }),
        });
        if (!_savedId) await _save(_defaultSetName(_lastPayload || {}));
        if (status) status.textContent = '';
        showSuccess(`▶ DJ set van ${itemKeys.length} tracks gestart.`);
    } catch (err) {
        if (status) {
            status.textContent = '✗ ' + (err.message || 'Playback mislukt');
            status.style.color = '#f44336';
        }
    }
}

function _openArcModal() {
    if (!_lastResult?.tracks?.length) return;
    const modal    = document.getElementById('arc-global-modal');
    const nameEl   = document.getElementById('arc-global-name');
    const resultEl = document.getElementById('arc-global-result');
    const saveBtn  = document.getElementById('arc-global-save');
    if (!modal) return;
    const name = document.getElementById('dj-set-name')?.value?.trim() || _defaultSetName(_lastPayload || {});
    if (nameEl)   nameEl.value = name;
    if (resultEl) { resultEl.textContent = ''; resultEl.className = 'arc-modal-result hidden'; }
    if (saveBtn)  { saveBtn.disabled = false; saveBtn.textContent = 'Opslaan op Qobuz'; }
    modal.classList.remove('hidden');
    const tracks = _lastResult.tracks;
    saveBtn?.addEventListener('click', async function _handler() {
        const n      = nameEl?.value.trim() || name;
        const addFav = document.getElementById('arc-global-favorites')?.checked ?? true;
        saveBtn.disabled = true; saveBtn.textContent = 'Bezig…';
        resultEl.className = 'arc-modal-result'; resultEl.textContent = '';
        try {
            const resp = await apiCall('/qobuz/prepare-for-arc', {
                method: 'POST',
                body: JSON.stringify({
                    playlist_name: n,
                    track_items: tracks.map(t => ({ title: t.title, artist: t.artist })),
                    add_to_favorites: addFav,
                }),
            });
            resultEl.className = 'arc-modal-result arc-modal-result--success';
            resultEl.textContent = `✓ Opgeslagen op Qobuz (${resp.saved || 0} tracks, ${resp.skipped || 0} overgeslagen)`;
            saveBtn.textContent = 'Opgeslagen';
        } catch (e) {
            resultEl.className = 'arc-modal-result arc-modal-result--error';
            resultEl.textContent = 'Fout: ' + e.message;
            saveBtn.disabled = false; saveBtn.textContent = 'Opslaan op Qobuz';
        }
    }, { once: true });
}

// ---------------------------------------------------------------------------
// Harmonic transition quality between two consecutive tracks
// ---------------------------------------------------------------------------

const CAMELOT_COMPAT = (() => {
    const map = {};
    for (let n = 1; n <= 12; n++) {
        for (const mode of ['A', 'B']) {
            const key = `${n}${mode}`;
            const prev = `${n === 1 ? 12 : n - 1}${mode}`;
            const next = `${n === 12 ? 1 : n + 1}${mode}`;
            const other = `${n}${mode === 'A' ? 'B' : 'A'}`;
            map[key] = new Set([prev, next, other]);
        }
    }
    return map;
})();

function _transitionQuality(fromKey, toKey) {
    if (!fromKey || !toKey) return null;
    if (fromKey === toKey) return 'same';
    if (CAMELOT_COMPAT[fromKey]?.has(toKey)) return 'ok';
    return 'clash';
}

// ---------------------------------------------------------------------------
// Track list renderer
// ---------------------------------------------------------------------------

function _formatDuration(ms) {
    if (!ms) return '';
    const s = Math.round(ms / 1000);
    return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

function _formatTotalDuration(ms) {
    if (!ms) return '';
    const totalMin = Math.round(ms / 60000);
    if (totalMin < 60) return `${totalMin} min`;
    const h = Math.floor(totalMin / 60);
    const m = totalMin % 60;
    return m ? `${h}u ${m}m` : `${h}u`;
}

function _camelotBadge(key) {
    if (!key) return '';
    const isMinor = key.endsWith('A');
    const color = isMinor ? '#7986cb' : '#4db6ac';
    return `<span class="dj-camelot-badge" style="background:${color};color:#fff;font-size:0.65rem;font-weight:700;padding:1px 5px;border-radius:4px;letter-spacing:0.02em">${_esc(key)}</span>`;
}

function _energyBar(energy) {
    if (energy == null) return '';
    const pct = Math.round((energy || 0) * 100);
    const color = pct > 75 ? '#f44336' : pct > 50 ? '#e5a00d' : pct > 25 ? '#4db6ac' : '#7986cb';
    return `<div class="dj-energy-bar" title="Energy ${pct}%" style="width:40px;height:4px;background:var(--border);border-radius:2px;overflow:hidden;display:inline-block;vertical-align:middle;margin-left:4px">
        <div style="width:${pct}%;height:100%;background:${color}"></div>
    </div>`;
}

function _transitionIndicator(quality, bpmDelta) {
    if (quality === null) return '';
    const icons = { same: '≈', ok: '✓', clash: '⚠' };
    const colors = { same: 'var(--text-muted)', ok: '#4caf50', clash: '#ff9800' };
    const bpmStr = bpmDelta != null ? ` ${bpmDelta > 0 ? '+' : ''}${bpmDelta.toFixed(0)}` : '';
    return `<div class="dj-transition" style="text-align:center;font-size:0.65rem;color:${colors[quality]};padding:2px 0;line-height:1">
        <span title="${quality === 'ok' ? 'Harmonisch' : quality === 'same' ? 'Zelfde toonaard' : 'Toonaard-botsing'}">${icons[quality]}</span><span style="color:var(--text-muted)">${bpmStr} BPM</span>
    </div>`;
}

function _renderTracks(tracks, curve) {
    const target = document.getElementById('dj-result');
    if (!target) return;
    target.style.display = '';
    if (!tracks?.length) {
        target.innerHTML = '<p class="auto-loading">Geen tracks gevonden. Heb je AUDIO_FEATURES_ENABLED aan en is de analyse al klaar?</p>';
        return;
    }

    let html = '';
    for (let i = 0; i < tracks.length; i++) {
        const t = tracks[i];
        const c = curve[i] || {};
        const actualBpm = t.bpm ? `${t.bpm.toFixed(0)}` : (c.bpm ? `${c.bpm.toFixed(0)}` : '–');
        const dur = _formatDuration(t.duration_ms);

        html += `
            <div class="rs-track-row dj-track-row" data-track-idx="${i}" data-item-key="${_esc(t.item_key)}">
                <span class="rs-track-num">${i + 1}</span>
                <img class="rs-track-art" src="/api/art/${_esc(t.item_key)}" alt="" loading="lazy"
                     onerror="this.style.display='none'">
                <div class="rs-track-info">
                    <div class="rs-track-title">${_esc(t.title)}</div>
                    <div class="rs-track-artist" style="display:flex;align-items:center;gap:6px;flex-wrap:wrap">
                        <span>${_esc(t.artist)} · ${_esc(t.album || '')}</span>
                        ${dur ? `<span style="color:var(--text-muted);font-size:0.72rem">${_esc(dur)}</span>` : ''}
                    </div>
                </div>
                <div style="display:flex;flex-direction:column;align-items:flex-end;gap:3px;flex-shrink:0">
                    <div style="display:flex;align-items:center;gap:5px">
                        ${_camelotBadge(t.camelot)}
                        <span class="auto-badge auto-badge--neutral" style="font-size:0.7rem">${actualBpm} BPM</span>
                    </div>
                    ${_energyBar(t.energy)}
                </div>
            </div>
        `;

        // Transition indicator between this and the next track
        if (i < tracks.length - 1) {
            const next = tracks[i + 1];
            const quality = _transitionQuality(t.camelot, next.camelot);
            const bpmDelta = (t.bpm != null && next.bpm != null) ? (next.bpm - t.bpm) : null;
            html += _transitionIndicator(quality, bpmDelta);
        }
    }
    target.innerHTML = html;

    // Load album art lazily via intersection observer if supported
    target.querySelectorAll('.rs-track-art').forEach(img => {
        img.addEventListener('load', () => { img.style.display = ''; });
    });

    // Update Camelot wheel with the keys used in this set
    const keys = (tracks || []).map(t => t.camelot).filter(Boolean);
    renderCamelotWheel('dj-camelot-wheel', [...new Set(keys)]);
}

// ---------------------------------------------------------------------------
// Summary stats card
// ---------------------------------------------------------------------------

function _renderSummary(tracks, totalDurationMs) {
    const container = document.getElementById('dj-summary');
    if (!container) return;

    const bpms = tracks.map(t => t.bpm).filter(Boolean);
    const avgBpm = bpms.length ? (bpms.reduce((a, b) => a + b, 0) / bpms.length) : null;
    const minBpm = bpms.length ? Math.min(...bpms) : null;
    const maxBpm = bpms.length ? Math.max(...bpms) : null;

    const energies = tracks.map(t => t.energy).filter(e => e != null);
    const minE = energies.length ? Math.min(...energies) : null;
    const maxE = energies.length ? Math.max(...energies) : null;

    let harmonicOk = 0, harmonicTotal = 0;
    for (let i = 0; i < tracks.length - 1; i++) {
        const q = _transitionQuality(tracks[i].camelot, tracks[i + 1].camelot);
        if (q !== null) {
            harmonicTotal++;
            if (q === 'ok' || q === 'same') harmonicOk++;
        }
    }
    const harmonicPct = harmonicTotal ? Math.round(harmonicOk / harmonicTotal * 100) : null;

    const artists = new Set(tracks.map(t => t.artist));

    const dur = _formatTotalDuration(totalDurationMs);
    const bpmRangeStr = minBpm != null ? `${minBpm.toFixed(0)}–${maxBpm.toFixed(0)} BPM` : '–';
    const energyRangeStr = minE != null ? `${Math.round(minE * 100)}–${Math.round(maxE * 100)}%` : '–';

    container.innerHTML = `
        <div style="display:flex;flex-wrap:wrap;gap:12px 20px;padding:10px 14px;background:var(--bg-elevated);border:1px solid var(--border);border-radius:10px;font-size:0.78rem;color:var(--text-secondary);margin-bottom:12px">
            ${dur ? `<span title="Geschatte duur">⏱ ${_esc(dur)}</span>` : ''}
            ${avgBpm != null ? `<span title="Gemiddeld BPM">♩ ∅ ${avgBpm.toFixed(0)} BPM</span>` : ''}
            <span title="BPM-bereik">↔ ${_esc(bpmRangeStr)}</span>
            ${harmonicPct != null ? `<span title="Harmonische transities" style="color:${harmonicPct >= 70 ? '#4caf50' : harmonicPct >= 40 ? '#ff9800' : '#f44336'}">⟳ ${harmonicPct}% harmonisch</span>` : ''}
            ${energyRangeStr !== '–' ? `<span title="Energy-bereik">⚡ ${_esc(energyRangeStr)}</span>` : ''}
            <span title="Aantal unieke artiesten">🎤 ${artists.size} artiest${artists.size !== 1 ? 'en' : ''}</span>
        </div>
    `;
    container.style.display = '';
}

// ---------------------------------------------------------------------------
// BPM/Energy curve chart
// ---------------------------------------------------------------------------

async function _renderCurve(curve, tracks) {
    const canvas = document.getElementById('dj-curve-chart');
    if (!canvas) return;
    canvas.style.display = '';
    await _chartJsPreload;
    if (_curveChart) {
        _curveChart.destroy();
        _curveChart = null;
    }
    const labels = curve.map((_, i) => String(i + 1));
    const hasValence = curve.some(c => c.valence != null);

    // Target datasets (solid lines)
    const datasets = [
        {
            label: 'BPM (doel)', data: curve.map(c => c.bpm),
            borderColor: '#e5a00d', backgroundColor: 'transparent',
            tension: 0.3, yAxisID: 'y', borderWidth: 2,
        },
        {
            label: 'Energy (doel ×100)', data: curve.map(c => Math.round((c.energy || 0) * 100)),
            borderColor: '#5fb3b3', backgroundColor: 'transparent',
            tension: 0.3, yAxisID: 'y', borderWidth: 2,
        },
    ];

    // Actual track values (dashed overlay)
    if (tracks?.length) {
        const actualBpms = tracks.map(t => t.bpm != null ? Math.round(t.bpm) : null);
        const actualEnergies = tracks.map(t => t.energy != null ? Math.round(t.energy * 100) : null);
        datasets.push({
            label: 'BPM (werkelijk)', data: actualBpms,
            borderColor: '#e5a00d', borderDash: [4, 3], borderWidth: 1.5,
            backgroundColor: 'transparent', tension: 0.2, yAxisID: 'y', pointRadius: 3,
        });
        datasets.push({
            label: 'Energy (werkelijk ×100)', data: actualEnergies,
            borderColor: '#5fb3b3', borderDash: [4, 3], borderWidth: 1.5,
            backgroundColor: 'transparent', tension: 0.2, yAxisID: 'y', pointRadius: 3,
        });
    }

    if (hasValence) {
        datasets.push({
            label: 'Mood/Valence (×100)', data: curve.map(c => Math.round((c.valence || 0) * 100)),
            borderColor: '#b388ff', borderDash: [6, 3], tension: 0.3, yAxisID: 'y', borderWidth: 1.5,
        });
    }

    _curveChart = new Chart(canvas, {
        type: 'line',
        data: { labels, datasets },
        options: {
            responsive: true, maintainAspectRatio: false,
            scales: { y: { beginAtZero: false } },
            plugins: {
                legend: { labels: { boxWidth: 12, font: { size: 11 } } },
                tooltip: { mode: 'index', intersect: false },
            },
            onClick: (_evt, elements) => {
                if (!elements?.length) return;
                const idx = elements[0].index;
                _highlightTrack(idx);
                const row = document.querySelector(`.dj-track-row[data-track-idx="${idx}"]`);
                row?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
            },
            onHover: (_evt, elements) => {
                if (canvas) canvas.style.cursor = elements?.length ? 'pointer' : 'default';
            },
        },
    });
}

function _highlightTrack(idx) {
    document.querySelectorAll('.dj-track-row').forEach((row, i) => {
        row.style.background = i === idx ? 'var(--bg-elevated)' : '';
    });
}

// ---------------------------------------------------------------------------
// New visual results renderer (Energy Profile + Track Sequence)
// ---------------------------------------------------------------------------

function _buildEnergySvg(curve, tracks) {
    const source = curve.length ? curve : tracks.map(t => ({ bpm: t.bpm || 120, energy: t.energy || 0.5 }));
    if (!source.length) return '';
    const W = 800, H = 90;
    const bpms = source.map(p => p.bpm || 120);
    const minB = Math.min(...bpms), maxB = Math.max(...bpms), rangeB = (maxB - minB) || 1;
    const pts = source.map((p, i) => ({
        x: (i / Math.max(source.length - 1, 1)) * W,
        y: H - (((p.bpm || 120) - minB) / rangeB * H * 0.75 + H * 0.1),
        energy: p.energy || 0,
    }));
    let pathD = `M ${pts[0].x.toFixed(1)},${pts[0].y.toFixed(1)}`;
    for (let i = 1; i < pts.length; i++) {
        const cx = (pts[i-1].x + pts[i].x) / 2;
        pathD += ` C ${cx.toFixed(1)},${pts[i-1].y.toFixed(1)} ${cx.toFixed(1)},${pts[i].y.toFixed(1)} ${pts[i].x.toFixed(1)},${pts[i].y.toFixed(1)}`;
    }
    const fillD = `${pathD} L ${W},${H} L 0,${H} Z`;
    const step = Math.max(1, Math.floor(pts.length / 8));
    const nodes = pts.filter((_, i) => i % step === 0 || i === pts.length - 1).map(p => {
        const col = p.energy > 0.65 ? '#ffba3e' : '#9ad1c6';
        return `<circle cx="${p.x.toFixed(1)}" cy="${p.y.toFixed(1)}" r="5" fill="${col}" stroke="#131313" stroke-width="1.5" style="filter:drop-shadow(0 0 8px ${col})"/>`;
    }).join('');
    return `<svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" style="width:100%;height:100%;display:block">
        <defs><linearGradient id="djcg" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="rgba(255,186,62,0.22)"/>
            <stop offset="100%" stop-color="transparent"/>
        </linearGradient></defs>
        <path d="${fillD}" fill="url(#djcg)"/>
        <path d="${pathD}" fill="none" stroke="rgba(255,186,62,0.65)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/>
        ${nodes}
    </svg>`;
}

function _buildTrackSequenceHtml(tracks) {
    if (!tracks.length) return `<p class="dj-seq-empty">Geen tracks gevonden.<br>Is <code>AUDIO_FEATURES_ENABLED=true</code> ingesteld en zijn er al tracks geanalyseerd?</p>`;
    // Threshold: if track BPM < 75% of the set's min BPM it was matched via half-time (bpm×2 falls in range)
    const minBpm = _lastPayload?.start_bpm || 0;
    let html = '';
    for (let i = 0; i < tracks.length; i++) {
        const t = tracks[i];
        const rawBpm = t.bpm != null ? Math.round(t.bpm) : null;
        const isHalfTime = rawBpm != null && minBpm > 0 && rawBpm < minBpm * 0.75;
        const bpm = isHalfTime ? rawBpm * 2 : rawBpm;
        const bpmLabel = bpm ? `${bpm}${isHalfTime ? '<span class="dj-seq-bpm-tag">×2</span>' : ''}` : null;
        const dur = _formatDuration(t.duration_ms);
        html += `
        <div class="dj-seq-track" data-item-key="${_esc(t.item_key)}">
            <span class="material-symbols-outlined dj-seq-drag">drag_indicator</span>
            <div class="dj-seq-art">
                <img src="/api/art/${_esc(t.item_key)}" alt="" loading="lazy" onerror="this.style.opacity=0">
            </div>
            <div class="dj-seq-info">
                <div class="dj-seq-title">${_esc(t.title || '')}</div>
                <div class="dj-seq-artist">${_esc(t.artist || '')}${t.album ? ' · ' + _esc(t.album) : ''}</div>
            </div>
            <div class="dj-seq-meta">
                ${bpmLabel ? `<span class="dj-seq-bpm">${bpmLabel}</span>` : ''}
                ${t.camelot ? `<span class="dj-seq-key ${t.camelot.endsWith('A') ? 'dj-seq-key--minor' : 'dj-seq-key--major'}">${_esc(t.camelot)}</span>` : ''}
            </div>
            <div class="dj-seq-dur">${_esc(dur)}</div>
        </div>`;
        if (i < tracks.length - 1) {
            const next = tracks[i + 1];
            const q = _transitionQuality(t.camelot, next.camelot);
            // Use effective BPM for delta so half-time tracks compare fairly
            const nextRaw = next.bpm != null ? Math.round(next.bpm) : null;
            const nextIsHalfTime = nextRaw != null && minBpm > 0 && nextRaw < minBpm * 0.75;
            const effectiveCur = isHalfTime ? rawBpm * 2 : rawBpm;
            const effectiveNext = nextIsHalfTime ? nextRaw * 2 : nextRaw;
            const bpmDelta = (effectiveCur != null && effectiveNext != null) ? Math.round(effectiveNext - effectiveCur) : null;
            const deltaStr = bpmDelta != null ? ` · ${bpmDelta > 0 ? '+' : ''}${bpmDelta} BPM` : '';
            if (q === 'clash') {
                html += `<div class="dj-seq-trans dj-seq-trans--clash"><div class="dj-seq-trans__line"></div><div class="dj-seq-trans__pill"><span class="material-symbols-outlined" style="font-size:13px">warning</span>Key clash gedetecteerd${deltaStr}</div></div>`;
            } else if (q !== null) {
                const label = q === 'same' ? 'Zelfde toonsoort' : 'Harmonische mix';
                html += `<div class="dj-seq-trans dj-seq-trans--ok"><div class="dj-seq-trans__line"></div><div class="dj-seq-trans__pill"><span class="material-symbols-outlined" style="font-size:13px;font-variation-settings:'FILL' 1">auto_awesome</span>${label}${deltaStr}</div></div>`;
            }
        }
    }
    return html;
}

function _renderDJResults(data) {
    const panel = document.getElementById('dj-results-panel');
    if (!panel) return;
    const tracks = data.tracks || [];
    const curve  = data.curve  || [];
    const bpms = tracks.map(t => t.bpm).filter(Boolean);
    const peakBpm = bpms.length ? Math.round(Math.max(...bpms)) : null;
    const avgBpm  = bpms.length ? Math.round(bpms.reduce((a,b)=>a+b,0) / bpms.length) : null;
    const totalDur = _formatTotalDuration(data.total_duration_ms || 0);
    const energySvg = (curve.length || tracks.some(t => t.bpm)) ? _buildEnergySvg(curve, tracks) : '';

    panel.innerHTML = `
        ${energySvg ? `
        <div class="dj-energy-panel">
            <div class="dj-energy-panel__header">
                <div>
                    <h3 class="dj-energy-panel__title">Set Energie Profiel</h3>
                    <p class="dj-energy-panel__sub">BPM-verloop en energie over de set</p>
                </div>
                <div class="dj-energy-panel__badges">
                    ${peakBpm ? `<span class="dj-ebadge dj-ebadge--amber">Piek: ${peakBpm} BPM</span>` : ''}
                    ${avgBpm  ? `<span class="dj-ebadge">Gem: ${avgBpm} BPM</span>` : ''}
                    ${totalDur ? `<span class="dj-ebadge">${_esc(totalDur)}</span>` : ''}
                </div>
            </div>
            <div class="dj-energy-panel__graph">${energySvg}</div>
        </div>` : ''}
        <div class="dj-seq-panel">
            <div class="dj-seq-panel__header">
                <h3 class="dj-seq-panel__title">
                    Track Volgorde
                    <span class="dj-seq-panel__count">${tracks.length} tracks${totalDur ? ' · ' + totalDur : ''}</span>
                </h3>
                <button id="dj-seq-play-btn" type="button" class="dj-seq-panel__play-btn">
                    <span class="material-symbols-outlined" style="font-size:17px;font-variation-settings:'FILL' 1">play_arrow</span>
                    Afspelen
                </button>
            </div>
            <div class="dj-seq-panel__list">${_buildTrackSequenceHtml(tracks)}</div>
        </div>
    `;
    panel.style.display = '';
    document.getElementById('dj-seq-play-btn')?.addEventListener('click', _openZoneModal);
}

// ---------------------------------------------------------------------------
// Build
// ---------------------------------------------------------------------------

async function _build(ev) {
    ev?.preventDefault();
    const status = document.getElementById('dj-status');
    if (status) { status.textContent = 'Bouw set…'; status.style.color = ''; }

    const genres = Array.from(_selectedGenres);

    const payload = {
        duration_minutes: parseInt(document.getElementById('dj-duration').value, 10) || 60,
        start_bpm: parseFloat(document.getElementById('dj-start-bpm').value) || 110,
        end_bpm:   parseFloat(document.getElementById('dj-end-bpm').value)   || 128,
        energy_curve: document.getElementById('dj-curve').value || 'ramp_up',
        genres,
        start_mood: document.getElementById('dj-start-mood')?.value || null,
        end_mood:   document.getElementById('dj-end-mood')?.value   || null,
        allow_half_step: document.getElementById('dj-opt-halfstep')?.checked ?? true,
        max_per_artist: (() => {
            const el = document.getElementById('dj-opt-max-artist');
            if (!el) return null;
            // Checkbox: checked = max 2 per artist, unchecked = no hard limit
            if (el.type === 'checkbox') return el.checked ? 2 : null;
            const val = parseInt(el.value, 10);
            return isNaN(val) ? null : val;
        })(),
        exclude_live: document.getElementById('dj-opt-no-live')?.checked ?? true,
        skip_recent: document.getElementById('dj-opt-no-recent')?.checked ?? false,
    };

    try {
        const data = await apiCall('/audio-features/dj-set', {
            method: 'POST',
            body: JSON.stringify(payload),
        });
        _lastResult = data;
        _lastPayload = payload;
        _savedId = null;
        _renderDJResults(data);
        // keep legacy wheel update (highlights active keys)
        const keys = (data.tracks || []).map(t => t.camelot).filter(Boolean);
        renderCamelotWheel('dj-camelot-wheel', [...new Set(keys)]);
        if (status) {
            status.textContent = `Set van ${data.returned} tracks · pool: ${data.total_matching}`;
            status.style.color = 'var(--teal)';
        }
        _showResultActions(payload);
    } catch (err) {
        if (status) {
            status.textContent = '✗ ' + (err.message || 'Onbekende fout');
            status.style.color = '#f44336';
        }
    }
}

function _defaultSetName(payload) {
    const parts = [];
    if (payload.start_mood) parts.push(payload.start_mood.charAt(0).toUpperCase() + payload.start_mood.slice(1));
    if (payload.end_mood)   parts.push(payload.end_mood.charAt(0).toUpperCase() + payload.end_mood.slice(1));
    if (payload.genres?.length) parts.push(payload.genres[0]);
    parts.push(`${Math.round(payload.start_bpm)}–${Math.round(payload.end_bpm)} BPM`);
    return 'DJ Set · ' + parts.join(' · ');
}

function _showResultActions(payload) {
    ['dj-play-btn', 'dj-save-btn', 'dj-arc-btn'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.style.display = '';
    });
    const saveBtn = document.getElementById('dj-save-btn');
    if (saveBtn) { saveBtn.textContent = 'Opslaan'; saveBtn.disabled = false; }
    const actionsEl = document.getElementById('dj-result-actions');
    if (actionsEl) actionsEl.style.display = 'block';
    const nameInput = document.getElementById('dj-set-name');
    if (nameInput && !nameInput.value) nameInput.value = _defaultSetName(payload);
}

async function _save(autoName) {
    if (!_lastResult?.tracks?.length) return null;
    const name = autoName || document.getElementById('dj-set-name')?.value?.trim() || _defaultSetName(_lastPayload || {});
    try {
        const saved = await apiCall('/dj-sets', {
            method: 'POST',
            body: JSON.stringify({
                name,
                duration_minutes: _lastPayload?.duration_minutes || 60,
                start_bpm: _lastPayload?.start_bpm,
                end_bpm:   _lastPayload?.end_bpm,
                start_mood: _lastPayload?.start_mood || null,
                end_mood:   _lastPayload?.end_mood   || null,
                genres: _lastPayload?.genres || [],
                tracks: _lastResult.tracks,
                curve:  _lastResult.curve || [],
            }),
        });
        _savedId = saved.id;
        const btn = document.getElementById('dj-save-btn');
        if (btn) { btn.textContent = 'Opgeslagen ✓'; btn.disabled = true; }
        return saved;
    } catch (err) {
        const status = document.getElementById('dj-status');
        if (status) { status.textContent = '✗ Opslaan mislukt: ' + err.message; status.style.color = '#f44336'; }
        return null;
    }
}

// ---------------------------------------------------------------------------
// DJ Set history loader
// ---------------------------------------------------------------------------

async function _loadDJHistory() {
    const list = document.getElementById('dj-history-list');
    if (!list) return;
    list.innerHTML = '<p style="color:var(--text-muted);font-size:0.85rem">Laden…</p>';
    try {
        const data = await apiCall('/dj-sets');
        const sets = Array.isArray(data) ? data : (data.sets || []);
        if (!sets.length) {
            list.innerHTML = '<p style="color:var(--text-muted);font-size:0.85rem;padding:24px 0">Nog geen opgeslagen sets.</p>';
            return;
        }
        list.innerHTML = '';
        for (const s of sets) {
            const item = document.createElement('div');
            item.style.cssText = 'display:flex;align-items:center;gap:14px;padding:14px 16px;background:var(--bg-surface);border:1px solid var(--border);border-radius:11px;margin-bottom:8px';

            const info = document.createElement('div');
            info.style.cssText = 'flex:1;min-width:0';

            const nameEl = document.createElement('div');
            nameEl.style.cssText = 'font-size:0.86rem;font-weight:600;color:var(--text-primary);margin-bottom:3px';
            nameEl.textContent = s.name || 'DJ Set';

            const meta = document.createElement('div');
            meta.style.cssText = 'font-size:0.72rem;color:var(--text-muted)';
            const moodStr = [s.start_mood, s.end_mood].filter(Boolean).join(' → ');
            const dateStr = s.created_at ? new Date(s.created_at).toLocaleDateString('nl-NL', { day: 'numeric', month: 'short' }) : '';
            meta.textContent = [
                `${s.tracks?.length || 0} tracks`,
                `${s.start_bpm || '?'}–${s.end_bpm || '?'} BPM`,
                moodStr,
                dateStr,
            ].filter(Boolean).join(' · ');

            info.append(nameEl, meta);

            const queueBtn = document.createElement('button');
            queueBtn.className = 'btn btn-primary btn-sm';
            queueBtn.textContent = 'Queue';
            queueBtn.addEventListener('click', () => {
                document.dispatchEvent(new CustomEvent('dj-history-play', { detail: { id: s.id } }));
            });

            const delBtn = document.createElement('button');
            delBtn.className = 'btn btn-sm';
            delBtn.style.cssText = 'color:var(--text-muted);border-color:var(--border)';
            delBtn.title = 'Verwijderen';
            delBtn.textContent = '✕';
            delBtn.addEventListener('click', async () => {
                if (!confirm(`"${s.name || 'DJ Set'}" verwijderen?`)) return;
                try {
                    await apiCall(`/dj-sets/${encodeURIComponent(s.id)}`, { method: 'DELETE' });
                    item.remove();
                } catch (e) {
                    alert('Verwijderen mislukt: ' + e.message);
                }
            });

            item.append(info, queueBtn, delBtn);
            list.appendChild(item);
        }
    } catch (e) {
        list.innerHTML = `<p style="color:var(--error);font-size:0.85rem">${_esc(e.message)}</p>`;
    }
}

// ---------------------------------------------------------------------------
// Tab switching
// ---------------------------------------------------------------------------

let _templatesPaneInitDone = false;

export function switchDJTab(tab) {
    const tabs = document.querySelectorAll('#dj-set-view .rs-tab[data-dj-tab]');
    tabs.forEach(t => {
        const active = t.dataset.djTab === tab;
        t.classList.toggle('active', active);
        t.setAttribute('aria-selected', active ? 'true' : 'false');
    });
    const builder   = document.getElementById('dj-builder-pane');
    const templates = document.getElementById('dj-templates-pane');
    const history   = document.getElementById('dj-history-pane');
    if (builder)   builder.style.display   = tab === 'builder'   ? '' : 'none';
    if (templates) templates.style.display = tab === 'templates' ? '' : 'none';
    if (history)   history.style.display   = tab === 'history'   ? '' : 'none';

    if (tab === 'history') _loadDJHistory();

    if (tab === 'templates' && !_templatesPaneInitDone) {
        _templatesPaneInitDone = true;
        import('./dj-templates.js').then(m => m.initDJTemplatesPane());
    } else if (tab === 'templates') {
        import('./dj-templates.js').then(m => m.initDJTemplatesPane());
    }
}

export function showTemplateBuildResult(data, template) {
    _lastResult = data;
    _lastPayload = {
        duration_minutes: template?.duration_minutes || 60,
        start_bpm: template?.start_bpm,
        end_bpm:   template?.end_bpm,
        energy_curve: template?.energy_curve,
        genres: template?.genres || [],
        start_mood: template?.start_mood || null,
        end_mood:   template?.end_mood   || null,
    };
    _savedId = null;
    _renderDJResults(data);
    const keys = (data.tracks || []).map(t => t.camelot).filter(Boolean);
    renderCamelotWheel('dj-camelot-wheel', [...new Set(keys)]);
    _showResultActions(_lastPayload);
    const status = document.getElementById('dj-status');
    if (status) {
        status.textContent = template
            ? `Template "${template.name}" → ${data.returned} tracks (pool: ${data.total_matching}).`
            : `Set van ${data.returned} tracks (pool: ${data.total_matching}).`;
        status.style.color = '#4caf50';
    }
    const nameInput = document.getElementById('dj-set-name');
    if (nameInput && template) nameInput.value = `DJ Set · ${template.name}`;
}

// ── Camelot Wheel SVG renderer ────────────────────────────────────────────────

const KEY_COLORS_A = {
    '1':'#e57373','2':'#ff8a65','3':'#ffb74d','4':'#dce775',
    '5':'#aed581','6':'#4db6ac','7':'#4fc3f7','8':'#7986cb',
    '9':'#ba68c8','10':'#f06292','11':'#e53935','12':'#ff7043',
};
const KEY_COLORS_B = {
    '1':'#ef9a9a','2':'#ffab91','3':'#ffcc80','4':'#f0f4c3',
    '5':'#c5e1a5','6':'#80cbc4','7':'#81d4fa','8':'#9fa8da',
    '9':'#ce93d8','10':'#f48fb1','11':'#ef5350','12':'#ff8a65',
};

export function renderCamelotWheel(containerId, activeKeys = []) {
    const container = document.getElementById(containerId);
    if (!container) return;

    const cx = 110, cy = 110, ro = 95, rm = 73, ri = 52;
    let paths = '';

    for (let n = 1; n <= 12; n++) {
        const startAngle = ((n - 1) / 12) * Math.PI * 2 - Math.PI / 2;
        const endAngle   = (n       / 12) * Math.PI * 2 - Math.PI / 2;
        const midA = (startAngle + endAngle) / 2;

        // Outer ring = B (major)
        const x1oB = cx + ro * Math.cos(startAngle), y1oB = cy + ro * Math.sin(startAngle);
        const x2oB = cx + ro * Math.cos(endAngle),   y2oB = cy + ro * Math.sin(endAngle);
        const x1mB = cx + rm * Math.cos(startAngle), y1mB = cy + rm * Math.sin(startAngle);
        const x2mB = cx + rm * Math.cos(endAngle),   y2mB = cy + rm * Math.sin(endAngle);
        const txB = cx + (ro + rm) / 2 * Math.cos(midA), tyB = cy + (ro + rm) / 2 * Math.sin(midA);
        const keyB = `${n}B`;
        const activeB = activeKeys.includes(keyB);
        paths += `<path d="M${x1oB.toFixed(1)},${y1oB.toFixed(1)} A${ro},${ro} 0 0,1 ${x2oB.toFixed(1)},${y2oB.toFixed(1)} L${x2mB.toFixed(1)},${y2mB.toFixed(1)} A${rm},${rm} 0 0,0 ${x1mB.toFixed(1)},${y1mB.toFixed(1)} Z" fill="${KEY_COLORS_B[n]}" opacity="${activeB ? 1 : 0.40}" stroke="#131313" stroke-width="1.5"/>`;
        paths += `<text x="${txB.toFixed(1)}" y="${tyB.toFixed(1)}" text-anchor="middle" dominant-baseline="middle" font-size="6.5" font-weight="700" fill="rgba(0,0,0,0.7)">${n}B</text>`;

        // Inner ring = A (minor)
        const x1mA = cx + rm * Math.cos(startAngle), y1mA = cy + rm * Math.sin(startAngle);
        const x2mA = cx + rm * Math.cos(endAngle),   y2mA = cy + rm * Math.sin(endAngle);
        const x1iA = cx + ri * Math.cos(startAngle), y1iA = cy + ri * Math.sin(startAngle);
        const x2iA = cx + ri * Math.cos(endAngle),   y2iA = cy + ri * Math.sin(endAngle);
        const txA = cx + (rm + ri) / 2 * Math.cos(midA), tyA = cy + (rm + ri) / 2 * Math.sin(midA);
        const keyA = `${n}A`;
        const activeA = activeKeys.includes(keyA);
        paths += `<path d="M${x1mA.toFixed(1)},${y1mA.toFixed(1)} A${rm},${rm} 0 0,1 ${x2mA.toFixed(1)},${y2mA.toFixed(1)} L${x2iA.toFixed(1)},${y2iA.toFixed(1)} A${ri},${ri} 0 0,0 ${x1iA.toFixed(1)},${y1iA.toFixed(1)} Z" fill="${KEY_COLORS_A[n]}" opacity="${activeA ? 1 : 0.40}" stroke="#131313" stroke-width="1.5"/>`;
        paths += `<text x="${txA.toFixed(1)}" y="${tyA.toFixed(1)}" text-anchor="middle" dominant-baseline="middle" font-size="6.5" font-weight="700" fill="rgba(0,0,0,0.7)">${n}A</text>`;
    }

    container.innerHTML = `
        <svg viewBox="0 0 220 220" style="display:block;width:100%;height:100%">
            ${paths}
            <circle cx="${cx}" cy="${cy}" r="${ri - 2}" fill="#1c1b1b" stroke="rgba(255,255,255,0.12)" stroke-width="1"/>
            <text x="${cx}" y="${cy - 6}" text-anchor="middle" font-size="9" fill="rgba(255,255,255,0.4)" font-weight="600">Camelot</text>
            <text x="${cx}" y="${cy + 6}" text-anchor="middle" font-size="8" fill="rgba(255,255,255,0.3)">Wheel</text>
        </svg>
    `;
}

// ─────────────────────────────────────────────────────────────────────────────
// Energy curve grid
// ─────────────────────────────────────────────────────────────────────────────

const ENERGY_CURVES = [
    { id:'flat',         label:'Flat',         path:'M 2,50 L 98,50' },
    { id:'ramp_up',      label:'Build',        path:'M 2,68 C 40,62 65,35 98,12' },
    { id:'ramp_down',    label:'Wind Down',    path:'M 2,12 C 35,18 68,58 98,65' },
    { id:'peak',         label:'Peak Hour',    path:'M 2,62 C 25,20 42,12 52,12 C 68,12 82,38 98,52' },
    { id:'crescendo',    label:'Crescendo',    path:'M 2,65 C 55,62 75,35 98,5' },
    { id:'wave',         label:'Wave',         path:'M 2,50 C 20,20 40,65 60,20 C 78,5 90,30 98,50' },
    { id:'sunrise',      label:'Sunrise',      path:'M 2,65 C 30,62 55,40 70,20 C 82,8 92,10 98,15' },
    { id:'marathon',     label:'Marathon',     path:'M 2,35 C 20,32 40,38 60,33 C 78,28 90,35 98,32' },
    { id:'rollercoaster',label:'Intervals',    path:'M 2,60 L 20,15 L 38,60 L 56,15 L 74,60 L 92,15 L 98,30' },
    { id:'explosion',    label:'Explosion',    path:'M 2,65 C 15,62 30,20 45,5 C 55,5 70,45 98,65' },
    { id:'afterparty',   label:'Afterparty',   path:'M 2,15 C 20,12 38,18 55,40 C 70,60 85,65 98,68' },
    { id:'valley',       label:'Valley',       path:'M 2,20 C 25,25 40,65 52,68 C 65,65 80,25 98,20' },
];

function _renderCurveGrid() {
    const grid = document.getElementById('dj-curve-grid');
    const hidden = document.getElementById('dj-curve');
    if (!grid || !hidden) return;

    const current = hidden.value || 'ramp_up';
    grid.querySelectorAll('.dj-curve-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.curveId === current);
        btn.onclick = () => {
            hidden.value = btn.dataset.curveId;
            grid.querySelectorAll('.dj-curve-btn').forEach(b => b.classList.remove('active'));
            btn.classList.add('active');
        };
    });
}

export async function initDJSetView() {
    if (!_initialized) {
        const resultEl = document.getElementById('dj-result');
        if (resultEl && !resultEl.textContent.trim()) resultEl.style.display = 'none';

        const summaryEl = document.getElementById('dj-summary');
        if (summaryEl) summaryEl.style.display = 'none';

        document.getElementById('dj-form')?.addEventListener('submit', _build);
        document.getElementById('dj-play-btn')?.addEventListener('click', _openZoneModal);
        document.getElementById('dj-save-btn')?.addEventListener('click', () => _save());
        document.getElementById('dj-arc-btn')?.addEventListener('click', _openArcModal);
        document.getElementById('dj-zone-modal-close')?.addEventListener('click', () => {
            document.getElementById('dj-zone-modal')?.classList.add('hidden');
        });

        document.getElementById('dj-template-shortcut-btn')?.addEventListener('click', () => {
            switchDJTab('templates');
        });

        document.querySelectorAll('.dj-duration-pill').forEach(pill => {
            pill.addEventListener('click', () => {
                const dur = pill.dataset.dur;
                const hidden = document.getElementById('dj-duration');
                if (hidden) hidden.value = dur;
                document.querySelectorAll('.dj-duration-pill').forEach(p => p.classList.remove('active'));
                pill.classList.add('active');
                _updateEstimatedOutput();
            });
        });
        _updateEstimatedOutput();

        document.querySelectorAll('#dj-set-view .rs-tab[data-dj-tab]').forEach(btn => {
            btn.addEventListener('click', () => switchDJTab(btn.dataset.djTab));
        });

        ['dj-start-bpm', 'dj-end-bpm'].forEach(id => {
            document.getElementById(id)?.addEventListener('input', () => {
                _bpmUserEdited = true;
                const hint = document.getElementById('dj-bpm-hint');
                if (hint) hint.textContent = 'Handmatig ingesteld';
                _updateEstimatedOutput();
            });
        });

        renderCamelotWheel('dj-camelot-wheel');

        _initialized = true;
    }
    _renderCurveGrid();
    await _loadGenres();
}
