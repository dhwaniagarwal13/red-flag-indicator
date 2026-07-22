"""Ingest raw filings and land them as Parquet.

    python -m redflag.ingest --universe sp500 --limit 30

Bronze (``data/raw/edgar/CIK*.json``) stays byte-identical to what the API
returned. Silver (``data/staging/facts.parquet``) is the flattened long table.
Re-runs reuse the disk cache, so this is cheap to repeat and safe to interrupt.
"""

from __future__ import annotations

import argparse
import logging
import sys
import time
from pathlib import Path

import pandas as pd

from redflag import config
from redflag.sources.edgar import EdgarSource
from redflag.universe import load_universe

log = logging.getLogger("redflag.ingest")


def ingest(universe: str, limit: int | None, refresh: bool) -> Path:
    tickers = load_universe(universe)
    if limit:
        tickers = tickers[:limit]

    with EdgarSource() as src:
        companies = src.list_companies()
        selected = companies[companies.ticker.isin(tickers)]
        # A universe should list one ticker per company, but list_companies()
        # is deliberately not deduplicated by entity_id (see its docstring —
        # dual-class shares share a CIK across tickers), so dedupe defensively
        # here instead: after matching, not before, so every requested ticker
        # still gets a chance to match its own row.
        selected = selected.drop_duplicates("entity_id").reset_index(drop=True)

        missing = sorted(set(tickers) - set(selected.ticker))
        if missing:
            log.warning("%d tickers not found in SEC map: %s", len(missing), missing[:10])

        log.info("ingesting %d companies", len(selected))
        frames: list[pd.DataFrame] = []
        failures: list[str] = []
        t0 = time.monotonic()

        for i, row in selected.iterrows():
            payload = src.fetch_facts(row.entity_id, refresh=refresh)
            if payload is None:
                failures.append(row.ticker)
                continue
            df = src.flatten_facts(row.entity_id, payload)
            if df.empty:
                failures.append(row.ticker)
                continue
            df["ticker"] = row.ticker
            df["company_name"] = row.company_name
            frames.append(df)

            if (i + 1) % 25 == 0:
                log.info("  %d/%d (%.0fs)", i + 1, len(selected), time.monotonic() - t0)

    if not frames:
        raise SystemExit("no facts ingested — check network and SEC_USER_AGENT")

    facts = pd.concat(frames, ignore_index=True)
    out = config.STAGING / "facts.parquet"
    facts.to_parquet(out, index=False)

    log.info(
        "wrote %s — %s facts, %d companies, %d failed (%s)",
        out.name,
        f"{len(facts):,}",
        facts.entity_id.nunique(),
        len(failures),
        ", ".join(failures[:5]) or "none",
    )
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--universe", default="pilot", help="universe name (see universe.py)")
    p.add_argument("--limit", type=int, default=None, help="cap company count")
    p.add_argument("--refresh", action="store_true", help="bypass the on-disk cache")
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
