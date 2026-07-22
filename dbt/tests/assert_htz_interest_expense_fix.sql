-- Regression test for the specific bug that motivated the Phase 1b tag-lineage
-- fix. Before the fix, Hertz's interest_expense appeared to swing ~-968%
-- (70M -> -608M) for FY2020 purely because a later filing switched from the
-- gross `InterestExpense` tag to the net `InterestIncomeExpenseNet` tag —
-- two economically different figures compared as if they were one series.
-- Splitting them into separate concepts (interest_expense vs.
-- interest_income_expense_net) and comparing only within a consistent tag
-- lineage should make that comparison impossible. A non-empty result means
-- the fix regressed.
select *
from {{ ref('fct_financials_pit') }}
where ticker = 'HTZ'
  and concept = 'interest_expense'
  and period_fiscal_year = 2020
  and in_lineage
  and abs(coalesce(restatement_pct, 0)) > 1.0
