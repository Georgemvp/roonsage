import { clsx } from "clsx";

type Props = {
  /** 0..100 — clamped */
  value: number;
  label?: string;
  /** "ring" for circular, "bar" for horizontal */
  variant?: "ring" | "bar";
  className?: string;
};

export function Progress({ value, label, variant = "bar", className }: Props) {
  const pct = Math.max(0, Math.min(100, value));

  if (variant === "ring") {
    const r = 28;
    const c = 2 * Math.PI * r;
    const offset = c - (pct / 100) * c;
    return (
      <div
        className={clsx("relative inline-flex items-center justify-center", className)}
        aria-label={label}
        role="progressbar"
        aria-valuenow={pct}
      >
        <svg width={70} height={70}>
          <circle cx={35} cy={35} r={r} stroke="rgba(255,255,255,0.08)" strokeWidth={6} fill="none" />
          <circle
            cx={35}
            cy={35}
            r={r}
            stroke="var(--color-accent)"
            strokeWidth={6}
            fill="none"
            strokeDasharray={c}
            strokeDashoffset={offset}
            strokeLinecap="round"
            transform="rotate(-90 35 35)"
            style={{ transition: "stroke-dashoffset 350ms ease" }}
          />
        </svg>
        <span className="absolute text-sm font-semibold tabular-nums">{Math.round(pct)}%</span>
      </div>
    );
  }

  return (
    <div className={clsx("w-full", className)}>
      {label ? (
        <div className="flex justify-between text-[11px] text-[color:var(--color-fg-muted)] mb-1">
          <span>{label}</span>
          <span className="tabular-nums">{Math.round(pct)}%</span>
        </div>
      ) : null}
      <div className="h-1.5 w-full overflow-hidden rounded-full bg-white/5">
        <div
          className="h-full rounded-full bg-[color:var(--color-accent)]"
          style={{ width: `${pct}%`, transition: "width 350ms ease" }}
        />
      </div>
    </div>
  );
}
