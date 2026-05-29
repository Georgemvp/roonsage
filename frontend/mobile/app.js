// Mobile shell entry point.
import { startRouter } from './router.js';
import { startMiniPlayer } from './miniplayer.js';
import { toast } from './util.js';

// Settings button in the top bar -> jump to the (desktop) settings for now.
const settingsBtn = document.getElementById('rs-topbar-settings');
if (settingsBtn) {
    settingsBtn.addEventListener('click', () => { location.hash = '#/settings'; });
}

// Let users escape to the desktop UI (long-press the logo title).
const title = document.getElementById('rs-topbar-title');
if (title) {
    let pressTimer = null;
    const startPress = () => {
        pressTimer = setTimeout(() => {
            localStorage.setItem('rs-force-desktop', '1');
            toast('Desktop-weergave geforceerd…');
            setTimeout(() => { window.location.href = '/'; }, 600);
        }, 800);
    };
    const cancelPress = () => { if (pressTimer) clearTimeout(pressTimer); };
    title.addEventListener('touchstart', startPress, { passive: true });
    title.addEventListener('touchend', cancelPress);
    title.addEventListener('mousedown', startPress);
    title.addEventListener('mouseup', cancelPress);
    title.addEventListener('mouseleave', cancelPress);
}

startRouter();
startMiniPlayer();
