// =============================================================================
// Shared UI states — shimmer loaders, error and empty states.
// =============================================================================
//
// One module, three helpers. Replaces ad-hoc inline HTML strings in discovery,
// music-map, song-paths, alchemy, sonic-fingerprint, playlist-prompt and
// friends so visual treatment stays consistent. All copy is in Dutch — see
// CLAUDE.md "Code Style" for the language convention.

const _COPY = {
    loading: 'Wachten op data…',
    emptyTitle: 'Nog niks gevonden',
    emptyHint: 'Probeer een andere filter of kom later terug.',
    errorTitle: 'Iets ging fout',
    errorHint: 'Probeer het zo opnieuw, of check Logs voor details.',
    retry: 'Opnieuw proberen',
};

/**
 * Render a shimmering placeholder grid into `el`.
 * Width parameter accepts CSS values; rows are stacked vertically.
 *
 * @param {HTMLElement} el     mount node — content is replaced
 * @param {Object}      opts
 * @param {number=}     opts.rows    how many shimmer bars (default 3)
 * @param {string=}     opts.label   optional aria-label
 */
export function showShimmer(el, { rows = 3, label } = {}) {
    if (!el) return;
    const ariaLabel = label || _COPY.loading;
    const bars = Array.from({ length: rows }, (_, i) => {
        const width = 90 - i * 14;
        return `<div class="rs-shimmer-bar" style="width:${width}%"></div>`;
    }).join('');
    el.innerHTML = `
        <div class="rs-shimmer-stack" role="status" aria-label="${ariaLabel}">
            ${bars}
        </div>`;
}

/**
 * Render an empty-state inside `el`. Replaces content.
 *
 * @param {HTMLElement} el
 * @param {Object}      opts
 * @param {string=}     opts.title
 * @param {string=}     opts.description
 * @param {string=}     opts.icon       single emoji / symbol
 * @param {{label:string,onClick:Function}=} opts.cta
 */
export function showEmpty(el, { title, description, icon = '✨', cta } = {}) {
    if (!el) return;
    el.innerHTML = `
        <div class="rs-state rs-state--empty" role="status">
            <div class="rs-state-icon" aria-hidden="true">${icon}</div>
            <h4 class="rs-state-title">${title || _COPY.emptyTitle}</h4>
            <p class="rs-state-desc">${description || _COPY.emptyHint}</p>
            ${cta ? `<button class="btn btn-secondary btn-sm rs-state-cta">${cta.label}</button>` : ''}
        </div>`;
    if (cta && typeof cta.onClick === 'function') {
        el.querySelector('.rs-state-cta')?.addEventListener('click', cta.onClick);
    }
}

/**
 * Render an error state inside `el`. Replaces content.
 *
 * @param {HTMLElement} el
 * @param {Object}      opts
 * @param {string=}     opts.title
 * @param {string=}     opts.description
 * @param {Function=}   opts.onRetry    omit to hide the retry button
 */
export function showError(el, { title, description, onRetry } = {}) {
    if (!el) return;
    el.innerHTML = `
        <div class="rs-state rs-state--error" role="alert">
            <div class="rs-state-icon" aria-hidden="true">⚠️</div>
            <h4 class="rs-state-title">${title || _COPY.errorTitle}</h4>
            <p class="rs-state-desc">${description || _COPY.errorHint}</p>
            ${onRetry ? `<button class="btn btn-primary btn-sm rs-state-cta">${_COPY.retry}</button>` : ''}
        </div>`;
    if (typeof onRetry === 'function') {
        el.querySelector('.rs-state-cta')?.addEventListener('click', onRetry);
    }
}

/**
 * Helper for the common "do an async fetch, render result" pattern.
 * Calls fetchFn, shows shimmer during the call, then either renders via render()
 * (on success with non-empty value) or emits an error/empty state.
 *
 * @param {HTMLElement} el
 * @param {() => Promise<any>} fetchFn
 * @param {(value: any) => void} render
 * @param {Object=} opts  forwarded to showEmpty/showError
 */
export async function withState(el, fetchFn, render, opts = {}) {
    showShimmer(el, { rows: opts.shimmerRows ?? 3 });
    try {
        const value = await fetchFn();
        const looksEmpty =
            value == null ||
            (Array.isArray(value) && value.length === 0) ||
            (typeof value === 'object' && Object.keys(value).length === 0);
        if (looksEmpty) {
            showEmpty(el, opts.empty || {});
            return;
        }
        render(value);
    } catch (err) {
        console.warn('[ui-states] fetch failed:', err);
        showError(el, {
            ...(opts.error || {}),
            onRetry: () => withState(el, fetchFn, render, opts),
        });
    }
}
