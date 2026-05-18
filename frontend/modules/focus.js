// =============================================================================
// Focus Management (Accessibility)
// =============================================================================

export const focusManager = {
    _stack: [],

    /** Open a modal: save focus, move into modal, trap Tab within it */
    openModal(modalEl) {
        const previousFocus = document.activeElement;

        // Find focusable elements inside the modal
        const focusable = this._getFocusable(modalEl);
        if (focusable.length) {
            const closeBtn = modalEl.querySelector('.modal-close, .bottom-sheet-close');
            requestAnimationFrame(() => (closeBtn || focusable[0]).focus());
        }

        // Trap Tab within modal
        const trapHandler = (e) => {
            if (e.key !== 'Tab') return;
            const els = this._getFocusable(modalEl);
            if (!els.length) return;
            const first = els[0];
            const last = els[els.length - 1];
            if (e.shiftKey && document.activeElement === first) {
                e.preventDefault();
                last.focus();
            } else if (!e.shiftKey && document.activeElement === last) {
                e.preventDefault();
                first.focus();
            }
        };
        document.addEventListener('keydown', trapHandler);
        this._stack.push({ modalEl, previousFocus, trapHandler });
    },

    /** Close a modal: remove trap, restore previous focus.
     *  Accepts an optional modalEl to find the matching entry (safe for non-LIFO order).
     *  Falls back to popping the top entry when called without arguments. */
    closeModal(modalEl) {
        let idx = this._stack.length - 1;
        if (modalEl) {
            idx = this._stack.findLastIndex(e => e.modalEl === modalEl);
        }
        if (idx < 0) return;
        const [entry] = this._stack.splice(idx, 1);
        document.removeEventListener('keydown', entry.trapHandler);
        if (entry.previousFocus && typeof entry.previousFocus.focus === 'function') {
            entry.previousFocus.focus();
        }
    },

    _getFocusable(el) {
        return [...el.querySelectorAll(
            'a[href], button:not([disabled]), textarea, input:not([disabled]), select:not([disabled]), [tabindex]:not([tabindex="-1"])'
        )].filter(e => !e.closest('.hidden') && e.offsetParent !== null);
    }
};
