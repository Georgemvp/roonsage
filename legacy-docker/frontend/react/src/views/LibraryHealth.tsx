import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { api } from "@/lib/api-client";
import { Card, CardHeader } from "@/components/ui/Card";
import { Button } from "@/components/ui/Button";
import { Progress } from "@/components/ui/Progress";
import { ShimmerStack } from "@/components/ui/Shimmer";
import { ErrorState, EmptyState } from "@/components/EmptyState";
import { showToast } from "@/lib/bridge";

type HealthSummary = {
  duplicates: { count: number; samples: { artist: string; title: string; album_count: number }[] };
  missing_metadata: {
    no_genre: number;
    no_year: number;
    no_art: number;
    no_bpm: number;
    no_key: number;
  };
  album_consistency: {
    inconsistent_albums: number;
    samples: { album: string; artist: string; release_id_count: number }[];
  };
  stale_entries: { count: number; older_than_days: number };
  disk_usage: { available: boolean; bytes_total: number | null; per_genre: { genre: string; bytes: number }[] };
  dead_files?: { available: boolean; missing: number; checked: number };
};

export function LibraryHealth() {
  const qc = useQueryClient();
  const { data, isLoading, error, refetch } = useQuery<HealthSummary>({
    queryKey: ["library-health"],
    queryFn: () => api<HealthSummary>("/library-health/summary"),
  });

  const fixDuplicates = useMutation({
    mutationFn: () => api("/library-health/fix-duplicates", { method: "POST" }),
    onSuccess: () => {
      showToast("Duplicaten markering bijgewerkt", "success");
      qc.invalidateQueries({ queryKey: ["library-health"] });
    },
    onError: (err) => showToast(`Fout: ${(err as Error).message}`, "error"),
  });

  const reenrichMissing = useMutation({
    mutationFn: () => api("/library-health/reenrich-missing", { method: "POST" }),
    onSuccess: () => {
      showToast("Re-enrich gepland voor ontbrekende metadata", "success");
      qc.invalidateQueries({ queryKey: ["library-health"] });
    },
  });

  const reanalyseBpm = useMutation({
    mutationFn: () => api("/library-health/reanalyse-missing-bpm", { method: "POST" }),
    onSuccess: () => {
      showToast("BPM-analyse gepland voor ontbrekende tracks", "success");
      qc.invalidateQueries({ queryKey: ["library-health"] });
    },
  });

  const recomputeLive = useMutation({
    mutationFn: () => api("/library-health/recompute-live-flags", { method: "POST" }),
    onSuccess: () => {
      showToast("Live-vlaggen herberekend", "success");
      qc.invalidateQueries({ queryKey: ["library-health"] });
    },
  });

  const scanDeadFiles = useMutation({
    mutationFn: () =>
      api<{ available: boolean; missing: number; checked: number }>(
        "/library-health/scan-dead-files",
        { method: "POST" },
      ),
    onSuccess: (res) => {
      if (!res.available) {
        showToast("MUSIC_LIBRARY_PATH ontbreekt — dead-file scan overgeslagen", "error");
      } else {
        showToast(`${res.missing} ontbrekende files (van ${res.checked})`, "success");
      }
      qc.invalidateQueries({ queryKey: ["library-health"] });
    },
  });

  const fixAll = useMutation({
    mutationFn: () => api("/library-health/fix-all", { method: "POST" }),
    onSuccess: () => {
      showToast("Alle maintenance-jobs uitgevoerd", "success");
      qc.invalidateQueries({ queryKey: ["library-health"] });
    },
    onError: (err) => showToast(`Fout: ${(err as Error).message}`, "error"),
  });

  if (isLoading) return <ShimmerStack rows={6} />;
  if (error) return <ErrorState description={(error as Error).message} onRetry={() => refetch()} />;
  if (!data) return null;

  const totalMissing =
    data.missing_metadata.no_genre +
    data.missing_metadata.no_year +
    data.missing_metadata.no_art +
    data.missing_metadata.no_bpm +
    data.missing_metadata.no_key;

  const anyPending =
    fixAll.isPending ||
    fixDuplicates.isPending ||
    reenrichMissing.isPending ||
    reanalyseBpm.isPending ||
    recomputeLive.isPending ||
    scanDeadFiles.isPending;

  return (
    <div className="flex flex-col gap-4">
      <Card>
        <CardHeader
          eyebrow="One-click"
          title="Fix All"
          action={
            <Button onClick={() => fixAll.mutate()} disabled={anyPending}>
              {fixAll.isPending ? "Bezig…" : "Run alle maintenance jobs"}
            </Button>
          }
        />
        <p className="text-xs text-[color:var(--color-fg-muted)]">
          Markeert duplicaten · herberekent live-vlaggen · re-queued ontbrekende metadata &amp; BPM ·
          scant dead files. Niets wordt verwijderd — alles is reversibel.
        </p>
      </Card>

      <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
      <Card>
        <CardHeader
          eyebrow="Duplicaten"
          title={`${data.duplicates.count} potentiële duplicaten`}
          action={
            data.duplicates.count > 0 ? (
              <Button onClick={() => fixDuplicates.mutate()} disabled={fixDuplicates.isPending}>
                Marker als duplicaat
              </Button>
            ) : null
          }
        />
        {data.duplicates.samples.length === 0 ? (
          <EmptyState title="Geen duplicaten gevonden" />
        ) : (
          <ul className="flex flex-col gap-1.5 text-sm">
            {data.duplicates.samples.slice(0, 8).map((d, i) => (
              <li key={i} className="flex items-center justify-between gap-2 rounded bg-white/[0.03] px-2 py-1.5">
                <span className="truncate">
                  <strong>{d.artist}</strong> — {d.title}
                </span>
                <span className="text-xs text-[color:var(--color-fg-muted)]">{d.album_count}×</span>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card>
        <CardHeader
          eyebrow="Metadata"
          title={`${totalMissing.toLocaleString("nl-NL")} ontbrekende velden`}
          action={
            totalMissing > 0 ? (
              <Button onClick={() => reenrichMissing.mutate()} disabled={reenrichMissing.isPending}>
                Re-enrich
              </Button>
            ) : null
          }
        />
        <MetadataRow label="Genre" value={data.missing_metadata.no_genre} />
        <MetadataRow label="Jaar" value={data.missing_metadata.no_year} />
        <MetadataRow label="Album art" value={data.missing_metadata.no_art} />
        <MetadataRow label="BPM" value={data.missing_metadata.no_bpm} />
        <MetadataRow label="Toonsoort" value={data.missing_metadata.no_key} />
        {data.missing_metadata.no_bpm > 0 ? (
          <div className="mt-2">
            <Button onClick={() => reanalyseBpm.mutate()} disabled={reanalyseBpm.isPending}>
              Re-analyse BPM
            </Button>
          </div>
        ) : null}
      </Card>

      <Card>
        <CardHeader
          eyebrow="Live / commentary"
          title="Hersample is_live flags"
          action={
            <Button onClick={() => recomputeLive.mutate()} disabled={recomputeLive.isPending}>
              Herbereken
            </Button>
          }
        />
        <p className="text-xs text-[color:var(--color-fg-muted)]">
          Scant titel + album op trefwoorden (live, unplugged, in concert, commentary) en zet
          de <code>is_live</code> kolom opnieuw. Roon-sync kan de vlag laten verouderen na rename.
        </p>
      </Card>

      <Card>
        <CardHeader
          eyebrow="Dead files"
          title={
            data.dead_files?.available
              ? `${data.dead_files.missing} missende bestanden (van ${data.dead_files.checked})`
              : "Niet beschikbaar"
          }
          action={
            <Button onClick={() => scanDeadFiles.mutate()} disabled={scanDeadFiles.isPending}>
              Volledige scan
            </Button>
          }
        />
        <p className="text-xs text-[color:var(--color-fg-muted)]">
          Vergelijkt <code>track_audio_features.file_path</code> met het filesystem en zet
          <code> file_missing=1</code> op verdwenen tracks. Niets wordt verwijderd; reversibel.
        </p>
      </Card>

      <Card>
        <CardHeader
          eyebrow="Album consistency"
          title={`${data.album_consistency.inconsistent_albums} inconsistente albums`}
        />
        <p className="text-xs text-[color:var(--color-fg-muted)]">
          Picard-style controle: alle tracks van een album delen idealiter dezelfde MusicBrainz release-ID.
          Tracks met afwijkende ID's komen vaak in Roon als losse mini-albums binnen.
        </p>
        {data.album_consistency.samples.length === 0 ? (
          <EmptyState title="Albums zijn netjes" />
        ) : (
          <ul className="flex flex-col gap-1.5 text-sm">
            {data.album_consistency.samples.slice(0, 6).map((a, i) => (
              <li key={i} className="flex items-center justify-between gap-2 rounded bg-white/[0.03] px-2 py-1.5">
                <span className="truncate">
                  <strong>{a.album}</strong> — {a.artist}
                </span>
                <span className="rs-pill">{a.release_id_count} IDs</span>
              </li>
            ))}
          </ul>
        )}
      </Card>

      <Card>
        <CardHeader
          eyebrow="Stale"
          title={`${data.stale_entries.count} verouderde cache-rijen`}
        />
        <p className="text-xs text-[color:var(--color-fg-muted)]">
          Tracks die ≥ {data.stale_entries.older_than_days} dagen niet meer in Roon zijn, maar nog in de
          lokale cache staan. Veilig om te verwijderen.
        </p>
      </Card>

      {data.disk_usage.available ? (
        <Card span={2}>
          <CardHeader eyebrow="Disk usage" title="Per genre" />
          <ul className="grid grid-cols-2 gap-2 text-xs md:grid-cols-3">
            {data.disk_usage.per_genre.slice(0, 9).map((g) => (
              <li key={g.genre}>
                <Progress label={g.genre} value={data.disk_usage.bytes_total ? (g.bytes / data.disk_usage.bytes_total) * 100 : 0} />
                <span className="text-[10px] text-[color:var(--color-fg-muted)]">
                  {(g.bytes / 1024 / 1024 / 1024).toFixed(1)} GB
                </span>
              </li>
            ))}
          </ul>
        </Card>
      ) : null}
      </div>
    </div>
  );
}

function MetadataRow({ label, value }: { label: string; value: number }) {
  return (
    <div className="flex items-center justify-between text-sm">
      <span>{label}</span>
      <span className="tabular-nums text-[color:var(--color-fg-muted)]">{value.toLocaleString("nl-NL")}</span>
    </div>
  );
}
