"""Camelot wheel — key → Camelot code conversion + harmonic-compatibility set.

The Camelot wheel is a DJ-friendly notation for musical keys:
each key has a number (1–12) and a letter (A for minor, B for major).
Adjacent numbers and the corresponding A/B swap are harmonically compatible,
which is the basis for "harmonic mixing".

Reference (https://mixedinkey.com/camelot-wheel/):

    C  major = 8B   |  A  minor = 8A
    G  major = 9B   |  E  minor = 9A
    D  major = 10B  |  B  minor = 10A
    A  major = 11B  |  F# minor = 11A
    E  major = 12B  |  C# minor = 12A
    B  major = 1B   |  G# minor = 1A
    F# major = 2B   |  D# minor = 2A
    C# major = 3B   |  A# minor = 3A
    G# major = 4B   |  F  minor = 4A
    D# major = 5B   |  C  minor = 5A
    A# major = 6B   |  G  minor = 6A
    F  major = 7B   |  D  minor = 7A
"""

from __future__ import annotations

# Normalize sharps/flats to a single canonical spelling.
_PITCH_ALIASES = {
    "Db": "C#", "Eb": "D#", "Gb": "F#", "Ab": "G#", "Bb": "A#",
}

_KEY_TO_CAMELOT: dict[tuple[str, str], str] = {
    ("C",  "major"): "8B",  ("A",  "minor"): "8A",
    ("G",  "major"): "9B",  ("E",  "minor"): "9A",
    ("D",  "major"): "10B", ("B",  "minor"): "10A",
    ("A",  "major"): "11B", ("F#", "minor"): "11A",
    ("E",  "major"): "12B", ("C#", "minor"): "12A",
    ("B",  "major"): "1B",  ("G#", "minor"): "1A",
    ("F#", "major"): "2B",  ("D#", "minor"): "2A",
    ("C#", "major"): "3B",  ("A#", "minor"): "3A",
    ("G#", "major"): "4B",  ("F",  "minor"): "4A",
    ("D#", "major"): "5B",  ("C",  "minor"): "5A",
    ("A#", "major"): "6B",  ("G",  "minor"): "6A",
    ("F",  "major"): "7B",  ("D",  "minor"): "7A",
}


def from_key(root: str, mode: str) -> str | None:
    """Convert (root, mode) → Camelot code, e.g. ("A", "minor") → "8A"."""
    if not root or not mode:
        return None
    root = _PITCH_ALIASES.get(root, root)
    return _KEY_TO_CAMELOT.get((root, mode.lower()))


def compatible(current: str) -> set[str]:
    """Return the set of Camelot codes that mix harmonically with ``current``.

    Compatible neighbours:
      - same code (perfect match)
      - same number, other letter (energy boost / mode switch)
      - ±1 number on the wheel (key change, smooth)

    A small +7 jump ("dominant", "energy spike") is intentionally NOT included
    by default — it works but is jarring for warm-up sets.
    """
    if not current or len(current) < 2:
        return set()
    try:
        num = int(current[:-1])
        letter = current[-1].upper()
    except ValueError:
        return set()
    if letter not in ("A", "B") or not (1 <= num <= 12):
        return set()

    other = "B" if letter == "A" else "A"
    plus_1 = (num % 12) + 1
    minus_1 = ((num - 2) % 12) + 1
    return {
        f"{num}{letter}",
        f"{num}{other}",
        f"{plus_1}{letter}",
        f"{minus_1}{letter}",
    }


def all_codes() -> list[str]:
    """Return all 24 Camelot codes in wheel order."""
    return [code for code in _KEY_TO_CAMELOT.values()]
