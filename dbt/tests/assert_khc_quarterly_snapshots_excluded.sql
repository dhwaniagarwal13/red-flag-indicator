-- Regression test for the KHC quarterly-instant-facts bug (see the
-- annual_period_ends fix in fct_financials_pit.sql). KHC's 10-Ks include a
-- supplementary quarterly-data table (a common post-merger recast
-- disclosure); these specific quarter-end dates leaked into the
-- point-in-time table as if they were fiscal-year-end balance-sheet
-- snapshots before the fix, producing up to 16 spurious rows for a single
-- real fiscal year.
select *
from {{ ref('fct_financials_pit') }}
where ticker = 'KHC'
  and period_end in (
      '2017-04-01', '2017-07-01', '2017-09-30',
      '2018-03-31', '2018-06-30', '2018-09-29'
  )
