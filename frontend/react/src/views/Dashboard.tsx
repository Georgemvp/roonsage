import { useQuery, useQueryClient } from "@tanstack/react-query";
import { clsx } from "clsx";
import { api } from "@/lib/api-client";
import { Card, CardHeader } from "@/components/ui/Card";
import { Progress } from "@/components/ui/Progress";
import { ShimmerStack, Shimmer } from "@/components/ui/Shimmer";
import { ErrorState, EmptyState } from "@/components/EmptyState";
import { navigateToHashView, useActiveZoneId } from "@/lib/bridge";
import { useChannel } from "@/lib/ws";

/*
 * Bento-grid home dashboard. Driven by a single aggregator endpoint
 * `/api/dashboard/summary` (backend/routes/dashboard.py) that fans out to the
 * underlying stats / intelligence / circadian / worker / sonic-fingerprint /
 * watchlist endpoints and returns one consolidated JSON payload.
 *
 * WebSocket channel `dashboard` pushes worker-progress deltas so the cards
 * update without re-fetching the aggregator.
 */

type DashboardSummary = {
  now_playing: {
    title: string | null;
    artist: string | null;
    album: string | null;
    art_key: string | null;
    zone_id: string | null;
    zone_name: string | null;
    state: string;
  } | null;
  library: {
    total_tracks: number;
    total_albums: number;
    total_artists: number;
    sync_state: "idle" | "syncing" | "error";
    sync_progress: number | null;
  };
  workers: {
    enrichment: { pending: number; processing: number; processed_24h: number; paused: boolean };
    audio_features: { pending: number; processing: number; processed_24h: number; paused: boolean };
    clustering: { last_run_at: string | null; n_clusters: number | null };
  };
  fingerprint: {
    top_dimensions: { name: string; value: number }[];
    sample_recommendations: { title: string; artist: string; score: number }[];
  } | null;
  today_mix: {
    mood: string;
    energy: number;
    track_count: number;
    cached: boolean;
  };
  recent_history: { title: string; artist: string; played_at: string; art_key: string | null }[];
  watchlist_updates: { artist: string; release_title: string; release_date: string }[];
};

export function Dashboard() {
  const zoneId = useActiveZoneId();
  const qc = useQueryClient();

  // Live updates: when a worker batch completes, invalidate the cached summary
  // so TanStack refetches in the background. We do NOT mix the trigger into
  // the queryKey — that would unmount/remount the result on every tick and
  // flash an empty card. invalidateQueries keeps the prior data visible while
  // the new one loads.
  useChannel("dashboard", () => {
    qc.invalidateQueries({ queryKey: ["dashboard-summary"] });
  });
  useChannel("enrichment", () => {
    qc.invalidateQueries({ queryKey: ["dashboard-summary"] });
  });
  useChannel("audio_features", () => {
    qc.invalidateQueries({ queryKey: ["dashboard-summary"] });
  });

  const { data, isLoading, error, refetch } = useQuery<DashboardSummary>({
    queryKey: ["dashboard-summary"],
    queryFn: () => api<DashboardSummary>("/dashboard/summary"),
    refetchInterval: 30_000,
  });

  if (isLoading) return <DashboardSkeleton />;
  if (error) {
    return (
      <Card span={4}>
        <ErrorState
          title="Dashboard niet beschikbaar"
          description="De aggregator gaf een fout terug — probeer het zo opnieuw."
          onRetry={() => refetch()}
        />
      </Card>
    );
  }
  if (!data) return null;

  return (
    <div className="grid grid-cols-1 gap-4 md:grid-cols-4">
      <NowPlayingCard data={data.now_playing} zoneId={zoneId} />
      <LibraryCard data={data.library} />
      <WorkersCard data={data.workers} />
      <TodayMixCard data={data.today_mix} />
      <FingerprintCard data={data.fingerprint} />
      <RecentHistoryCard data={data.recent_history} />
      <WatchlistCard data={data.watchlist_updates} />
    </div>
  );
}

// ─── Now Playing ──────────────────────────────────────────────────────────

