"""SEC EDGAR XBRL source adapter.

Uses the ``companyfacts`` API, which returns every XBRL fact a company has ever
filed, each stamped with the accession number and filing date of the document it
appeared in. That filing date is what makes this source worth the trouble: it
lets us reconstruct what was knowable on any past date, instead of quietly
using restated figures that nobody had at the time.

Politeness: the SEC publishes a 10 req/s fair-access ceiling and requires a
User-Agent identifying the requester. We throttle below the ceiling and cache
every response to disk, so a re-run costs nothing.
"""

from __future__ import annotations

import json
import logging
import time
from pathlib import Path

import httpx
import pandas as pd

from redflag import config
from redflag.concepts import TAG_LOOKUP

log = logging.getLogger(__name__)


class RateLimiter:
    """Simple blocking throttle: never more than ``rps`` calls per second."""

    def __init__(self, rps: float) -> None:
        self._min_interval = 1.0 / rps
        self._last = 0.0

    def wait(self) -> None:
        elapsed = time.monotonic() - self._last
        if elapsed < self._min_interval:
            time.sleep(self._min_interval - elapsed)
        self._last = time.monotonic()


class EdgarSource:
    name = "edgar"

    def __init__(self, cache_dir: Path | None = None) -> None:
        self.cache_dir = cache_dir or (config.RAW / "edgar")
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        self._limiter = RateLimiter(config.SEC_MAX_RPS)
        self._client = httpx.Client(
            headers={
                "User-Agent": config.SEC_USER_AGENT,
                "Accept-Encoding": "gzip, deflate",
            },
            timeout=30.0,
            follow_redirects=True,
        )

    # ------------------------------------------------------------------ http
    def _get_json(self, url: str, *, retries: int = 3) -> dict | None:
        for attempt in range(retries):
            self._limiter.wait()
            try:
                r = self._client.get(url)
            except httpx.RequestError as exc:
                log.warning("network error on %s (%s), retrying", url, exc)
                time.sleep(2**attempt)
                continue

            if r.status_code == 200:
                return r.json()
            if r.status_code == 404:
                return None  # company genuinely has no XBRL facts
            if r.status_code == 429:
                back_off = 2 ** (attempt + 2)
                log.warning("rate limited by SEC, backing off %ss", back_off)
                time.sleep(back_off)
                continue
            log.warning("HTTP %s on %s", r.status_code, url)
            time.sleep(2**attempt)
        return None

    # -------------------------------------------------------------- universe
    def list_companies(self) -> pd.DataFrame:
        cache = self.cache_dir / "_company_tickers.json"
        if cache.exists():
            payload = json.loads(cache.read_text(encoding="utf-8"))
        else:
            payload = self._get_json(config.SEC_TICKER_MAP_URL)
            if payload is None:
                raise RuntimeError("could not fetch SEC ticker map")
            cache.write_text(json.dumps(payload), encoding="utf-8")

        rows = [
            {
                "entity_id": str(v["cik_str"]).zfill(10),
                "ticker": v["ticker"],
                "company_name": v["title"],
            }
            for v in payload.values()
        ]
        return pd.DataFrame(rows).drop_duplicates("entity_id").reset_index(drop=True)

    # ------------------------------------------------------------------ facts
    def _cache_path(self, entity_id: str) -> Path:
        return self.cache_dir / f"CIK{entity_id}.json"

    def fetch_facts(self, entity_id: str, *, refresh: bool = False) -> dict | None:
        """Fetch one company's facts, using the on-disk cache unless refreshing."""
        path = self._cache_path(entity_id)
        if path.exists() and not refresh:
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                log.warning("corrupt cache for %s, refetching", entity_id)

        payload = self._get_json(config.SEC_COMPANYFACTS_URL.format(cik=entity_id))
        if payload is None:
            return None
        path.write_text(json.dumps(payload), encoding="utf-8")
        return payload

    # --------------------------------------------------------------- flatten
    def flatten_facts(self, entity_id: str, payload: dict) -> pd.DataFrame:
        """Unpack nested companyfacts JSON into one row per reported fact."""
        facts = payload.get("facts", {})
        rows: list[dict] = []

        for taxonomy, concepts in facts.items():
            if taxonomy != "us-gaap":
                continue  # dei holds entity metadata, not financials
            for tag, body in concepts.items():
                mapped = TAG_LOOKUP.get(tag)
                if mapped is None:
                    continue  # not a concept we model
                concept, priority = mapped

                for unit, observations in body.get("units", {}).items():
                    for obs in observations:
                        fy = obs.get("fy")
                        if fy is None or fy < config.MIN_FISCAL_YEAR:
                            continue
                        rows.append(
                            {
                                "entity_id": entity_id,
                                "concept": concept,
                                "source_tag": tag,
                                "tag_priority": priority,
                                "unit": unit,
                                "period_start": obs.get("start"),
                                "period_end": obs.get("end"),
                                "fiscal_year": fy,
                                "fiscal_period": obs.get("fp"),
                                "form": obs.get("form"),
                                "filed_date": obs.get("filed"),
                                "accession": obs.get("accn"),
                                "frame": obs.get("frame"),
                                "value": obs.get("val"),
                            }
                        )

        if not rows:
            return pd.DataFrame(columns=_FLAT_COLUMNS)

        df = pd.DataFrame(rows)
        df["period_start"] = pd.to_datetime(df["period_start"], errors="coerce")
        df["period_end"] = pd.to_datetime(df["period_end"], errors="coerce")
        df["filed_date"] = pd.to_datetime(df["filed_date"], errors="coerce")
        return df

    def close(self) -> None:
        self._client.close()

    def __enter__(self) -> EdgarSource:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()


_FLAT_COLUMNS = [
    "entity_id",
    "concept",
    "source_tag",
    "tag_priority",
    "unit",
    "period_start",
    "period_end",
    "fiscal_year",
    "fiscal_period",
    "form",
    "filed_date",
    "accession",
    "frame",
    "value",
]
