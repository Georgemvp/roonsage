"""AcoustID track verification endpoints.

POST /api/verify/track  — verify that a candidate track matches an expected track.
GET  /api/verify/status — report AcoustID configuration status.
"""

from __future__ import annotations

import logging

from fastapi import APIRouter
from pydantic import BaseModel, Field

from backend.config import get_acoustid_config

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["verify"])


# ---------------------------------------------------------------------------
# Request / Response models
# ---------------------------------------------------------------------------


class VerifyTrackRequest(BaseModel):
    """Request body for POST /api/verify/track."""

    expected_artist: str = Field(..., description="Artist name you're looking for")
    expected_title: str = Field(..., description="Track title you're looking for")
    candidate_artist: str = Field(..., description="Artist name from Qobuz search result")
    candidate_title: str = Field(..., description="Track title from Qobuz search result")
    candidate_duration: int = Field(
        0,
        ge=0,
        description="Duration of Qobuz result in seconds (0 = unknown)",
    )
    expected_duration: int = Field(
        0,
        ge=0,
        description="Expected track duration in seconds (0 = unknown)",
    )


class VerifyTrackResponse(BaseModel):
    """Response from POST /api/verify/track."""

    match: bool
    confidence: float
    reason: str
    version_flags: list[str]
    acoustid_enabled: bool


class VerifyStatusResponse(BaseModel):
    """Response from GET /api/verify/status."""

    enabled: bool
    auto_verify_qobuz: bool
    api_key_present: bool


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@router.post("/verify/track", response_model=VerifyTrackResponse)
async def verify_track(request: VerifyTrackRequest) -> VerifyTrackResponse:
    """Verify whether a Qobuz search result matches the intended track.

    Uses fuzzy string matching + version-marker detection (no audio required).
    When AcoustID is enabled the result also factors in fingerprint metadata.

    Fail-open: if AcoustID is disabled or verification raises, returns a
    high-confidence match so callers are never blocked.
    """
    acoustid_cfg = get_acoustid_config()
    enabled = acoustid_cfg["enabled"]

    try:
        from backend.acoustid_client import verify_match_sync  # noqa: PLC0415

        verdict = verify_match_sync(
            expected_artist=request.expected_artist,
            expected_title=request.expected_title,
            candidate_artist=request.candidate_artist,
            candidate_title=request.candidate_title,
            candidate_duration=request.candidate_duration,
            expected_duration=request.expected_duration,
        )
        return VerifyTrackResponse(
            match=verdict["match"],
            confidence=verdict["confidence"],
            reason=verdict["reason"],
            version_flags=verdict["version_flags"],
            acoustid_enabled=enabled,
        )
    except Exception as exc:
        logger.warning("verify_track endpoint error: %s", exc)
        return VerifyTrackResponse(
            match=True,
            confidence=0.5,
            reason="Verification skipped (internal error)",
            version_flags=[],
            acoustid_enabled=enabled,
        )


@router.get("/verify/status", response_model=VerifyStatusResponse)
async def verify_status() -> VerifyStatusResponse:
    """Return the current AcoustID configuration status."""
    acoustid_cfg = get_acoustid_config()
    return VerifyStatusResponse(
        enabled=acoustid_cfg["enabled"],
        auto_verify_qobuz=acoustid_cfg["auto_verify_qobuz"],
        api_key_present=bool(acoustid_cfg["api_key"]),
    )
