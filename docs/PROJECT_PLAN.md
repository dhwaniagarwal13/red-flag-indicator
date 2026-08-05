# Project plan

A condensed, decision-focused view of how this project was actually built. The
[README](../README.md) has the full technical narrative for every phase; this doc
pulls out the sequencing logic, the risk-management pattern, and the decision log —
the parts most relevant to talking about this as a project, not just as code.

## Objective

Build a point-in-time forensic-accounting screener over SEC XBRL filings that
reconstructs what was knowable on any past date, and validate it against real,
known accounting-quality events (Under Armour, Kraft Heinz, Bausch Health, GE,
Hertz, Wells Fargo, Luckin Coffee) rather than trusting the models on faith.

## Build order and why

The build follows a strict validate-small-before-scaling-up pattern, repeated at
every level:

1. **Phase 1 — ingestion and the point-in-time fact table.** Nothing else can be
   trusted until "what was knowable on date X" is correctly reconstructed.
2. **Phase 1b — fix what Phase 1 got wrong**, before building anything on top of it.
   Three real artifacts (a tag switch misread as a value change, a filing typo, a
   legitimate stock-split restatement) were diagnosed and fixed, each locked in as
   a regression test, *before* a single scoring model was built on the fact table.
3. **Phase 3a/3b/3c — one model at a time, each validated against 8 case-study
   companies with known outcomes**, not against the full universe. A 23-company
   pilot is small enough to hand-check; 501 companies aren't. Each new model
   surfaced bugs the previous ones hadn't — not because the earlier models were
   sloppier, but because a different self-join or concept combination exercises
   shared infrastructure differently. That pattern held three times in a row and is
   named explicitly in the README's limitations section rather than treated as
   resolved.
4. **Phase 2 — scale to the S&P 500, deliberately last, not first.** "Debugging a
   wrong ratio against 8 well-understood companies is tractable; debugging it
   against 500 unknowns is not." Scaling before the metric layer was proven would
   have made every bug from phases 1–3 far harder to isolate. Scaling after it
   still surfaced three more real bugs in the first hour — sequencing didn't
   prevent every problem, but it kept each one attributable.
5. **Phase 4 — formal validation**, only once there was something to validate: an
   "as of" case backtest and a Sloan (1996) accrual/forward-return test, run
   against the already-proven scoring layer rather than against unvalidated numbers.
6. **Phase 5 — the dashboard**, deliberately last. A visualization layer over
   unvalidated numbers just makes wrong numbers easier to look at.

## Risk management: the pattern behind every bug fix

Every bug in this project follows the same triage, documented in the README rather
than fixed silently:

- **Investigate before trusting an extreme number.** Luckin Coffee's Z-Score came
  back at 55.9 — an order of magnitude outside a plausible range — and was traced
  to an ADR-ratio mismatch rather than accepted as "a genuinely exceptional company."
- **Investigate before trusting a suppressed one, too.** When the same plausible-range
  test fired again at S&P 500 scale (Carnival, NVIDIA, Palantir), the check that it
  wasn't a repeat of the Luckin bug was real — verified against actual balance sheets
  and actual COVID-era revenue collapses — before the test bounds were widened rather
  than the finding being dismissed.
- **Lock every real fix in as a regression test**, named for the case that exposed it
  (`assert_htz_interest_expense_fix.sql`, `assert_ge_cogs_sum_fix.sql`,
  `assert_lhx_fiscal_year_change_resolved.sql`, ...), so a future change can't
  silently reintroduce something already paid for once.
- **State plainly when something that looks like a bug isn't one.** GE's FY2016
  operating cash flow swing looked identical in shape to the Hertz tag-switch
  artifact, but turned out to be GE's real, publicly documented restatement — and the
  README says so explicitly rather than quietly suppressing a real number to match
  the pattern of a fixed bug.

## Decision log

- **`combine: "best"` vs. `"sum"` on concept metadata**, not a global rule. Most
  concepts pick the higher-priority XBRL tag; COGS needed to *sum* two simultaneous
  tags (products + services) instead, after GE's COGS was found to be silently
  understated by the "best" logic. The fix is scoped to the concepts that actually
  need it, not applied blanket.
- **Pairing prices with `latest_reported_value`, not first-reported**, for Z-Score's
  market-value term — the one deliberate exception to this project's own point-in-time
  convention, because Yahoo's price history is always split-adjusted to today's share
  count, and pairing it with an unadjusted share count would misstate market cap by
  up to 28x. Documented prominently in the model SQL so the exception doesn't read as
  an oversight.
- **A flat CSV export over a live database connection for the dashboard.** Power BI
  and Tableau *can* connect to DuckDB directly, but that couples the dashboard to a
  driver install and one machine's file path — against the reproducibility bias
  everywhere else in this project. A CSV opens anywhere.
- **The "as of" backtest duplicates production formulas rather than sharing macros
  with them.** Refactoring three already-validated models to share code with a new,
  unproven one risked the exact kind of regression this project spent three phases
  hunting. A reconciliation test (`assert_asof_reconciles_with_production.sql`)
  checks the two copies agree, so drift is caught rather than assumed away.

## What's explicitly out of scope

- Separating legitimate restatements (P&G's divestiture accounting) from suspicious
  ones needs judgment a mechanical fix can't supply — named as Phase 3+ work, not
  attempted here.
- M-Score is not claimed to catch what it was never built for — Wells Fargo's
  sales-practices fraud and Bausch's drug-pricing scheme were outside its detection
  scope from the start, and the README says so rather than treating the misses as
  failures of the model.
- Coverage gaps (GE, Hertz, Wells Fargo on most models) are reported as real,
  structural limitations — not patched over with an estimate.

## If this continued

The clearest next step is already named in the README: cross-referencing 8-K
divestiture disclosures to separate reclassification from revision, which would
directly address the P&G false-positive pattern. Everything else documented as a
limitation is either a structural data-coverage gap (not fixable without a different
data source) or a deliberate scope boundary (not a gap at all).
