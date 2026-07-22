"""Tests for the Sloan accrual-anomaly statistics, not the underlying data.

Runs against a synthetic panel rather than the real warehouse -- same reason
test_universe.py mocks the network call: this should stay a fast,
deterministic unit test of the math (quintile aggregation, hedge return,
Welch t-stat), not a re-run of the actual finding, which lives in the dbt
models and is checked by eye via `make sloan-test`.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from redflag import sloan_test  # noqa: E402


def _synthetic_panel() -> pd.DataFrame:
    # Constructed so the answer is known: Q1 (lowest tata) returns ~10%, Q5
    # (highest tata) returns ~0%, split across two fiscal years so the
    # quintile-per-year grouping logic is actually exercised. A small,
    # deterministic per-name wobble keeps within-quintile variance nonzero
    # (real panels never have exactly equal returns), so the Welch t-stat
    # denominator isn't degenerately zero.
    rows = []
    for year in (2020, 2021):
        for q in range(1, 6):
            for i in range(20):  # 20 names per quintile per year
                base = 0.10 if q == 1 else (0.0 if q == 5 else 0.05)
                wobble = 0.001 * (i - 10)
                rows.append(
                    {
                        "period_fiscal_year": year,
                        "ticker": f"T{year}{q}{i}",
                        "tata": -0.5 + 0.1 * q,
                        "fwd_return_12m": base + wobble,
                        "accrual_quintile": q,
                    }
                )
    return pd.DataFrame(rows)


def test_hedge_return_matches_known_construction():
    result = sloan_test.run(_synthetic_panel())
    q1 = next(q for q in result.quintiles if q.quintile == 1)
    q5 = next(q for q in result.quintiles if q.quintile == 5)

    assert q1.mean_return == pytest.approx(0.10, abs=1e-3)
    assert q5.mean_return == pytest.approx(0.0, abs=1e-3)
    assert result.hedge_return == pytest.approx(0.10, abs=1e-3)
    assert result.n_years == 2


def test_hedge_return_positive_gives_significant_t_stat():
    result = sloan_test.run(_synthetic_panel())
    assert result.t_stat > 0
    # Constructed with a wide, unambiguous gap (10% vs 0%) and tiny
    # within-quintile noise, so this should read as essentially certain.
    assert result.p_value < 0.001


def test_report_is_a_readable_string_with_all_quintiles():
    result = sloan_test.run(_synthetic_panel())
    text = sloan_test.report(result)
    for q in (1, 2, 3, 4, 5):
        assert f"{q:>2}" in text
    assert "Hedge return" in text
