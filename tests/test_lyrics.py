"""Tests for backend.lyrics — extractor and semantic search.

Extractor tests build minimal MP3/FLAC files via mutagen so we exercise the
real tag reads. Search tests mock the embedder to skip the transformers model.
"""

from __future__ import annotations

import sqlite3
from typing import TYPE_CHECKING

import pytest

if TYPE_CHECKING:
    from pathlib import Path  # noqa: F401

pytest.importorskip("numpy")
pytest.importorskip("mutagen")

from backend.lyrics import embedder, extractor, search  # noqa: E402

# ---------------------------------------------------------------------------
# Extractor tests
# ---------------------------------------------------------------------------


def _write_minimal_mp3(path: Path) -> None:
    """Write a 1-frame silent MP3 so mutagen will accept it."""
    # MPEG1 Layer3, 128kbps, 44.1kHz, mono — minimal valid header + padding.
    header = b"\xff\xfb\x90\x00"
    # 417-byte frame at 128kbps/44.1kHz.
    frame = header + b"\x00" * (417 - len(header))
    path.write_bytes(frame)


def test_extract_mp3_returns_lyrics(tmp_path):
    from mutagen.id3 import ID3, USLT
    mp3 = tmp_path / "song.mp3"
    _write_minimal_mp3(mp3)
    tags = ID3()
    tags.add(USLT(encoding=3, lang="eng", desc="", text="Sailing on a sea of dreams"))
    tags.save(str(mp3))
    assert extractor.extract_lyrics(mp3) == "Sailing on a sea of dreams"


def test_extract_returns_none_when_missing(tmp_path):
    mp3 = tmp_path / "empty.mp3"
    _write_minimal_mp3(mp3)
    assert extractor.extract_lyrics(mp3) is None


def test_extract_handles_missing_file(tmp_path):
    assert extractor.extract_lyrics(tmp_path / "does-not-exist.mp3") is None


# ---------------------------------------------------------------------------
# Search tests (with mocked embedder)
# ---------------------------------------------------------------------------


def _seed_db(tmp_path, monkeypatch):
    from backend import db as db_module

    db_path = tmp_path / "lyrics.db"
    monkeypatch.setattr(db_module, "DB_PATH", db_path)
    monkeypatch.setattr(db_module, "_schema_initialized", False)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    db_module.init_schema(conn)
    return conn


def _fake_embed_text(text: str):
    """Map keywords → axis-aligned unit vectors so cosines are crisp."""
    import numpy as np
    v = np.zeros(embedder.EMBEDDING_DIM, dtype=np.float32)
    tl = text.lower()
    if "loss" in tl or "redemption" in tl or "grief" in tl:
        v[0] = 1.0
    elif "travel" in tl or "road" in tl or "highway" in tl:
        v[1] = 1.0
    elif "protest" in tl or "revolution" in tl or "freedom" in tl:
        v[2] = 1.0
    else:
        v[3] = 1.0
    return v


def test_search_returns_empty_when_no_embeddings(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch)
    monkeypatch.setattr(embedder, "embed_text", _fake_embed_text)
    assert search.search_lyrics(conn, "anything", limit=10) == []
    conn.close()


def test_search_ranks_thematically(tmp_path, monkeypatch):
    import numpy as np

    conn = _seed_db(tmp_path, monkeypatch)
    monkeypatch.setattr(embedder, "embed_text", _fake_embed_text)

    samples = [
        ("loss1",   "songs about grief and redemption"),
        ("loss2",   "a story of loss and recovery"),
        ("travel1", "long road open highway driving"),
        ("protest1", "freedom revolution and protest"),
    ]
    for key, lyrics in samples:
        conn.execute(
            "INSERT INTO tracks (item_key, title, artist, album) VALUES (?, ?, ?, ?)",
            (key, key, "A", "Alb"),
        )
        conn.execute(
            """INSERT INTO lyrics_data (item_key, lyrics, source, extracted_at)
               VALUES (?, ?, 'tag', '2026-01-01')""",
            (key, lyrics),
        )
        emb = _fake_embed_text(lyrics)
        conn.execute(
            """INSERT INTO lyrics_embeddings (item_key, embedding, model_version)
               VALUES (?, ?, 'fake')""",
            (key, np.asarray(emb, dtype=np.float32).tobytes()),
        )
    conn.commit()

    results = search.search_lyrics(conn, "songs about loss and redemption", limit=4)
    assert results, "expected results"
    top_two = [r["item_key"] for r in results[:2]]
    assert "loss1" in top_two and "loss2" in top_two
    # Each result has a similarity score and (for the loss tracks) a snippet.
    assert all(r["similarity"] is not None for r in results)
    assert any(r["snippet"] for r in results[:2])
    conn.close()


def test_get_track_lyrics_returns_record(tmp_path, monkeypatch):
    conn = _seed_db(tmp_path, monkeypatch)
    conn.execute(
        "INSERT INTO tracks (item_key, title, artist, album) VALUES ('k1', 't', 'a', 'al')",
    )
    conn.execute(
        """INSERT INTO lyrics_data (item_key, lyrics, source, extracted_at)
           VALUES ('k1', 'hello world', 'tag', '2026-01-01')""",
    )
    conn.commit()
    out = search.get_track_lyrics(conn, "k1")
    assert out and out["lyrics"] == "hello world"
    assert search.get_track_lyrics(conn, "missing") is None
    conn.close()
