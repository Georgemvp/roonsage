"""Metadata Enrichment Pipeline REST endpoints (v10.0).

Routes:
  GET  /api/enrichment/status        — queue stats: pending, complete, failed, …
  POST /api/enrichment/start         — populate queue and start/resume worker
  POST /api/enrichment/pause         — pause worker after current item
  POST /api/enrichment/resume        — resume paused worker
  GET  /api/enrichment/queue         — paginated queue with per-item status
  GET  /api/enrichment/missing       — tracks without enrichment data
  POST /api/enrichment/enrich-single — enrich one track on demand
  GET  /api/enrichment/tags          — aggregated Last.fm tag cloud
  POST /api/enrichment/retry-failed  — reset all failed items back to pending
"""

import json
import logging
from collections import Counter

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel

from backend.db import get_db_connection

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/enrichment", tags=["enrichment"])


# ---------------------------------------------------------------------------
# Response models
# ---------------------------------------------------------------------------


class EnrichmentStatusResponse(BaseModel):
    pending: int = 0
    processing: int = 0
    complete: int = 0
    failed: int = 0
    enriched_total: int = 0
    mb_matches: int = 0
    lastfm_matches: int = 0
    worker_running: bool = False
    worker_paused: bool = False
    lastfm_active: bool = False  # True when Last.fm is configured and active in enrichment
    skip_mb: bool = False        # True when ENRICHMENT_SKIP_MB=true (LF-only, ~50× faster)
    total_tracks: int = 0
    source_breakdown: dict = {}
    recent_completed: list = []


class EnrichmentQueueItem(BaseModel):
    item_key: str
    artist: str
    title: str
    album: str | None = None
    status: str
    attempts: int = 0
    error_message: str | None = None
    created_at: str | None = None
    processed_at: str | None = None


class EnrichmentQueueResponse(BaseModel):
    items: list[EnrichmentQueueItem]
    total: int
    page: int
    page_size: int


class StartEnrichmentResponse(BaseModel):
    started: bool
    queued: int = 0
    message: str = ""


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.get("/status", response_model=EnrichmentStatusResponse)
async def get_enrichment_status() -> EnrichmentStatusResponse:
    """Return queue statistics and worker state."""
    from backend.enrichment_worker import get_queue_stats, get_worker  # noqa: PLC0415

    conn = get_db_connection()
    try:
        stats = get_queue_stats(conn)

        total_tracks = conn.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]

        breakdown_rows = conn.execute(
            "SELECT enrichment_source, COUNT(*) AS cnt FROM track_metadata_ext GROUP BY enrichment_source"
        ).fetchall()
        source_breakdown = {row["enrichment_source"]: row["cnt"] for row in breakdown_rows}

        recent_rows = conn.execute(
            """SELECT eq.artist, eq.title, eq.processed_at
               FROM enrichment_queue eq
               WHERE eq.status = 'complete'
               ORDER BY eq.processed_at DESC
               LIMIT 10"""
        ).fetchall()
        recent_completed = [
            {"artist": r["artist"], "title": r["title"], "processed_at": r["processed_at"]}
            for r in recent_rows
        ]
    finally:
        conn.close()

    from backend.enrichment_worker import ENRICHMENT_SKIP_MB  # noqa: PLC0415
    from backend.lastfm_client import get_lf_client  # noqa: PLC0415

    worker = get_worker()
    lf_client = get_lf_client()
    lastfm_active = lf_client is not None and lf_client.is_configured()
    return EnrichmentStatusResponse(
        pending=stats.get("pending", 0),
        processing=stats.get("processing", 0),
        complete=stats.get("complete", 0),
        failed=stats.get("failed", 0),
        enriched_total=stats.get("enriched_total", 0),
        mb_matches=stats.get("mb_matches", 0),
        lastfm_matches=stats.get("lastfm_matches", 0),
        worker_running=worker.is_running(),
        worker_paused=worker.is_paused(),
        lastfm_active=lastfm_active,
        skip_mb=ENRICHMENT_SKIP_MB,
        total_tracks=total_tracks,
        source_breakdown=source_breakdown,
        recent_completed=recent_completed,
    )


