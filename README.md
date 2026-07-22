# Red-Flag Screener

A point-in-time forensic-accounting screener over SEC XBRL filings. Ingests
as-filed financial statements, reconstructs what was knowable on any past date,
and ranks companies on the standard forensic metrics — Beneish M-Score, Altman
Z-Score, Piotroski F-Score, accrual quality, and Benford's-Law digit analysis.

**Status: Beneish M-Score and Altman Z-Score both live.** Ingestion, staging
and the point-in-time fact table run end to end on a 23-company pilot; the
restatement-detection artifacts found in Phase 1 are fixed and
regression-tested; M-Score shows a genuine hit on Under Armour's FY2015
channel-stuffing year; and Z-Score (now pulling in a second data source —
market prices) shows Kraft Heinz and Bausch Health sitting in chronic
"distress" territory, consistent with their real post-merger leverage.
Piotroski F-Score is next. See [Current findings](#current-findings) for the
restatement-layer results, [M-Score](#beneish-m-score) and
[Z-Score](#altman-z-score) for the scoring results.

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
      ├──► fct_beneish_mscore     8 indices + composite, per company-year
      └──► fct_altman_zscore      5 factors + composite, per company-year
                  ▼
          (next) fct_fscore → Power BI / Tableau Public
```

`dbt/seeds/concepts.csv` is a generated artefact (`make seeds` /
`python -m redflag.export_seeds`), never hand-edited — `redflag/concepts.py`
is the single source of truth for concept metadata (sign convention,
restatement eligibility), so dbt and Python can never quietly disagree about it.

## Stack

Python 3.11+ · DuckDB · dbt-core + dbt-duckdb · pandas · httpx · yfinance · Power BI / Tableau Public

Verified working on Python 3.14 / Windows.

---

## Quickstart

```bash
make install
export SEC_USER_AGENT="Your Name your@email.com"   # SEC requires a contact
make all          # ingest -> ingest-prices -> seeds -> dbt run -> dbt test -> pytest
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
- **55% company-year coverage on M-Score** even after fixing the two bugs
  found while building it (see [M-Score](#beneish-m-score)) — some real filers
  simply stop tagging a granular concept (e.g. SG&A as its own line) in later
  years, and that's not mechanically recoverable from missing data.
- **67% company-year coverage on Z-Score**, with one significant gap: Hertz
  — the single most relevant validation case in the pilot, given it actually
  filed for bankruptcy in 2020 — has zero scored years. `current_assets` and
  `operating_income` are missing across nearly its whole history.
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

## Roadmap

- [x] Phase 1 — ingestion, staging, point-in-time fact table
- [x] Phase 1b — fix tag/sign/units contamination above
- [x] Phase 3a — Beneish M-Score, validated against case studies
- [x] Phase 3b — Altman Z-Score, validated against case studies (adds a second data source: market prices)
- [ ] Phase 3c — Piotroski F-Score
- [ ] Phase 2 — expand to S&P 500 (deliberately after the metric layer is proven, not before)
- [ ] Phase 4 — formal validation: full case backtest + accrual forward-return test
- [ ] Phase 5 — Power BI screener + Tableau Public mirror
- [ ] Phase 6 — findings write-up

---

## A note on interpretation

Everything here screens for **aggressive or unusual accounting**, not fraud. Most
flagged companies are entirely fine, and a screen that surfaces 15% of the market
is a filter for further review — not a verdict on any company.
