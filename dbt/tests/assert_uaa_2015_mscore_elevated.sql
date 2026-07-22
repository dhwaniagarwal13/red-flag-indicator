-- Validation anchor, not just a regression guard. Under Armour was later
-- charged by the SEC for pulling sales forward into Q3 2015 ("channel
-- stuffing") to hit growth targets. Across the 14 fiscal years this pilot can
-- score for UAA, FY2015 should be the single most elevated (least negative)
-- M-Score — exactly the year the SEC's complaint centers on, driven by an
-- above-normal DSRI (receivables growing faster than sales, the textbook
-- channel-stuffing signature). If this stops being true, either the formula
-- or an input regressed — investigate before assuming the finding is gone.
with ranked as (
    select
        period_fiscal_year,
        m_score,
        row_number() over (order by m_score desc) as rn  -- least negative first
    from {{ ref('fct_beneish_mscore') }}
    where ticker = 'UAA'
      and m_score is not null
)
select *
from ranked
where rn = 1
  and period_fiscal_year != 2015
