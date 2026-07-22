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
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Concept:
    name: str
    kind: str  # "duration" | "instant"
    tags: tuple[str, ...]
    statement: str
    required: bool = True  # if False, absence is expected for some filers


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
        "cogs",
        "duration",
        (
            "CostOfGoodsAndServicesSold",
            "CostOfRevenue",
            "CostOfGoodsSold",
            "CostOfServices",
        ),
        "income_statement",
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
    ),
    Concept(
        "interest_expense",
        "duration",
        ("InterestExpense", "InterestExpenseDebt", "InterestIncomeExpenseNet"),
        "income_statement",
        required=False,
    ),
    Concept(
        "income_tax_expense",
        "duration",
        ("IncomeTaxExpenseBenefit",),
        "income_statement",
        required=False,
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
        "shares_diluted",
        "duration",
        (
            "WeightedAverageNumberOfDilutedSharesOutstanding",
            "WeightedAverageNumberOfSharesOutstandingBasic",
        ),
        "income_statement",
        required=False,
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
