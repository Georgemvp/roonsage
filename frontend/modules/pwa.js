/**
 * PWA wiring — service worker lifecycle, install prompt, update toast.
 *
 * Only runs on https or localhost (browser security requirement). Silent if
 * the browser doesn't support service workers.
 */

const DISMISS_KEY = 'roonsage-pwa-install-dismissed';
const DISMISS_TTL_MS = 14 * 24 * 60 * 60 * 1000; // 14 days

let deferredInstallPrompt = null;
let pendingWorker = null;

function getToast() {
    return document.getElementById('pwa-toast');
}

function showToast({ title, message, actionLabel, onAccept, onDismiss }) {
    const toast = getToast();
    if (!toast) return;
    document.getElementById('pwa-toast-title').textContent = title;
    document.getElementById('pwa-toast-msg').textContent = message;
    const acceptBtn = document.getElementById('pwa-toast-accept');
    const dismissBtn = document.getElementById('pwa-toast-dismiss');
    acceptBtn.textContent = actionLabel;

    const accept = async () => {
        hideToast();
        try { await onAccept?.(); } catch (e) { console.warn('PWA action failed', e); }
    };
    const dismiss = () => {
        hideToast();
        onDismiss?.();
    };
    acceptBtn.onclick = accept;
    dismissBtn.onclick = dismiss;

    toast.classList.remove('hidden');
    requestAnimationFrame(() => toast.classList.add('pwa-toast--visible'));
}

function hideToast() {
    const toast = getToast();
    if (!toast) return;
    toast.classList.remove('pwa-toast--visible');
    setTimeout(() => toast.classList.add('hidden'), 250);
}

function recentlyDismissed() {
    try {
        const ts = parseInt(localStorage.getItem(DISMISS_KEY) || '0', 10);
        return ts && (Date.now() - ts) < DISMISS_TTL_MS;
    } catch (e) { return false; }
}

function markDismissed() {
    try { localStorage.setItem(DISMISS_KEY, String(Date.now())); } catch (e) {}
}

function isStandalone() {
    return window.matchMedia('(display-mode: standalone)').matches ||
           window.navigator.standalone === true;
}

function listenForInstallPrompt() {
    window.addEventListener('beforeinstallprompt', (e) => {
        e.preventDefault();
        deferredInstallPrompt = e;
        if (isStandalone() || recentlyDismissed()) return;
        showToast({
            title: 'Install RoonSage',
            message: 'Add to your home screen for a faster, full-screen experience.',
            actionLabel: 'Install',
            onAccept: async () => {
                if (!deferredInstallPrompt) return;
                deferredInstallPrompt.prompt();
                const { outcome } = await deferredInstallPrompt.userChoice;
                deferredInstallPrompt = null;
                if (outcome === 'dismissed') markDismissed();
            },
            onDismiss: markDismissed,
        });
    });

    window.addEventListener('appinstalled', () => {
        deferredInstallPrompt = null;
        hideToast();
    });
}

function showUpdateToast(worker) {
    showToast({
        title: 'Update available',
        message: 'A new version of RoonSage is ready.',
        actionLabel: 'Reload',
        onAccept: () => {
            worker.postMessage('SKIP_WAITING');
        },
        onDismiss: () => {},
    });
}

async function registerServiceWorker() {
    if (!('serviceWorker' in navigator)) return;
    if (location.protocol !== 'https:' && location.hostname !== 'localhost' && location.hostname !== '127.0.0.1') {
        return; // SW requires secure context
    }

    try {
        const swUrl = `/sw.js?v=${window.ROONSAGE_VERSION || 'dev'}`;
        const registration = await navigator.serviceWorker.register(swUrl, { scope: '/' });

        // If a worker is already waiting (e.g. previous tab triggered the update), surface it.
        if (registration.waiting && navigator.serviceWorker.controller) {
            pendingWorker = registration.waiting;
            showUpdateToast(pendingWorker);
        }

        registration.addEventListener('updatefound', () => {
            const installing = registration.installing;
            if (!installing) return;
            installing.addEventListener('statechange', () => {
                if (installing.state === 'installed' && navigator.serviceWorker.controller) {
                    pendingWorker = installing;
                    showUpdateToast(pendingWorker);
                }
            });
        });

        let refreshing = false;
        navigator.serviceWorker.addEventListener('controllerchange', () => {
            if (refreshing) return;
            refreshing = true;
            window.location.reload();
        });
    } catch (err) {
        console.warn('Service worker registration failed:', err);
    }
}

export function initPWA() {
    listenForInstallPrompt();
    registerServiceWorker();
}
