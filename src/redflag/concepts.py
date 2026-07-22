"""Canonical concept mapping for US-GAAP XBRL tags.

The problem this solves: two companies reporting the identical economic figure
often tag it differently. Apple reports revenue as
``RevenueFromContractWithCustomerExcludingAssessedTax``; an older filer may use
``SalesRevenueNet``; a third uses plain ``Revenues``. Any analysis that hardcodes
one tag silently loses whole companies.

So each canonical concept lists its acceptable tags **in priority order**. The
first tag present for a given company-period wins, and we record which tag was
used so coverage is auditable rather than assumed.

``kind`` matters for correctness:
  * ``duration`` — flow items (revenue, net income). The fact has start+end.
  * ``instant``  — stock items (assets, equity). The fact has end only.
Mixing them silently produces nonsense, so the flattener keys off this.

Two more fields exist because real XBRL data breaks in specific, recurring ways
(see Phase 1b diagnosis in the project README):

``sign_convention`` — most expense-type concepts are tagged as a positive
magnitude by convention, but a filer occasionally submits one as negative
(e.g. presented as a reduction). ``"always_positive"`` tells the staging layer
to normalise sign with ``abs()``. Left as ``"any"`` for concepts where the sign
is itself meaningful (``income_tax_expense`` is legitimately negative in a year
with a net tax *benefit* — normalising that away would delete real information).

``restatement_eligible`` — some concepts change value for reasons that have
nothing to do with accounting quality. Diluted share counts move on stock
splits (a healthy, disclosed, unrelated event) and are also unusually prone to
filer scale/unit typos. Both would contaminate a restatement-based risk score,
so such concepts are excluded from that particular use — while still being kept
in the fact table for anyone who wants them for other purposes.

``combine`` — the tag list for most concepts holds *alternatives*: a company
uses exactly one of them, so picking the first available (by priority) is
correct. A handful of concepts instead see genuine *components* tagged
side by side in the same filing: several companies (GE, Honeywell, Lockheed,
Cisco, Adobe, Bausch — six of twenty-three in this pilot) split cost of
revenue into `CostOfGoodsSold` (products) + `CostOfServices` (services) as two
simultaneous, additive line items rather than reporting one combined figure.
Treating that pair as alternatives and picking the higher-priority one — the
naive approach this project shipped with initially — silently discards the
services component and understates COGS. ``combine="sum"`` tells the staging
layer to add every distinct tag present in a filing instead of picking one;
``combine="best"`` (default) keeps the original pick-one behaviour for
concepts where that's actually correct (e.g. revenue: a company reporting
`Revenues` is not additionally reporting `SalesRevenueNet` for the same
period — those really are alternatives, never simultaneous components).
"""

from __future__ import annotations

from dataclasses import dataclass

import pandas as pd


@dataclass(frozen=True)
class Concept:
    name: str
    kind: str  # "duration" | "instant"
    tags: tuple[str, ...]
    statement: str
    required: bool = True  # if False, absence is expected for some filers
    sign_convention: str = "any"  # "any" | "always_positive"
    restatement_eligible: bool = True
    combine: str = "best"  # "best" | "sum"


