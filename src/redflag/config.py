"""Central paths and settings.

Everything that varies by machine or by run lives here, so no script needs a
hardcoded absolute path.
"""

from __future__ import annotations

import os
from pathlib import Path

# Repo root = three levels up from src/redflag/config.py
ROOT = Path(__file__).resolve().parents[2]

DATA = ROOT / "data"
RAW = DATA / "raw"  # bronze: exactly what the API returned
STAGING = DATA / "staging"  # silver: flattened Parquet
WAREHOUSE = DATA / "redflag.duckdb"

for _d in (RAW, STAGING):
    _d.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# SEC EDGAR
# ---------------------------------------------------------------------------
# The SEC requires a User-Agent identifying who is making the request, with a
# contact address. Requests without one are refused. Override via env var when
# someone else runs this repo.
SEC_USER_AGENT = os.environ.get(
    "SEC_USER_AGENT", "redflag-screener dhwaniagarwal1395@gmail.com"
)

# SEC's published fair-access ceiling is 10 requests/second. We stay under it.
SEC_MAX_RPS = float(os.environ.get("SEC_MAX_RPS", "6"))

SEC_TICKER_MAP_URL = "https://www.sec.gov/files/company_tickers.json"
SEC_COMPANYFACTS_URL = "https://data.sec.gov/api/xbrl/companyfacts/CIK{cik}.json"
SEC_SUBMISSIONS_URL = "https://data.sec.gov/submissions/CIK{cik}.json"

# ---------------------------------------------------------------------------
# Analysis window
# ---------------------------------------------------------------------------
# XBRL structured data on EDGAR only becomes reliably complete from ~2010.
# Anything earlier is sparse and inconsistently tagged, so we don't pretend.
MIN_FISCAL_YEAR = int(os.environ.get("MIN_FISCAL_YEAR", "2010"))
