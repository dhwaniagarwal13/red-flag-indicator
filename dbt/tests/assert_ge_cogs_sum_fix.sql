-- Regression test for the split-COGS bug found while building the M-Score
-- model. GE tags CostOfGoodsSold (products) and CostOfServices (services) as
-- two simultaneous components in the same filing, not alternatives — picking
-- one by tag priority (the original approach) silently discarded the other
-- and understated COGS. GE's FY2012 10-K reports CostOfGoodsSold=56,785M and
-- CostOfServices=17,525M; the concept should equal their sum, 74,310M. A
-- single-tag value near either component alone, or a source_tag without the
-- combine-mode '+' label, means the fix regressed.
select *
from {{ ref('fct_financials_pit') }}
where ticker = 'GE'
  and concept = 'cogs'
  and period_fiscal_year = 2012
  and is_first_report
  and (source_tag not like '%+%' or abs(value - 74310000000) > 1000000)
