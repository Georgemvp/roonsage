"""Qobuz playlist save endpoints."""

import asyncio
import logging
from typing import Optional

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from backend.config import get_qobuz_config
from backend.qobuz_api import (
    get_qobuz_api_client,
    get_qobuz_api_error,
    init_qobuz_api_client,
)

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
    error = get_qobuz_api_error()
    return {
        "available": client is not None and client.is_authenticated(),
        "error": error,
    }


class ValidateQobuzRequest(BaseModel):
    app_id: Optional[str] = None
    email: Optional[str] = None
    password: Optional[str] = None


@router.post("/api/qobuz/validate")
async def validate_qobuz_credentials(req: ValidateQobuzRequest):
    """Validate Qobuz credentials by attempting to log in.

    Accepts {"app_id": "...", "email": "...", "password": "..."} in the body
    to test specific credentials. If no body fields are provided, uses the
    currently configured credentials from environment / config.user.yaml.
    """
    if req.app_id and req.email and req.password:
        app_id = req.app_id
        email = req.email
        password = req.password
    else:
        qobuz_cfg = get_qobuz_config()
        app_id = qobuz_cfg.get("app_id", "")
        email = qobuz_cfg.get("email", "")
        password = qobuz_cfg.get("password", "")

    if not (app_id and email and password):
        return {
            "available": False,
            "error": "Vul App ID, email en wachtwoord in.",
        }

    # Re-initialize the singleton with the provided credentials
    client = await asyncio.to_thread(init_qobuz_api_client, app_id, email, password)
    error = get_qobuz_api_error()

    return {
        "available": client is not None and client.is_authenticated(),
        "error": error,
    }
