"""In-memory event bus for backend → WebSocket fan-out.

Workers publish progress events via ``publish(channel, payload)``; the
``/ws/<channel>`` endpoints (backend.routes.ws) subscribe to a channel and
forward each event to connected browsers.

Asyncio-only. Producers from worker threads must hop back to the event loop
via ``loop.call_soon_threadsafe`` before calling publish() — see
``publish_threadsafe`` for the helper.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
from collections import defaultdict
from contextlib import asynccontextmanager
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from collections.abc import AsyncIterator

logger = logging.getLogger(__name__)

# channel name → set of asyncio.Queue subscribers
_subscribers: dict[str, set[asyncio.Queue]] = defaultdict(set)
_loop: asyncio.AbstractEventLoop | None = None

# Public channel names. Kept here as constants so producers don't typo them.
CH_ENRICHMENT = "enrichment"
CH_AUDIO_FEATURES = "audio_features"
CH_CLUSTERING = "clustering"
CH_SYNC = "sync"
CH_AUTOMATIONS = "automations"
CH_DASHBOARD = "dashboard"

VALID_CHANNELS = {
    CH_ENRICHMENT,
    CH_AUDIO_FEATURES,
    CH_CLUSTERING,
    CH_SYNC,
    CH_AUTOMATIONS,
    CH_DASHBOARD,
}


def set_event_loop(loop: asyncio.AbstractEventLoop) -> None:
    """Wire the running event loop so threaded producers can hop into it."""
    global _loop
    _loop = loop


def publish(channel: str, payload: Any) -> None:
    """Publish an event to all subscribers of ``channel``.

    Drops the event if the channel has no subscribers (which is the common case
    — no UI is open). Drops the event for any one subscriber whose queue is
    full; we choose to lose old progress over blocking the producer.
    """
    if channel not in VALID_CHANNELS:
        logger.debug("publish() to unknown channel %r dropped", channel)
        return
    subs = _subscribers.get(channel)
    if not subs:
        return
    for q in list(subs):
        # Subscriber is slow; drop the event rather than block the producer.
        with contextlib.suppress(asyncio.QueueFull):
            q.put_nowait(payload)


def publish_threadsafe(channel: str, payload: Any) -> None:
    """Thread-safe variant. Workers running in a thread executor use this."""
    loop = _loop
    if loop is None:
        return
    # Loop closed during shutdown — silently drop the event.
    with contextlib.suppress(RuntimeError):
        loop.call_soon_threadsafe(publish, channel, payload)


@asynccontextmanager
async def subscribe(channel: str, maxsize: int = 64) -> AsyncIterator[asyncio.Queue]:
    """Async context manager that yields a queue of events for ``channel``."""
    q: asyncio.Queue = asyncio.Queue(maxsize=maxsize)
    _subscribers[channel].add(q)
    try:
        yield q
    finally:
        _subscribers[channel].discard(q)
