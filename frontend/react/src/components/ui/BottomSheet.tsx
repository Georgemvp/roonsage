import { clsx } from "clsx";
import type { ReactNode } from "react";
import { useEffect, useRef, useState } from "react";

type BottomSheetProps = {
  open: boolean;
  onClose: () => void;
  title?: string;
  /** Optional explicit subtitle / hint */
  description?: string;
  children: ReactNode;
  /** When true the sheet covers ~85% of viewport instead of fitting content */
  tall?: boolean;
};

/**
 * Spotify-style modal bottom sheet — slides up from the bottom on mobile.
 *
 * Lifted from SoulSync's library track popover. Designed for action menus
 * (play, queue, add to playlist, etc.). Swipe-to-dismiss is supported via a
 * touch handle at the top. Backdrop click closes too.
 */
export function BottomSheet({
  open,
  onClose,
  title,
  description,
  children,
  tall = false,
}: BottomSheetProps) {
  const [mounted, setMounted] = useState(open);
  const [visible, setVisible] = useState(false);
  const sheetRef = useRef<HTMLDivElement>(null);
  const dragOriginY = useRef<number | null>(null);
  const dragDelta = useRef(0);

  // Animate enter / exit. We keep the DOM mounted during the exit transition
  // and unmount only after it finishes.
  useEffect(() => {
    if (open) {
      setMounted(true);
      // Next frame so the transition fires from the start state.
      requestAnimationFrame(() => setVisible(true));
    } else {
      setVisible(false);
      const t = setTimeout(() => setMounted(false), 220);
      return () => clearTimeout(t);
    }
  }, [open]);

  // Close on Escape so the keyboard-only path works too.
  useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [open, onClose]);

  if (!mounted) return null;

  // Touch handlers: pull the sheet down with the finger; release > 120 px
  // closes it. < 120 px snaps back via the CSS transition.
  const onTouchStart = (e: React.TouchEvent) => {
    dragOriginY.current = e.touches[0].clientY;
    dragDelta.current = 0;
    if (sheetRef.current) sheetRef.current.style.transition = "none";
  };
  const onTouchMove = (e: React.TouchEvent) => {
    if (dragOriginY.current === null) return;
    const delta = e.touches[0].clientY - dragOriginY.current;
    if (delta < 0) return;
    dragDelta.current = delta;
    if (sheetRef.current) {
      sheetRef.current.style.transform = `translateY(${delta}px)`;
    }
  };
  const onTouchEnd = () => {
    if (sheetRef.current) sheetRef.current.style.transition = "";
    if (dragDelta.current > 120) {
      onClose();
    } else if (sheetRef.current) {
      sheetRef.current.style.transform = "";
    }
    dragOriginY.current = null;
    dragDelta.current = 0;
  };

  return (
    <div
      className={clsx(
        "fixed inset-0 z-[120] flex flex-col justify-end transition-colors duration-200",
        visible ? "bg-black/55 backdrop-blur-sm" : "bg-black/0 backdrop-blur-0",
      )}
      onClick={onClose}
      role="dialog"
      aria-modal="true"
      aria-label={title}
    >
      <div
        ref={sheetRef}
        className={clsx(
          "rs-glass-strong relative mx-auto w-full max-w-[480px] rounded-t-2xl",
          "border-t border-x border-[color:var(--color-border)]",
          "px-4 pb-[env(safe-area-inset-bottom)] pt-3 shadow-[0_-12px_40px_rgba(0,0,0,0.45)]",
          "transition-transform duration-200 ease-out will-change-transform",
          visible ? "translate-y-0" : "translate-y-full",
          tall ? "max-h-[85vh] overflow-y-auto" : "max-h-[70vh] overflow-y-auto",
        )}
        onClick={(e) => e.stopPropagation()}
        onTouchStart={onTouchStart}
        onTouchMove={onTouchMove}
        onTouchEnd={onTouchEnd}
      >
        <div className="mx-auto mb-3 h-1.5 w-10 rounded-full bg-white/15" aria-hidden />
        {title ? (
          <div className="mb-2 flex flex-col gap-0.5">
            <h3 className="text-base font-semibold text-[color:var(--color-fg)]">{title}</h3>
            {description ? (
              <p className="text-xs text-[color:var(--color-fg-muted)]">{description}</p>
            ) : null}
          </div>
        ) : null}
        <div className="flex flex-col gap-1.5">{children}</div>
      </div>
    </div>
  );
}

type SheetActionProps = {
  icon?: ReactNode;
  label: string;
  /** Optional one-line description shown under the label */
  hint?: string;
  onClick?: () => void;
  /** Show a danger-coloured row (Verwijderen, etc.) */
  danger?: boolean;
  disabled?: boolean;
};

/**
 * One row inside a BottomSheet. Native button so keyboard focus works.
 */
export function SheetAction({
  icon,
  label,
  hint,
  onClick,
  danger,
  disabled,
}: SheetActionProps) {
  return (
    <button
      type="button"
      onClick={onClick}
      disabled={disabled}
      className={clsx(
        "flex w-full items-center gap-3 rounded-lg px-3 py-3 text-left",
        "transition-colors hover:bg-white/[0.06] active:bg-white/[0.10]",
        "disabled:opacity-50 disabled:hover:bg-transparent",
        danger ? "text-[color:var(--color-error)]" : "text-[color:var(--color-fg)]",
      )}
    >
      {icon ? <span className="shrink-0 text-lg">{icon}</span> : null}
      <span className="flex flex-1 flex-col">
        <span className="text-sm font-medium">{label}</span>
        {hint ? <span className="text-xs text-[color:var(--color-fg-muted)]">{hint}</span> : null}
      </span>
    </button>
  );
}
