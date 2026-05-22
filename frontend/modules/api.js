// =============================================================================
// API Calls
// =============================================================================

import { state } from './state.js';

export async function apiCall(endpoint, options = {}) {
    const response = await fetch(`/api${endpoint}`, {
        headers: {
            'Content-Type': 'application/json',
            ...options.headers,
        },
        ...options,
    });

    if (!response.ok) {
        const error = await response.json().catch(() => ({ detail: 'Unknown error' }));
        const detail = Array.isArray(error.detail) ? error.detail.map(e => e.msg).join('; ') : error.detail;
        throw new Error(detail || error.error || 'Request failed');
    }

    if (response.status === 204) return null;
    return response.json();
}

export async function fetchConfig() {
    return apiCall('/config');
}

export async function updateConfig(updates) {
    return apiCall('/config', {
        method: 'POST',
        body: JSON.stringify(updates),
    });
}

// =============================================================================
// Ollama API Calls
// =============================================================================

export async function fetchOllamaStatus(url) {
    return apiCall(`/ollama/status?url=${encodeURIComponent(url)}`);
}

export async function fetchOllamaModels(url) {
    return apiCall(`/ollama/models?url=${encodeURIComponent(url)}`);
}

export async function fetchOllamaModelInfo(url, modelName) {
    return apiCall(`/ollama/model-info?url=${encodeURIComponent(url)}&model=${encodeURIComponent(modelName)}`);
}

// =============================================================================
// Setup Wizard API Calls
// =============================================================================

export async function fetchSetupStatus() {
    return apiCall('/setup/status');
}

export async function validateRoon(host, port) {
    return apiCall('/setup/validate-roon', {
        method: 'POST',
        body: JSON.stringify({ roon_host: host, roon_port: parseInt(port) || 9330 }),
    });
}

export async function validateAI(provider, apiKey, ollamaUrl, customUrl) {
    return apiCall('/setup/validate-ai', {
        method: 'POST',
        body: JSON.stringify({
            provider,
            api_key: apiKey || '',
            ollama_url: ollamaUrl || '',
            custom_url: customUrl || '',
        }),
    });
}

export async function completeSetup() {
    return apiCall('/setup/complete', { method: 'POST' });
}

export async function analyzePrompt(prompt, useTasteProfile = true) {
    return apiCall('/analyze/prompt', {
        method: 'POST',
        body: JSON.stringify({ prompt, use_taste_profile: useTasteProfile }),
    });
}

export async function searchTracks(query) {
    return apiCall(`/library/search?q=${encodeURIComponent(query)}`);
}

export async function analyzeTrack(track) {
    // Pass the full track object so the backend can skip the Roon Browse API
    // lookup (which returns navigation items instead of real track metadata).
    return apiCall('/analyze/track', {
        method: 'POST',
        body: JSON.stringify({
            item_key: track.item_key,
            title: track.title || null,
            artist: track.artist || null,
            album: track.album || null,
            year: track.year || null,
            genres: Array.isArray(track.genres) ? track.genres : [],
            duration_ms: track.duration_ms || 0,
        }),
    });
}

// Module-level abort controller for SSE requests
// Allows aborting previous request when starting a new one
export let currentAbortController = null;
// pendingNavHash lives in events.js (not here) — do not declare it here


