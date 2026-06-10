"""Pytest fixtures for RoonSage tests."""

from unittest.mock import MagicMock

import pytest

import backend.db as _db_module
import backend.db.connection as _db_connection
from backend.models import Dimension, Track


@pytest.fixture(autouse=True)
def _patch_db_path(tmp_path, monkeypatch):
    """Redirect every DB read to a per-test temp file and initialise schema.

    get_connection() reads backend.db.connection.DB_PATH directly;
    patching only the re-export in backend.db.__init__ leaves it stale.
    """
    import sqlite3 as _sqlite3
    from backend.db.migrations import init_schema as _init_schema

    db_path = tmp_path / "test_roonsage.db"
    tmp_path.mkdir(parents=True, exist_ok=True)

    monkeypatch.setattr(_db_connection, "DB_PATH", db_path)
    monkeypatch.setattr(_db_module, "DB_PATH", db_path)
    monkeypatch.setattr(_db_module, "DATA_DIR", tmp_path)
    monkeypatch.setattr(_db_module, "_schema_initialized", False)

    # Pre-initialise schema so tables exist for any test that opens a
    # raw connection without going through ensure_db_initialized().
    conn = _sqlite3.connect(str(db_path))
    _init_schema(conn)
    conn.commit()
    conn.close()


@pytest.fixture
def mock_roon_tracks() -> list[Track]:
    """Sample library tracks for testing filter/match logic."""
    return [
        Track(
            item_key="1",
            title="Fake Plastic Trees",
            artist="Radiohead",
            album="The Bends",
            duration_ms=290000,
            year=1995,
            genres=["Alternative", "Rock"],
            art_url="/api/art/1",
        ),
        Track(
            item_key="2",
            title="Black",
            artist="Pearl Jam",
            album="Ten",
            duration_ms=340000,
            year=1991,
            genres=["Grunge", "Rock"],
            art_url="/api/art/2",
        ),
        Track(
            item_key="3",
            title="Creep",
            artist="Radiohead",
            album="Pablo Honey",
            duration_ms=238000,
            year=1993,
            genres=["Alternative", "Rock"],
            art_url="/api/art/3",
        ),
        Track(
            item_key="4",
            title="Bitter Sweet Symphony",
            artist="The Verve",
            album="Urban Hymns",
            duration_ms=358000,
            year=1997,
            genres=["Alternative", "Britpop"],
            art_url="/api/art/4",
        ),
        Track(
            item_key="5",
            title="Wonderwall",
            artist="Oasis",
            album="(What's the Story) Morning Glory?",
            duration_ms=259000,
            year=1995,
            genres=["Britpop", "Rock"],
            art_url="/api/art/5",
        ),
        Track(
            item_key="6",
            title="Say It Ain't So",
            artist="Weezer",
            album="Weezer (Blue Album)",
            duration_ms=258000,
            year=1994,
            genres=["Alternative", "Rock"],
            art_url="/api/art/6",
        ),
        Track(
            item_key="7",
            title="Under the Bridge",
            artist="Red Hot Chili Peppers",
            album="Blood Sugar Sex Magik",
            duration_ms=264000,
            year=1991,
            genres=["Alternative", "Rock", "Funk"],
            art_url="/api/art/7",
        ),
        Track(
            item_key="8",
            title="Smells Like Teen Spirit",
            artist="Nirvana",
            album="Nevermind",
            duration_ms=301000,
            year=1991,
            genres=["Grunge", "Alternative", "Rock"],
            art_url="/api/art/8",
        ),
        Track(
            item_key="9",
            title="Champagne Supernova - Live",
            artist="Oasis",
            album="Live at Knebworth 1996",
            duration_ms=460000,
            year=1996,
            genres=["Britpop", "Rock"],
            art_url="/api/art/9",
        ),
        Track(
            item_key="10",
            title="Purple Rain",
            artist="Prince",
            album="Purple Rain",
            duration_ms=520000,
            year=1984,
            genres=["Pop", "Rock", "R&B"],
            art_url="/api/art/10",
        ),
    ]


@pytest.fixture
def mock_dimensions() -> list[Dimension]:
    """Sample dimensions for testing seed track analysis."""
    return [
        Dimension(
            id="mood",
            label="The melancholy, bittersweet mood",
            description="Emotionally heavy, reflective tone with a sense of yearning",
        ),
        Dimension(
            id="era",
            label="Mid-90s British alternative rock",
            description="The Britpop/post-grunge era sound",
        ),
        Dimension(
            id="instrumentation",
            label="Layered guitars with string arrangements",
            description="Electric and acoustic guitars with orchestral elements",
        ),
        Dimension(
            id="vocals",
            label="Vulnerable, falsetto-tinged vocals",
            description="Emotional delivery with moments of restraint",
        ),
        Dimension(
            id="theme",
            label="Alienation and modern disconnect",
            description="Themes of feeling out of place in consumer society",
        ),
    ]


@pytest.fixture
def mock_llm_response_tracks() -> list[dict]:
    """Sample LLM response for track selection."""
    return [
        {"artist": "Radiohead", "album": "The Bends", "title": "Fake Plastic Trees"},
        {"artist": "Pearl Jam", "album": "Ten", "title": "Black"},
        {"artist": "The Verve", "album": "Urban Hymns", "title": "Bitter Sweet Symphony"},
    ]


@pytest.fixture
def mock_llm_response_analysis() -> dict:
    """Sample LLM response for prompt analysis."""
    return {
        "genres": ["Alternative", "Rock"],
        "decades": ["1990s"],
        "reasoning": "The request for 'melancholy 90s alternative' suggests mid-90s alternative rock with emotionally introspective themes.",
    }


@pytest.fixture
def mock_anthropic_client(mocker):
    """Mock Anthropic client for testing."""
    mock_client = MagicMock()
    mock_response = MagicMock()
    mock_response.content = [MagicMock(text='{"test": "response"}')]
    mock_response.usage.input_tokens = 100
    mock_response.usage.output_tokens = 50
    mock_client.messages.create.return_value = mock_response
    return mock_client


@pytest.fixture
def mock_openai_client(mocker):
    """Mock OpenAI client for testing."""
    mock_client = MagicMock()
    mock_response = MagicMock()
    mock_response.choices = [MagicMock(message=MagicMock(content='{"test": "response"}'))]
    mock_response.usage.prompt_tokens = 100
    mock_response.usage.completion_tokens = 50
    mock_client.chat.completions.create.return_value = mock_response
    return mock_client