function NowPlayingCard({
  data,
  zoneId,
}: {
  data: DashboardSummary["now_playing"];
  zoneId: string | null;
}) {
  const isPlaying = data?.state === "playing";
  return (
    <Card span={2}>
      <CardHeader
        eyebrow="Now playing"
        title={data?.zone_name ?? "Geen zone actief"}
        action={
          data?.state ? (
            <span className={clsx("rs-pill", isPlaying && "rs-pill-live")}>
              {isPlaying ? <PlayingDot /> : null}
              {data.state}
            </span>
          ) : null
        }
      />
      {data?.title ? (
        <div className="flex items-center gap-4">
          {data.art_key ? (
            <img
              src={`/api/art/${data.art_key}?width=96&height=96`}
              alt=""
              width={96}
              height={96}
              className="rounded-xl object-cover shadow-lg"
              loading="lazy"
            />
          ) : (
            <ArtPlaceholder size={96} />
          )}
          <div className="flex min-w-0 flex-col">
            <span className="truncate text-lg font-semibold">{data.title}</span>
            <span className="truncate text-sm text-[color:var(--color-fg-muted)]">
              {data.artist}
            </span>
            <span className="truncate text-xs text-[color:var(--color-fg-muted)]/70">
              {data.album}
            </span>
          </div>
        </div>
      ) : (
        <div className="flex flex-1 flex-col items-center justify-center gap-3 py-6 text-center">
          <IdleEqualizer />
          <div>
            <h4 className="text-base font-semibold">Niets aan het spelen</h4>
            <p className="mt-1 text-sm text-[color:var(--color-fg-muted)]">
              {zoneId ? "Start iets in Roon om hier feedback te zien." : "Kies eerst een zone."}
            </p>
          </div>
        </div>
      )}
    </Card>
  );
}

function PlayingDot() {
  return (
    <span className="relative inline-flex h-1.5 w-1.5">
      <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-current opacity-60" />
      <span className="relative inline-flex h-1.5 w-1.5 rounded-full bg-current" />
    </span>
  );
}

function ArtPlaceholder({ size }: { size: number }) {
  return (
    <div
      className="grid place-items-center rounded-xl"
      style={{
        width: size,
        height: size,
        background:
          "radial-gradient(circle at 30% 30%, color-mix(in srgb, var(--color-accent) 22%, transparent), transparent 65%), rgba(255,255,255,0.04)",
      }}
    >
      <svg width={size * 0.42} height={size * 0.42} viewBox="0 0 24 24" fill="none" aria-hidden>
        <path
          d="M9 18V6l11-2v12"
          stroke="var(--color-accent)"
          strokeWidth="1.6"
          strokeLinecap="round"
          strokeLinejoin="round"
        />
        <circle cx="7" cy="18" r="2.4" stroke="var(--color-accent)" strokeWidth="1.6" />
        <circle cx="18" cy="16" r="2.4" stroke="var(--color-accent)" strokeWidth="1.6" />
      </svg>
    </div>
  );
}

function IdleEqualizer() {
  // Static, deliberately calm equalizer — no animation when idle so it
  // doesn't compete with the "playing" indicator elsewhere.
  return (
    <div className="flex h-12 items-end gap-1.5 opacity-60">
      {[0.45, 0.7, 0.3, 0.85, 0.5, 0.35].map((h, i) => (
        <span
          key={i}
          className="w-1.5 rounded-full bg-gradient-to-t from-[color:var(--color-accent)]/40 to-[color:var(--color-accent)]/10"
          style={{ height: `${h * 100}%` }}
        />
      ))}
    </div>
  );
}

// ─── Library ──────────────────────────────────────────────────────────────

