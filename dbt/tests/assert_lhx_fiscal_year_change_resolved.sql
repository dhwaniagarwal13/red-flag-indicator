-- Anchor test for a real corporate event found scaling to the S&P 500.
-- L3Harris (LHX) reported on a June 30 fiscal year through FY2019 (Harris
-- Corp's legacy calendar), then filed a genuine ~6-month transition report
-- ending 2020-01-03 to move onto a calendar-year basis — both period_end
-- dates are real, meaningful annual-ish periods, and both naturally land
-- under period_fiscal_year=2019. Before the canonical-period-end fix (see
-- fct_financials_pit.sql), this produced two is_first_report rows per
-- concept for FY2019, which fanned out into duplicate company-year rows in
-- every model that self-joins year-over-year. Assert exactly one canonical
-- period_end survives per concept for that year — this doesn't have to be
-- 2019-06-28 specifically (the tie-break is "whichever period_end more
-- concepts agree on", which is allowed to land on either real date), but it
-- must not be both.
select entity_id, concept, period_fiscal_year, count(*) as n
from {{ ref('fct_financials_pit') }}
where ticker = 'LHX'
  and is_first_report
  and period_fiscal_year = 2019
group by entity_id, concept, period_fiscal_year
having count(*) > 1
