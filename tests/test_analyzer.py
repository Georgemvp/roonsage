"""Tests for prompt and track analysis."""

import json
import pytest
from unittest.mock import MagicMock, patch


class TestPromptAnalysis:
    """Tests for prompt analysis."""

    def test_analyze_prompt_extracts_genres(self, mocker):
        """Should extract suggested genres from prompt."""
        from backend.analyzer import analyze_prompt
        from backend.llm_client import LLMResponse

        mock_response = LLMResponse(
            content=json.dumps({
                "genres": ["Alternative", "Rock"],
                "decades": ["1990s"],
                "reasoning": "The prompt suggests 90s alternative rock."
            }),
            input_tokens=100,
            output_tokens=50,
            model="test-model"
        )

        with patch("backend.analyzer.get_llm_client") as mock_llm:
            mock_client = MagicMock()
            mock_client.analyze.return_value = mock_response
            mock_client.parse_json_response.return_value = json.loads(mock_response.content)
            mock_llm.return_value = mock_client

            with patch("backend.analyzer.get_roon_client") as mock_roon:
                mock_roon_client = MagicMock()
                mock_roon_client.get_library_stats.return_value = {
                    "genres": [{"name": "Alternative", "count": 100}, {"name": "Rock", "count": 200}],
                    "decades": [{"name": "1990s", "count": 150}]
                }
                mock_roon.return_value = mock_roon_client

                result = analyze_prompt("melancholy 90s alternative")

                assert "Alternative" in result.suggested_genres
                assert "1990s" in result.suggested_decades

    def test_analyze_prompt_handles_malformed_response(self, mocker):
        """Should handle malformed LLM JSON responses gracefully."""
        from backend.analyzer import analyze_prompt
        from backend.llm_client import LLMResponse

        mock_response = LLMResponse(
            content="Not valid JSON at all",
            input_tokens=100,
            output_tokens=50,
            model="test-model"
        )

        with patch("backend.analyzer.get_llm_client") as mock_llm:
            mock_client = MagicMock()
            mock_client.analyze.return_value = mock_response
            mock_client.parse_json_response.side_effect = ValueError("Invalid JSON")
            mock_llm.return_value = mock_client

            with patch("backend.analyzer.get_roon_client") as mock_roon:
                mock_roon_client = MagicMock()
                mock_roon_client.get_library_stats.return_value = {
                    "genres": [{"name": "Rock", "count": 100}],
                    "decades": [{"name": "1990s", "count": 100}]
                }
                mock_roon.return_value = mock_roon_client

                with pytest.raises(ValueError):
                    analyze_prompt("test prompt")

    def test_analyze_prompt_returns_available_filters(self, mocker):
        """Should return available genres and decades from library."""
        from backend.analyzer import analyze_prompt
        from backend.llm_client import LLMResponse

        mock_response = LLMResponse(
            content=json.dumps({
                "genres": ["Rock"],
                "decades": ["1990s"],
                "reasoning": "Test"
            }),
            input_tokens=100,
            output_tokens=50,
            model="test-model"
        )

        with patch("backend.analyzer.get_llm_client") as mock_llm:
            mock_client = MagicMock()
            mock_client.analyze.return_value = mock_response
            mock_client.parse_json_response.return_value = json.loads(mock_response.content)
            mock_llm.return_value = mock_client

            with patch("backend.analyzer.get_roon_client") as mock_roon:
                mock_roon_client = MagicMock()
                mock_roon_client.get_library_stats.return_value = {
                    "genres": [
                        {"name": "Rock", "count": 500},
                        {"name": "Jazz", "count": 200},
                        {"name": "Classical", "count": 100}
                    ],
                    "decades": [
                        {"name": "1980s", "count": 300},
                        {"name": "1990s", "count": 400},
                        {"name": "2000s", "count": 200}
                    ]
                }
                mock_roon.return_value = mock_roon_client

                result = analyze_prompt("rock music from the 90s")

                # Should include all available options from library
                assert len(result.available_genres) == 3
                assert len(result.available_decades) == 3


