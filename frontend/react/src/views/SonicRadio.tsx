import { useMutation, useQuery } from "@tanstack/react-query";
import { useEffect, useMemo, useRef, useState } from "react";

import { api } from "@/lib/api-client";
import { Card, CardHeader } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { ShimmerStack } from "@/components/ui/Shimmer";
import { ErrorState, EmptyState } from "@/components/EmptyState";
import { getActiveZoneId, showToast } from "@/lib/bridge";

/*
 * Sonic Radio — continuous-play mode driven by the sonic fingerprint.
 * Backend (backend/routes/sonic_radio.py) maintains a per-session never-repeat
 * queue, biased by time-of-day mood centroid. UI: one big play button, like/skip
 * controls update the in-session profile. The optional seed-track typeahead
 * (this view) lets the user steer the initial fingerprint toward a specific
 * track via /api/library/search → /api/sonic-radio/start with seed_item_key.
 */

type RadioStatus = {
  running: boolean;
  current_track: { title: string; artist: string; art_key: string | null } | null;
  upcoming: { title: string; artist: string }[];
  session_id: string | null;
  played_count: number;
  mood: string;
};

type LibraryTrack = {
  item_key: string;
  title: string;
  artist: string;
  album: string;
  year?: number | null;
};

function shortArtist(artist: string): string {
  const parts = artist.split(",").map((s) => s.trim()).filter(Boolean);
  if (parts.length <= 2) return artist;
  return `${parts[0]}, ${parts[1]} e.a.`;
}

