"""Background task tracker for free-provider AI enrichment."""

import logging
import threading
import time
from dataclasses import dataclass
from enum import StrEnum

logger = logging.getLogger(__name__)


class TaskStatus(StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    DONE = "done"
    FAILED = "failed"
    SKIPPED = "skipped"


TASK_LABELS = {
    "vibe_tagging":        "Mood & vibe tagging",
    "watchlist_scoring":   "Release relevantie scoring",
    "weekly_insights":     "Wekelijkse luister-insights",
    "discovery_desc":      "Discovery beschrijvingen",
    "playlist_desc":       "Playlist beschrijving",
    "lyrics_themes":       "Lyrics thema-extractie",
    "cluster_labels":      "Cluster labeling",
    "song_path_narrative": "Song path narratief",
    "template_suggest":    "Template suggesties",
    "notification_enrich": "Notificatie verrijking",
}


@dataclass
class BackgroundTask:
    task_id: str
    label: str
    status: TaskStatus = TaskStatus.QUEUED
    total: int = 0
    completed: int = 0
    started_at: float = 0.0
    finished_at: float = 0.0
    error: str = ""

    @property
    def progress_pct(self) -> int:
        if self.total <= 0:
            return 0
        return min(100, int(self.completed / self.total * 100))

    def to_dict(self) -> dict:
        return {
            "task_id": self.task_id,
            "label": self.label,
            "status": self.status.value,
            "total": self.total,
            "completed": self.completed,
            "progress_pct": self.progress_pct,
            "elapsed_s": round(
                (self.finished_at or time.time()) - self.started_at, 1
            ) if self.started_at else 0,
            "error": self.error,
        }


class BackgroundTaskTracker:
    """Thread-safe singleton tracking background AI tasks."""

    def __init__(self) -> None:
        self._tasks: dict[str, BackgroundTask] = {}
        self._lock = threading.Lock()
        self._cleanup_age = 60  # seconds to keep finished tasks

    def start(self, task_id: str, total: int = 0) -> None:
        label = TASK_LABELS.get(task_id, task_id)
        with self._lock:
            self._tasks[task_id] = BackgroundTask(
                task_id=task_id,
                label=label,
                status=TaskStatus.RUNNING,
                total=total,
                started_at=time.time(),
            )
        logger.info("Background task started: %s (total=%d)", label, total)

    def progress(self, task_id: str, completed: int) -> None:
        with self._lock:
            task = self._tasks.get(task_id)
            if task:
                task.completed = completed

    def finish(self, task_id: str) -> None:
        with self._lock:
            task = self._tasks.get(task_id)
            if task:
                task.status = TaskStatus.DONE
                task.completed = task.total
                task.finished_at = time.time()
        logger.info("Background task done: %s", task_id)

    def fail(self, task_id: str, error: str) -> None:
        with self._lock:
            task = self._tasks.get(task_id)
            if task:
                task.status = TaskStatus.FAILED
                task.error = error
                task.finished_at = time.time()
        logger.warning("Background task failed: %s — %s", task_id, error)

    def get_all(self) -> list[dict]:
        now = time.time()
        with self._lock:
            expired = [
                tid for tid, t in self._tasks.items()
                if t.finished_at and now - t.finished_at > self._cleanup_age
            ]
            for tid in expired:
                del self._tasks[tid]
            return [t.to_dict() for t in self._tasks.values()]


# Singleton
task_tracker = BackgroundTaskTracker()
