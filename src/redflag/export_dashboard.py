"""Export fct_dashboard to CSV for the Power BI / Tableau Public dashboard.

    python -m redflag.export_dashboard

A flat CSV rather than a live DuckDB connection: both tools *can* connect to
DuckDB directly (Power BI via ODBC, Tableau via its DuckDB connector as of
2024.2), but that couples the dashboard to a local driver install and this
machine's file path. A CSV opens with "Get Data > Text/CSV" / "Connect > Text
File" with nothing else to configure, which matches this project's own bias
toward reproducibility over convenience (see the README's point-in-time
argument) -- anyone should be able to open the dashboard from the export
alone, without also having DuckDB, dbt, or this repo's Python environment.

Re-run after `make build` whenever the underlying marts change; the file is
git-ignored (see .gitignore) since it's a build artefact, not a source.
"""

from __future__ import annotations

import sys

import duckdb

from redflag.config import DATA, WAREHOUSE


def main() -> int:
    if not WAREHOUSE.exists():
        raise SystemExit(f"{WAREHOUSE} not found -- run `make build` first.")

    out_dir = DATA / "exports"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / "dashboard.csv"

    con = duckdb.connect(str(WAREHOUSE), read_only=True)
    try:
        df = con.execute(
            "select *, entity_id || '-' || period_fiscal_year as detail_key "
            "from main_marts.fct_dashboard"
        ).fetchdf()
    finally:
        con.close()

    df.to_csv(out, index=False)
    print(f"wrote {out} ({len(df)} rows, {len(df.columns)} columns)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
