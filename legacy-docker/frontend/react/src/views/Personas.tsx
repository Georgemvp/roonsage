import { useQuery, useMutation } from "@tanstack/react-query";
import { api } from "@/lib/api-client";
import { Card, CardHeader } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { ShimmerStack } from "@/components/ui/Shimmer";
import { ErrorState } from "@/components/EmptyState";
import { getActiveZoneId, showToast } from "@/lib/bridge";
import { useState } from "react";

/*
 * Playlist persona picker. Each persona is a named, opinionated generator
 * served by /api/personas/<slug>/preview (returns 25–50 tracks). Playing
 * triggers /api/personas/<slug>/play which posts to /api/roon/play-tracks.
 */

type Persona = {
  slug: string;
  name: string;
  emoji: string;
  description: string;
  source: string;
  generated_at: string | null;
  track_count: number;
};

type PreviewTrack = {
  number: number;
  title: string;
  artist: string;
  album: string;
  art_key: string | null;
};

export function Personas() {
  const [active, setActive] = useState<string | null>(null);

  const { data: personas, isLoading, error, refetch } = useQuery<Persona[]>({
    queryKey: ["personas"],
    queryFn: () => api<Persona[]>("/personas/list"),
  });

  if (isLoading) return <ShimmerStack rows={8} />;
  if (error) return <ErrorState description={(error as Error).message} onRetry={() => refetch()} />;
  if (!personas) return null;

  return (
    <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
      {personas.map((p) => (
        <PersonaCard key={p.slug} persona={p} active={active === p.slug} onActivate={() => setActive(p.slug)} />
      ))}
    </div>
  );
}

function PersonaCard({ persona, active, onActivate }: { persona: Persona; active: boolean; onActivate: () => void }) {
  const { data: preview, isFetching } = useQuery<{ tracks: PreviewTrack[] }>({
    queryKey: ["persona-preview", persona.slug],
    queryFn: () => api<{ tracks: PreviewTrack[] }>(`/personas/${persona.slug}/preview`),
    enabled: active,
  });

  const playMut = useMutation({
    mutationFn: () => {
      const zoneId = getActiveZoneId();
      if (!zoneId) throw new Error("Geen Roon-zone actief — kies eerst een zone.");
      return api(`/personas/${persona.slug}/play`, {
        method: "POST",
        json: { zone_id: zoneId },
      });
    },
    onSuccess: () => showToast(`${persona.name} speelt af`, "success"),
    onError: (err) => showToast((err as Error).message, "error"),
  });

  return (
    <Card>
      <CardHeader
        eyebrow={persona.source}
        title={`${persona.emoji} ${persona.name}`}
        action={<span className="rs-pill">{persona.track_count}</span>}
      />
      <p className="text-sm text-[color:var(--color-fg-muted)]">{persona.description}</p>

      {active && preview ? (
        <ul className="max-h-48 overflow-y-auto rounded bg-white/[0.03] p-2 text-xs">
          {preview.tracks.slice(0, 12).map((t) => (
            <li key={t.number} className="flex items-center gap-2 py-1">
              <span className="w-5 shrink-0 text-right tabular-nums text-[color:var(--color-fg-muted)]">{t.number}</span>
              <span className="min-w-0 flex-1 truncate">
                <strong>{t.artist}</strong> — {t.title}
              </span>
            </li>
          ))}
        </ul>
      ) : null}

      <div className="mt-auto flex gap-2">
        <Button variant="ghost" onClick={onActivate} disabled={isFetching}>
          {active ? "Verbergen" : "Preview"}
        </Button>
        <Button onClick={() => playMut.mutate()} disabled={playMut.isPending}>
          Afspelen
        </Button>
      </div>
    </Card>
  );
}
