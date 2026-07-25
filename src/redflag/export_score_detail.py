"""Export the M-Score/Z-Score/F-Score component breakdown to CSV, for the
Power BI drill-through page.

    python -m redflag.export_score_detail

`fct_dashboard` (and dashboard.csv) is deliberately one composite score per
model -- adding all 22 underlying components there would defeat its point as
a wide-but-flat summary row. This is the detail companion: one row per
(entity_id, period_fiscal_year) with the 8 Beneish indices, 5 Altman
factors, and 9 Piotroski signals that produced each composite, for the
"why was this company flagged" drill-through view.

Also writes a `detail_key` column (entity_id || "-" || period_fiscal_year)
on both this export and dashboard.csv would need one too -- Power BI import
relationships are single-column, so build the matching key on dashboard.csv
via a Power Query calculated column: entity_id & "-" & period_fiscal_year.
"""

from __future__ import annotations

import sys

import duckdb

from redflag.config import DATA, WAREHOUSE

QUERY = """
select
    m.entity_id,
    m.ticker,
    m.company_name,
    m.period_fiscal_year,
    m.entity_id || '-' || m.period_fiscal_year as detail_key,

    -- Beneish M-Score: 8 indices
    m.dsri, m.gmi, m.aqi, m.sgi, m.depi, m.sgai, m.tata, m.lvgi,

    -- Altman Z-Score: 5 factors
    z.x1, z.x2, z.x3, z.x4, z.x5,

    -- Piotroski F-Score: 9 binary signals
    f.signal_positive_roa, f.signal_positive_cfo, f.signal_roa_improved,
    f.signal_earnings_quality, f.signal_leverage_decreased,
    f.signal_liquidity_improved, f.signal_no_dilution,
    f.signal_margin_improved, f.signal_turnover_improved

from main_marts.fct_beneish_mscore m
left join main_marts.fct_altman_zscore z
    using (entity_id, period_fiscal_year)
left join main_marts.fct_piotroski_fscore f
    using (entity_id, period_fiscal_year)
"""


def main() -> int:
    if not WAREHOUSE.exists():
        raise SystemExit(f"{WAREHOUSE} not found -- run `make build` first.")

    out_dir = DATA / "exports"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / "score_detail.csv"

    con = duckdb.connect(str(WAREHOUSE), read_only=True)
    try:
        df = con.execute(QUERY).fetchdf()
    finally:
        con.close()

    df.to_csv(out, index=False)
    print(f"wrote {out} ({len(df)} rows, {len(df.columns)} columns)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
