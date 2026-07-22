-- Regression test for the 52/53-week fiscal-calendar boundary bug found
-- while building F-Score (see stg_facts.sql). JNJ and KHC land their fiscal
-- year end in early January some years; naively taking year(period_end)
-- collided that snapshot with the following true fiscal year under the same
-- period_fiscal_year label, producing two is_first_report rows for what
-- should be one (entity, concept, fiscal year) — and fanning out into
-- duplicate company-year rows in every model that self-joins year-over-year
-- (M-Score, Z-Score, F-Score all do).
select entity_id, concept, period_fiscal_year, count(*) as n
from {{ ref('fct_financials_pit') }}
where is_first_report
group by entity_id, concept, period_fiscal_year
having count(*) > 1
