/**
 * RoonSage service worker — installable PWA + lightweight offline shell.
 *
 * Strategy:
 *   - App shell (HTML/CSS/JS modules, icons, manifest): stale-while-revalidate.
 *   - Same-origin GET requests for static assets: cache-first with background refresh.
 *   - /api/* and any non-GET: network-only — live data, no stale playlists.
 *   - Album art (/api/art/*, /api/external-art): cache-first, bounded.
 *
 * The cache version is bumped via the BUILD_ID query string injected by the
 * backend at /sw.js — that means a deploy invalidates the cache cleanly.
 */

const BUILD_ID = new URL(self.location.href).searchParams.get('v') || 'dev';
const SHELL_CACHE = `roonsage-shell-${BUILD_ID}`;
const ART_CACHE = 'roonsage-art-v1';
const ART_CACHE_MAX = 200;

const SHELL_URLS = [
    '/',
    '/static/style.css',
    '/static/app.js',
    '/static/manifest.json',
    '/static/icon-192.svg',
    '/static/icon-512.svg',
];

self.addEventListener('install', (event) => {
    event.waitUntil(
        caches.open(SHELL_CACHE).then((cache) =>
            cache.addAll(SHELL_URLS).catch(() => {
                // Best-effort: if one shell URL fails (e.g. behind basic-auth),
                // don't abort the whole install — the SW still works online.
            })
        ).then(() => self.skipWaiting())
    );
});

self.addEventListener('activate', (event) => {
    event.waitUntil(
        caches.keys().then((keys) =>
            Promise.all(
                keys
                    .filter((k) => k.startsWith('roonsage-shell-') && k !== SHELL_CACHE)
                    .map((k) => caches.delete(k))
            )
        ).then(() => self.clients.claim())
    );
});

self.addEventListener('message', (event) => {
    if (event.data === 'SKIP_WAITING') self.skipWaiting();
});

function isArtRequest(url) {
    return url.pathname.startsWith('/api/art/') || url.pathname === '/api/external-art';
}

function isApiRequest(url) {
    return url.pathname.startsWith('/api/') && !isArtRequest(url);
}

function isShellRequest(req, url) {
    if (req.mode === 'navigate') return true;
    if (url.pathname === '/') return true;
    if (url.pathname.startsWith('/static/')) return true;
    if (url.pathname === '/manifest.json' || url.pathname === '/sw.js') return true;
    return false;
}

async function trimCache(cacheName, max) {
    const cache = await caches.open(cacheName);
    const keys = await cache.keys();
    if (keys.length <= max) return;
    for (const req of keys.slice(0, keys.length - max)) {
        await cache.delete(req);
    }
}

async function cacheFirstArt(request) {
    const cache = await caches.open(ART_CACHE);
    const cached = await cache.match(request);
    if (cached) return cached;
    try {
        const resp = await fetch(request);
        if (resp.ok) {
            cache.put(request, resp.clone()).then(() => trimCache(ART_CACHE, ART_CACHE_MAX));
        }
        return resp;
    } catch (err) {
        if (cached) return cached;
        throw err;
    }
}

async function staleWhileRevalidate(request) {
    const cache = await caches.open(SHELL_CACHE);
    const cached = await cache.match(request);
    const network = fetch(request).then((resp) => {
        if (resp.ok && resp.type === 'basic') {
            cache.put(request, resp.clone()).catch(() => {});
        }
        return resp;
    }).catch(() => cached);
    return cached || network;
}

async function navigationFallback(request) {
    try {
        const resp = await fetch(request);
        if (resp.ok) {
            const cache = await caches.open(SHELL_CACHE);
            cache.put('/', resp.clone()).catch(() => {});
        }
        return resp;
    } catch (err) {
        const cache = await caches.open(SHELL_CACHE);
        const cached = await cache.match('/') || await cache.match(request);
        if (cached) return cached;
        throw err;
    }
}

self.addEventListener('fetch', (event) => {
    const req = event.request;
    if (req.method !== 'GET') return;

    const url = new URL(req.url);
    if (url.origin !== self.location.origin) return;

    if (isApiRequest(url)) return;

    if (isArtRequest(url)) {
        event.respondWith(cacheFirstArt(req));
        return;
    }

    if (req.mode === 'navigate') {
        event.respondWith(navigationFallback(req));
        return;
    }

    if (isShellRequest(req, url)) {
        event.respondWith(staleWhileRevalidate(req));
    }
});
