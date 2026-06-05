import { clsx } from "clsx";
import type { ButtonHTMLAttributes } from "react";

type Variant = "primary" | "ghost" | "danger";

export function Button({
  variant = "primary",
  className,
  ...rest
}: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: Variant }) {
  return (
    <button
      className={clsx(
        "inline-flex items-center justify-center gap-2 rounded-full px-4 py-1.5 text-sm font-semibold transition active:scale-[0.98] disabled:cursor-not-allowed disabled:opacity-50",
        variant === "primary" &&
          "bg-[color:var(--color-accent)] text-black hover:brightness-110",
        variant === "ghost" &&
          "bg-transparent text-[color:var(--color-fg)] hover:bg-white/5 border border-[color:var(--color-border)]",
        variant === "danger" &&
          "bg-[color:var(--color-danger)]/15 text-[color:var(--color-danger)] hover:bg-[color:var(--color-danger)]/25",
        className,
      )}
      {...rest}
    />
  );
}
