"""WebSocket endpoints for live progress updates.

One endpoint per channel: /ws/<channel>. The client connects, then receives
JSON messages as workers publish them via backend.event_bus.

Heartbeat: server sends a ping every 25s so any reverse proxy in the path
doesn't time the socket out. Client drops the ping silently.
"""

from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from backend.event_bus import VALID_CHANNELS, subscribe

logger = logging.getLogger(__name__)

# No /api prefix — WebSocket endpoints sit on /ws/<channel>. The auth middleware
# in main.py only enforces basic-auth on the HTTP upgrade response, which the
# browser passes through automatically because credentials: 'same-origin'.
router = APIRouter(tags=["websocket"])


@router.websocket("/ws/{channel}")
async def ws_channel(websocket: WebSocket, channel: str) -> None:
    if channel not in VALID_CHANNELS:
        await websocket.close(code=4404, reason="unknown channel")
        return

    await websocket.accept()
    logger.debug("WS connected: channel=%s", channel)

    async with subscribe(channel) as queue:
        send_task = asyncio.create_task(_pump_outgoing(websocket, queue))
        heartbeat_task = asyncio.create_task(_heartbeat(websocket))
        recv_task = asyncio.create_task(_drain_incoming(websocket))

        done, pending = await asyncio.wait(
            {send_task, heartbeat_task, recv_task},
            return_when=asyncio.FIRST_COMPLETED,
        )
        for t in pending:
            t.cancel()

    logger.debug("WS closed: channel=%s", channel)


async def _pump_outgoing(ws: WebSocket, queue: asyncio.Queue) -> None:
    while True:
        payload = await queue.get()
        try:
            await ws.send_json(payload)
        except Exception:
            return


async def _heartbeat(ws: WebSocket) -> None:
    while True:
        await asyncio.sleep(25)
        try:
            await ws.send_json({"type": "ping"})
        except Exception:
            return


async def _drain_incoming(ws: WebSocket) -> None:
    """Read and discard incoming frames so the WS protocol stays clean."""
    try:
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        return
    except Exception:
        return
