# Red-Flag Screener

A point-in-time forensic-accounting screener over SEC XBRL filings. Ingests
as-filed financial statements, reconstructs what was knowable on any past date,
and ranks companies on the standard forensic metrics — Beneish M-Score, Altman
Z-Score, Piotroski F-Score, accrual quality, and Benford's-Law digit analysis.

**Status: formally validated.** All three scoring models (Beneish M-Score,
Altman Z-Score, Piotroski F-Score) are live, tested, and run across 501
companies / 7,554 company-years — not just the 23-company pilot they were
built and validated on. Scaling up surfaced three more real bugs (see
[Scaling to the S&P 500](#scaling-to-the-sp-500)), on top of the eight found
building the models themselves. M-Score and F-Score independently converge on
Under Armour's FY2015 channel-stuffing year; Z-Score shows Kraft Heinz and
Bausch Health sitting in chronic "distress" territory, consistent with their
real post-merger leverage. [Phase 4](#phase-4-formal-validation) then tested
the point-in-time architecture itself against the calendar: querying the
screen "as of" a date shortly after UAA's FY2015 10-K was filed reproduces
the same M-Score/F-Score hit **3.7 years before** the federal investigation
became public, and a Sloan (1996)-style accrual/forward-return test on the
whole panel finds the predicted sign, though not a clean monotonic effect.
See [Current findings](#current-findings) for the restatement-layer results,
[M-Score](#beneish-m-score), [Z-Score](#altman-z-score),
[F-Score](#piotroski-f-score) for the pilot-scale validation,
[Scaling to the S&P 500](#scaling-to-the-sp-500) for what changed at scale,
and [Phase 4](#phase-4-formal-validation) for the case backtest and accrual test.

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
SEC EDGAR companyfacts API              yfinance (daily close prices)
      │   rate-limited, cached, resumable    │   cached, one series per ticker
      ▼                                      ▼
data/raw/edgar/CIK*.json            data/raw/prices/{ticker}.parquet
      │   flatten + concept map              │
      ▼                                      ▼
data/staging/facts.parquet          data/staging/prices.parquet
      │   dbt                               │   dbt
      ▼                                      ▼
stg_facts ─── join concepts.csv       stg_prices
      ▼                                      │
fct_financials_pit                           │   nearest trading-day close
  bitemporal; restatement only                │   on/before each fiscal year end
  within a consistent tag lineage            │
      │◄─────────────────────────────────────┘
      ├──► fct_beneish_mscore      8 indices + composite, per company-year   ─┐
      ├──► fct_altman_zscore       5 factors + composite, per company-year   ─┤
      ├──► fct_piotroski_fscore    9 binary signals + composite, per company-year ─┤
      ├──► fct_accrual_returns     TATA vs. 12-month forward return (Sloan test)   │
      └──► fct_financials_asof ──► fct_scores_asof   "as of a past date" case backtest
                                                                                   │
   fct_dashboard  ◄────────── denormalised, one wide row per company-year  ◄──────┘
      │   export_dashboard.py
      ▼
   data/exports/dashboard.csv  ──►  Power BI Desktop / Tableau Public
                              └───►  dashboard/index.html @ localhost:8000
                                    (plain CSV; no key, no driver, no account)
```

`dbt/seeds/concepts.csv` is a generated artefact (`make seeds` /
`python -m redflag.export_seeds`), never hand-edited — `redflag/concepts.py`
is the single source of truth for concept metadata (sign convention,
restatement eligibility), so dbt and Python can never quietly disagree about it.

`data/universe/sp500.csv` is likewise generated (`python -m redflag.fetch_sp500`,
from Wikipedia's S&P 500 constituent table), not hand-maintained.
`redflag.universe.load_universe("full")` unions it with the case-study
companies — see [Scaling to the S&P 500](#scaling-to-the-sp-500).

## Stack

Python 3.11+ · DuckDB · dbt-core + dbt-duckdb · pandas · httpx · yfinance · Power BI / Tableau Public

Verified working on Python 3.14 / Windows.

---

## Quickstart

```bash
make install
export SEC_USER_AGENT="Your Name your@email.com"   # SEC requires a contact
make all          # ingest -> ingest-prices -> seeds -> dbt run -> dbt test -> pytest
                  # UNIVERSE=pilot by default; UNIVERSE=full for the S&P 500
                  # (needs data/universe/sp500.csv — see make seeds-sp500 below)
```

`make fetch-sp500` fetches the S&P 500 constituent list once; after that,
`make all UNIVERSE=full` ingests and scores the full universe. Budget real
time for this — EDGAR is rate-limited and price history is fetched one
ticker at a time (~500 companies takes several minutes for each).

`make sloan-test` prints the [Sloan accrual anomaly](#the-sloan-1996-accrual-forward-return-test)
report after `make all` has built `fct_accrual_returns`.

`make dashboard` writes `data/exports/dashboard.csv` — the flat file the
[Power BI / Tableau dashboard](#phase-5-dashboard) reads. No API key, no
database driver, no account: it's a plain CSV you open with "Get Data >
Text/CSV". `make dashboard-web` does the same export and also serves a
[local browser dashboard](#the-local-browser-dashboard) at `localhost:8000`.

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

## Beneish M-Score

`fct_beneish_mscore` computes the classic 8-variable model, one row per
company-fiscal-year:

```
M = -4.84 + 0.920·DSRI + 0.528·GMI + 0.404·AQI + 0.892·SGI
           + 0.115·DEPI - 0.172·SGAI + 4.679·TATA - 0.327·LVGI
```

M > **-1.78** is Beneish's published cutoff for "resembles a known earnings
manipulator" — a screening threshold from a statistical model fit to past
cases, not a verdict on any individual company. Every input uses each fiscal
year's own `is_first_report` value (see [Data model](#data-model)); `m_score`
is left `null` — never zero-filled — when any of the 8 inputs can't be
computed, with `missing_inputs` naming which ones, so a gap in coverage is
visible rather than silently read as a clean score.

### Two more bugs, found by building on top of the fixed layer

Wiring real ratios on top of `fct_financials_pit` immediately surfaced two
problems Phase 1b's diagnostics hadn't touched — both caught by checking
*why* case-study companies weren't scoring, rather than accepting "58%
coverage" as just how the data is:

1. **Balance-sheet concepts were silently absent from the whole marts table.**
   `fct_financials_pit` filtered on `period_type = 'annual'`, but balance-sheet
   items (`total_assets`, `receivables`, ...) are XBRL *instant* facts — a
   snapshot with no duration — so they classify as `period_type = 'instant'`
   and never matched. `total_assets`, `receivables`, `current_assets` and five
   other concepts had **zero** rows in the marts table before this was caught.
   Fixed by including `period_type in ('annual', 'instant')` — the form filter
   already restricts to 10-K/20-F, so any instant fact surviving it is, by
   construction, a fiscal-year-end balance-sheet snapshot.

2. **Split cost-of-revenue tags were silently understating COGS.** Six of the
   23 pilot companies (GE, Honeywell, Lockheed, Cisco, Adobe, Bausch) tag cost
   of revenue as **two simultaneous line items** in the same filing —
   `CostOfGoodsSold` (products) + `CostOfServices` (services) — not as
   alternatives. The original dedup logic picked the higher-priority tag and
   silently discarded the other, understating COGS (and overstating gross
   margin) for every one of those companies. Concepts now carry a `combine`
   field (`"best"` picks one tag, the original and still-correct behaviour for
   most concepts; `"sum"` adds every distinct tag present) — `cogs` is the
   first concept to need `"sum"`. GE's FY2012 COGS moved from 56.8B (products
   only) to the correct 74.3B (products + services), a real value-correctness
   fix, not just a coverage one — locked in as `assert_ge_cogs_sum_fix.sql`.

Coverage after both fixes: **196 of 354 pilot company-years (55%)** get a
complete 8-input score. The gaps left are mostly genuine — Wells Fargo (a
bank) never scores because COGS isn't a meaningful concept for a financial
institution, which is correct behaviour, not a pipeline gap.

### Validation against the case-study companies

| Company | What happened | What the M-Score shows |
|---|---|---|
| **Under Armour** | SEC charged the company over pulling Q4 2015 sales into Q3 to hit growth targets ("channel stuffing") | **A genuine hit.** FY2015 is UAA's single most elevated M-Score across all 14 scored years (-0.997, closest to the -1.78 cutoff of its whole 2011–2021 history), driven by an elevated DSRI (1.21 — receivables growing faster than sales, the textbook channel-stuffing signature) and a strongly positive TATA (earnings well ahead of cash generation). Locked in as `assert_uaa_2015_mscore_elevated.sql` |
| **Kraft Heinz** | SEC action over procurement/vendor-rebate accounting that misstated COGS, disclosed 2019, covering roughly 2015–2018 | **Inconclusive.** Only FY2017–2019 score (2013–2016 are missing inputs) — the earliest, most relevant years are exactly the ones this pilot can't evaluate |
| **Bausch Health (ex-Valeant)** | Philidor specialty-pharmacy scandal broke October 2015 | **No clear hit on the event year** (FY2015 scores -2.50, unremarkable). The two years that *do* score highest (2011, 2013) predate the scandal and more plausibly reflect Valeant's aggressive acquisition-driven growth (DSRI and SGI both run elevated across most of 2011–2017) than the drug-pricing/channel issue specifically — which was a pricing scheme, not a classic accrual-manipulation pattern in the sense Beneish's model targets |
| **GE** | 2018–19 insurance-reserve restatement | **Unscoreable.** Only 1 of 16 years has a complete score, and it isn't a relevant one. Not a fraud-detection miss — a coverage gap |
| **Wells Fargo, Hertz, Luckin Coffee** | Sales-practice scandal / historical restatement / fabricated revenue | **Unscoreable** for structural reasons (bank; thin cost-line tagging; 20-F filer with far sparser XBRL — 10 concepts vs. a typical 20+ for a domestic 10-K filer) |
| **Baseline** (AAPL, MSFT, JNJ, PG, KO, WMT, HD, TXN) | No known issues | All cluster tightly between **-2.11 and -2.72** for their most recent scored year — comfortably below the cutoff, consistent, unremarkable. A screen that flagged any of these would itself be the finding |

Read honestly: **one clean, mechanistically-explained hit (UAA), two coverage
casualties (GE, and the earliest years of KHC), one legitimate near-miss with
a plausible alternative explanation (BHC), and a clean baseline.** That's a
believable result for a screening tool, not an oversold one — Beneish's model
is tuned specifically for *accrual-based earnings manipulation*; Wells Fargo's
sales-practice fraud and Valeant's pricing scheme were never going to be
in its detection scope, and it isn't claimed otherwise.

---

## Altman Z-Score

`fct_altman_zscore` computes the original 1968 model, one row per
company-fiscal-year:

```
Z = 1.2·X1 + 1.4·X2 + 3.3·X3 + 0.6·X4 + 1.0·X5
  X1 = working capital / total assets       X4 = market value of equity / total liabilities
  X2 = retained earnings / total assets     X5 = revenue / total assets
  X3 = EBIT / total assets (≈ operating income)
```

Z > **2.99** "safe", **1.81–2.99** "grey", < **1.81** "distress" — again,
statistical zones, not a verdict. Unlike M-Score, this measures **bankruptcy
risk**, not earnings manipulation — worth being precise about, because it
changes what counts as a "hit" below.

### A second data source, and the correctness trap it came with

X4 is the only input anywhere in this project that isn't from a company's own
filings — it needs what the *market* thought the company was worth. That
meant standing up a second source (`redflag/sources/prices.py`, via
`yfinance`; stooq.com's free CSV endpoint, the original plan, now sits behind
a JavaScript proof-of-work bot check and isn't fetchable without a browser).

Getting this right had a real trap: Yahoo's price history is always
split-adjusted to *today's* share count — there's no way to ask it for the
raw, as-traded price from before a since-occurred split. Pairing that
adjusted price with `fct_financials_pit.value` for shares (the
as-originally-filed count, Phase 1b's convention) would multiply an adjusted
price by an unadjusted share count and misstate market cap by whatever split
happened since — up to 28x for Apple, which split 7:1 in 2014 and 4:1 in 2020.
Fixed by pairing the price with `latest_reported_value` instead (also fully
split-adjusted, same basis) — the one input in this model that deliberately
breaks from the "always use what was first known" convention, because here
getting the *scale* right matters more than point-in-time purity. Documented
prominently in the model SQL, not left implicit.

### A second bug: an admitted fraud that scored as maximally "safe"

Luckin Coffee's first Z-Score came back at **55.9** — X4 alone was 95x. Real
Z-scores run single digits to the high teens; anything in that range is a
scale bug, not a genuinely exceptional company, so this got investigated
before being trusted. Cause: Luckin's XBRL reports ~1.6 billion total
ordinary shares, but the LKNCY ADR does not trade 1 ADR = 1 ordinary share —
ADR programs commonly bundle several ordinary shares into one ADR, and
multiplying total ordinary shares by the ADR price overstates market cap by
whatever that ratio is. The correct ratio could be looked up and applied, but
guessing it and silently "correcting" the number would just swap one
unverified figure for another. Fixed by structurally excluding every 20-F
filer from X4 (this pilot only has one, Luckin, but the exclusion is general,
not Luckin-specific) — `x1`, `x2`, `x3`, `x5` still compute normally, only the
price-dependent term and the composite are withheld. Locked in as
`assert_20f_filers_excluded_from_zscore.sql`; the underlying scale check that
would catch a *different* company hitting a similar issue in a future
universe expansion is `assert_zscore_within_plausible_range.sql`.

Coverage after both fixes: **246 of 367 pilot company-years (67%)**.

### Validation against the case-study companies

| Company | What happened | What the Z-Score shows |
|---|---|---|
| **Bausch Health (ex-Valeant)** | Decade of acquisition-fuelled growth on heavy debt | **A genuine, sustained finding.** "Distress" zone (0.06–1.9) for essentially its entire 16-year history — not a single-event hit, but Z-Score correctly reading chronic balance-sheet fragility from a real, well-documented leverage story |
| **Kraft Heinz** | 2015 3G Capital/Heinz merger financed with heavy debt; 2019 stock collapse and goodwill writedown | **Also a genuine, sustained finding.** "Distress" zone (0.5–1.5) across all 11 scored years — consistent with Kraft Heinz's well-known post-merger over-leverage, not tied to one accounting event |
| **Under Armour** | SEC channel-stuffing charge | **Correctly no dramatic signal** ("safe"/"grey" throughout, no break around 2015–2016) — and that's the right outcome, not a miss. Pulling sales forward is an earnings-quality problem, not a solvency one; UAA was never balance-sheet distressed, so a bankruptcy-risk model has nothing to catch here. This is what M-Score is for |
| **Luckin Coffee** | Fabricated ~$310M in revenue, disclosed 2020 | **Unscoreable** — see the ADR fix above. X1, X2, X3, X5 are all visible if you want to look, but the composite is deliberately withheld rather than guessed at |
| **Hertz** | Actually filed Chapter 11, May 2020 — the one case-study company where Z-Score's actual design purpose applies most directly | **Zero coverage, 0 of 13 years.** The most relevant validation case in the whole pilot for this specific model, and this pilot cannot evaluate it — `current_assets`/`operating_income` are missing across nearly its whole history. Stated plainly rather than glossed over: this is a real gap, not a subtle one |
| **GE** | 2018–19 restatement | **Zero coverage.** Same story as M-Score — `current_assets` wasn't tagged before FY2019 for a company that didn't present a classified balance sheet |
| **Baseline** (AAPL, MSFT, JNJ, PG, KO, WMT, HD, TXN) | No known issues | All comfortably "safe" (4.9–10.3) for their most recent scored year. Sanity-checked against reality too: AAPL's FY2025 market cap computes to $3.83 trillion — matches the real number |

Read honestly: **two genuine, sustained findings that track real leverage
stories (BHC, KHC), one correctly quiet result that would be a false
expectation to score as a "miss" (UAA), one structurally unscoreable case with
a well-understood cause (LKNCY), and one real disappointment (Hertz — the
single best validation case for *this specific model*, unscoreable due to
coverage gaps).** Z-Score and M-Score are complementary, not redundant: BHC
and KHC score unremarkably on M-Score but are the clearest hits on Z-Score,
while UAA is the reverse — exactly what should happen when one model measures
earnings quality and the other measures solvency.

---

## Piotroski F-Score

`fct_piotroski_fscore` computes the original 2000 model, one row per
company-fiscal-year: nine binary signals, 1 point each, summed 0–9.

```
Profitability (4):  positive ROA · positive CFO · ROA improved YoY · CFO > net income (earnings quality)
Leverage/liquidity (3):  leverage ratio decreased · current ratio improved · no new shares issued
Efficiency (2):  gross margin improved YoY · asset turnover improved YoY
```

F ≥ **8** "strong", F ≤ **2** "weak", otherwise "neutral". Where M-Score
hunts for manipulation and Z-Score measures solvency risk, F-Score is this
project's only **positive** signal — fundamental strength, not another way to
find trouble. All nine signals compare each year's own `is_first_report`
value against the prior year's, on the same basis both times — unlike
Z-Score's X4, nothing here is multiplied by a price, so there's no
split-adjustment mismatch to guard against.

### Two more bugs — this time in the shared point-in-time layer itself

Building the third model on the same foundation the first two already used
still turned up two more real bugs, both structural rather than
concept-specific — meaning they'd silently affected M-Score and Z-Score too,
just not enough to surface as obviously as they did here (F-Score's
year-over-year self-join fans out visibly on any duplicate row; the other two
models' pivots are less exposed to it).

1. **A supplementary quarterly-data table leaked into the annual snapshot
   logic.** Kraft Heinz's 10-Ks include a quarterly-data table (a common
   post-merger recast disclosure — KHC merged with Heinz in 2015), and
   Phase 1b's assumption that *"any instant fact surviving the 10-K/20-F form
   filter is a genuine fiscal-year-end snapshot"* turned out to be wrong for
   this filer: instant facts dated at quarter-ends (2017-04-01, 2017-07-01,
   ...) were being accepted as annual balance-sheet snapshots, producing up
   to **16 spurious rows for one real fiscal year**. Fixed by anchoring
   instant facts to a `period_end` that a genuine annual *duration* fact
   (already correctly restricted to 350–380-day periods) also reports for the
   same filing — a quarter-end date with no matching annual duration fact in
   the same accession is now excluded. Locked in as
   `assert_khc_quarterly_snapshots_excluded.sql`.

2. **52/53-week fiscal calendars collided two different years under one
   label.** `period_fiscal_year` was derived as `year(period_end)` — fine for
   a company whose fiscal year ends near mid-year or on Dec 31, wrong for one
   whose 52/53-week fiscal year end lands in the *first few days of January*.
   JNJ's fiscal 2011 ends **2012-01-01**; naive `year()` labelled that
   `period_fiscal_year = 2012`, colliding with the *real* fiscal 2012
   (ending 2012-12-30) under the same label. Both models that self-join
   year-over-year for signals — which is all three scores — then fanned
   that single mislabelled row out into duplicates. Fixed narrowly: only a
   `period_end` in the first ten days of January shifts back a year;
   everything else (including genuinely non-calendar fiscal years like
   Microsoft's June 30 or Walmart's Jan 31) is left untouched — shifting
   broadly (e.g. "back 6 months") was considered and rejected, because it
   would have *mis*labelled those correctly-dated fiscal years instead of
   fixing anything. Locked in as
   `assert_unique_first_report_per_fiscal_year.sql`, which checks the
   invariant directly (exactly one `is_first_report` row per company-concept-
   fiscal-year) rather than re-deriving the specific dates, so it would catch
   a *different* fiscal-calendar collision too, not just this one.

Coverage: **240 of 354 pilot company-years (68%)**.

### Validation against the case-study companies

| Company | What happened | What the F-Score shows |
|---|---|---|
| **Under Armour** | SEC channel-stuffing charge | **A genuine, independent hit.** FY2015 scores **1 of 9** ("weak") — UAA's single lowest score across its entire 12-year scored history (every other year: 3–8). Only `positive_roa` passes; `positive_cfo` and `earnings_quality` (CFO > net income) both fail — nominally profitable (consistent with hitting a growth target) while cash generation and every other fundamental signal deteriorated simultaneously. This is a *different* model catching the *same* year M-Score flagged, through entirely different signals — not the same finding twice |
| **Kraft Heinz** | SEC procurement/COGS action, disclosed 2019 | No signal on the relevant years (2016–2019 sit in the 5–6 "neutral" band, unremarkable). FY2023 scores 8 ("strong") — ordinary post-recovery business, not tied to the scandal |
| **Bausch Health** | Chronic post-acquisition leverage (the Z-Score finding) | Mostly 3–7 "neutral" across its scored years — F-Score doesn't independently flag BHC, which is coherent: F-Score's leverage signal only checks the *direction* of change (did leverage go up or down this year), not the *level* — a company can be chronically over-leveraged (Z-Score's finding) while still occasionally deleveraging year-over-year (F-Score's signal). The two models are answering different questions, not disagreeing |
| **GE, Hertz, Wells Fargo, Luckin Coffee** | Various | **Unscoreable**, for the same structural reasons documented under M-Score and Z-Score (unclassified balance sheets pre-restructuring; no COGS concept for a bank; thin 20-F tagging) |
| **Baseline** (AAPL, MSFT, JNJ, PG, KO, WMT, HD, TXN) | No known issues | 4–8, mostly "neutral" with AAPL at "strong" (8) — a healthy, unremarkable spread. Not every signal fires every year for a fine company, which is exactly the point: UAA's 2015 collapse to a single passing signal is the outlier, not the norm |

Read honestly: **one strong, independently-corroborating hit (UAA), one
appropriately quiet result with a coherent explanation for why (BHC — a
leverage-direction signal doesn't contradict a leverage-level finding), one
non-finding on the scandal years (KHC), and the same coverage-gap companies as
before.** The most valuable result here isn't the UAA hit in isolation — it's
that M-Score and F-Score, built independently on different signal
combinations, converge on the same company-year without having been tuned to
agree.

---

## Scaling to the S&P 500

`python -m redflag.fetch_sp500` pulls the current constituent list from
Wikipedia (S&P's own membership data isn't free; this is the same source most
free finance tooling uses) and writes it to `data/universe/sp500.csv`.
`universe.load_universe("full")` unions it with the case-study companies —
kept as an explicit union, not assumed to be a subset, because most of the
case studies (LKNCY, NKLA, BHC, HTZ) have been removed from or never held
index membership, generally *because of* the events that make them useful
test cases. Losing them silently when scaling up would have defeated the
point of validating against them in the first place.

Deliberately done *after* the metric layer was built and validated on the
pilot, not before: debugging a wrong ratio against 8 well-understood
companies is tractable; debugging it against 500 unknowns is not. That
ordering paid off immediately — every bug below was caught within minutes of
the first full-scale build, against tests and diagnostic habits already
established on the pilot.

**Result: 501 companies, 7,554 company-years**, built and tested in under 3
seconds end to end (DuckDB, even with 1.87M raw XBRL facts). Coverage
naturally dropped from the pilot's hand-picked blue-chip mix — the S&P 500
pulls in far more banks, insurers and REITs, which these ratio-based models
are structurally not suited to (see [Known limitations](#known-limitations)):
M-Score 42% (was 55%), Z-Score 65% (was 67%), F-Score 47% (was 68%).

### Three more bugs, found in the first hour at scale

1. **Dual-class tickers silently lost.** `EdgarSource.list_companies()`
   deduplicated SEC's ticker map by CIK before any ticker matching happened —
   fine for the pilot (no dual-class companies in it), wrong in general: a
   company with two share classes (Alphabet: GOOG/GOOGL, Fox: FOX/FOXA,
   Brown-Forman: BF-A/BF-B, ...) shares one CIK across multiple tickers, and
   the dedup kept only whichever ticker happened to appear first, silently
   failing any lookup for the other. Confirmed against the actual failure:
   BF-B, FOX, GOOG, NWS and MAA all reported "not found in SEC map" despite
   resolving to perfectly valid CIKs with real XBRL data. Fixed by moving the
   dedup to *after* ticker matching (in `redflag.ingest`) instead of before
   (in `list_companies()`) — recovered 2 companies (499 → 501; MAA and NWS's
   CIKs were already covered by other tickers pointing at the same entity).

2. **A fiscal-year change fanned out into duplicate rows.** `period_fiscal_year`
   assumes one real annual period per company per calendar-year label — true
   for 497 of 501 companies, false for one clean, well-documented case: L3Harris
   (LHX) reported on Harris Corp's legacy June 30 fiscal year through FY2019,
   then filed a genuine ~6-month transition report ending 2020-01-03 to move
   onto a calendar-year basis. Both dates are real, meaningful annual periods;
   both naturally land under `period_fiscal_year = 2019`. No date-arithmetic
   rule can correctly split a genuine fiscal-year change into two labels —
   there's no calendar-based way to know in advance that "2019" should
   sometimes mean two different periods for one company. Fixed by picking one
   canonical `period_end` per company-year (whichever date the *most other
   concepts* for that company-year also report against) rather than trying to
   guess the "right" one — the losing period stays fully present in the table,
   it just doesn't feed the scoring models for that label. A much smaller,
   ~1-day version of the identical symptom (a probable XBRL context-date
   authoring inconsistency between filings, not a second real period) also
   showed up for Deere and a handful of others; the same fix resolves both.
   Locked in as `assert_lhx_fiscal_year_change_resolved.sql` for the specific
   real case and `assert_unique_first_report_per_fiscal_year.sql` for the
   general invariant.

3. **The plausible-range sanity tests stopped being reliable bug detectors.**
   Both of the defensive range checks added during M-Score/Z-Score
   development (the same kind of test that caught LKNCY's ADR bug) fired at
   S&P 500 scale — but investigation showed neither was a bug. Carnival and
   Norwegian Cruise Line both hit extreme M-Scores (-21.7, +98.2) because
   several Beneish indices are year-over-year ratios-of-ratios, and both
   companies had a real, near-zero-revenue year during COVID-era shutdowns in
   the comparison window — a genuine business collapse, not bad data. NVIDIA,
   Palantir, Texas Pacific Land, Intuitive Surgical and Monolithic Power all
   hit extreme Z-Scores (50-195) — checked against their actual balance
   sheets, not assumed: their total-liabilities-to-total-assets ratios are
   entirely ordinary (10-25%), so this isn't a near-zero-denominator
   artifact the way LKNCY's ADR mismatch was. It's simply that these are some
   of the market's most richly-valued companies relative to a normal
   liability base — exactly the asset-light/high-valuation weakness already
   documented for Z-Score, just far more extreme than Adobe's ~17 in the
   pilot. Both tests' bounds were widened with the specific verified cases
   documented in the test files, on the explicit understanding that a fixed
   numeric bound is a weaker bug signal now than it was at pilot scale —
   PLTR's legitimate 195 exceeds LKNCY's original buggy 55.9. A future
   failure here needs the same checking-not-assuming treatment these three
   companies got, not an automatic "must be a bug" or an automatic "just
   widen the bound again."

---

## Phase 4: formal validation

Two things "point-in-time" had never actually been tested end to end: whether
a query run *on a specific past date* would have shown what this project
claims it would, and whether the accrual signal underlying M-Score's TATA
term (and F-Score's earnings-quality signal) predicts anything about future
stock returns the way the accounting literature says it should. Both needed
new machinery, not just new SQL on the existing marts.

### The "as of" case backtest

Everything before this phase answers "what does fiscal year Y's own first
filing say" — `is_first_report` is a fixed property of a row, not a function
of when you're asking. A genuine backtest needs a query date: `fct_financials_asof`
adds it, cross-joining the point-in-time base data against
`dbt/seeds/backtest_events.csv` (one `as_of_date` per case-study company,
shortly after their last pre-scandal 10-K/20-F was filed) and keeping only
fiscal years whose filing was `first_filed_date <= as_of_date`.
`fct_scores_asof` recomputes M-Score/Z-Score/F-Score on top of it.

That model duplicates the three production marts' formulas rather than
sharing macros with them — a deliberate tradeoff, not an oversight. Refactoring
three already-validated, heavily-tested models to share code with a new,
unproven one risked exactly the kind of regression this project has spent
three phases hunting. Instead, `backtest_events.csv` includes a `full_history`
control row per company (`as_of_date` 2099-01-01 — every filing seen so far),
and `assert_asof_reconciles_with_production.sql` checks that duplicate scores
production exactly, company-year for company-year. It passes. If the two
copies ever drift, that test catches it before a wrong "as of" number does.

| Company | As-of date (shortly after the relevant 10-K/20-F) | Public disclosure | Lead time | What the screen showed, using only what was filed by then |
|---|---|---|---|---|
| **Under Armour** | 2016-02-25 (FY2015 10-K) | 2019-11-03 (WSJ/Bloomberg report federal probe) | **3.7 years** | **A genuine hit, on both models, using only the as-filed FY2015 10-K.** M-Score -0.997 (FY2015's single most elevated year across its whole scored history) and F-Score 1/9 ("weak", FY2015's single lowest year) — both already computable in February 2016, more than three and a half years before the public knew to look, and over five years before the May 2021 SEC settlement |
| **Kraft Heinz** | 2018-02-19 (FY2017 10-K) | 2019-02-21 (SEC subpoena + $15.4B writedown disclosed) | 1.0 year | Partial. Only FY2015's Z-Score is computable that early (0.853, "distress") — coverage this early in KHC's panel is thin, same structural gap already documented in [Z-Score](#altman-z-score). M-Score and F-Score are unscoreable at this as-of date |
| **Bausch Health** | 2015-02-28 (FY2014 10-K) | 2015-10-15 (Philidor scandal first reported) | 7.5 months | **No dramatic flag**, consistent with the production finding. M-Score -2.513 (unremarkable), F-Score 7/9 ("neutral-to-strong"). Z-Score 1.912 ("grey", borderline) — a mild signal, not a spike, consistent with chronic leverage rather than a 2014-specific event |
| **GE** | 2017-02-27 (FY2016 10-K, the restated-OCF year) | 2019-08-15 (Markopolos "bigger fraud than Enron" report) | 2.5 years | Unscoreable on all three models, even 2.5 years out — confirms the coverage gap is structural (missing `current_assets` pre-FY2019), not a timing artifact |
| **Hertz** | 2020-02-28 (FY2019 10-K) | 2020-05-22 (Chapter 11 filed) | 3 months | Unscoreable — zero Z-Score coverage right up to three months before the bankruptcy filing itself, the single most relevant test in this whole project. A real, honestly-reported gap, not a near-miss |
| **Wells Fargo** | 2016-02-27 (FY2015 10-K) | 2016-09-08 (CFPB/OCC settlement) | 6.5 months | Unscoreable — no COGS concept for a bank, same structural limitation as the production marts |
| **Luckin Coffee** | 2020-04-05 (3 days after disclosure) | 2020-04-02 (fraud disclosed) | n/a | **Zero rows.** FY2019's 20-F wasn't filed until 2021-06-30 — fourteen months *after* the fraud was already public. This is a different failure mode than GE/HTZ/WFC's coverage gaps: there was no filing for the screen to evaluate yet, at any lead time, because the fraud broke faster than the annual-report cadence this whole project depends on |

Read honestly: **one clean, mechanistically independent double-hit years
ahead of the public record (UAA), one partial early signal limited by early-panel
coverage (KHC), one correctly quiet result (BHC), and four cases —
GE, Hertz, Wells Fargo, Luckin Coffee — where the "as of" test doesn't add a
new finding so much as prove the existing coverage gaps aren't timing
artifacts that a longer lead time would have fixed.** UAA is the case that
actually validates the whole premise of this project: the red flag was sitting
in as-filed data years before anyone but the company itself and the SEC's
eventual investigators had reason to look.

### The Sloan (1996) accrual forward-return test

Sloan's finding: firms with high accruals (earnings running well ahead of
cash flow) subsequently earn *lower* stock returns than low-accrual firms,
because the market doesn't fully price the lower persistence of the accrual
component of earnings. `fct_accrual_returns` reuses TATA — already computed
and validated as one of Beneish M-Score's 8 indices — paired with each
company-year's forward 12-month return, entered on the first trading day
**on or after** the 10-K's `first_filed_date` (not `period_end`, and never
before it — the position can't open before the information that motivates it
existed) and exited 12 months later, both nearest-trading-day joins with a
10-day tolerance. Companies are sorted into accrual quintiles *within* each
fiscal year (cross-sectional, standard methodology — comparing a 2010 accrual
level against a 2022 one without conditioning on the year would just measure
which years had better markets). `src/redflag/sloan_test.py`
(`make sloan-test`) runs the portfolio sort and a Welch t-test on the
Q1-minus-Q5 hedge return.

12,951 company-years across 16 fiscal years have both a computable TATA and a
priced 12-month forward return:

| Quintile (1=lowest accruals, 5=highest) | n | mean TATA | mean return | median return |
|---|---|---|---|---|
| 1 | 2,596 | -0.114 | 23.02% | 16.14% |
| 2 | 2,592 | -0.056 | 14.44% | 12.35% |
| 3 | 2,590 | -0.037 | 12.82% | 10.28% |
| 4 | 2,587 | -0.020 | 13.60% | 11.61% |
| 5 | 2,586 | 0.020 | 14.58% | 10.97% |

Hedge return (Q1 minus Q5), means: **+8.44%**, Welch t = 7.01 (p < 0.0001).
Hedge return, medians: **+5.18%**.

Read honestly, not just headline: the sign is right and the mean-based hedge
return is statistically decisive, but it is **not** a clean monotonic Sloan
effect — checked, not assumed, the same way the plausible-range test outliers
were checked in [Scaling to the S&P 500](#scaling-to-the-sp-500). Quintiles
2 through 5 sit within about two points of each other; nearly the entire
effect is Q1 running far above the rest. Q1's top names by forward return are
AMD (FY2015), Tesla (FY2012, FY2019), AppLovin (FY2022-23), Palantir (FY2023)
and CrowdStrike (FY2019-20) — hyper-growth names whose deeply negative TATA
reflects heavy stock-based comp and R&D outrunning reported earnings, not the
conservative-accounting story Sloan's original manufacturing-era sample was
built on, and several of them happened to be among the market's best-performing
stocks of the decade. The median-based hedge return (+5.18%, versus +8.44% for
the mean) is the more honest read of the typical company in each quintile: a
real, positive, directionally-Sloan-consistent gap between Q1 and Q5, several
times smaller than the mean makes it look, and driven by the whole distribution
shifting down from Q1 to Q3 rather than a smooth decline all the way to Q5.

---

## Phase 5: dashboard

The screen is only useful if you can look at it. Phases 1–4 leave everything
queryable from SQL and validated by tests, but "run this dbt model and write a
DuckDB query" is not a way to *explore* 7,554 company-years. Phase 5 adds a
Power BI screener (with a Tableau Public mirror) and a local browser dashboard,
all sitting on top of a single denormalised export.

### No API key, no connection, no account

Worth stating plainly because it's a common and reasonable worry: **nothing in
this dashboard connects to Claude, to any API, or to any authenticated
service, and there is no key to obtain anywhere.** Power BI and Tableau here
are pure visualisers — they read one flat file off your disk and draw charts
from it. The entire hand-off is:

```
make build       # dbt builds fct_dashboard inside the DuckDB warehouse
make dashboard   # export_dashboard.py writes data/exports/dashboard.csv
                 # → open that CSV in Power BI Desktop / Tableau Public
```

In Power BI: **Get Data → Text/CSV → pick `dashboard.csv`**. In Tableau:
**Connect → Text File**. No connection string, no ODBC driver, no login. (The
tools *can* connect to DuckDB directly via ODBC — that's the road not taken
here, because it would couple the dashboard to a driver install and this
machine's file path, against the reproducibility bias in
[Why point-in-time](#why-point-in-time). A CSV opens anywhere.)

`data/exports/` is git-ignored — the CSV is a build artefact regenerated from
the warehouse, never committed, same rule as `data/staging`. Publishing to
Tableau *Public* uploads the CSV to Tableau's cloud; that's a manual step the
dashboard author takes, not something the repo does for you.

### The local browser dashboard

For anyone who doesn't have Power BI or Tableau installed, `dashboard/index.html`
is a second, self-contained way to look at the same export — a static page
(vanilla JS, no framework, no build step, no CDN dependency) with a
sortable/filterable screener table and four charts (M-Score, Z-Score and
F-Score distributions, plus average red flags by sector).

```
make dashboard-web    # exports dashboard.csv, then serves the repo at :8000
                       # open http://localhost:8000/dashboard/
```

This is `python -m http.server`, not a framework or a backend — the page's
only network call is a same-origin `fetch()` of `../data/exports/dashboard.csv`.
That fetch is *why* a server is needed at all: browsers block `fetch()` of
local files opened directly as `file://`, so double-clicking `index.html`
won't work — `make dashboard-web` (or any static file server rooted at the
repo) is required. Nothing here talks to Claude, an API, or the internet;
`localhost:8000` never leaves your machine. Stop the server with Ctrl+C.

### One table, built once, not three joined at render time

`fct_dashboard` is one wide row per (company, fiscal year): the three composite
scores, their standard-threshold flags, sector, case-study annotation, and a
`red_flag_count`, all in one place. It does **not** recompute anything — each
score is pulled as-is from the already-validated
[M-Score](#beneish-m-score) / [Z-Score](#altman-z-score) /
[F-Score](#piotroski-f-score) marts, so there is no way for the dashboard layer
to disagree with them. Denormalising here rather than joining three fact tables
inside the BI tool keeps the visual layer simple and puts the join somewhere
dbt-tested.

Two details that matter for how you read it:

- The grain is a **full outer join** across the three scoring marts, not an
  inner join. A 20-F filer with no `market_value_of_equity` has no Z-Score some
  years (see [Z-Score](#altman-z-score)); that company-year still appears, with
  `z_score` null, rather than vanishing along with its M-Score and F-Score.
- `red_flag_count` is **null-tolerant**: it counts only the models that actually
  produced a score, and `models_scored` tells you how many that was. A
  company-year flagged by the one model that could score it reads as "1 of 1",
  not diluted against two models that had no data. `assert_dashboard_flag_counts_consistent.sql`
  enforces `0 ≤ red_flag_count ≤ models_scored ≤ 3`.

The columns in `dashboard.csv`:

| Column | Meaning |
|---|---|
| `ticker`, `company_name`, `gics_sector` | Identity + sector (sector is S&P-500-only; null for delisted case studies like LKNCY/HTZ) |
| `is_case_study`, `case_study_note` | Whether this is a known-outcome test company, and why |
| `period_fiscal_year`, `period_end` | The fiscal year, derived from the period end (not the filing year) |
| `m_score`, `z_score`, `z_zone`, `f_score`, `f_band` | The three composite scores as computed in their own marts |
| `m_score_flag`, `z_score_flag`, `f_score_flag` | Booleans at the published thresholds (below), null when that model couldn't score the year |
| `red_flag_count`, `models_scored` | How many models flagged / how many produced a score |

### Build spec (what to put on the canvas)

The dashboard is authored by hand in the desktop app — `.pbix`/`.twb` files
aren't a text format that can be generated from the repo. This is the intended
layout; every field named below is a column in `dashboard.csv`.

| View | Type | Fields | Notes |
|---|---|---|---|
| **Screener** | Sortable table | rows: `ticker`, `period_fiscal_year`; values: `m_score`, `z_score`, `f_score`, `red_flag_count` | Conditional-format the flag columns red when `*_flag = true`; default sort `red_flag_count` desc, then `period_fiscal_year` desc. This is the workhorse view. |
| **Sector risk** | Heatmap / matrix | rows: `gics_sector`; columns: `period_fiscal_year`; colour: avg `red_flag_count` (or % where `red_flag_count > 0`) | Shows which sectors light up in which years. Exclude null sector or bucket it as "Non-index". |
| **Case-study spotlight** | Line / scatter | filter: `is_case_study = true`; x: `period_fiscal_year`; y: `m_score` (or a small-multiple of all three); tooltip: `case_study_note` | Overlay each name's disclosure year (from the [Phase 4 table](#the-as-of-case-backtest)) to show the score moving *before* the public event — this is the headline story. |
| **Distribution** | Histogram | one per score: `m_score`, `z_score`, `f_score`; a slicer on `period_fiscal_year` | Draw the threshold as a reference line so a viewer sees where any given company sits relative to the cut. |

Threshold legend (the same published, static cuts documented in each mart's
header — a flag is a *screen*, not a verdict):

- **Beneish M-Score** — `m_score_flag = true` when M > **−1.78** (higher =
  more manipulation-like).
- **Altman Z-Score** — `z_score_flag = true` in the **distress** zone, Z < 1.81
  (`z_zone` also carries `grey` 1.81–2.99 and `safe` > 2.99).
- **Piotroski F-Score** — `f_score_flag = true` in the **weak** band, F ≤ 2
  (`f_band` also carries `neutral` and `strong` ≥ 8).

Read honestly: a red flag here means "worth a closer look", nothing more. The
[case backtest](#the-as-of-case-backtest) is the honest guide to what these
flags do and don't catch — Under Armour lit up years early; GE, Hertz and
Wells Fargo sit in real, documented coverage gaps and would show blanks on this
dashboard, not warnings. The dashboard makes the screen explorable; it does not
make it more certain than the validation says it is.

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
- **M-Score is not well-suited to banks/insurers.** COGS isn't a meaningful
  concept for a financial institution, so GMI — and therefore the composite —
  is structurally unscoreable for them (Wells Fargo in this pilot). Correct
  behaviour, not a gap to fix.
- **M-Score only detects accrual-based earnings manipulation**, by design —
  it was never going to catch a sales-practices scandal (Wells Fargo) or a
  drug-pricing scheme (Valeant/Bausch), and isn't claimed to.
- **Company-year coverage: pilot vs. the full S&P 500 universe.** M-Score 55%
  → 42%, Z-Score 67% → 65%, F-Score 68% → 47% (see
  [Scaling to the S&P 500](#scaling-to-the-sp-500)). The pilot was hand-picked
  toward traditional, well-tagged blue chips; the S&P 500 includes far more
  banks, insurers and REITs these ratio-based models don't fit well. Some real
  filers also simply stop tagging a granular concept (e.g. SG&A as its own
  line) in later years, which isn't mechanically recoverable from missing data.
- **Hertz has zero scored Z-Score years**, in either universe — the single
  most relevant validation case available, given it actually filed for
  bankruptcy in 2020. `current_assets` and `operating_income` are missing
  across nearly its whole history.
- **A fixed numeric bound is a weaker bug-detection signal at S&P 500 scale
  than it was at pilot scale.** The plausible-range dbt tests (originally
  written to catch exactly the kind of scale bug LKNCY's ADR mismatch was)
  had to be widened after real companies — NVIDIA, Palantir, Texas Pacific
  Land — legitimately exceeded LKNCY's own buggy value. See
  [Scaling to the S&P 500](#scaling-to-the-sp-500) for the specific
  companies checked before the bounds were touched.
- **Z-Score isn't reliable for asset-light/richly-valued companies.** Altman's
  original model assumes a manufacturing-style balance sheet; Adobe hits ~17
  in this pilot (the model's normal range tops out around 3), not because it's
  financially exceptional but because its total assets are small relative to
  its market cap. Not wrong, exactly, but not comparable across sectors either.
- **Z-Score's market-value term (X4) is structurally unavailable for foreign
  private issuers** (20-F filers, e.g. Luckin Coffee) — see
  [Z-Score](#altman-z-score) for why an ADR doesn't reliably convert to a
  per-ordinary-share market cap without a verified ADR ratio this project
  doesn't currently source.
- **68% company-year coverage on F-Score**, same structural gaps as the other
  two models (banks, GE/Hertz's unclassified balance sheets, Luckin's thin
  20-F tagging).
- **F-Score's leverage signal checks direction, not level.** A chronically
  over-leveraged company (Bausch Health) can still score a passing leverage
  signal in a year it deleverages even slightly — that's a feature of what
  the signal is designed to measure, not a bug, but it means F-Score and
  Z-Score can legitimately disagree on the same company without either being
  wrong.
- **Two more real bugs were found building F-Score**, in shared
  infrastructure (`fct_financials_pit`/`stg_facts`) that M-Score and Z-Score
  were already quietly relying on — see [F-Score](#piotroski-f-score). Worth
  naming as a pattern, not just a one-off: each new model built on this
  foundation has found at least one real bug the previous ones didn't
  surface, simply because a self-join or a new concept combination exercises
  the data differently. There is no strong reason to assume the foundation is
  now bug-free rather than just less obviously buggy.

## Roadmap

- [x] Phase 1 — ingestion, staging, point-in-time fact table
- [x] Phase 1b — fix tag/sign/units contamination above
- [x] Phase 3a — Beneish M-Score, validated against case studies
- [x] Phase 3b — Altman Z-Score, validated against case studies (adds a second data source: market prices)
- [x] Phase 3c — Piotroski F-Score, validated against case studies
- [x] Phase 2 — expand to the S&P 500 (501 companies, 7,554 company-years; done after the metric layer was proven, not before)
- [x] Phase 4 — formal validation: point-in-time case backtest (UAA flagged 3.7 years early) + Sloan (1996) accrual forward-return test
- [x] Phase 5 — dashboard: `fct_dashboard` mart + `dashboard.csv` export + a local browser dashboard (`make dashboard-web`) + build spec for a Power BI screener / Tableau Public mirror (plain CSV, no API key)
- [ ] Phase 6 — findings write-up

---

## A note on interpretation

Everything here screens for **aggressive or unusual accounting**, not fraud. Most
flagged companies are entirely fine, and a screen that surfaces 15% of the market
is a filter for further review — not a verdict on any company.
