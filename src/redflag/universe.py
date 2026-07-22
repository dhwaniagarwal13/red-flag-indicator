"""Company universes.

The ``pilot`` universe is deliberately not a random sample. It pairs well-behaved
large caps (a sanity baseline — a screener that flags Microsoft is broken) with
companies that were later charged, restated, or collapsed. Those known cases are
the closest thing this project has to labelled data, so they belong in the
universe from day one rather than being bolted on at validation time.

Inclusion here is *not* an accusation. These are companies whose accounting later
became the subject of regulatory action, restatement, or public dispute, and they
serve as test cases for whether the screener surfaces anything before the fact.
"""

from __future__ import annotations

import csv
from pathlib import Path

from redflag import config

# Large, heavily-scrutinised filers. If the screener ranks these as high risk,
# the screener is wrong — they function as a false-positive check.
_BASELINE = [
    "AAPL", "MSFT", "JNJ", "PG", "KO", "WMT", "HD", "MRK",
    "PEP", "CSCO", "ORCL", "ADBE", "TXN", "HON", "UNP", "LMT",
]

# Companies whose reported figures later drew SEC action, restatement, or
# well-documented dispute. Used as recall test cases in Phase 4.
_CASE_STUDIES = {
    "LKNCY": "Luckin Coffee — fabricated revenue, disclosed 2020",
    "UAA": "Under Armour — SEC charges over pull-forward sales",
    "KHC": "Kraft Heinz — SEC action over procurement accounting",
    "HTZ": "Hertz — 2015 multi-year restatement",
    "BHC": "Bausch Health (ex-Valeant) — 2015-16 accounting controversy",
    "NKLA": "Nikola — SEC settlement over misleading statements",
    "WFC": "Wells Fargo — sales-practice scandal",
    "GE": "General Electric — SEC action over insurance/power disclosures",
}

UNIVERSES: dict[str, list[str]] = {
    "baseline": _BASELINE,
    "cases": list(_CASE_STUDIES),
    "pilot": _BASELINE + list(_CASE_STUDIES),
}


def _load_csv_universe(name: str) -> list[str]:
    path = Path(config.DATA) / "universe" / f"{name}.csv"
    if not path.exists():
        raise SystemExit(
            f"unknown universe {name!r}. Built-ins: {', '.join(UNIVERSES)}, full. "
            f"Or create {path} with a 'ticker' column "
            f"(python -m redflag.fetch_sp500 creates sp500.csv)."
        )
    with path.open(newline="", encoding="utf-8") as fh:
        return [r["ticker"].strip().upper() for r in csv.DictReader(fh) if r.get("ticker")]


def load_universe(name: str) -> list[str]:
    """Return tickers for a named universe.

    ``full`` is S&P 500 (``data/universe/sp500.csv``) plus the case-study
    companies, deduplicated — kept as an explicit union rather than assuming
    the case studies are a subset, because most of them aren't: LKNCY, NKLA,
    BHC and HTZ have all been removed from or never held index membership at
    various points, precisely because of the events that make them useful
    test cases. Scaling to the full universe must not silently drop them.

    Any other name not in ``UNIVERSES`` falls back to
    ``data/universe/<name>.csv`` (one ``ticker`` column), so a universe such
    as the S&P 500 can be dropped in without a code change.
    """
    if name == "full":
        sp500 = _load_csv_universe("sp500")
        combined = list(dict.fromkeys(sp500 + list(_CASE_STUDIES)))  # dedup, preserve order
        return combined

    if name in UNIVERSES:
        return UNIVERSES[name]

    return _load_csv_universe(name)


def case_study_notes() -> dict[str, str]:
    """Ticker -> why it is a test case. Surfaced in the validation write-up."""
    return dict(_CASE_STUDIES)
