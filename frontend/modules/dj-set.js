// =============================================================================
// DJ Set view — beatmatched, harmonically-mixed set builder
// =============================================================================
//
// Renders the form in #dj-set-view, calls /api/audio-features/dj-set, draws
// the resulting BPM curve in a Chart.js canvas, and provides "Play on zone"
// which dispatches the curated set via the standard play_tracks endpoint.

import { apiCall } from './api.js';
import { showSuccess } from './ui.js';

let _initialized = false;
let _lastResult = null;
let _lastPayload = null;
let _savedId = null;
let _curveChart = null;
let _selectedGenres = new Set();
let _bpmUserEdited = false;

// Pre-fetch genres as soon as the module loads so the data is ready by the
// time the user opens the DJ Set view — avoids "Laden…" delay on navigation.
const _genresFetch = apiCall('/library/stats').catch(() => null);

// Energy rank per mood (1 = calmest, 18 = most energetic).
// Used to restrict which end moods are valid for a given curve direction.
const MOOD_ENERGY_RANK = {
    meditatief: 1, rustig: 2, dromerig: 3, zacht: 4, melancholisch: 5,
    romantisch: 6, chill: 7, nostalgisch: 8, serieus: 9, donker: 10,
    blij: 11, vrolijk: 12, intens: 13, energiek: 14, krachtig: 15,
    feestelijk: 16, opgewonden: 17, euforisch: 18,
};

// Which direction a curve travels: 'up' (end > start), 'down' (end < start), 'any'.
const CURVE_DIRECTION = {
    ramp_up:      'up',
    crescendo:    'up',
    sunrise:      'up',
    explosion:    'up',
    marathon:     'up',
    ramp_down:    'down',
    afterparty:   'down',
    flat:         'any',
    peak:         'any',
    valley:       'any',
    wave:         'any',
    rollercoaster:'any',
};

