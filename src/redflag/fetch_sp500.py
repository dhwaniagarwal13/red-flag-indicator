"""Fetch the current S&P 500 constituent list and write it as a universe CSV.

    python -m redflag.fetch_sp500

Writes data/universe/sp500.csv with a `ticker` column, consumable by
redflag.universe.load_universe("sp500"). Source: Wikipedia's "List of S&P 500
companies", the same source most free finance tooling uses for this — S&P's
own index membership data is not free.

Two things worth knowing about this list:

1. It's a snapshot of *today's* constituents, not a historical membership
   record. Combined with the survivorship bias already noted in the README
   (SEC's own ticker map only lists current registrants), a company that was
   in the S&P 500 during some past scandal but has since been removed
   (acquired, delisted, dropped from the index) will not appear here even if
   it's still a live SEC registrant. This is exactly why the `pilot`
   universe's case-study companies are kept as a separate, deliberately
   curated list rather than assumed to be a subset of `sp500`.

2. Wikipedia formats dual-class tickers with a dot (`BRK.B`, `BF.B`); SEC's
   ticker map uses a dash (`BRK-B`, `BF-B`). Normalised here so the ticker
   matches what redflag.sources.edgar.list_companies() expects.
"""

from __future__ import annotations

import io
import sys

import httpx
import pandas as pd

from redflag import config

WIKIPEDIA_URL = "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies"


def fetch() -> pd.DataFrame:
    # Wikipedia's bot policy blocks generic User-Agents (verified: a bare
    # "Mozilla/5.0" gets a 403); an identifying one with contact info works.
    resp = httpx.get(WIKIPEDIA_URL, headers={"User-Agent": config.SEC_USER_AGENT}, timeout=30)
    resp.raise_for_status()

    table = pd.read_html(io.StringIO(resp.text))[0]
    table = table.rename(columns={"Symbol": "ticker", "Security": "company_name"})
    table["ticker"] = table["ticker"].str.replace(".", "-", regex=False)
    return table[["ticker", "company_name", "GICS Sector"]].rename(
        columns={"GICS Sector": "gics_sector"}
    )


def main() -> int:
    df = fetch()
    out_dir = config.DATA / "universe"
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / "sp500.csv"
    df.to_csv(out, index=False)
    print(f"wrote {out} ({len(df)} constituents)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
