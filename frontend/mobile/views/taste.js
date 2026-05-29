import { apiCall } from '../../modules/api.js';
import { esc } from '../util.js';

const DESKTOP = (hash) => `/#${hash}`;

export function render() {
    return `
    <div class="px-margin-mobile pt-md pb-xl flex flex-col gap-lg">
        <section class="flex flex-col gap-base">
            <p class="font-label-caps text-label-caps text-primary tracking-widest uppercase opacity-80">Intelligence</p>
            <h1 class="font-headline-lg-mobile text-headline-lg-mobile text-text-primary">My Taste</h1>
            <p class="font-body-sm text-body-sm text-text-muted">Je luistergewoonten, genreprofiel en favorieten.</p>
        </section>

        <section id="taste-stats" class="grid grid-cols-2 gap-sm">${statSkeleton()}</section>

        <section class="glass-panel rounded-xl p-md flex flex-col gap-md">
            <h2 class="font-title-md text-title-md text-text-primary">Genres</h2>
            <div id="taste-genres" class="flex flex-wrap gap-xs">${chipSkeleton()}</div>
        </section>

        <section class="glass-panel rounded-xl p-md flex flex-col gap-md">
            <h2 class="font-title-md text-title-md text-text-primary">Tijdperken</h2>
            <div id="taste-decades" class="flex items-end justify-between h-32 gap-xs px-1"></div>
        </section>

        <section class="glass-panel rounded-xl p-md flex flex-col gap-md">
            <h2 class="font-title-md text-title-md text-text-primary">Stemmingen</h2>
            <div id="taste-moods" class="flex flex-wrap gap-xs"></div>
        </section>

        <section class="flex flex-col gap-md">
            <h2 class="font-title-md text-title-md text-text-primary">Top artiesten</h2>
            <div id="taste-artists" class="flex flex-col gap-xs"></div>
        </section>

        <a href="${DESKTOP('taste')}" class="text-center font-label-caps text-label-caps text-primary py-sm">Volledige taste-pagina (desktop) →</a>
    </div>`;
}

function statSkeleton() {
    return Array.from({ length: 4 }).map(() =>
        `<div class="glass-panel rounded-xl p-md h-20 animate-pulse"></div>`).join('');
}
function chipSkeleton() {
    return Array.from({ length: 6 }).map(() =>
        `<div class="h-7 w-20 rounded-full bg-surface-container-low animate-pulse"></div>`).join('');
}

export async function mount() {
    const [profile, stats] = await Promise.all([
        apiCall('/taste/profile').catch(() => null),
        apiCall('/listening/stats?days=365').catch(() => null),
    ]);
    renderStats(stats, profile);
    renderGenres(profile);
    renderDecades(profile);
    renderMoods(profile);
    renderArtists(profile);
}

function statCard(icon, tint, value, label) {
    return `
    <div class="glass-panel rounded-xl p-md flex flex-col gap-1">
        <span class="material-symbols-outlined text-${tint}" style="font-size:22px;">${icon}</span>
        <span class="font-title-md text-title-md text-text-primary">${esc(value)}</span>
        <span class="font-body-sm text-body-sm text-text-muted">${esc(label)}</span>
    </div>`;
}

function renderStats(stats, profile) {
    const el = document.getElementById('taste-stats');
    if (!el) return;
    const hours = stats?.total_minutes != null ? Math.round(stats.total_minutes / 60) : '—';
    const tracks = stats?.total_tracks != null ? stats.total_tracks.toLocaleString('nl-NL') : '—';
    const artistCount = profile?.artists ? Object.keys(profile.artists).length : '—';
    const skip = stats?.skip_rate_pct != null ? `${stats.skip_rate_pct}%` : '—';
    el.innerHTML =
        statCard('schedule', 'primary', hours, 'Uur geluisterd') +
        statCard('album', 'secondary', tracks, 'Tracks gespeeld') +
        statCard('artist', 'tertiary', artistCount, 'Top artiesten') +
        statCard('skip_next', 'primary', skip, 'Skip-ratio');
}

function topEntries(obj, n) {
    if (!obj) return [];
    return Object.entries(obj).sort((a, b) => b[1] - a[1]).slice(0, n);
}

function renderGenres(profile) {
    const el = document.getElementById('taste-genres');
    if (!el) return;
    const genres = topEntries(profile?.genres, 12);
    if (!genres.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Nog geen genredata.</p>`; return; }
    const max = genres[0][1] || 1;
    el.innerHTML = genres.map(([name, score], i) => {
        const strong = i < 4 || score >= max * 0.7;
        return `<span class="px-md py-xs rounded-full font-label-caps text-label-caps border ${strong ? 'bg-primary/20 text-primary border-primary/30' : 'bg-surface-container text-text-muted border-white/5'}">${esc(name)} ${Math.round(score * 100)}%</span>`;
    }).join('');
}

function decadeShort(name) {
    const m = String(name).match(/(\d{4})/);
    return m ? `${m[1].slice(2)}s` : name; // "2010s" -> "10s"
}

function renderDecades(profile) {
    const el = document.getElementById('taste-decades');
    if (!el) return;
    const decades = profile?.decades ? Object.entries(profile.decades).sort((a, b) => a[0].localeCompare(b[0])) : [];
    if (!decades.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Nog geen data.</p>`; return; }
    const max = Math.max(...decades.map(([, v]) => v), 0.01);
    el.innerHTML = decades.map(([name, v]) => {
        const h = Math.max(6, Math.round((v / max) * 100));
        const peak = v >= max * 0.95;
        return `
        <div class="flex-1 flex flex-col items-center justify-end h-full gap-1">
            <div class="w-full ${peak ? 'viola-gradient shadow-[0_0_12px_rgba(211,187,255,0.3)]' : 'bg-surface-variant'} rounded-t-sm transition-all" style="height:${h}%"></div>
            <span class="font-label-caps text-[10px] ${peak ? 'text-primary' : 'text-text-muted'}">${esc(decadeShort(name))}</span>
        </div>`;
    }).join('');
}

function renderMoods(profile) {
    const el = document.getElementById('taste-moods');
    if (!el) return;
    const moods = topEntries(profile?.moods, 8);
    if (!moods.length) { el.parentElement.style.display = 'none'; return; }
    el.innerHTML = moods.map(([name, score]) =>
        `<span class="px-md py-xs rounded-full font-label-caps text-label-caps bg-tertiary/15 text-tertiary border border-tertiary/20">${esc(name)} ${Math.round(score * 100)}%</span>`
    ).join('');
}

function renderArtists(profile) {
    const el = document.getElementById('taste-artists');
    if (!el) return;
    const artists = topEntries(profile?.artists, 10);
    if (!artists.length) { el.innerHTML = `<p class="font-body-sm text-body-sm text-text-muted">Nog geen artiestendata.</p>`; return; }
    const max = artists[0][1] || 1;
    el.innerHTML = artists.map(([name, score], i) => `
        <div class="flex items-center gap-md py-sm border-b border-surface-charcoal">
            <span class="font-title-md text-title-md text-text-muted w-6 text-center">${i + 1}</span>
            <div class="flex-1 min-w-0">
                <p class="font-body-lg text-body-lg text-text-primary truncate">${esc(name)}</p>
                <div class="mt-1 h-1 w-full bg-white/5 rounded-full overflow-hidden">
                    <div class="h-full viola-gradient rounded-full" style="width:${Math.round((score / max) * 100)}%"></div>
                </div>
            </div>
        </div>`).join('');
}