@router.post("/start", response_model=StartEnrichmentResponse)
async def start_enrichment() -> StartEnrichmentResponse:
    """Populate the enrichment queue and start (or resume) the worker."""
    from backend.enrichment_worker import (  # noqa: PLC0415
        get_worker,
        populate_enrichment_queue,
    )
    from backend.lastfm_client import get_lf_client  # noqa: PLC0415

    conn = get_db_connection()
    try:
        # Re-queue tracks enriched without Last.fm when Last.fm is now configured
        lf_client = get_lf_client()
        lastfm_available = lf_client is not None and lf_client.is_configured()
        if lastfm_available:
            row = conn.execute(
                "SELECT COUNT(*) FROM track_metadata_ext WHERE enrichment_source IN ('musicbrainz', 'none')"
            ).fetchone()
            without_lastfm = row[0] if row else 0
            if without_lastfm > 0:
                logger.info("Re-queuing %d tracks for Last.fm enrichment", without_lastfm)
                conn.execute(
                    "DELETE FROM track_metadata_ext WHERE enrichment_source IN ('musicbrainz', 'none')"
                )
                conn.execute("""
                    UPDATE enrichment_queue
                    SET status = 'pending', attempts = 0
                    WHERE status = 'complete'
                      AND item_key NOT IN (SELECT item_key FROM track_metadata_ext)
                """)
                conn.commit()

        queued = populate_enrichment_queue(conn)
    finally:
        conn.close()

    worker = get_worker()
    if worker.is_paused():
        worker.resume()
        msg = f"Worker resumed. {queued} new items added to queue."
    elif not worker.is_running():
        worker.start()
        msg = f"Worker started. {queued} new items added to queue."
    else:
        msg = f"Worker already running. {queued} new items added to queue."

    return StartEnrichmentResponse(started=True, queued=queued, message=msg)


@router.post("/pause")
async def pause_enrichment() -> dict:
    """Pause the enrichment worker after the current item finishes."""
    from backend.enrichment_worker import get_worker  # noqa: PLC0415

    get_worker().pause()
    return {"success": True, "message": "Worker paused"}


@router.post("/resume")
async def resume_enrichment() -> dict:
    """Resume a paused enrichment worker."""
    from backend.enrichment_worker import get_worker  # noqa: PLC0415

    worker = get_worker()
    if not worker.is_running():
        worker.start()
        return {"success": True, "message": "Worker restarted"}
    worker.resume()
    return {"success": True, "message": "Worker resumed"}


@router.get("/queue", response_model=EnrichmentQueueResponse)
async def get_enrichment_queue(
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=200),
    status: str | None = Query(None),
) -> EnrichmentQueueResponse:
    """Paginated view of the enrichment queue.

    Query params:
      page       — 1-based page number (default 1)
      page_size  — items per page (default 50, max 200)
      status     — filter by status: pending / processing / complete / failed
    """
    conn = get_db_connection()
    try:
        where = ""
        params: list = []
        if status:
            where = "WHERE status = ?"
            params.append(status)

        total = conn.execute(
            f"SELECT COUNT(*) FROM enrichment_queue {where}", params
        ).fetchone()[0]

        offset = (page - 1) * page_size
        rows = conn.execute(
            f"SELECT item_key, artist, title, album, status, attempts, "
            f"error_message, created_at, processed_at "
            f"FROM enrichment_queue {where} "
            f"ORDER BY created_at ASC "
            f"LIMIT ? OFFSET ?",
            [*params, page_size, offset],
        ).fetchall()
    finally:
        conn.close()

    items = [
        EnrichmentQueueItem(
            item_key=row["item_key"],
            artist=row["artist"],
            title=row["title"],
            album=row["album"],
            status=row["status"],
            attempts=row["attempts"] or 0,
            error_message=row["error_message"],
            created_at=row["created_at"],
            processed_at=row["processed_at"],
        )
        for row in rows
    ]

    return EnrichmentQueueResponse(
        items=items,
        total=total,
        page=page,
        page_size=page_size,
    )


