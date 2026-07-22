# Red-Flag Screener

A point-in-time forensic-accounting screener over SEC XBRL filings. Ingests
as-filed financial statements, reconstructs what was knowable on any past date,
and ranks companies on the standard forensic metrics — Beneish M-Score, Altman
Z-Score, Piotroski F-Score, accrual quality, and Benford's-Law digit analysis.

**Status: Phase 1 (thin slice) complete.** Ingestion, staging and the
point-in-time fact table run end to end on a 23-company pilot. The metric layer
is not built yet. See [Current findings](#current-findings) for what the data
already shows, including what is *not* yet trustworthy.

---

## Why point-in-time

Most free financial data is *restated* — silently corrected with hindsight. Any
backtest built on it is fiction, because it uses numbers nobody had at the time.

SEC EDGAR stamps every XBRL fact with the date it was filed, which makes honest
reconstruction possible. Two distinct problems this solves:

| Problem | Example from this dataset |
|---|---|
| **Restatement** | The same fiscal year reported with different values in later filings |
| **Availability lag** | Apple's FY2024 ended 2024-09-28 but was not filed until 2024-11-01. Joining on fiscal year uses it five weeks early. |

The second affects *every* company, not just troubled ones, and is the more
pervasive source of lookahead bias.

---

## Architecture

```
SEC EDGAR companyfacts API
      │   rate-limited (6 req/s), cached to disk, resumable
      ▼
data/raw/edgar/CIK*.json          bronze — byte-identical to the API response
      │   flatten + canonical concept mapping
      ▼
data/staging/facts.parquet        silver — one row per reported fact
      │   dbt
      ▼
stg_facts                         cleaned, period-typed, lag-checked
      ▼
fct_financials_pit                bitemporal: value × filing that reported it
      ▼
(next) fct_ratios → fct_scores → Power BI / Tableau Public
```

## Stack

Python 3.11+ · DuckDB · dbt-core + dbt-duckdb · pandas · httpx · Power BI / Tableau Public

Verified working on Python 3.14 / Windows.

---

## Quickstart

```bash
python -m venv .venv
.venv/Scripts/pip install -e .          # or: pip install -r requirements.txt

export SEC_USER_AGENT="Your Name your@email.com"   # SEC requires a contact
python -m redflag.ingest --universe pilot

cd dbt && DBT_PROFILES_DIR=. dbt run && dbt test
```

No absolute paths anywhere — everything resolves from the repo root.

---

## Data model

`fct_financials_pit` is **bitemporal**: it tracks both the period a number
describes and the date it was filed. One row per (company, concept, period,
reporting filing), so a fiscal year typically appears three times — its own 10-K
plus two years as a comparative.

Key columns: `report_version`, `n_reports`, `is_first_report`, `is_latest_report`,
`first_reported_value`, `latest_reported_value`, `restatement_pct`, `was_restated`.

This supports both analytical bases:

- **as-first-reported** — what the market saw on filing day (correct for backtests)
- **as-latest-reported** — the figure after revision (correct for "what happened")

---

## Current findings

Restatement rates across the pilot universe put GE, Under Armour, Wells Fargo,
Kraft Heinz and Bausch Health near the top, and Apple, Cisco, Adobe and Home
Depot near the bottom. That ordering is suggestive — four of eight case-study
companies rank in the top seven.

**It is not yet trustworthy.** Diagnostics showed the current
`restatement_pct` is contaminated by three artifacts:

1. **Tag switching.** A filer moving from `NetCashProvidedByUsedInOperatingActivities`
   to `...ContinuingOperations` between filings registers as a restatement. Values
   must be compared within the same `source_tag`.
2. **Sign conventions.** XBRL does not enforce a sign for expense items —
   Hertz's interest expense flips from +70M to −608M between filings.
3. **Share counts.** `shares_diluted` restatements are stock splits (Apple 7:1,
   4:1) and unit-scale inconsistencies (Merck reporting in millions vs units),
   never accounting revisions.

A fourth issue is conceptual rather than mechanical: **legitimate restatements
look identical to suspicious ones.** Procter & Gamble ranks second largely
because divesting Duracell and its beauty brands forced restatement of prior-year
comparatives for discontinued operations. Separating reclassification from
revision is the substantive analytical problem here.

---

## Known limitations

- **Survivorship bias in the universe.** SEC's ticker map lists only *current*
  registrants, so Nikola (delisted after its 2025 bankruptcy) silently dropped
  out. Delisted companies must be pinned by CIK.
- **Entity continuity.** Hertz re-listed after bankruptcy under a different CIK;
  ticker-based lookup follows the surviving entity, not the history.
- **Foreign private issuers** file 20-F with markedly thinner XBRL tagging —
  Luckin Coffee yields 10 concepts against a typical 20+ for a domestic filer.
- **XBRL coverage starts ~2010.** Enron and WorldCom are out of reach; validation
  cases must be post-2010.

## Roadmap

- [x] Phase 1 — ingestion, staging, point-in-time fact table
- [ ] Phase 1b — fix tag/sign/units contamination above
- [ ] Phase 2 — expand to S&P 500
- [ ] Phase 3 — ratio + score models (M-Score, Z-Score, F-Score, accruals, Benford)
- [ ] Phase 4 — validation: case backtest + accrual forward-return test
- [ ] Phase 5 — Power BI screener + Tableau Public mirror
- [ ] Phase 6 — findings write-up

---

## A note on interpretation

Everything here screens for **aggressive or unusual accounting**, not fraud. Most
flagged companies are entirely fine, and a screen that surfaces 15% of the market
is a filter for further review — not a verdict on any company.
