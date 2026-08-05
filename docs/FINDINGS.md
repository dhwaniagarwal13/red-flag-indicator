# Findings — Red-Flag Screener

Phase 6 of the [project roadmap](../README.md#roadmap). This is the
standalone summary of what the screener actually found, after five phases of
build-out and validation. Full methodology, bug diagnoses, and section-by-
section detail live in the [README](../README.md); this document is the
"what did we learn" answer, not a repeat of the "how was it built" one.

## Headline result

Under Armour's FY2015 10-K — filed **2016-02-25** — independently triggers
both the Beneish M-Score (-0.997, the single most manipulation-like year in
UAA's scored history) and the Piotroski F-Score (1/9, "weak", UAA's single
weakest year). The federal channel-stuffing investigation didn't become
public until **2019-11-03**. Querying the screen *as of* a date shortly
after the FY2015 filing — using only data that existed at that time,
enforced by a point-in-time architecture, not hindsight — reproduces that
same double-hit **3.7 years before the public record**, and more than five
years before the May 2021 SEC settlement.

That single case is the project's strongest evidence that the core premise
works: the signal was sitting in as-filed data years before anyone outside
the company and the SEC's eventual investigators had reason to look.

## What the three models found, at scale

Run across 501 S&P 500 companies / 7,554 company-years (not just the
23-company pilot they were built and validated on):

| Model | What it flagged | Coverage |
|---|---|---|
| **Beneish M-Score** | Manipulation-consistent scores for Under Armour's FY2015 (validated case) | 42% of company-years |
| **Altman Z-Score** | Kraft Heinz and Bausch Health sitting in chronic "distress"/"grey" territory — consistent with their real, documented post-merger leverage, not a false alarm | 65% of company-years |
| **Piotroski F-Score** | Independently confirms the UAA FY2015 hit found by M-Score | 47% of company-years |

Coverage is lower than the pilot precisely because the S&P 500 includes far
more banks, insurers, and REITs than these ratio-based models fit well —
see [Known limitations](../README.md#known-limitations). That's a
structural property of the models, not a bug: M-Score, for example, is
*correctly* unscoreable for Wells Fargo, because COGS isn't a meaningful
concept for a bank.

## The point-in-time case backtest (Phase 4)

Seven known-outcome companies, each queried "as of" a date shortly after
their last pre-scandal 10-K/20-F — using only what was filed by that date:

| Company | Lead time before public disclosure | Result |
|---|---|---|
| **Under Armour** | **3.7 years** | Genuine hit, both models, FY2015 10-K alone |
| **Kraft Heinz** | 1.0 year | Partial — only one early year scoreable, thin panel coverage |
| **Bausch Health** | 7.5 months | Correctly quiet (mild Z-Score signal, no spike) — consistent with chronic leverage, not a 2014-specific event |
| **GE** | 2.5 years | Unscoreable on all three models — confirms a structural coverage gap, not a timing artifact |
| **Hertz** | 3 months | Unscoreable — zero Z-Score coverage right up to 3 months before Chapter 11 |
| **Wells Fargo** | 6.5 months | Unscoreable — no COGS concept for a bank |
| **Luckin Coffee** | n/a | Zero rows — the FY2019 20-F wasn't filed until 14 months *after* the fraud was already public |

Read honestly, this is **one clean hit, one partial signal, one correctly
quiet result, and four cases where the gap is a documented structural
limitation** (missing concepts, thin foreign-issuer tagging, or a filing
cadence too slow for a fraud that broke faster than the annual report).
None of the four "misses" are the model quietly failing — each is a named,
explained coverage gap that would show up as blank on the dashboard, not as
a false "clear."

## The Sloan (1996) accrual/forward-return test (Phase 4)

12,951 company-years sorted into accrual quintiles, cross-sectionally by
fiscal year, with a forward 12-month return entered on the trading day the
10-K was actually filed (never earlier):

| Quintile (1 = lowest accruals) | n | mean return | median return |
|---|---|---|---|
| 1 | 2,596 | 23.02% | 16.14% |
| 2 | 2,592 | 14.44% | 12.35% |
| 3 | 2,590 | 12.82% | 10.28% |
| 4 | 2,587 | 13.60% | 11.61% |
| 5 | 2,586 | 14.58% | 10.97% |

Hedge return (Q1 − Q5): **+8.44%** mean (Welch t = 7.01, p < 0.0001), **+5.18%**
median. The sign matches Sloan's original finding and the mean result is
statistically decisive — but it is **not** a clean monotonic effect.
Quintiles 2–5 sit within about two points of each other; nearly the whole
effect is Q1 running far above the rest, driven by hyper-growth names
(AMD, Tesla, AppLovin, Palantir, CrowdStrike) whose deeply negative accruals
reflect heavy stock-based comp and R&D outrunning reported earnings — the
opposite story from Sloan's manufacturing-era conservative-accounting
sample, and several of them happened to be among the decade's
best-performing stocks. The median hedge return (+5.18%, about 60% of the
mean) is the more honest read of the typical company in each quintile.

## What this project actually demonstrates

1. **The point-in-time architecture works as designed.** The "as of" backtest
   isn't just a claim — it's tested against a full-history control and
   reconciled company-year for company-year against production scores.
2. **One real, independently-corroborated early warning** (Under Armour),
   which is the specific claim a screener like this exists to make good on.
3. **Honest coverage gaps, not silent failures.** Every "miss" in the case
   backtest is a named structural limitation (bank accounting, foreign
   issuer tagging, filing cadence), not the model failing quietly on data it
   should have handled.
4. **A real but modest accrual-return relationship** — directionally
   consistent with 30 years of accounting literature, but concentrated in a
   handful of names rather than a clean monotonic quintile spread, and
   reported that way rather than rounded up to "confirmed."
5. **Bug-finding compounds with scale.** Three more real data bugs surfaced
   in the first hour of scaling from 23 to 501 companies, on top of the
   eight found building the three models — see
   [Scaling to the S&P 500](../README.md#scaling-to-the-sp-500). There's no
   strong reason to assume the foundation is bug-free now rather than just
   less obviously buggy.

## Interpretation

Every flag here means "worth a closer look," not "verdict." A screen that
flags roughly 15% of the market is a filter for further review. The honest
reading of this project's own results is that it earns its use of the word
"validated" for the specific things it was tested against — one clean
early-warning case, structurally explained gaps everywhere else it was
checked — and no further than that.
