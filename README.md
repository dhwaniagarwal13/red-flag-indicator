# Red-Flag Screener

A point-in-time forensic-accounting screener over SEC XBRL filings. Ingests
as-filed financial statements, reconstructs what was knowable on any past date,
and ranks companies on the standard forensic metrics — Beneish M-Score, Altman
Z-Score, Piotroski F-Score, accrual quality, and Benford's-Law digit analysis.

**Status: Phase 1b complete.** Ingestion, staging and the point-in-time fact
table run end to end on a 23-company pilot, and the three restatement-detection
artifacts found in Phase 1 are fixed and covered by regression tests. The
metric layer (M-Score, Z-Score, F-Score, Benford) is not built yet. See
[Current findings](#current-findings) for what the data shows now.

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
stg_facts                         cleaned, period-typed, lag-checked, sign-normalised
      │   join dbt/seeds/concepts.csv (exported from redflag.concepts)
      ▼
fct_financials_pit                bitemporal: value × filing, restatement computed
                                   only within a consistent XBRL-tag lineage
      ▼
(next) fct_ratios → fct_scores → Power BI / Tableau Public
```

`dbt/seeds/concepts.csv` is a generated artefact (`make seeds` /
`python -m redflag.export_seeds`), never hand-edited — `redflag/concepts.py`
is the single source of truth for concept metadata (sign convention,
restatement eligibility), so dbt and Python can never quietly disagree about it.

## Stack

Python 3.11+ · DuckDB · dbt-core + dbt-duckdb · pandas · httpx · Power BI / Tableau Public

Verified working on Python 3.14 / Windows.

---

## Quickstart

```bash
make install
export SEC_USER_AGENT="Your Name your@email.com"   # SEC requires a contact
make all          # ingest -> seeds -> dbt run -> dbt test -> pytest
```

No absolute paths anywhere in the code — everything resolves from the repo
root (`redflag.config.ROOT`, or `$REDFLAG_ROOT` for dbt). One thing that *is*
absolute and does **not** survive being moved: the venv's own console-script
launchers (`dbt.exe` etc.) — pip bakes the interpreter's absolute path into
them at install time. If you relocate the repo, recreate the venv
(`rm -rf .venv && make install`) rather than moving it; this project's own
venv briefly broke exactly this way mid-Phase-1b.

---

## Data model

`fct_financials_pit` is **bitemporal**: it tracks both the period a number
describes and the date it was filed. One row per (company, concept, period,
reporting filing), so a fiscal year typically appears three times — its own 10-K
plus two years as a comparative.

Key columns: `report_version`, `n_reports`, `is_first_report`, `is_latest_report`,
`first_reported_value`, `latest_reported_value`, `restatement_pct`, `was_restated`,
plus three added in Phase 1b: `latest_tag`, `in_lineage`, `tag_switch_detected`,
and `restatement_eligible` (joined from the concepts seed).

This supports both analytical bases:

- **as-first-reported** — what the market saw on filing day (correct for backtests)
- **as-latest-reported** — the figure after revision (correct for "what happened")

---

## Current findings

Restatement rates across the pilot universe put GE, Procter & Gamble, Bausch
Health, Lockheed Martin, Wells Fargo, Under Armour and Kraft Heinz at the top,
and Cisco, Adobe, Luckin Coffee and Hertz at zero. Five of eight case-study
companies land in the top six of 22.

### Phase 1b: three artifacts diagnosed and fixed

Phase 1's restatement_pct compared every filing for a period against every
other filing for that period, regardless of which XBRL tag reported the value
or what that value's sign should mean. Three real cases exposed why that's
wrong:

| Case | Root cause | Fix |
|---|---|---|
| **Hertz interest expense**, FY2020: appeared to swing 70M → −608M (−968%) | A later filing switched from the gross `InterestExpense` tag to the net `InterestIncomeExpenseNet` tag — two different figures, not one restated | `restatement_pct` now computed only across filings sharing the **same tag** (`in_lineage`); tag changes are surfaced separately via `tag_switch_detected` rather than read as a value change. `InterestIncomeExpenseNet` split into its own `interest_income_expense_net` concept so it can never be merged into gross expense again |
| **Merck diluted shares**, FY2012: 3,076 → 3,076,000,000, same tag, same declared unit | A scale typo in Merck's own filed XBRL, not an accounting event | `shares_diluted` marked `restatement_eligible = false` — kept in the fact table for transparency, excluded from any restatement-based score |
| **Apple diluted shares**, FY2013: exact 7.0000x jump | Correct, legitimate retroactive restatement for Apple's 2014 7-for-1 stock split | Same fix as above — share counts are structurally excluded from the risk signal regardless of *why* they moved, because neither cause is an accounting-quality signal |

Applying the tag-lineage fix also cleaned up the general leaderboard, not just
the three hand-diagnosed cases — e.g. Merck's restatement rate across core P&L
concepts dropped from 12.5%/33.9% worst-move to 8.3%/16.5% once
inconsistent-tag comparisons stopped being counted.

**One case that looked like it might be a fourth artifact, and wasn't.** GE's
operating cash flow for FY2016 moved from −244M to 1160M under the exact same
tag (`NetCashProvidedByUsedInOperatingActivities`) across all three filings
that reported it — no tag switch, no sign issue. That's GE's real, publicly
documented 2018–19 accounting restatement (the insurance/long-term-care reserve
issue that drew SEC scrutiny), and it correctly survives the fix. Worth stating
plainly: **not every large restatement is a data bug** — the fix here was to
stop conflating artifacts with genuine restatements, not to suppress large
numbers.

Both fixed cases are locked in as dbt regression tests
(`dbt/tests/assert_htz_interest_expense_fix.sql`,
`assert_no_negative_always_positive_values.sql`), plus Python-level tests on
the concept metadata itself (`tests/test_concepts.py`) so the underlying cause
can't silently regress even before a full ingest+build cycle would catch it.

### Still an open, conceptual problem

**Legitimate restatements can look identical to suspicious ones**, and no
mechanical fix resolves this — it needs judgment. Procter & Gamble ranks near
the top largely because divesting Duracell and its beauty brands forced
restatement of prior-year comparatives for discontinued operations — ordinary
GAAP housekeeping, not a red flag. Separating reclassification from revision
(e.g. by cross-referencing 8-K divestiture disclosures) is Phase 3+ work, not
something the point-in-time layer alone can settle.

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
- [x] Phase 1b — fix tag/sign/units contamination above
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