// Typical BPM center + half-spread per mood.
// center = midpoint, spread = half the typical range.
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
        if (!val) return; // keep the "— Zelfde als start —" placeholder
        const rank = MOOD_ENERGY_RANK[val] ?? 0;
        let allowed = true;
        if (direction === 'up'   && startMood) allowed = rank > startRank;
        if (direction === 'down' && startMood) allowed = rank < startRank;
        opt.hidden   = !allowed;
        opt.disabled = !allowed;
    });

    // If the currently selected end mood is no longer valid, reset it
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
        // High → low: start at the higher of the two, end at the lower
        startBpm = Math.max(startProfile.center, endCenter) + Math.round(startProfile.spread * 0.5);
        endBpm   = Math.min(startProfile.center, endCenter) - Math.round(startProfile.spread * 0.5);
    } else {
        // ramp_up, peak, valley: start low, ramp up to end
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
    return String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
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
        const genres = data.genres || [];
        if (!genres.length) {
            cloud.innerHTML = '<span style="color:var(--text-muted);font-size:0.85em;">Geen genres gevonden.</span>';
            return;
        }
        cloud.innerHTML = genres.map(g => `
            <button type="button"
                class="discovery-genre-pill${_selectedGenres.has(g.name) ? ' discovery-genre-pill--selected' : ''}"
                data-dj-genre="${_esc(g.name)}"
                title="${g.count} tracks"
            >${_esc(g.name)} <span class="discovery-genre-count">${g.count}</span></button>
        `).join('');
        cloud.querySelectorAll('[data-dj-genre]').forEach(btn => {
            btn.addEventListener('click', () => {
                const genre = btn.dataset.djGenre;
                if (_selectedGenres.has(genre)) {
                    _selectedGenres.delete(genre);
                    btn.classList.remove('discovery-genre-pill--selected');
                } else {
                    _selectedGenres.add(genre);
                    btn.classList.add('discovery-genre-pill--selected');
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

function _renderTracks(tracks, curve) {
    const target = document.getElementById('dj-result');
    if (!target) return;
    if (!tracks?.length) {
        target.innerHTML = '<p class="auto-loading">Geen tracks gevonden. Heb je AUDIO_FEATURES_ENABLED aan en is de analyse al klaar?</p>';
        return;
    }
    const rows = tracks.map((t, i) => {
        const c = curve[i] || {};
        const bpm = c.bpm ? `${c.bpm.toFixed(0)} BPM` : '';
        return `
            <div class="auto-row">
                <span class="auto-row-num">${i + 1}</span>
                <div class="auto-row-main">
                    <div class="auto-row-title">${_esc(t.title)}</div>
                    <div class="auto-row-sub">${_esc(t.artist)} · ${_esc(t.album || '')}</div>
                </div>
                <span class="auto-badge auto-badge--neutral">${bpm}</span>
            </div>
        `;
    }).join('');
    target.innerHTML = rows;
}

function _renderCurve(curve) {
    const canvas = document.getElementById('dj-curve-chart');
    if (!canvas || typeof Chart === 'undefined') return;
    if (_curveChart) {
        _curveChart.destroy();
        _curveChart = null;
    }
    const labels = curve.map((_, i) => String(i + 1));
    const hasValence = curve.some(c => c.valence != null);
    const datasets = [
        {
            label: 'BPM', data: curve.map(c => c.bpm),
            borderColor: '#e5a00d', tension: 0.3, yAxisID: 'y',
        },
        {
            label: 'Energy (×100)', data: curve.map(c => Math.round((c.energy || 0) * 100)),
            borderColor: '#5fb3b3', tension: 0.3, yAxisID: 'y',
        },
    ];
    if (hasValence) {
        datasets.push({
            label: 'Mood/Valence (×100)', data: curve.map(c => Math.round((c.valence || 0) * 100)),
            borderColor: '#b388ff', borderDash: [4, 3], tension: 0.3, yAxisID: 'y',
        });
    }
    _curveChart = new Chart(canvas, {
        type: 'line',
        data: { labels, datasets },
        options: {
            responsive: true, maintainAspectRatio: false,
            scales: { y: { beginAtZero: false } },
        },
    });
}

async function _build(ev) {
    ev?.preventDefault();
    const status = document.getElementById('dj-status');
    const playBtn = document.getElementById('dj-play-btn');
    if (status) { status.textContent = 'Bouw set…'; status.style.color = ''; }

    const genres = Array.from(_selectedGenres);
    const startMood = document.getElementById('dj-start-mood')?.value || null;
    const endMood   = document.getElementById('dj-end-mood')?.value   || null;

    const payload = {
        duration_minutes: parseInt(document.getElementById('dj-duration').value, 10) || 60,
        start_bpm: parseFloat(document.getElementById('dj-start-bpm').value) || 110,
        end_bpm: parseFloat(document.getElementById('dj-end-bpm').value) || 128,
        energy_curve: document.getElementById('dj-curve').value || 'ramp_up',
        genres,
        start_mood: startMood || null,
        end_mood:   (endMood && endMood !== startMood) ? endMood : null,
    };

    try {
        const data = await apiCall('/audio-features/dj-set', {
            method: 'POST',
            body: JSON.stringify(payload),
        });
        _lastResult = data;
        _lastPayload = payload;
        _savedId = null;
        _renderTracks(data.tracks, data.curve || []);
        _renderCurve(data.curve || []);
        if (status) {
            status.textContent = `Set van ${data.returned} tracks (pool: ${data.total_matching}).`;
            status.style.color = '#4caf50';
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
    // Reveal the action buttons next to Build set
    ['dj-play-btn', 'dj-save-btn', 'dj-arc-btn'].forEach(id => {
        const el = document.getElementById(id);
        if (el) el.style.display = '';
    });
    const saveBtn = document.getElementById('dj-save-btn');
    if (saveBtn) { saveBtn.textContent = 'Opslaan'; saveBtn.disabled = false; }
    // Show name input below tracklist
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

export async function initDJSetView() {
    if (!_initialized) {
        document.getElementById('dj-form')?.addEventListener('submit', _build);
        document.getElementById('dj-play-btn')?.addEventListener('click', _openZoneModal);
        document.getElementById('dj-save-btn')?.addEventListener('click', () => _save());
        document.getElementById('dj-arc-btn')?.addEventListener('click', _openArcModal);
        document.getElementById('dj-zone-modal-close')?.addEventListener('click', () => {
            document.getElementById('dj-zone-modal')?.classList.add('hidden');
        });

        // Filter end moods + BPM auto-suggest when mood or curve changes
        ['dj-start-mood', 'dj-curve'].forEach(id => {
            document.getElementById(id)?.addEventListener('change', () => {
                _filterEndMoods();
                _bpmUserEdited = false;
                _suggestBpm();
            });
        });
        document.getElementById('dj-end-mood')?.addEventListener('change', () => {
            _bpmUserEdited = false;
            _suggestBpm();
        });
        // Track manual BPM edits
        ['dj-start-bpm', 'dj-end-bpm'].forEach(id => {
            document.getElementById(id)?.addEventListener('input', () => {
                _bpmUserEdited = true;
                const hint = document.getElementById('dj-bpm-hint');
                if (hint) hint.textContent = 'Handmatig ingesteld';
            });
        });

        _initialized = true;
    }
    _filterEndMoods();
    await _loadGenres();
}
