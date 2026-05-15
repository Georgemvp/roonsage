"""Qobuz playlist save endpoints."""

import asyncio
import logging
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from backend.qobuz_api import get_qobuz_api_client

logger = logging.getLogger(__name__)

router = APIRouter()


class TrackInput(BaseModel):
    artist: str
    title: str


class SaveQobuzPlaylistRequest(BaseModel):
    name: str
    description: Optional[str] = ""
    tracks: list[TrackInput]
    is_public: Optional[bool] = False


@router.post("/api/qobuz/playlist/save")
async def save_qobuz_playlist(req: SaveQobuzPlaylistRequest):
    """Save a playlist to the user's Qobuz account.

    Resolves each track by artist+title via Qobuz search API,
    creates a new playlist, and adds matched tracks.
    """
    client = get_qobuz_api_client()
    if not client:
        raise HTTPException(
            status_code=503,
            detail=(
                "Qobuz API niet geconfigureerd. "
                "Stel QOBUZ_APP_ID, QOBUZ_EMAIL en QOBUZ_PASSWORD in."
            ),
        )

    tracks_dicts = [{"artist": t.artist, "title": t.title} for t in req.tracks]

    if len(tracks_dicts) > 2000:
        raise HTTPException(
            status_code=400,
            detail="Qobuz staat maximaal 2000 tracks per playlist toe.",
        )

    result = await asyncio.to_thread(
        client.save_playlist,
        name=req.name,
        tracks=tracks_dicts,
        description=req.description or "",
        is_public=req.is_public or False,
    )
    return result


@router.get("/api/qobuz/save-status")
async def qobuz_save_status():
    """Check if Qobuz playlist save is configured and available."""
    client = get_qobuz_api_client()
    return {
        "available": client is not None and client.is_authenticated(),
    }
