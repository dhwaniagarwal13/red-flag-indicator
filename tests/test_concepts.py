"""Tests for the concept metadata that Phase 1b's fixes depend on.

These exist because the fixes are only as good as the metadata driving them:
if a future edit to concepts.py silently re-merges a net and a gross tag under
one concept, or drops the sign convention that keeps expenses non-negative,
the dbt-level regression tests (dbt/tests/) would eventually catch the
symptom — but only after a full ingest + build cycle. These catch the cause
in milliseconds, with no network access required.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from redflag import concepts  # noqa: E402


def test_each_tag_maps_to_exactly_one_concept():
    seen: dict[str, str] = {}
    for concept in concepts.CONCEPTS:
        for tag in concept.tags:
            assert tag not in seen, (
                f"tag {tag!r} claimed by both {seen.get(tag)!r} and {concept.name!r} — "
                "a shared tag silently merges two concepts, which is exactly the "
                "class of bug Phase 1b fixed for interest_expense"
            )
            seen[tag] = concept.name


def test_interest_expense_and_net_interest_stay_separate():
    """Regression guard for the HTZ bug: gross expense and net interest are
    economically different figures and must never share a concept again."""
    gross = concepts.CONCEPT_BY_NAME["interest_expense"]
    net = concepts.CONCEPT_BY_NAME["interest_income_expense_net"]
    assert "InterestIncomeExpenseNet" not in gross.tags
    assert "InterestIncomeExpenseNet" in net.tags
    assert gross.sign_convention == "always_positive"
    assert net.sign_convention == "any"


def test_share_counts_excluded_from_restatement_scoring():
    """Regression guard for the AAPL/MRK bug: splits and scale typos are not
    accounting-quality signals."""
    assert concepts.CONCEPT_BY_NAME["shares_diluted"].restatement_eligible is False


def test_income_tax_expense_sign_not_normalised():
    """A tax benefit is a real negative value, not a tagging error — must not
    be forced positive."""
    assert concepts.CONCEPT_BY_NAME["income_tax_expense"].sign_convention == "any"


def test_required_concepts_are_always_positive_or_any_but_never_undefined():
    valid = {"any", "always_positive"}
    for concept in concepts.CONCEPTS:
        assert concept.sign_convention in valid, concept.name


def test_to_dataframe_matches_concept_count():
    df = concepts.to_dataframe()
    assert len(df) == len(concepts.CONCEPTS)
    assert set(df.columns) == {
        "concept",
        "kind",
        "statement",
        "required",
        "sign_convention",
        "restatement_eligible",
    }
    assert df["concept"].is_unique