@router.get("/missing")
async def get_missing_metadata(limit: int = Query(20, ge=1, le=100)) -> dict:
    """Return tracks that have no enrichment data or source='none'."""
    conn = get_db_connection()
    try:
        rows = conn.execute(
            """SELECT t.item_key, t.artist, t.title, t.album, t.image_key
               FROM tracks t
               LEFT JOIN track_metadata_ext me ON me.item_key = t.item_key
               WHERE me.item_key IS NULL OR me.enrichment_source = 'none'
               ORDER BY t.artist, t.title
               LIMIT ?""",
            (limit,),
        ).fetchall()

        total_missing = conn.execute(
            """SELECT COUNT(*)
               FROM tracks t
               LEFT JOIN track_metadata_ext me ON me.item_key = t.item_key
               WHERE me.item_key IS NULL OR me.enrichment_source = 'none'"""
        ).fetchone()[0]
    finally:
        conn.close()

    return {
        "tracks": [
            {
                "id": row["item_key"],
                "artist": row["artist"],
                "title": row["title"],
                "album": row["album"],
                "image_key": row["image_key"],
            }
            for row in rows
        ],
        "total_missing": total_missing,
    }


@router.post("/enrich-single")
async def enrich_single_track(body: dict) -> dict:
    """Enrich a single track by item_key, bypassing the batch dedup cache."""
    from backend.enrichment_worker import _batch_cache, enrich_one  # noqa: PLC0415

    item_key = body.get("track_id")
    if not item_key:
        raise HTTPException(status_code=400, detail="track_id required")

    conn = get_db_connection()
    try:
        row = conn.execute(
            "SELECT artist, title FROM tracks WHERE item_key = ?", (item_key,)
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Track not found")

        artist, title = row["artist"], row["title"]

        # Bypass batch dedup cache for on-demand enrichment
        import re as _re  # noqa: PLC0415
        primary = artist.split(",")[0].strip().lower() if artist else ""
        clean = _re.sub(r'\s*[\(\[].*?[\)\]]\s*$', '', title).strip().lower() if title else ""
        _batch_cache.pop((primary, clean), None)

        success = await enrich_one(item_key, artist, title, conn)
    finally:
        conn.close()

    return {"success": success, "item_key": item_key}


@router.get("/tags")
async def get_enrichment_tags(limit: int = Query(30, ge=1, le=100)) -> dict:
    """Aggregate the most common Last.fm tags across all enriched tracks."""
    conn = get_db_connection()
    try:
        rows = conn.execute(
            "SELECT lastfm_tags FROM track_metadata_ext WHERE lastfm_tags IS NOT NULL"
        ).fetchall()
    finally:
        conn.close()

    tag_counts: Counter = Counter()
    for row in rows:
        try:
            tags = json.loads(row["lastfm_tags"])
            for tag in tags:
                tag_counts[tag.lower().strip()] += 1
        except (json.JSONDecodeError, TypeError):
            pass

    return {
        "tags": [
            {"name": name, "count": count}
            for name, count in tag_counts.most_common(limit)
        ],
        "total_unique": len(tag_counts),
    }


@router.post("/retry-failed")
async def retry_failed() -> dict:
    """Reset all failed enrichment queue items back to pending."""
    conn = get_db_connection()
    try:
        count = conn.execute(
            """UPDATE enrichment_queue
               SET status = 'pending', attempts = 0, error_message = NULL
               WHERE status = 'failed'"""
        ).rowcount
        conn.commit()
    finally:
        conn.close()

    return {"reset": count, "message": f"{count} failed items reset to pending."}
