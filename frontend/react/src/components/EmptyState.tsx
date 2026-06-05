import type { ReactNode } from "react";
import { Button } from "./ui/Button";

type Props = {
  icon?: ReactNode;
  title: string;
  description?: string;
  cta?: { label: string; onClick: () => void };
};

export function EmptyState({ icon, title, description, cta }: Props) {
  return (
    <div className="flex flex-col items-center gap-3 py-10 text-center">
      {icon ? <div className="text-3xl opacity-60">{icon}</div> : null}
      <h4 className="text-base font-semibold">{title}</h4>
      {description ? (
        <p className="max-w-sm text-sm text-[color:var(--color-fg-muted)]">{description}</p>
      ) : null}
      {cta ? (
        <Button variant="ghost" onClick={cta.onClick}>
          {cta.label}
        </Button>
      ) : null}
    </div>
  );
}

export function ErrorState({
  title = "Iets ging fout",
  description,
  onRetry,
}: {
  title?: string;
  description?: string;
  onRetry?: () => void;
}) {
  return (
    <div className="flex flex-col items-center gap-3 py-10 text-center">
      <div className="text-3xl">⚠️</div>
      <h4 className="text-base font-semibold">{title}</h4>
      {description ? (
        <p className="max-w-sm text-sm text-[color:var(--color-fg-muted)]">{description}</p>
      ) : null}
      {onRetry ? (
        <Button variant="ghost" onClick={onRetry}>
          Opnieuw proberen
        </Button>
      ) : null}
    </div>
  );
}
