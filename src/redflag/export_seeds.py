"""Export Python-defined reference data as dbt seeds.

    python -m redflag.export_seeds

concepts.py is the single source of truth for concept metadata (sign
convention, restatement eligibility, required-ness). This writes it out as a
CSV dbt can join against, so that metadata never has to be hand-duplicated in
SQL. Run before ``dbt seed`` whenever concepts.py changes.

Same reasoning for universe.py's ``_CASE_STUDIES``: it's the single source of
truth for which tickers are case studies and why, used by both the Python
universe loader and (via this export) the dashboard mart's
``is_case_study`` / ``case_study_note`` columns.
"""

from __future__ import annotations

import csv
import sys

from redflag import concepts, universe
from redflag.config import ROOT


def _write_case_studies() -> None:
    out = ROOT / "dbt" / "seeds" / "case_studies.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    with out.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(["ticker", "case_study_note"])
        for ticker, note in universe.case_study_notes().items():
            writer.writerow([ticker, note])
    print(f"wrote {out} ({len(universe.case_study_notes())} case studies)")


def main() -> int:
    out = ROOT / "dbt" / "seeds" / "concepts.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    concepts.to_dataframe().to_csv(out, index=False)
    print(f"wrote {out} ({len(concepts.CONCEPTS)} concepts)")

    _write_case_studies()
    return 0


if __name__ == "__main__":
    sys.exit(main())