export function generatePlaylistStream(request, onProgress, onComplete, onError) {
    // Abort any previous in-flight request
    if (currentAbortController) {
        currentAbortController.abort();
    }

    // Timeout handling - 10 minutes for local providers, 5 minutes for cloud
    let timeoutId = null;
    let completed = false;
    currentAbortController = new AbortController();
    const isLocalProvider = state.config?.is_local_provider ?? false;
    const TIMEOUT_MS = isLocalProvider ? 600000 : 300000;  // 10 min vs 5 min

    function resetTimeout() {
        if (timeoutId) clearTimeout(timeoutId);
        timeoutId = setTimeout(() => {
            currentAbortController.abort();
            onError(new Error('Request timed out. Try selecting some filters to reduce the library size.'));
        }, TIMEOUT_MS);
    }

    function clearTimeoutHandler() {
        if (timeoutId) {
            clearTimeout(timeoutId);
            timeoutId = null;
        }
    }

    resetTimeout();

    // Use fetch with streaming for SSE (EventSource doesn't support POST)
    fetch('/api/generate/stream', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(request),
        signal: currentAbortController.signal,
    }).then(response => {
        if (!response.ok) {
            clearTimeoutHandler();
            throw new Error(`HTTP ${response.status}`);
        }

        const reader = response.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';

        function processStream() {
            reader.read().then(({ done, value }) => {
                // Reset timeout on each chunk received
                if (!done) {
                    resetTimeout();
                }

                // Decode and add to buffer (even if done, to flush any remaining)
                buffer += decoder.decode(value, { stream: !done });
                const lines = buffer.split('\n');
                buffer = lines.pop(); // Keep incomplete line in buffer

                // SSE parsing: accumulate data until blank line signals end of event.
                // This prevents failures when large data lines are split across chunks.
                // See: https://html.spec.whatwg.org/multipage/server-sent-events.html
                let currentEvent = null;
                let currentData = '';
                for (const line of lines) {
                    if (line.startsWith('event: ')) {
                        currentEvent = line.slice(7);
                        currentData = '';
                    } else if (line.startsWith('data: ')) {
                        // Accumulate data (SSE can have multiple data: lines per event)
                        currentData += line.slice(6);
                    } else if (line === '' && currentEvent && currentData) {
                        // Blank line = end of SSE event, now parse complete data
                        try {
                            const data = JSON.parse(currentData);
                            if (currentEvent === 'progress') {
                                onProgress(data);
                            } else if (currentEvent === 'narrative') {
                                // Store narrative data in state
                                state.playlistTitle = data.playlist_title || '';
                                state.narrative = data.narrative || '';
                                state.trackReasons = data.track_reasons || {};
                                state.userRequest = data.user_request || '';
                                // Initialize tracks array for batched receiving
                                state.pendingTracks = [];
                                console.log('[RoonSage] Narrative received:', state.playlistTitle);
                            } else if (currentEvent === 'tracks') {
                                // Accumulate track batches
                                if (data.batch && Array.isArray(data.batch)) {
                                    state.pendingTracks = state.pendingTracks || [];
                                    state.pendingTracks.push(...data.batch);
                                    console.log('[RoonSage] Track batch received, total:', state.pendingTracks.length);
                                }
                            } else if (currentEvent === 'complete') {
                                console.log('[RoonSage] Complete event received, pending tracks:', state.pendingTracks?.length || 0);
                                clearTimeoutHandler();
                                completed = true;
                                // Merge accumulated tracks into complete data
                                const completeData = {
                                    ...data,
                                    tracks: state.pendingTracks || data.tracks || [],
                                };
                                state.pendingTracks = [];
                                onComplete(completeData);
                            } else if (currentEvent === 'error') {
                                clearTimeoutHandler();
                                onError(new Error(data.message));
                            }
                        } catch (e) {
                            console.error('[RoonSage] Failed to parse SSE event:', currentEvent, e);
                        }
                        currentEvent = null;
                        currentData = '';
                    }
                }

                if (done) {
                    clearTimeoutHandler();
                    if (buffer.trim().length > 0) {
                        console.warn('[RoonSage] Stream ended with unparsed buffer:', buffer);
                    }
                    // iOS Safari fallback: if stream ended without complete event but we have tracks
                    if (state.pendingTracks && state.pendingTracks.length > 0 && !completed) {
                        console.warn('[RoonSage] Stream ended without complete event, synthesizing completion with', state.pendingTracks.length, 'tracks');
                        const syntheticComplete = {
                            tracks: state.pendingTracks,
                            track_count: state.pendingTracks.length,
                            playlist_title: state.playlistTitle || 'Playlist',
                            narrative: state.narrative || '',
                        };
                        state.pendingTracks = [];
                        onComplete(syntheticComplete);
                    }
                    return;
                }

                processStream();
            }).catch(err => {
                clearTimeoutHandler();
                if (err.name !== 'AbortError') {
                    onError(err);
                }
            });
        }

        processStream();
    }).catch(err => {
        clearTimeoutHandler();
        if (err.name !== 'AbortError') {
            onError(err);
        }
    });
}

// =============================================================================
// Instant Queue API Calls (005)
// =============================================================================

export async function fetchRoonZones() {
    return apiCall('/roon/zones');
}

export async function createPlayQueue(itemKeys, zoneId, mode) {
    return apiCall('/queue', {
        method: 'POST',
        body: JSON.stringify({ item_keys: itemKeys, zone_id: zoneId, mode }),
    });
}

export async function fetchLibraryStats() {
    // Try the cached endpoint first — it reads SQLite and never holds _browse_lock.
    // Fall back to the live Roon endpoint only when the cache has no genres yet
    // (i.e., the library has never been synced).
    try {
        const cached = await apiCall('/library/stats/cached');
        if (cached && cached.genres && cached.genres.length > 0) {
            return cached;
        }
    } catch (_) {
        // Cache unavailable — fall through to live endpoint
    }
    return apiCall('/library/stats');
}

export async function fetchLibraryStatus() {
    return apiCall('/library/status');
}

export async function triggerLibrarySync() {
    return apiCall('/library/sync', { method: 'POST' });
}
