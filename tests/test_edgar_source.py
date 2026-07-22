"""Tests for EdgarSource.list_companies().

Regression coverage for a real bug found scaling to the S&P 500: dropping
duplicate entity_id rows silently discarded whichever ticker of a dual-class
company (Alphabet: GOOG/GOOGL, Fox: FOX/FOXA, ...) didn't happen to appear
first in SEC's ticker map, so a lookup for the discarded ticker failed even
though the company has perfectly valid XBRL data.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from redflag.sources.edgar import EdgarSource  # noqa: E402


def _make_source(tmp_path: Path, tickers: list[dict]) -> EdgarSource:
    cache_dir = tmp_path / "edgar"
    cache_dir.mkdir()
    payload = {str(i): t for i, t in enumerate(tickers)}
    (cache_dir / "_company_tickers.json").write_text(json.dumps(payload), encoding="utf-8")
    return EdgarSource(cache_dir=cache_dir)


def test_dual_class_tickers_both_resolve(tmp_path):
    """Alphabet's GOOG and GOOGL share one CIK. Both must be independently
    findable by ticker — this is exactly what silently broke before the fix."""
    src = _make_source(
        tmp_path,
        [
            {"cik_str": 1652044, "ticker": "GOOGL", "title": "Alphabet Inc."},
            {"cik_str": 1652044, "ticker": "GOOG", "title": "Alphabet Inc."},
            {"cik_str": 320193, "ticker": "AAPL", "title": "Apple Inc."},
        ],
    )
    companies = src.list_companies()

    assert set(companies.ticker) == {"GOOGL", "GOOG", "AAPL"}
    assert (companies.ticker == "GOOG").any()
    assert (companies.ticker == "GOOGL").any()


def test_list_companies_not_deduplicated_by_entity_id(tmp_path):
    """The old bug: dropping to one row per CIK before any ticker filtering
    silently discards whichever ticker lost the coin flip. Assert the
    dataframe explicitly is NOT collapsed to unique entity_id, since that's
    exactly the property that broke ticker lookups for BF-B/FOX/GOOG/NWS/MAA
    at S&P 500 scale."""
    src = _make_source(
        tmp_path,
        [
            {"cik_str": 14693, "ticker": "BF-A", "title": "Brown-Forman"},
            {"cik_str": 14693, "ticker": "BF-B", "title": "Brown-Forman"},
        ],
    )
    companies = src.list_companies()
    assert len(companies) == 2
    assert companies.entity_id.nunique() == 1