class TestFilterSuggestions:
    """Tests for filter suggestion logic."""

    def test_filters_suggest_matching_library_genres(self, mocker):
        """Suggested genres should match library genres."""
        from backend.analyzer import analyze_prompt
        from backend.llm_client import LLMResponse

        # LLM suggests "Alt Rock" but library has "Alternative"
        mock_response = LLMResponse(
            content=json.dumps({
                "genres": ["Alt Rock", "Grunge"],
                "decades": ["1990s"],
                "reasoning": "90s alternative rock"
            }),
            input_tokens=100,
            output_tokens=50,
            model="test-model"
        )

        with patch("backend.analyzer.get_llm_client") as mock_llm:
            mock_client = MagicMock()
            mock_client.analyze.return_value = mock_response
            mock_client.parse_json_response.return_value = json.loads(mock_response.content)
            mock_llm.return_value = mock_client

            with patch("backend.analyzer.get_roon_client") as mock_roon:
                mock_roon_client = MagicMock()
                mock_roon_client.get_library_stats.return_value = {
                    "genres": [
                        {"name": "Alternative", "count": 500},
                        {"name": "Grunge", "count": 100}
                    ],
                    "decades": [{"name": "1990s", "count": 400}]
                }
                mock_roon.return_value = mock_roon_client

                result = analyze_prompt("90s alt rock")

                # Grunge should be in suggestions (exact match)
                # Alt Rock might not be if no fuzzy match
                assert "Grunge" in result.suggested_genres


class TestTrackAnalysis:
    """Tests for seed track dimension extraction."""

    def test_analyze_track_extracts_dimensions(self, mocker):
        """Should extract musical dimensions from a track."""
        from backend.analyzer import analyze_track
        from backend.llm_client import LLMResponse
        from backend.models import Track

        track = Track(
            item_key="1",
            title="Fake Plastic Trees",
            artist="Radiohead",
            album="The Bends",
            duration_ms=290000,
            year=1995,
            genres=["Alternative", "Rock"],
        )

        mock_response = LLMResponse(
            content=json.dumps({
                "dimensions": [
                    {"id": "mood", "label": "Melancholy, bittersweet mood", "description": "Emotional and reflective"},
                    {"id": "era", "label": "Mid-90s British alternative", "description": "Britpop era sound"},
                    {"id": "vocals", "label": "Falsetto-tinged vocals", "description": "Thom Yorke's distinctive style"},
                ]
            }),
            input_tokens=100,
            output_tokens=80,
            model="test-model"
        )

        with patch("backend.analyzer.get_llm_client") as mock_llm:
            mock_client = MagicMock()
            mock_client.analyze.return_value = mock_response
            mock_client.parse_json_response.return_value = json.loads(mock_response.content)
            mock_llm.return_value = mock_client

            result = analyze_track(track)

            assert result.track.item_key == "1"
            assert len(result.dimensions) == 3
            assert result.dimensions[0].id == "mood"
            assert "melancholy" in result.dimensions[0].label.lower()

    def test_analyze_track_returns_specific_labels(self, mocker):
        """Dimension labels should be specific, not generic."""
        from backend.analyzer import analyze_track
        from backend.llm_client import LLMResponse
        from backend.models import Track

        track = Track(
            item_key="2",
            title="Black",
            artist="Pearl Jam",
            album="Ten",
            duration_ms=340000,
            year=1991,
            genres=["Grunge", "Rock"],
        )

        mock_response = LLMResponse(
            content=json.dumps({
                "dimensions": [
                    {"id": "mood", "label": "The raw, aching heartbreak", "description": "Loss and longing"},
                    {"id": "vocals", "label": "Eddie Vedder's baritone intensity", "description": "Powerful delivery"},
                ]
            }),
            input_tokens=100,
            output_tokens=60,
            model="test-model"
        )

        with patch("backend.analyzer.get_llm_client") as mock_llm:
            mock_client = MagicMock()
            mock_client.analyze.return_value = mock_response
            mock_client.parse_json_response.return_value = json.loads(mock_response.content)
            mock_llm.return_value = mock_client

            result = analyze_track(track)

            # Labels should be specific, not just "the mood" or "the vocals"
            for dim in result.dimensions:
                assert len(dim.label) > 10  # Should be descriptive
                assert dim.label.lower() != f"the {dim.id}"  # Not generic