function LibraryCard({ data }: { data: DashboardSummary["library"] }) {
  return (
    <Card>
      <CardHeader
        eyebrow="Library"
        title="Bibliotheek"
        action={
          <span
            className={clsx(
              "rs-pill",
              data.sync_state === "syncing" && "rs-pill-active",
              data.sync_state === "error" && "rs-pill-danger",
            )}
          >
            {data.sync_state}
          </span>
        }
      />
      <div className="flex items-baseline gap-1.5">
        <span className="text-3xl font-bold tabular-nums text-[color:var(--color-accent)]">
          {data.total_tracks.toLocaleString("nl-NL")}
        </span>
        <span className="text-[10px] uppercase tracking-wider text-[color:var(--color-fg-muted)]">
          tracks
        </span>
      </div>
      <div className="flex items-center gap-3 text-xs text-[color:var(--color-fg-muted)]">
        <span className="flex items-baseline gap-1">
          <span className="text-sm font-semibold tabular-nums text-[color:var(--color-fg)]">
            {data.total_albums.toLocaleString("nl-NL")}
          </span>
          albums
        </span>
        <span className="h-3 w-px bg-white/10" />
        <span className="flex items-baseline gap-1">
          <span className="text-sm font-semibold tabular-nums text-[color:var(--color-fg)]">
            {data.total_artists.toLocaleString("nl-NL")}
          </span>
          artists
        </span>
      </div>
      {data.sync_progress != null ? (
        <Progress value={data.sync_progress} label="Syncing" />
      ) : null}
    </Card>
  );
}

// ─── Workers ──────────────────────────────────────────────────────────────

function WorkersCard({ data }: { data: DashboardSummary["workers"] }) {
  return (
    <Card>
      <CardHeader eyebrow="Workers" title="Achtergrondtaken" />
      <div className="flex flex-col gap-2.5">
        <WorkerRow
          label="Enrichment"
          pending={data.enrichment.pending}
          active={data.enrichment.processing}
          paused={data.enrichment.paused}
        />
        <WorkerRow
          label="Audio features"
          pending={data.audio_features.pending}
          active={data.audio_features.processing}
          paused={data.audio_features.paused}
        />
        <WorkerRow
          label="Clusters"
          pending={0}
          active={data.clustering.n_clusters ?? 0}
          paused={false}
          activeLabel={
            data.clustering.n_clusters != null ? `${data.clustering.n_clusters} clusters` : "—"
          }
        />
      </div>
    </Card>
  );
}

function WorkerRow({
  label,
  pending,
  active,
  paused,
  activeLabel,
}: {
  label: string;
  pending: number;
  active: number;
  paused: boolean;
  activeLabel?: string;
}) {
  const total = pending + active;
  const isIdle = !paused && total === 0;
  const isActive = !paused && active > 0;
  const dotClass = paused
    ? "bg-[color:var(--color-warning)]/70"
    : isActive
      ? "bg-[color:var(--color-success)]"
      : isIdle
        ? "bg-white/15"
        : "bg-[color:var(--color-accent)]";
  const statusText = paused
    ? "gepauzeerd"
    : activeLabel
      ? activeLabel
      : isIdle
        ? "idle"
        : `${active} actief · ${pending} wachtend`;

  return (
    <div>
      <div className="flex items-center gap-2">
        <span className="relative inline-flex h-2 w-2 shrink-0">
          {isActive ? (
            <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-[color:var(--color-success)] opacity-60" />
          ) : null}
          <span className={clsx("relative inline-flex h-2 w-2 rounded-full", dotClass)} />
        </span>
        <span className="text-xs text-[color:var(--color-fg-muted)] flex-1 truncate">{label}</span>
        <span className="text-[11px] tabular-nums text-right text-[color:var(--color-fg-muted)] shrink-0">
          {statusText}
        </span>
      </div>
      {!isIdle && !paused && total > 0 ? (
        <Progress
          value={Math.round((active / Math.max(total, 1)) * 100)}
          className="mt-1.5"
        />
      ) : null}
    </div>
  );
}

// ─── Today's mix ──────────────────────────────────────────────────────────

