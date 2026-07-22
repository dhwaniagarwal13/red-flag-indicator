"""Sloan (1996)-style accrual anomaly test, run against fct_accrual_returns.

    python -m redflag.sloan_test

Sloan's finding: firms with high accruals (earnings running well ahead of
cash flow) subsequently earn *lower* stock returns than firms with low
accruals, because the market doesn't fully price the lower persistence of the
accrual component of earnings. This isn't a bug hunt like the rest of this
project's phases — it's a statistical claim about the whole panel, so unlike
M-Score/Z-Score/F-Score's case-study validations, there's no single "right
answer" to lock in as a regression test. The point is to run the test
honestly and report what the data says, including if it doesn't replicate
cleanly on this specific 500-company, ~15-year sample — a null result here is
not a data-quality bug the way an M-Score of -1.78 landing on the wrong
company would be.

Portfolio sort is cross-sectional *within* each fiscal year (accrual_quintile
in fct_accrual_returns.sql is computed that way), matching standard
accrual-anomaly methodology — comparing an accrual level in 2010 against one
in 2022 without conditioning on the year would just be measuring which years
had better markets, not which accrual levels did.

The hedge portfolio (Q1 lowest accruals minus Q5 highest) is tested with a
Welch t-test — unequal-variance by construction, since nothing here assumes
the five quintiles have equal return variance. p-values use the normal
approximation to the t-distribution rather than pulling in scipy for it: with
several thousand company-years per quintile, the degrees of freedom are far
into the range where the two are indistinguishable to any decimal place that
matters here.
"""

from __future__ import annotations

import math
import sys
from dataclasses import dataclass

import duckdb
import pandas as pd

from redflag import config


@dataclass
class QuintileStats:
    quintile: int
    n: int
    mean_tata: float
    mean_return: float
    median_return: float
    std_return: float


@dataclass
class SloanResult:
    quintiles: list[QuintileStats]
    hedge_return: float  # mean(Q1) - mean(Q5)
    t_stat: float
    p_value: float
    n_years: int


def _normal_two_sided_p(t_stat: float) -> float:
    # 2 * (1 - Phi(|t|)), Phi via the standard-library error function.
    return 2 * (1 - 0.5 * (1 + math.erf(abs(t_stat) / math.sqrt(2))))


def load_panel() -> pd.DataFrame:
    con = duckdb.connect(str(config.WAREHOUSE), read_only=True)
    try:
        return con.execute(
            """
            select period_fiscal_year, ticker, tata, fwd_return_12m, accrual_quintile
            from main_marts.fct_accrual_returns
            where accrual_quintile is not null
            """
        ).fetchdf()
    finally:
        con.close()


def run(panel: pd.DataFrame | None = None) -> SloanResult:
    if panel is None:
        panel = load_panel()

    quintiles = []
    for q in sorted(panel["accrual_quintile"].unique()):
        sub = panel.loc[panel["accrual_quintile"] == q, "fwd_return_12m"]
        tata_sub = panel.loc[panel["accrual_quintile"] == q, "tata"]
        quintiles.append(
            QuintileStats(
                quintile=int(q),
                n=len(sub),
                mean_tata=float(tata_sub.mean()),
                mean_return=float(sub.mean()),
                median_return=float(sub.median()),
                std_return=float(sub.std(ddof=1)),
            )
        )

    q1 = next(q for q in quintiles if q.quintile == 1)
    q5 = next(q for q in quintiles if q.quintile == max(qq.quintile for qq in quintiles))

    hedge_return = q1.mean_return - q5.mean_return
    se = math.sqrt((q1.std_return**2) / q1.n + (q5.std_return**2) / q5.n)
    t_stat = hedge_return / se if se > 0 else float("nan")
    p_value = _normal_two_sided_p(t_stat)

    return SloanResult(
        quintiles=quintiles,
        hedge_return=hedge_return,
        t_stat=t_stat,
        p_value=p_value,
        n_years=panel["period_fiscal_year"].nunique(),
    )


def report(result: SloanResult) -> str:
    lines = [
        "Sloan (1996) accrual anomaly test",
        f"({result.n_years} fiscal years, cross-sectional quintiles by TATA)",
        "",
        f"{'Q':>2}  {'n':>6}  {'mean TATA':>10}  {'mean return':>12}  "
        f"{'median return':>14}  {'std':>8}",
    ]
    for q in result.quintiles:
        lines.append(
            f"{q.quintile:>2}  {q.n:>6}  {q.mean_tata:>10.4f}  "
            f"{q.mean_return:>12.4%}  {q.median_return:>14.4%}  {q.std_return:>8.4f}"
        )
    q1, q5 = result.quintiles[0], result.quintiles[-1]
    median_hedge = q1.median_return - q5.median_return
    lines += [
        "",
        f"Hedge return, means   (Q1 minus Q5): {result.hedge_return:.4%}"
        f"   Welch t={result.t_stat:.3f}  p={result.p_value:.4f}",
        f"Hedge return, medians (Q1 minus Q5): {median_hedge:.4%}",
        "",
        "Sloan's prediction: hedge_return > 0 (low accruals subsequently"
        " outperform). Report both mean and median because the mean is"
        " sensitive to a handful of extreme growth-stock outliers landing in"
        " Q1 (heavy stock-based comp / R&D can produce very negative TATA"
        " independent of earnings quality) -- the median is the more honest"
        " read of the typical company in each quintile.",
    ]
    return "\n".join(lines)


def main() -> int:
    result = run()
    print(report(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
