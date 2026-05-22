"""Tests for the cron parser in scheduler.py."""

from datetime import datetime

import pytest

from backend.scheduler import _parse_field, matches_cron


class TestParseField:
    def test_wildcard_returns_full_range(self):
        assert _parse_field("*", 0, 59) == set(range(0, 60))
        assert _parse_field("*", 0, 23) == set(range(0, 24))
        assert _parse_field("*", 1, 12) == set(range(1, 13))

    def test_exact_value(self):
        assert _parse_field("5", 0, 59) == {5}
        assert _parse_field("0", 0, 59) == {0}
        assert _parse_field("59", 0, 59) == {59}

    def test_range(self):
        assert _parse_field("1-5", 0, 59) == {1, 2, 3, 4, 5}
        assert _parse_field("0-3", 0, 59) == {0, 1, 2, 3}

    def test_comma_list(self):
        assert _parse_field("1,3,5", 0, 59) == {1, 3, 5}

    def test_mixed_comma_and_range(self):
        assert _parse_field("1-3,7,10-12", 0, 59) == {1, 2, 3, 7, 10, 11, 12}

    def test_single_value_same_as_exact(self):
        assert _parse_field("30", 0, 59) == {30}

    def test_boundary_values(self):
        assert 0 in _parse_field("*", 0, 59)
        assert 59 in _parse_field("*", 0, 59)
        assert 0 in _parse_field("0", 0, 59)


class TestMatchesCron:
    def test_all_wildcards_matches_any_time(self):
        dt = datetime(2024, 6, 15, 14, 30)  # Saturday 14:30
        assert matches_cron("* * * * *", dt) is True

    def test_exact_match(self):
        # "30 14 15 6 6" = June 15 at 14:30, which is a Saturday (cron dow=6)
        dt = datetime(2024, 6, 15, 14, 30)  # Saturday
        assert matches_cron("30 14 15 6 6", dt) is True

    def test_minute_mismatch(self):
        dt = datetime(2024, 6, 15, 14, 31)
        assert matches_cron("30 14 15 6 *", dt) is False

    def test_hour_mismatch(self):
        dt = datetime(2024, 6, 15, 15, 30)
        assert matches_cron("30 14 15 6 *", dt) is False

    def test_day_mismatch(self):
        dt = datetime(2024, 6, 16, 14, 30)
        assert matches_cron("30 14 15 6 *", dt) is False

    def test_month_mismatch(self):
        dt = datetime(2024, 7, 15, 14, 30)
        assert matches_cron("30 14 15 6 *", dt) is False

    def test_dow_mismatch(self):
        # Saturday (cron dow=6), we require Sunday (cron dow=0)
        dt = datetime(2024, 6, 15, 14, 30)  # Saturday
        assert matches_cron("30 14 15 6 0", dt) is False

    def test_dow_conversion_sunday(self):
        # 2024-06-16 is a Sunday; Python weekday()=6, cron dow=0
        dt = datetime(2024, 6, 16, 0, 0)
        assert matches_cron("0 0 * * 0", dt) is True

    def test_dow_conversion_monday(self):
        # 2024-06-17 is a Monday; Python weekday()=0, cron dow=1
        dt = datetime(2024, 6, 17, 0, 0)
        assert matches_cron("0 0 * * 1", dt) is True

    def test_dow_conversion_saturday(self):
        # 2024-06-15 is a Saturday; Python weekday()=5, cron dow=6
        dt = datetime(2024, 6, 15, 0, 0)
        assert matches_cron("0 0 * * 6", dt) is True

    def test_range_in_hours(self):
        dt = datetime(2024, 1, 1, 10, 0)
        assert matches_cron("0 8-18 * * *", dt) is True

    def test_range_excludes_boundary(self):
        dt = datetime(2024, 1, 1, 7, 0)
        assert matches_cron("0 8-18 * * *", dt) is False

    def test_list_of_minutes(self):
        dt = datetime(2024, 1, 1, 12, 15)
        assert matches_cron("0,15,30,45 12 * * *", dt) is True

    def test_invalid_field_count_returns_false(self):
        dt = datetime(2024, 1, 1, 12, 0)
        assert matches_cron("* * * *", dt) is False  # only 4 fields

    def test_invalid_field_value_returns_false(self):
        dt = datetime(2024, 1, 1, 12, 0)
        assert matches_cron("abc * * * *", dt) is False

    def test_empty_expr_returns_false(self):
        dt = datetime(2024, 1, 1, 12, 0)
        assert matches_cron("", dt) is False

    def test_hourly_cron(self):
        # Every hour at minute 0
        dt = datetime(2024, 3, 15, 9, 0)
        assert matches_cron("0 * * * *", dt) is True
        dt2 = datetime(2024, 3, 15, 9, 1)
        assert matches_cron("0 * * * *", dt2) is False

    def test_daily_at_midnight(self):
        dt = datetime(2024, 3, 15, 0, 0)
        assert matches_cron("0 0 * * *", dt) is True
        dt2 = datetime(2024, 3, 15, 0, 1)
        assert matches_cron("0 0 * * *", dt2) is False