export function SonicRadio() {
  const { data: status, isLoading, error, refetch } = useQuery<RadioStatus>({
    queryKey: ["sonic-radio-status"],
    queryFn: () => api<RadioStatus>("/sonic-radio/summary"),
    refetchInterval: 5_000,
  });

  // --- Seed-track typeahead state ---
  const [seedQuery, setSeedQuery] = useState("");
  const [seedTrack, setSeedTrack] = useState<LibraryTrack | null>(null);
  const [debounced, setDebounced] = useState("");
  const [showSuggestions, setShowSuggestions] = useState(false);
  const inputWrapRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const t = setTimeout(() => setDebounced(seedQuery.trim()), 200);
    return () => clearTimeout(t);
  }, [seedQuery]);

  // Close the suggestion dropdown on outside click.
  useEffect(() => {
    function onDocClick(e: MouseEvent) {
      if (!inputWrapRef.current?.contains(e.target as Node)) {
        setShowSuggestions(false);
      }
    }
    document.addEventListener("mousedown", onDocClick);
    return () => document.removeEventListener("mousedown", onDocClick);
  }, []);

  const suggestionsQuery = useQuery<LibraryTrack[]>({
    queryKey: ["library-search", debounced],
    queryFn: () => api<LibraryTrack[]>(`/library/search?q=${encodeURIComponent(debounced)}`),
    enabled: debounced.length >= 2 && !seedTrack,
    staleTime: 60_000,
  });

  const suggestions = useMemo(() => suggestionsQuery.data?.slice(0, 15) ?? [], [suggestionsQuery.data]);

  // --- Mutations ---
  const startMut = useMutation({
    mutationFn: () => {
      const zoneId = getActiveZoneId();
      if (!zoneId) throw new Error("Geen Roon-zone actief.");
      return api("/sonic-radio/start", {
        method: "POST",
        json: {
          zone_id: zoneId,
          play: true,
          mode: "replace",
          seed_item_key: seedTrack?.item_key ?? null,
        },
      });
    },
    onSuccess: () => {
      showToast(
        seedTrack ? `Sonic Radio rond ${seedTrack.artist} — ${seedTrack.title}` : "Sonic Radio gestart",
        "success",
      );
      refetch();
    },
    onError: (err) => showToast((err as Error).message, "error"),
  });

  const stopMut = useMutation({
    mutationFn: () => {
      const zoneId = getActiveZoneId();
      if (!zoneId) throw new Error("Geen Roon-zone actief.");
      return api("/sonic-radio/stop", { method: "POST", json: { zone_id: zoneId } });
    },
    onSuccess: () => {
      showToast("Sonic Radio gestopt", "info");
      refetch();
    },
  });

  const skipMut = useMutation({
    mutationFn: () => {
      const zoneId = getActiveZoneId();
      if (!zoneId) throw new Error("Geen Roon-zone actief.");
      const trackId = status?.current_track
        ? `${status.current_track.artist}::${status.current_track.title}`
        : "";
      return api("/sonic-radio/skip", { method: "POST", json: { zone_id: zoneId, track_id: trackId } });
    },
  });
  const likeMut = useMutation({
    mutationFn: () => {
      const zoneId = getActiveZoneId();
      if (!zoneId) throw new Error("Geen Roon-zone actief.");
      const trackId = status?.current_track
        ? `${status.current_track.artist}::${status.current_track.title}`
        : "";
      return api("/sonic-radio/like", { method: "POST", json: { zone_id: zoneId, track_id: trackId } });
    },
  });

  if (isLoading) return <ShimmerStack rows={4} />;
  if (error) return <ErrorState description={(error as Error).message} onRetry={() => refetch()} />;
  if (!status) return null;

  function pickTrack(t: LibraryTrack) {
    setSeedTrack(t);
    setSeedQuery(`${t.artist} — ${t.title}`);
    setShowSuggestions(false);
  }

  function clearSeed() {
    setSeedTrack(null);
    setSeedQuery("");
    setShowSuggestions(false);
  }

  return (
    <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
      <Card>
        <CardHeader eyebrow="Sonic Radio" title={status.running ? "Live" : "Klaar om te starten"} />
        {status.running ? (
          <div className="flex flex-col gap-3">
            {status.current_track ? (
              <div className="flex items-center gap-3">
                {status.current_track.art_key ? (
                  <img
                    src={`/api/art/${status.current_track.art_key}?width=64&height=64`}
                    alt=""
                    width={64}
                    height={64}
                    className="shrink-0 rounded-lg object-cover"
                    loading="lazy"
                  />
                ) : (
                  <div className="grid h-16 w-16 shrink-0 place-items-center rounded-lg bg-white/5 text-2xl">♪</div>
                )}
                <div className="min-w-0 flex-1">
                  <div className="line-clamp-2 text-base font-semibold leading-snug">
                    {status.current_track.title}
                  </div>
                  <div className="mt-0.5 truncate text-sm text-[color:var(--color-fg-muted)]">
                    {shortArtist(status.current_track.artist)}
                  </div>
                </div>
              </div>
            ) : (
              <EmptyState title="Wachten op volgende track…" />
            )}
            <div className="text-xs text-[color:var(--color-fg-muted)]">
              {status.played_count} tracks in wachtrij · {status.mood}
            </div>
            <div className="flex gap-2">
              <Button variant="ghost" onClick={() => skipMut.mutate()}>
                Skip
              </Button>
              <Button variant="ghost" onClick={() => likeMut.mutate()}>
                Like
              </Button>
              <Button variant="danger" onClick={() => stopMut.mutate()}>
                Stop
              </Button>
            </div>
          </div>
        ) : (
          <div className="flex flex-col gap-3">
            <div ref={inputWrapRef} className="relative">
              <input
                type="text"
                placeholder="Optioneel: zoek een zaad-track (artiest of titel)"
                value={seedQuery}
                onChange={(e) => {
                  setSeedQuery(e.target.value);
                  setSeedTrack(null);
                  setShowSuggestions(true);
                }}
                onFocus={() => {
                  if (!seedTrack && debounced.length >= 2) setShowSuggestions(true);
                }}
                className="w-full rounded-md border border-[color:var(--color-border)] bg-white/5 px-3 py-2 text-sm outline-none focus:border-[color:var(--color-accent)]"
              />
              {seedTrack ? (
                <button
                  type="button"
                  onClick={clearSeed}
                  aria-label="Zaad-track wissen"
                  className="absolute right-2 top-1/2 -translate-y-1/2 rounded px-2 py-0.5 text-xs text-[color:var(--color-fg-muted)] hover:bg-white/10"
                >
                  ×
                </button>
              ) : null}

              {showSuggestions && !seedTrack && debounced.length >= 2 ? (
                <div
                  className="absolute left-0 right-0 top-full z-10 mt-1 rounded-md border border-[color:var(--color-border)] bg-[color:var(--color-bg)] shadow-xl"
                  style={{ maxHeight: "320px", overflowY: "auto" }}
                >
                  {suggestionsQuery.isLoading ? (
                    <div className="px-3 py-2 text-xs text-[color:var(--color-fg-muted)]">Zoeken…</div>
                  ) : suggestions.length === 0 ? (
                    <div className="px-3 py-2 text-xs text-[color:var(--color-fg-muted)]">
                      Geen tracks gevonden voor "{debounced}"
                    </div>
                  ) : (
                    <ul role="listbox">
                      {suggestions.map((t) => (
                        <li key={t.item_key}>
                          <button
                            type="button"
                            onClick={() => pickTrack(t)}
                            className="flex w-full flex-col gap-0.5 px-3 py-2.5 text-left transition hover:bg-white/8 active:bg-white/12"
                          >
                            <span className="truncate text-sm font-semibold leading-snug">
                              {t.title}
                            </span>
                            <span className="truncate text-xs text-[color:var(--color-fg-muted)]">
                              {t.artist}
                              {t.album ? ` · ${t.album}` : ""}
                              {t.year ? ` · ${t.year}` : ""}
                            </span>
                          </button>
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
              ) : null}
            </div>

            {seedTrack ? (
              <div className="text-[11px] text-[color:var(--color-fg-muted)]">
                Sonic Radio zal de eerste tracks rond deze keuze biasen.
              </div>
            ) : null}

            <Button onClick={() => startMut.mutate()} disabled={startMut.isPending}>
              {startMut.isPending ? "Bezig…" : "Start Sonic Radio"}
            </Button>
          </div>
        )}
      </Card>

      <Card>
        <CardHeader eyebrow="Wachtrij" title="Volgende tracks" />
        {status.upcoming.length === 0 ? (
          <EmptyState title="Lege wachtrij" description="Start de radio om voorstellen te zien." />
        ) : (
          <ul className="flex flex-col gap-1">
            {status.upcoming.slice(0, 10).map((t, i) => (
              <li key={i} className="flex items-center gap-2 rounded bg-white/[0.03] px-2 py-2">
                <span className="w-5 shrink-0 text-right text-xs tabular-nums text-[color:var(--color-fg-muted)]">
                  {i + 1}
                </span>
                <div className="min-w-0 flex-1">
                  <div className="truncate text-sm font-medium">{t.title}</div>
                  <div className="truncate text-xs text-[color:var(--color-fg-muted)]">
                    {shortArtist(t.artist)}
                  </div>
                </div>
              </li>
            ))}
          </ul>
        )}
      </Card>
    </div>
  );
}
