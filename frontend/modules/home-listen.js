import { apiCall } from './api.js';

function _esc(str) {
    return String(str).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

function _dateLabel(date) {
    const now = new Date();
    const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const yesterdayStart = new Date(todayStart - 86400000);
    if (date >= todayStart) return 'Vandaag';
    if (date >= yesterdayStart) return 'Gisteren';
    return date.toLocaleDateString('nl-NL', { weekday: 'short', day: 'numeric', month: 'short' });
}

export async function loadHomeListenFeed() {
    const el = document.getElementById('home-listen-feed');
    if (!el) return;
    try {
        const data = await apiCall('/listening/history?days=14&limit=12').catch(() => null);
        const events = Array.isArray(data) ? data : (data?.events || []);
        if (!events.length) return;

        let lastDate = null;
        let html = '';
        for (const ev of events) {
            const artKey = ev.image_key || ev.art_key;
            const artHtml = artKey
                ? `<img src="/api/art/${artKey}?width=36&height=36" alt="" loading="lazy" onerror="this.style.display='none'">`
                : `<span class="home-listen-art--placeholder">♪</span>`;
            const title = ev.track_title || ev.title || ev.track || '';
            const ts = ev.timestamp
                ? new Date(ev.timestamp).toLocaleTimeString('nl-NL', { hour: '2-digit', minute: '2-digit' })
                : '';
            const dateLabel = ev.timestamp ? _dateLabel(new Date(ev.timestamp)) : '';

            if (dateLabel && dateLabel !== lastDate) {
                html += `<div class="home-listen-date-header">${_esc(dateLabel)}</div>`;
                lastDate = dateLabel;
            }
            html += `
            <div class="home-listen-row${ev.skipped ? ' home-listen-row--skipped' : ''}">
                <div class="home-listen-art">${artHtml}</div>
                <div class="home-listen-info">
                    <span class="home-listen-title">${_esc(title)}</span>
                    <span class="home-listen-artist">${_esc(ev.artist || '')}</span>
                </div>
                <span class="home-listen-time">${_esc(ts)}</span>
            </div>`;
        }
        el.innerHTML = html;
    } catch (e) {
        console.warn('Listen feed load failed:', e);
    }
}
