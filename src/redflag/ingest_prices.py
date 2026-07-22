"""Fetch price history and land it as Parquet.

    python -m redflag.ingest_prices --universe pilot

Only needed for Altman Z-Score's market-value-of-equity term. Separate from
redflag.ingest (which pulls EDGAR filings) because it's a different source
with a different cache and a different reason to re-run — prices update daily,
filings don't.
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

import pandas as pd

from redflag import config
from redflag.sources.prices import PriceSource
from redflag.universe import load_universe

log = logging.getLogger("redflag.ingest_prices")


def ingest(universe: str, limit: int | None, refresh: bool) -> Path:
    tickers = load_universe(universe)
    if limit:
        tickers = tickers[:limit]

    src = PriceSource()
    frames: list[pd.DataFrame] = []
    failures: list[str] = []

    for i, ticker in enumerate(tickers):
        df = src.fetch_history(ticker, refresh=refresh)
        if df is None or df.empty:
            failures.append(ticker)
            continue
        frames.append(df)
        if (i + 1) % 10 == 0:
            log.info("  %d/%d", i + 1, len(tickers))

    if not frames:
        raise SystemExit("no price history ingested")

    prices = pd.concat(frames, ignore_index=True)
    out = config.STAGING / "prices.parquet"
    prices.to_parquet(out, index=False)

    log.info(
        "wrote %s — %s rows, %d tickers, %d failed (%s)",
        out.name,
        f"{len(prices):,}",
        prices.ticker.nunique(),
        len(failures),
        ", ".join(failures) or "none",
    )
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--universe", default="pilot")
    p.add_argument("--limit", type=int, default=None)
    p.add_argument("--refresh", action="store_true")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s  %(levelname)-7s %(message)s",
        datefmt="%H:%M:%S",
    )
    ingest(args.universe, args.limit, args.refresh)
    return 0


if __name__ == "__main__":
    sys.exit(main())
