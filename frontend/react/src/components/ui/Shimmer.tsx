import { clsx } from "clsx";

export function Shimmer({
  className,
  height = 16,
  width = "100%",
}: {
  className?: string;
  height?: number | string;
  width?: number | string;
}) {
  return (
    <div
      className={clsx("rs-shimmer", className)}
      style={{ height, width }}
      aria-hidden="true"
    />
  );
}

export function ShimmerStack({ rows = 3 }: { rows?: number }) {
  return (
    <div className="flex flex-col gap-2">
      {Array.from({ length: rows }, (_, i) => (
        <Shimmer key={i} height={14} width={`${85 - i * 12}%`} />
      ))}
    </div>
  );
}
