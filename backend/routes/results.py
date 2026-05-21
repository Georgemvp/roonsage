"""Results persistence endpoints."""

import asyncio
import re

from fastapi import APIRouter, HTTPException, Query, Response

from backend import library_cache
from backend.models import (
    ResultDetail,
    ResultListItem,
    ResultListResponse,
)

router = APIRouter(prefix="/api/results", tags=["results"])

_VALID_RESULT_TYPES = {"prompt_playlist", "seed_playlist", "album_recommendation", "mcp_playlist"}
_RESULT_ID_RE = re.compile(r"^[0-9a-f]{8,16}$")


@router.get("", response_model=ResultListResponse)
async def list_results(
    type: str | None = Query(None, description="Filter by type (comma-separated)"),
    limit: int = Query(20, ge=1, le=100),
    offset: int = Query(0, ge=0),
) -> ResultListResponse:
    """List saved results for the history view."""
    if type:
        requested = {t.strip() for t in type.split(",")}
        invalid = requested - _VALID_RESULT_TYPES
        if invalid:
            raise HTTPException(status_code=400, detail=f"Invalid result type: {', '.join(sorted(invalid))}")
    results, total = await asyncio.to_thread(
        library_cache.list_results, result_type=type, limit=limit, offset=offset
    )
    return ResultListResponse(
        results=[ResultListItem(**r) for r in results],
        total=total,
    )


@router.get("/{result_id}", response_model=ResultDetail)
async def get_result(result_id: str) -> ResultDetail:
    """Fetch a single saved result with full snapshot."""
    if not _RESULT_ID_RE.match(result_id):
        raise HTTPException(status_code=400, detail="Invalid result ID format")
    result = await asyncio.to_thread(library_cache.get_result, result_id)
    if not result:
        raise HTTPException(status_code=404, detail="Result not found")
    return ResultDetail(**result)


@router.delete("/{result_id}", status_code=204)
async def delete_result(result_id: str):
    """Delete a saved result."""
    if not _RESULT_ID_RE.match(result_id):
        raise HTTPException(status_code=400, detail="Invalid result ID format")
    deleted = await asyncio.to_thread(library_cache.delete_result, result_id)
    if not deleted:
        raise HTTPException(status_code=404, detail="Result not found")
    return Response(status_code=204)
