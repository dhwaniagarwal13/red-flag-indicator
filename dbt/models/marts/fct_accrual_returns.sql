-- Sloan (1996)-style accrual anomaly test: pairs each company-fiscal-year's
-- accrual level with its forward 12-month stock return, so
-- src/redflag/sloan_test.py can test Sloan's finding that high-accrual firms
-- subsequently underperform low-accrual firms -- i.e. accruals predict
-- returns because the market doesn't fully price earnings quality.
--
-- Accrual measure: TATA, reused directly from fct_beneish_mscore rather than
-- rebuilt from scratch -- (net_income - cfo) / total_assets is exactly
-- Sloan's cash-flow-statement approach to total accruals (Hribar & Collins
-- 2002 treat it as equivalent to the balance-sheet approach Sloan's original
-- paper used), and reusing an already-validated, already-tested number is
-- safer than adding a second, subtly different accrual formula that could
-- disagree with the first for reasons that are about implementation, not
-- economics.
--
-- Point-in-time discipline for the return itself: the entry price is the
-- first trading day ON OR AFTER the 10-K's first_filed_date, never on or
-- before it -- buying on the filing date or earlier would use a price that
-- didn't yet reflect the accrual information being tested. The exit price is
-- 12 months later, same rule. Both differ from fct_altman_zscore's price
-- join, which deliberately wants the price AT period_end (for a market-cap
-- snapshot); this wants the price the moment the accrual figure became
-- knowable, which is filing day, not fiscal year end -- the gap between the
-- two (filing_lag_days in fct_financials_pit) is often 30-60 days and matters
-- here specifically because a forward-return test must not let the position
-- start before the signal existed.

with accruals as (

    select entity_id, ticker, period_fiscal_year, tata
    from {{ ref('fct_beneish_mscore') }}
    where tata is not null

),

filing as (

    select distinct entity_id, period_fiscal_year, first_filed_date
    from {{ ref('fct_financials_pit') }}
    where is_first_report

),

base as (

    select a.entity_id, a.ticker, a.period_fiscal_year, a.tata, f.first_filed_date
    from accruals a
    join filing f
        using (entity_id, period_fiscal_year)

),

-- Nearest trading day ON OR AFTER a target date, within a 10-calendar-day
-- tolerance (weekends/holidays around the target without drifting onto a
-- stale, much-later price if the ticker has a gap in its price history).
entry_candidates as (

    select
        b.entity_id, b.period_fiscal_year,
        sp.price_date, sp.close,
        row_number() over (
            partition by b.entity_id, b.period_fiscal_year
            order by sp.price_date asc
        ) as rn
    from base b
    join {{ ref('stg_prices') }} sp
        on  sp.ticker = b.ticker
        and sp.price_date >= b.first_filed_date
        and sp.price_date <= b.first_filed_date + interval 10 day

),

exit_candidates as (

    select
        b.entity_id, b.period_fiscal_year,
        sp.price_date, sp.close,
        row_number() over (
            partition by b.entity_id, b.period_fiscal_year
            order by sp.price_date asc
        ) as rn
    from base b
    join {{ ref('stg_prices') }} sp
        on  sp.ticker = b.ticker
        and sp.price_date >= b.first_filed_date + interval 365 day
        and sp.price_date <= b.first_filed_date + interval 375 day

),

entry as (
    select entity_id, period_fiscal_year, price_date as entry_date, close as entry_price
    from entry_candidates
    where rn = 1
),

exit as (
    select entity_id, period_fiscal_year, price_date as exit_date, close as exit_price
    from exit_candidates
    where rn = 1
),

returns as (

    select
        b.entity_id,
        b.ticker,
        b.period_fiscal_year,
        b.tata,
        b.first_filed_date,
        e.entry_date,
        e.entry_price,
        x.exit_date,
        x.exit_price,
        case
            when e.entry_price is null or x.exit_price is null or e.entry_price = 0 then null
            else round(x.exit_price / e.entry_price - 1, 4)
        end as fwd_return_12m
    from base b
    left join entry e using (entity_id, period_fiscal_year)
    left join exit  x using (entity_id, period_fiscal_year)

)

select
    *,
    -- 1 = lowest (most conservative) accruals, 5 = highest (most aggressive).
    -- Sloan predicts quintile 1 outperforms quintile 5. Partitioning also on
    -- "has a forward return" (not just period_fiscal_year) keeps
    -- missing-price company-years in a partition of their own, so they can't
    -- consume a quintile slot and skew the boundaries for the rows that
    -- actually get scored -- their accrual_quintile still comes out null via
    -- the outer case, they just don't distort everyone else's ranks first.
    case
        when fwd_return_12m is not null
        then ntile(5) over (
            partition by period_fiscal_year, (fwd_return_12m is not null)
            order by tata asc
        )
    end as accrual_quintile
from returns
