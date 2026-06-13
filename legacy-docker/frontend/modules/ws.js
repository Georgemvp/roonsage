// =============================================================================
// WebSocket client for live worker progress.
// =============================================================================
//
// One persistent connection per channel, shared across views. The backend ws
// endpoint sits at /ws/<channel> and publishes JSON messages. Listeners
// subscribe via subscribe(channel, handler) and get a disposer back.
//
// Auto-reconnect with exponential back-off, capped at 30 s. The server emits
// {"type": "ping"} every 25 s to keep proxies awake; we ignore those frames.

const _sockets = new Map();         // channel → WebSocket
const _listeners = new Map();       // channel → Set<handler>
const _backoff = new Map();         // channel → attempt count

const VALID_CHANNELS = new Set([
    'enrichment',
    'audio_features',
    'clustering',
    'sync',
    'automations',
    'dashboard',
]);

function _wsUrl(channel) {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    return `${proto}//${location.host}/ws/${channel}`;
}

function _open(channel) {
    const existing = _sockets.get(channel);
    if (existing && existing.readyState <= WebSocket.OPEN) return existing;

    const ws = new WebSocket(_wsUrl(channel));
    _sockets.set(channel, ws);

    ws.addEventListener('open', () => {
        _backoff.set(channel, 0);
    });

    ws.addEventListener('message', (ev) => {
        const handlers = _listeners.get(channel);
        if (!handlers || handlers.size === 0) return;
        let data;
        try { data = JSON.parse(ev.data); } catch { data = ev.data; }
        if (data?.type === 'ping') return;
        handlers.forEach((cb) => {
            try { cb(data); } catch (e) { console.warn('[ws] handler failed:', e); }
        });
    });

    ws.addEventListener('close', () => {
        _sockets.delete(channel);
        const attempts = (_backoff.get(channel) || 0) + 1;
        _backoff.set(channel, attempts);
        // Only reconnect if there are still listeners interested.
        if (_listeners.get(channel)?.size) {
            const wait = Math.min(30_000, 1_000 * 2 ** Math.min(attempts, 5));
            setTimeout(() => _open(channel), wait);
        }
    });

    return ws;
}

/**
 * Subscribe to a channel. Returns a disposer function.
 *
 * @param {string} channel
 * @param {(data: any) => void} handler
 * @returns {() => void} disposer
 */
export function subscribe(channel, handler) {
    if (!VALID_CHANNELS.has(channel)) {
        console.warn(`[ws] unknown channel "${channel}"`);
        return () => {};
    }
    let set = _listeners.get(channel);
    if (!set) {
        set = new Set();
        _listeners.set(channel, set);
    }
    set.add(handler);
    _open(channel);
    return () => {
        const s = _listeners.get(channel);
        s?.delete(handler);
        if (s && s.size === 0) {
            _sockets.get(channel)?.close();
            _sockets.delete(channel);
        }
    };
}
