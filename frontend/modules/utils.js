// =============================================================================
// Utility Functions
// =============================================================================

export function escapeHtml(str) {
    if (!str) return '';
    return str
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#039;');
}

export function artistHue(name) {
    if (!name) return -1;
    let h = 5381;
    for (let i = 0; i < name.length; i++) h = ((h << 5) + h + name.charCodeAt(i)) >>> 0;
    return h % 360;
}

export function artPlaceholderHtml(artist, large = false) {
    const hue = artistHue(artist);
    const letter = artist ? artist.charAt(0).toUpperCase() : '♫';
    const bg = hue >= 0 ? `hsl(${hue},30%,20%)` : 'hsl(0,0%,20%)';
    const fg = hue >= 0 ? `hsl(${hue},40%,60%)` : 'hsl(0,0%,55%)';
    const glow = large && hue >= 0 ? `background-image:radial-gradient(circle,hsl(${hue},40%,35%) 0%,transparent 70%);` : '';
    return `<div class="art-placeholder" style="background-color:${bg};color:${fg};${glow}">${escapeHtml(letter)}</div>`;
}

export function trackArtHtml(track) {
    if (track.art_url) {
        return `<img class="track-art" src="${escapeHtml(track.art_url)}"
                     alt="${escapeHtml(track.album)}" loading="lazy"
                     data-artist="${escapeHtml(track.artist || '')}"
                     onerror="this.outerHTML=artPlaceholderHtml(this.dataset.artist)">`;
    }
    return artPlaceholderHtml(track.artist);
}
