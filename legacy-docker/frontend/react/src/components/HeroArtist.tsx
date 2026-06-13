import { clsx } from "clsx";
import type { ReactNode } from "react";

type HeroArtistProps = {
  name: string;
  imageUrl?: string | null;
  /** Subtitle / metadata strip (e.g. "12 albums · 184 tracks") */
  meta?: string;
  /** Optional play button or extra action slot */
  primaryAction?: ReactNode;
  secondaryActions?: ReactNode;
  /** Optional accent colour extracted from the artwork */
  accentColor?: string;
};

/**
 * Edge-to-edge artist hero — SoulSync's "current artist" banner pattern.
 *
 * Designed for the mobile library view: a 2:1 image with a gradient overlay,
 * the artist name laid on top, and a row of action buttons at the bottom.
 * Falls back to a flat coloured panel when ``imageUrl`` is missing.
 */
export function HeroArtist({
  name,
  imageUrl,
  meta,
  primaryAction,
  secondaryActions,
  accentColor,
}: HeroArtistProps) {
  // Soft accent ring around the image — defaults to the app's amber accent so
  // we never look "off brand" when the analyser couldn't extract a colour.
  const ring = accentColor || "var(--accent-bright, #e5a00d)";

  return (
    <section
      className={clsx(
        "relative isolate w-full overflow-hidden",
        "h-[44vh] min-h-[260px] max-h-[420px]",
      )}
      aria-label={`Hero ${name}`}
    >
      {imageUrl ? (
        <img
          src={imageUrl}
          alt=""
          loading="eager"
          className="absolute inset-0 h-full w-full object-cover"
        />
      ) : (
        <div
          className="absolute inset-0 h-full w-full"
          style={{
            background: `radial-gradient(circle at 30% 25%, ${ring}33, transparent 65%), var(--bg-elevated, #1f1f24)`,
          }}
        />
      )}
      {/* Bottom-to-top gradient so text stays legible on any artwork */}
      <div
        className="pointer-events-none absolute inset-0"
        style={{
          background:
            "linear-gradient(180deg, transparent 35%, rgba(0,0,0,0.30) 60%, rgba(0,0,0,0.85) 100%)",
        }}
      />
      {/* Subtle accent halo near the title */}
      <div
        className="pointer-events-none absolute -bottom-12 left-1/2 h-40 w-40 -translate-x-1/2 rounded-full opacity-50 blur-3xl"
        style={{ background: ring }}
      />

      <div className="relative flex h-full flex-col justify-end gap-3 p-4">
        <div className="flex flex-col gap-1">
          <h1 className="text-3xl font-bold tracking-tight text-white drop-shadow-md">
            {name}
          </h1>
          {meta ? (
            <p className="text-xs uppercase tracking-wider text-white/70">{meta}</p>
          ) : null}
        </div>

        {(primaryAction || secondaryActions) && (
          <div className="flex items-center gap-2">
            {primaryAction}
            {secondaryActions ? (
              <div className="ml-auto flex items-center gap-1.5">{secondaryActions}</div>
            ) : null}
          </div>
        )}
      </div>
    </section>
  );
}