function TodayMixCard({ data }: { data: DashboardSummary["today_mix"] }) {
  const energyPct = Math.round(data.energy * 100);
  return (
    <Card>
      <CardHeader eyebrow="Vandaag" title={data.mood} />
      <div className="flex items-center gap-4">
        <EnergyRing value={energyPct} />
        <div className="flex flex-col text-xs text-[color:var(--color-fg-muted)]">
          <span>
            <span className="font-semibold text-[color:var(--color-fg)] tabular-nums">
              {data.track_count}
            </span>{" "}
            tracks
          </span>
          <span className="mt-0.5 text-[10px] uppercase tracking-wider">
            {data.cached ? "uit cache" : "vers gegenereerd"}
          </span>
        </div>
      </div>
      <button
        type="button"
        onClick={() => navigateToHashView("circadian-auto")}
        className="mt-auto inline-flex items-center justify-center gap-1.5 rounded-full bg-[color:var(--color-accent)] px-4 py-2 text-sm font-semibold text-black transition hover:brightness-110 active:scale-[0.98]"
      >
        <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" aria-hidden>
          <path d="M8 5v14l11-7z" />
        </svg>
        Speel vandaag's mix
      </button>
    </Card>
  );
}

function EnergyRing({ value }: { value: number }) {
  const r = 22;
  const c = 2 * Math.PI * r;
  const pct = Math.max(0, Math.min(100, value));
  const offset = c - (pct / 100) * c;
  return (
    <div className="relative inline-flex items-center justify-center" aria-label={`Energie ${pct}`}>
      <svg width={56} height={56}>
        <circle cx={28} cy={28} r={r} stroke="rgba(255,255,255,0.08)" strokeWidth={5} fill="none" />
        <circle
          cx={28}
          cy={28}
          r={r}
          stroke="var(--color-accent)"
          strokeWidth={5}
          fill="none"
          strokeDasharray={c}
          strokeDashoffset={offset}
          strokeLinecap="round"
          transform="rotate(-90 28 28)"
          style={{ transition: "stroke-dashoffset 400ms ease" }}
        />
      </svg>
      <div className="absolute flex flex-col items-center leading-none">
        <span className="text-base font-bold tabular-nums">{pct}</span>
        <span className="text-[8px] uppercase tracking-wider text-[color:var(--color-fg-muted)]">
          energie
        </span>
      </div>
    </div>
  );
}

// ─── Sonic fingerprint ────────────────────────────────────────────────────

function FingerprintCard({ data }: { data: DashboardSummary["fingerprint"] }) {
  return (
    <Card span={2}>
      <CardHeader eyebrow="Sonic fingerprint" title="Jouw muzikale DNA" />
      {data?.top_dimensions.length ? (
        <ul className="grid grid-cols-2 gap-x-5 gap-y-2">
          {data.top_dimensions.map((dim) => (
            <FingerprintBar key={dim.name} name={dim.name} value={dim.value} />
          ))}
        </ul>
      ) : (
        <ShimmerStack />
      )}
      <button
        type="button"
        onClick={() => navigateToHashView("sonic-fingerprint")}
        className="mt-auto inline-flex items-center gap-1 self-start text-sm font-medium text-[color:var(--color-accent)] hover:underline"
      >
        Open Fingerprint
        <span aria-hidden>→</span>
      </button>
    </Card>
  );
}

function FingerprintBar({ name, value }: { name: string; value: number }) {
  // value comes in as 0..1 from the fingerprint endpoint; renderer also
  // accepts already-percent values for forward-compat with the radar page.
  const pct = Math.round(value <= 1 ? value * 100 : value);
  return (
    <li className="flex flex-col gap-1">
      <div className="flex items-baseline justify-between gap-2 text-xs">
        <span className="truncate text-[color:var(--color-fg-muted)]">{name}</span>
        <span className="font-mono tabular-nums text-[color:var(--color-fg)]">{pct}</span>
      </div>
      <div className="h-1 w-full overflow-hidden rounded-full bg-white/5">
        <div
          className="h-full rounded-full bg-gradient-to-r from-[color:var(--color-accent)]/70 to-[color:var(--color-accent)]"
          style={{ width: `${pct}%`, transition: "width 400ms ease" }}
        />
      </div>
    </li>
  );
}

// ─── Recent history ───────────────────────────────────────────────────────

