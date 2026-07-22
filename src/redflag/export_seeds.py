"""Export Python-defined reference data as dbt seeds.

    python -m redflag.export_seeds

concepts.py is the single source of truth for concept metadata (sign
convention, restatement eligibility, required-ness). This writes it out as a
CSV dbt can join against, so that metadata never has to be hand-duplicated in
SQL. Run before ``dbt seed`` whenever concepts.py changes.
"""

from __future__ import annotations

import sys

from redflag import concepts
from redflag.config import ROOT


def main() -> int:
    out = ROOT / "dbt" / "seeds" / "concepts.csv"
    out.parent.mkdir(parents=True, exist_ok=True)
    concepts.to_dataframe().to_csv(out, index=False)
    print(f"wrote {out} ({len(concepts.CONCEPTS)} concepts)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
