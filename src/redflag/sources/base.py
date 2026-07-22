"""Source adapter interface.

Keeping ingestion behind this protocol is what makes a second universe (Indian
listed companies via NSE, say) an additive change rather than a rewrite. Any
source must be able to answer two questions: which companies exist, and what
facts has a given company reported.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

import pandas as pd


@runtime_checkable
class FinancialSource(Protocol):
    """A provider of as-filed company financial facts."""

    name: str

    def list_companies(self) -> pd.DataFrame:
        """Return the investable universe.

        Columns: ``entity_id``, ``ticker``, ``company_name``.
        ``entity_id`` is the source's stable key (CIK for EDGAR).
        """
        ...

    def fetch_facts(self, entity_id: str) -> dict | None:
        """Return the raw, unmodified payload for one company, or None if absent."""
        ...

    def flatten_facts(self, entity_id: str, payload: dict) -> pd.DataFrame:
        """Normalise a raw payload into the canonical long fact format.

        Columns: ``entity_id``, ``concept``, ``source_tag``, ``tag_priority``,
        ``unit``, ``period_start``, ``period_end``, ``fiscal_year``,
        ``fiscal_period``, ``form``, ``filed_date``, ``accession``, ``value``.

        One row per *reported fact*, not per period — the same fiscal year
        restated in three later filings yields three rows. That redundancy is
        the entire point: it is what makes point-in-time reconstruction possible.
        """
        ...
