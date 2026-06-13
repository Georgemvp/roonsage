import { clsx } from "clsx";
import type { ReactNode } from "react";

type CardProps = {
  children: ReactNode;
  className?: string;
  /** Visual weight: glass = subtle, strong = more opaque (use for modals/dropdowns) */
  variant?: "glass" | "strong";
  /** Larger bento cards span multiple grid columns */
  span?: 1 | 2 | 3 | 4;
};

export function Card({ children, className, variant = "glass", span = 1 }: CardProps) {
  return (
    <div
      className={clsx(
        variant === "strong" ? "rs-glass-strong" : "rs-glass",
        "p-5 flex flex-col gap-3",
        span === 2 && "md:col-span-2",
        span === 3 && "md:col-span-3",
        span === 4 && "md:col-span-4",
        className,
      )}
    >
      {children}
    </div>
  );
}

export function CardHeader({ eyebrow, title, action }: { eyebrow?: string; title: string; action?: ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-3">
      <div className="flex flex-col gap-0.5">
        {eyebrow ? (
          <span className="text-[10px] font-semibold uppercase tracking-wider text-[color:var(--color-fg-muted)]">
            {eyebrow}
          </span>
        ) : null}
        <h3 className="text-base font-semibold text-[color:var(--color-fg)]">{title}</h3>
      </div>
      {action ? <div className="shrink-0">{action}</div> : null}
    </div>
  );
}
