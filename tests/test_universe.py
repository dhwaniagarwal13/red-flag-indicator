"""Tests for universe loading, especially the 'full' union logic.

Doesn't depend on data/universe/sp500.csv actually existing on disk — the S&P
500 fetch is a network call that shouldn't run in a fast test suite, so
_load_csv_universe is patched instead.
"""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from redflag import universe  # noqa: E402


def test_full_universe_includes_case_studies_not_in_sp500():
    """Most case-study companies (LKNCY, NKLA, BHC, HTZ) have been removed
    from or never held S&P 500 membership, precisely because of the events
    that make them useful test cases. 'full' must not silently drop them."""
    fake_sp500 = ["AAPL", "MSFT", "WFC", "GE"]  # only 2 of 8 case studies overlap
    with patch.object(universe, "_load_csv_universe", return_value=fake_sp500):
        result = universe.load_universe("full")

    for ticker in universe.case_study_notes():
        assert ticker in result, f"{ticker} dropped from the full universe"


def test_full_universe_deduplicates_overlap():
    fake_sp500 = ["AAPL", "WFC", "GE"]  # WFC and GE are also case studies
    with patch.object(universe, "_load_csv_universe", return_value=fake_sp500):
        result = universe.load_universe("full")

    assert len(result) == len(set(result)), "full universe contains duplicate tickers"


def test_pilot_universe_unchanged():
    pilot = universe.load_universe("pilot")
    assert "AAPL" in pilot
    assert "LKNCY" in pilot
    assert len(pilot) == len(set(pilot))