CONCEPTS: tuple[Concept, ...] = (
    # ---------------------------------------------------------------- income
    Concept(
        "revenue",
        "duration",
        (
            "RevenueFromContractWithCustomerExcludingAssessedTax",
            "RevenueFromContractWithCustomerIncludingAssessedTax",
            "Revenues",
            "SalesRevenueNet",
            "SalesRevenueGoodsNet",
        ),
        "income_statement",
    ),
    Concept(
        # combine="sum": CostOfGoodsSold and CostOfServices are components
        # (products vs. services), tagged side by side, not alternatives —
        # see the module docstring. CostOfGoodsAndServicesSold and
        # CostOfRevenue are each already a combined total on their own, so
        # summing is still correct when only one of those appears alone.
        "cogs",
        "duration",
        (
            "CostOfGoodsAndServicesSold",
            "CostOfRevenue",
            "CostOfGoodsSold",
            "CostOfServices",
        ),
        "income_statement",
        sign_convention="always_positive",
        combine="sum",
    ),
    Concept("gross_profit", "duration", ("GrossProfit",), "income_statement", required=False),
    Concept("operating_income", "duration", ("OperatingIncomeLoss",), "income_statement"),
    Concept(
        "net_income",
        "duration",
        (
            "NetIncomeLoss",
            "ProfitLoss",
            "NetIncomeLossAvailableToCommonStockholdersBasic",
        ),
        "income_statement",
    ),
    Concept(
        "sga",
        "duration",
        (
            "SellingGeneralAndAdministrativeExpense",
            "GeneralAndAdministrativeExpense",
            "SellingGeneralAndAdministrativeExpenses",
        ),
        "income_statement",
        required=False,
        sign_convention="always_positive",
    ),
    Concept(
        "depreciation_amortisation",
        "duration",
        (
            "DepreciationDepletionAndAmortization",
            "DepreciationAndAmortization",
            "DepreciationAmortizationAndAccretionNet",
            "Depreciation",
        ),
        "cash_flow",
        required=False,
        sign_convention="always_positive",
    ),
    Concept(
        # Gross interest expense only. Deliberately does NOT include
        # InterestIncomeExpenseNet, which nets interest income against
        # interest expense and can legitimately be negative (net interest
        # income) — conflating it here previously produced a false "sign
        # flip" restatement whenever a filer switched between the two tags.
        # See interest_income_expense_net below for the net figure.
        "interest_expense",
        "duration",
        ("InterestExpense", "InterestExpenseDebt"),
        "income_statement",
        required=False,
        sign_convention="always_positive",
    ),
    Concept(
        "interest_income_expense_net",
        "duration",
        ("InterestIncomeExpenseNet",),
        "income_statement",
        required=False,
        # Net figure: sign is meaningful (net income vs. net expense).
    ),
    Concept(
        "income_tax_expense",
        "duration",
        ("IncomeTaxExpenseBenefit",),
        "income_statement",
        required=False,
        # Legitimately negative in a net-tax-benefit year — do not normalise.
    ),
    # ------------------------------------------------------------ cash flow
    Concept(
        "cfo",
        "duration",
        (
            "NetCashProvidedByUsedInOperatingActivities",
            "NetCashProvidedByUsedInOperatingActivitiesContinuingOperations",
        ),
        "cash_flow",
    ),
    Concept(
        "capex",
        "duration",
        (
            "PaymentsToAcquirePropertyPlantAndEquipment",
            "PaymentsToAcquireProductiveAssets",
        ),
        "cash_flow",
        required=False,
    ),
    # --------------------------------------------------------- balance sheet
    Concept(
        "receivables",
        "instant",
        (
            "AccountsReceivableNetCurrent",
            "ReceivablesNetCurrent",
            "AccountsReceivableNet",
        ),
        "balance_sheet",
        required=False,
    ),
    Concept("inventory", "instant", ("InventoryNet",), "balance_sheet", required=False),
    Concept("current_assets", "instant", ("AssetsCurrent",), "balance_sheet", required=False),
    Concept("total_assets", "instant", ("Assets",), "balance_sheet"),
    Concept(
        "ppe_net",
        "instant",
        ("PropertyPlantAndEquipmentNet",),
        "balance_sheet",
        required=False,
    ),
    Concept(
        "current_liabilities",
        "instant",
        ("LiabilitiesCurrent",),
        "balance_sheet",
        required=False,
    ),
    Concept("total_liabilities", "instant", ("Liabilities",), "balance_sheet", required=False),
    Concept(
        "long_term_debt",
        "instant",
        (
            "LongTermDebtNoncurrent",
            "LongTermDebt",
            "LongTermDebtAndCapitalLeaseObligations",
        ),
        "balance_sheet",
        required=False,
    ),
    Concept(
        "retained_earnings",
        "instant",
        ("RetainedEarningsAccumulatedDeficit",),
        "balance_sheet",
        required=False,
    ),
    Concept(
        "equity",
        "instant",
        (
            "StockholdersEquity",
            "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest",
        ),
        "balance_sheet",
        required=False,
    ),
    Concept(
        # Excluded from restatement scoring: retroactive changes here are
        # overwhelmingly stock splits (a real, legitimate, disclosed event —
        # Apple's FY2013 comparative share count was correctly restated 7x
        # after its 2014 split) or plain filer scale/unit typos (Merck once
        # filed a fiscal-2012 comparative off by exactly 1,000,000x). Neither
        # is an accounting-quality signal.
        "shares_diluted",
        "duration",
        (
            "WeightedAverageNumberOfDilutedSharesOutstanding",
            "WeightedAverageNumberOfSharesOutstandingBasic",
        ),
        "income_statement",
        required=False,
        restatement_eligible=False,
    ),
)

# tag -> (canonical_name, priority) so the flattener can resolve in one pass
TAG_LOOKUP: dict[str, tuple[str, int]] = {}
for _c in CONCEPTS:
    for _rank, _tag in enumerate(_c.tags):
        # A tag should only ever map to one concept; first definition wins.
        TAG_LOOKUP.setdefault(_tag, (_c.name, _rank))

CONCEPT_BY_NAME: dict[str, Concept] = {c.name: c for c in CONCEPTS}
ALL_TAGS: frozenset[str] = frozenset(TAG_LOOKUP)
REQUIRED_CONCEPTS: tuple[str, ...] = tuple(c.name for c in CONCEPTS if c.required)


def to_dataframe() -> pd.DataFrame:
    """Concept metadata as a table, for export as a dbt seed.

    concepts.py is the single source of truth for this metadata; the seed is a
    generated artefact (see ``export_seeds.py``), never hand-edited.
    """
    return pd.DataFrame(
        {
            "concept": c.name,
            "kind": c.kind,
            "statement": c.statement,
            "required": c.required,
            "sign_convention": c.sign_convention,
            "restatement_eligible": c.restatement_eligible,
            "combine": c.combine,
        }
        for c in CONCEPTS
    )
