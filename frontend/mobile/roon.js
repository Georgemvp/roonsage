// Shared Roon playback helpers for mobile views.
import { apiCall } from '../modules/api.js';

export async function getZones() {
    try {
        const z = await apiCall('/roon/zones');
        return (Array.isArray(z) ? z : z?.zones || []);
    } catch {
        return [];
    }
}

export async function getActiveZone() {
    const zones = await getZones();
    const withAudio = zones.filter((z) => z.now_playing);
    return withAudio.find((z) => z.state === 'playing') || withAudio[0] || zones[0] || null;
}

const PREF_KEY = 'rs-zone-id';

export function getPreferredZoneId() {
    try { return localStorage.getItem(PREF_KEY) || null; } catch { return null; }
}

export function setPreferredZoneId(id) {
    try {
        if (id) localStorage.setItem(PREF_KEY, id);
        else localStorage.removeItem(PREF_KEY);
    } catch { /* storage blocked */ }
}

// Zone that play actions target: the user's saved preference if it's still
// online, otherwise the currently-playing/first zone.
export async function getDefaultZoneId() {
    const zones = await getZones();
    const pref = getPreferredZoneId();
    if (pref && zones.some((z) => z.zone_id === pref)) return pref;
    const withAudio = zones.filter((z) => z.now_playing);
    const active = withAudio.find((z) => z.state === 'playing') || withAudio[0] || zones[0];
    return active?.zone_id || null;
}

export async function transport(zoneId, action) {
    if (!zoneId) return;
    return apiCall('/roon/transport', {
        method: 'POST',
        body: JSON.stringify({ zone_id: zoneId, action }),
    });
}

export async function setVolume(zoneName, action, value) {
    return apiCall('/roon/volume', {
        method: 'POST',
        body: JSON.stringify({ zone_name: zoneName, action, value }),
    });
}

export async function playAlbum(albumItemKey, zoneId) {
    if (!zoneId) zoneId = await getDefaultZoneId();
    if (!zoneId) throw new Error('Geen zone gevonden');
    return apiCall('/roon/play-album', {
        method: 'POST',
        body: JSON.stringify({ album_item_key: albumItemKey, zone_id: zoneId }),
    });
}

// Play an album by resolving its current track keys from the cache (artist +
// album text). Robust against stale Roon browse keys in cached discovery data.
export async function playAlbumByName(artist, album, zoneId) {
    if (!zoneId) zoneId = await getDefaultZoneId();
    if (!zoneId) throw new Error('Geen zone gevonden');
    const tracks = await apiCall(`/library/album-tracks?artist=${encodeURIComponent(artist)}&album=${encodeURIComponent(album)}`);
    const keys = (tracks || []).map((t) => t.item_key).filter(Boolean);
    if (!keys.length) throw new Error('Album niet gevonden in bibliotheek');
    return apiCall('/queue', {
        method: 'POST',
        body: JSON.stringify({ item_keys: keys, zone_id: zoneId, mode: 'replace' }),
    });
}
