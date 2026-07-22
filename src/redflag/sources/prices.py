"""Daily close price source, via yfinance.

Only needed for one thing so far: Altman Z-Score's market-value-of-equity term
(X4), which the accounting data alone can't provide — it needs what the
market thought the company was worth, not just its own books.

Correctness note that matters more than it looks: Yahoo's price history is
always split-adjusted to the *current* share count — there is no way to ask
it for the raw, as-traded-that-day price once a stock has split since. That
means a price pulled for, say, 2013 already has 2014's and 2020's splits baked
in. Pairing that price with `fct_financials_pit.value` for shares_diluted
(the as-originally-filed count for that year, unadjusted — the Phase 1b
convention) would multiply an adjusted price by an unadjusted share count and
silently misstate market cap by the split ratio (up to 28x for Apple, which
split 7:1 in 2014 and 4:1 in 2020). The consumer of this data must pair it
with `latest_reported_value` instead, which is on the same current-basis
footing. See fct_altman_zscore.sql.

Also deliberately uses the "Close" column, not "Adj Close": "Adj Close"
additionally bakes in a hypothetical dividend-reinvestment adjustment, which
has nothing to do with what the market actually valued the shares at on a
given date and would understate historical market cap.
"""

from __future__ import annotations

import logging
import time
from pathlib import Path

import pandas as pd
import yfinance as yf

from redflag import config

log = logging.getLogger(__name__)

# Politeness delay between tickers. yfinance/Yahoo doesn't publish a rate
# limit; this is a conservative, unhurried default, not a measured one.
REQUEST_DELAY_SECONDS = 1.0


class PriceSource:
    name = "yfinance"

    def __init__(self, cache_dir: Path | None = None) -> None:
        self.cache_dir = cache_dir or (config.RAW / "prices")
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    def _cache_path(self, ticker: str) -> Path:
        return self.cache_dir / f"{ticker}.parquet"

    def fetch_history(self, ticker: str, *, refresh: bool = False) -> pd.DataFrame | None:
        """Full daily close-price history for one ticker, or None if unavailable.

        Columns: ticker, date, close. Cached to disk — a re-run costs nothing.
        """
        path = self._cache_path(ticker)
        if path.exists() and not refresh:
            return pd.read_parquet(path)

        time.sleep(REQUEST_DELAY_SECONDS)
        try:
            hist = yf.Ticker(ticker).history(period="max", auto_adjust=False)
        except Exception as exc:  # yfinance raises assorted exception types
            log.warning("price fetch failed for %s: %s", ticker, exc)
            return None

        if hist.empty:
            log.warning("no price history for %s", ticker)
            return None

        df = (
            hist[["Close"]]
            .rename(columns={"Close": "close"})
            .reset_index()
            .rename(columns={"Date": "date"})
        )
        df["date"] = pd.to_datetime(df["date"]).dt.tz_localize(None)
        df["ticker"] = ticker
        df = df[["ticker", "date", "close"]]
        df.to_parquet(path, index=False)
        return df