function RecentHistoryCard({ data }: { data: DashboardSummary["recent_history"] }) {
  return (
    <Card span={2}>
      <CardHeader eyebrow="Vandaag geluisterd" title="Recent" />
      {data.length ? (
        <ul className="flex flex-col gap-1.5">
          {data.slice(0, 5).map((row, i) => (
            <li
              key={i}
              className="flex items-center gap-3 rounded-lg bg-white/[0.03] px-2 py-1.5 transition hover:bg-white/[0.06]"
            >
              {row.art_key ? (
                <img
                  src={`/api/art/${row.art_key}?width=32&height=32`}
                  alt=""
                  width={32}
                  height={32}
                  className="rounded"
                  loading="lazy"
                />
              ) : (
                <div className="grid h-8 w-8 place-items-center rounded bg-white/5 text-xs">♪</div>
              )}
              <div className="min-w-0 flex-1">
                <div className="truncate text-sm font-medium">{row.title}</div>
                <div className="truncate text-xs text-[color:var(--color-fg-muted)]">
                  {row.artist}
                </div>
              </div>
              <span className="text-[10px] tabular-nums text-[color:var(--color-fg-muted)]">
                {new Date(row.played_at).toLocaleTimeString("nl-NL", {
                  hour: "2-digit",
                  minute: "2-digit",
                })}
              </span>
            </li>
          ))}
        </ul>
      ) : (
        <EmptyState
          icon={<HistoryIcon />}
          title="Nog niets gespeeld vandaag"
          description="Zodra je iets in Roon afspeelt verschijnt het hier."
        />
      )}
    </Card>
  );
}

function HistoryIcon() {
  return (
    <svg width={32} height={32} viewBox="0 0 24 24" fill="none" aria-hidden>
      <circle cx="12" cy="12" r="9" stroke="currentColor" strokeWidth="1.5" />
      <path
        d="M12 7v5l3 2"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

// ─── Watchlist ────────────────────────────────────────────────────────────

function WatchlistCard({ data }: { data: DashboardSummary["watchlist_updates"] }) {
  return (
    <Card span={2}>
      <CardHeader eyebrow="Watchlist" title="Nieuwe releases" />
      {data.length ? (
        <ul className="flex flex-col gap-1.5 text-sm">
          {data.slice(0, 4).map((r, i) => (
            <li
              key={i}
              className="flex items-center justify-between gap-3 rounded-lg bg-white/[0.03] px-2 py-1.5"
            >
              <div className="min-w-0 flex-1">
                <div className="truncate font-medium">{r.release_title}</div>
                <div className="truncate text-xs text-[color:var(--color-fg-muted)]">
                  {r.artist}
                </div>
              </div>
              <span className="text-[10px] tabular-nums text-[color:var(--color-fg-muted)]">
                {r.release_date}
              </span>
            </li>
          ))}
        </ul>
      ) : (
        <EmptyState
          icon={<WatchlistIcon />}
          title="Geen nieuwe releases"
          description="Voeg artiesten toe aan je watchlist om hier op de hoogte te blijven."
          cta={{ label: "Open watchlist", onClick: () => navigateToHashView("watchlist") }}
        />
      )}
    </Card>
  );
}

function WatchlistIcon() {
  return (
    <svg width={32} height={32} viewBox="0 0 24 24" fill="none" aria-hidden>
      <path
        d="M3 12s3-7 9-7 9 7 9 7-3 7-9 7-9-7-9-7z"
        stroke="currentColor"
        strokeWidth="1.5"
      />
      <circle cx="12" cy="12" r="3" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}

// ─── Skeleton ─────────────────────────────────────────────────────────────

function DashboardSkeleton() {
  return (
    <div className="grid grid-cols-1 gap-4 md:grid-cols-4">
      <Card span={2}>
        <Shimmer height={24} width="40%" />
        <Shimmer height={80} />
      </Card>
      <Card><Shimmer height={120} /></Card>
      <Card><Shimmer height={120} /></Card>
      <Card><Shimmer height={120} /></Card>
      <Card span={2}><ShimmerStack rows={4} /></Card>
      <Card span={2}><ShimmerStack rows={5} /></Card>
      <Card span={2}><ShimmerStack rows={4} /></Card>
    </div>
  );
}
