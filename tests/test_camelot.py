"""Tests for the Camelot wheel helpers."""

from backend.audio_features import camelot


class TestFromKey:
    def test_canonical_majors(self):
        assert camelot.from_key("C", "major") == "8B"
        assert camelot.from_key("G", "major") == "9B"
        assert camelot.from_key("F", "major") == "7B"

    def test_canonical_minors(self):
        assert camelot.from_key("A", "minor") == "8A"
        assert camelot.from_key("E", "minor") == "9A"
        assert camelot.from_key("D", "minor") == "7A"

    def test_flat_alias_normalised(self):
        # Db major == C# major == 3B
        assert camelot.from_key("Db", "major") == "3B"
        # Eb minor == D# minor == 2A
        assert camelot.from_key("Eb", "minor") == "2A"

    def test_mode_case_insensitive(self):
        assert camelot.from_key("C", "MAJOR") == "8B"
        assert camelot.from_key("A", "Minor") == "8A"

    def test_empty_inputs_return_none(self):
        assert camelot.from_key("", "major") is None
        assert camelot.from_key("C", "") is None

    def test_unknown_key_returns_none(self):
        assert camelot.from_key("H", "major") is None


class TestCompatible:
    def test_basic_neighbourhood(self):
        # 8A → {8A, 8B, 9A, 7A}
        assert camelot.compatible("8A") == {"8A", "8B", "9A", "7A"}

    def test_wheel_wraparound_high(self):
        # 12A → {12A, 12B, 1A, 11A}
        assert camelot.compatible("12A") == {"12A", "12B", "1A", "11A"}

    def test_wheel_wraparound_low(self):
        # 1B → {1B, 1A, 2B, 12B}
        assert camelot.compatible("1B") == {"1B", "1A", "2B", "12B"}

    def test_b_letter_neighbourhood(self):
        assert camelot.compatible("8B") == {"8B", "8A", "9B", "7B"}

    def test_invalid_returns_empty(self):
        assert camelot.compatible("") == set()
        assert camelot.compatible("XX") == set()
        assert camelot.compatible("13A") == set()
        assert camelot.compatible("0A") == set()


class TestAllCodes:
    def test_returns_24_unique_codes(self):
        codes = camelot.all_codes()
        assert len(codes) == 24
        assert len(set(codes)) == 24
        # Sanity: every code is "<num>A" or "<num>B" with num in 1..12.
        for c in codes:
            assert c[-1] in ("A", "B")
            assert 1 <= int(c[:-1]) <= 12
