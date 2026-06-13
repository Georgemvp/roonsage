// Minimal hash router for the mobile shell.
//
// Each route maps to a lazy view module that exports:
//   render() -> HTML string (or element)
//   mount(el)   (optional) called after the HTML is in the DOM
//   unmount()   (optional) called before navigating away (cleanup timers etc.)
//
// `tab` decides which bottom-nav item highlights. `title` sets the top bar.

const routes = {
    home: { load: () => import('./views/home.js'), tab: 'home', title: 'RoonSage' },
    nowplaying: { load: () => import('./views/nowplaying.js'), tab: 'home', title: 'RoonSage' },
    discover: { load: () => import('./views/discover.js'), tab: 'discover', title: 'Discover' },
    taste: { load: () => import('./views/taste.js'), tab: 'taste', title: 'My Taste' },
    library: { load: () => import('./views/library.js'), tab: 'library', title: 'Library' },
    fingerprint: { load: () => import('./views/fingerprint.js'), tab: 'discover', title: 'Sonic Fingerprint' },
    circadian: { load: () => import('./views/circadian.js'), tab: 'discover', title: 'Circadian' },
    generate: { load: () => import('./views/generate.js'), tab: 'home', title: 'Genereer playlist' },
    djset: { load: () => import('./views/djset.js'), tab: 'home', title: 'DJ Set' },
    search: { load: () => import('./views/search.js'), tab: 'discover', title: 'Advanced Discovery' },
    songpaths: { load: () => import('./views/songpaths.js'), tab: 'discover', title: 'Song Paths' },
    watchlist: { load: () => import('./views/watchlist.js'), tab: 'home', title: 'Watchlist' },
    automations: { load: () => import('./views/automations.js'), tab: 'home', title: 'Automations' },
    enrichment: { load: () => import('./views/enrichment.js'), tab: 'home', title: 'Enrichment' },
    seed: { load: () => import('./views/seed.js'), tab: 'home', title: 'Seed Song' },
    recommend: { load: () => import('./views/recommend.js'), tab: 'home', title: 'Album-aanbeveling' },
    alchemy: { load: () => import('./views/alchemy.js'), tab: 'discover', title: 'Song Alchemy' },
    musicmap: { load: () => import('./views/musicmap.js'), tab: 'discover', title: 'Music Map' },
    settings: { load: () => import('./views/settings.js'), tab: '', title: 'AI-instellingen' },
    playback: { load: () => import('./views/playback.js'), tab: '', title: 'Afspelen' },
};

let _current = null;

function parseHash() {
    const raw = (location.hash || '#/home').replace(/^#\/?/, '');
    const [name, ...rest] = raw.split('/');
    return { name: name || 'home', params: rest };
}

function setActiveTab(tab) {
    document.querySelectorAll('.rs-tab').forEach((a) => {
        const active = a.dataset.tab === tab;
        a.classList.toggle('text-primary', active);
        a.classList.toggle('font-bold', active);
        a.classList.toggle('text-text-muted', !active);
        const icon = a.querySelector('.material-symbols-outlined');
        if (icon) icon.style.fontVariationSettings = active ? "'FILL' 1" : "'FILL' 0";
    });
}

function setTitle(title) {
    const el = document.getElementById('rs-topbar-title');
    if (el) el.textContent = title || 'RoonSage';
}

async function navigate() {
    const { name, params } = parseHash();
    const route = routes[name] || routes.home;
    const main = document.getElementById('rs-main');
    if (!main) return;

    if (_current?.unmount) {
        try { _current.unmount(); } catch (e) { console.warn('unmount error', e); }
    }

    let mod;
    try {
        mod = await route.load();
    } catch (e) {
        console.error('Failed to load view', name, e);
        main.innerHTML = `<div class="px-margin-mobile pt-md text-text-muted">Kon scherm niet laden.</div>`;
        return;
    }

    setActiveTab(route.tab);
    setTitle(route.title);

    const html = typeof mod.render === 'function' ? mod.render(params) : '';
    main.innerHTML = `<div class="rs-fade">${html}</div>`;
    window.scrollTo(0, 0);
    _current = mod;
    if (mod.mount) {
        try { await mod.mount(main, params); } catch (e) { console.error('mount error', name, e); }
    }
}

export function startRouter() {
    window.addEventListener('hashchange', navigate);
    if (!location.hash) location.hash = '#/home'; // fires hashchange -> navigate
    else navigate();
}
