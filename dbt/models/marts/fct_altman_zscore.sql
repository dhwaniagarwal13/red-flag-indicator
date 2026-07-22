-- Altman Z-Score (original 1968 model, public/manufacturing form): one row
-- per (company, fiscal year).
--
-- Z = 1.2*X1 + 1.4*X2 + 3.3*X3 + 0.6*X4 + 1.0*X5
--   X1 = working capital / total assets
--   X2 = retained earnings / total assets
--   X3 = EBIT / total assets            (approximated by operating_income)
--   X4 = market value of equity / total liabilities
--   X5 = revenue / total assets
--
-- Z > 2.99 "safe", 1.81-2.99 "grey", < 1.81 "distress" — Altman's published
-- zones from a statistical model, not a verdict on any one company.
--
-- X4 is the interesting one: it's the only input in this whole project that
-- isn't from the company's own filings — it's what the market thought the
-- company was worth, from redflag.sources.prices (yfinance). That makes X4
-- deliberately NOT point-in-time in the same sense as the rest of this
-- project: market_value_of_equity pairs today's-basis share count
-- (`latest_reported_value`, fully split-adjusted) with a price series that is
-- itself always split-adjusted to today's basis. Using `value` (the
-- as-originally-filed, NOT split-adjusted count) instead would multiply an
-- adjusted price by an unadjusted share count and misstate market cap by
-- whatever split ratio occurred since — see redflag/sources/prices.py for the
-- full reasoning. The two other inputs (X1, X2, X3, X5) still use each year's
-- own `is_first_report` value, consistent with the rest of this project.
--
-- Like fct_beneish_mscore, z_score is null — never zero-filled — when any of
-- X1-X5 can't be computed, with missing_inputs naming which.
--
-- Foreign private issuers (form 20-F, e.g. Luckin Coffee in this pilot) are
-- deliberately excluded from X4/market cap, not merely left to whatever the
-- data implies. Luckin's XBRL reports total ordinary shares (~1.6 billion),
-- but LKNCY the ADR does not trade 1 ADR = 1 ordinary share — ADR programs
-- commonly bundle several ordinary shares into one ADR, and multiplying total
-- ordinary shares by the ADR price overstates market cap by whatever that
-- ratio is. This produced a Z-Score of 55.9 (X4 alone = 95x) for LKNCY's
-- FY2019 before this fix — an admitted fraud reading as maximally "safe",
-- which is worse than useless. The correct ADR ratio could be looked up and
-- applied, but guessing it and silently "correcting" the number would just
-- swap one unverified figure for another; excluding it is the honest move
-- until that ratio is actually sourced and verified. X1, X2, X3, X5 (none of
-- which depend on price) are still computed for 20-F filers.

with foreign_filer as (

    select distinct entity_id
    from {{ ref('fct_financials_pit') }}
    where form in ('20-F', '20-F/A')

),

base as (

    select entity_id, ticker, company_name, period_end, period_fiscal_year, concept, value, latest_reported_value
    from {{ ref('fct_financials_pit') }}
    where is_first_report

),

pivoted as (

    select
        entity_id,
        any_value(ticker)       as ticker,
        any_value(company_name) as company_name,
        period_end,
        period_fiscal_year,

        max(value) filter (where concept = 'current_assets')                        as current_assets,
        max(value) filter (where concept = 'current_liabilities')                   as current_liabilities,
        max(value) filter (where concept = 'total_assets')                          as total_assets,
        max(value) filter (where concept = 'retained_earnings')                     as retained_earnings,
        max(value) filter (where concept = 'operating_income')                      as operating_income,
        max(value) filter (where concept = 'revenue')                               as revenue,
        max(value) filter (where concept = 'total_liabilities')                     as total_liabilities_reported,
        max(value) filter (where concept = 'long_term_debt')                        as long_term_debt,
        max(latest_reported_value) filter (where concept = 'shares_diluted')        as shares_current_basis

    from base
    group by entity_id, period_end, period_fiscal_year

),

derived as (

    select
        *,
        coalesce(total_liabilities_reported, current_liabilities + long_term_debt) as total_liabilities
    from pivoted

),

-- Closest trading-day close on or before period_end, within a 10-calendar-day
-- tolerance (covers weekends/holidays around a fiscal year end without
-- reaching back far enough to pick up a stale, pre-year-end price).
candidate_prices as (

    select
        d.entity_id,
        d.period_end,
        sp.price_date,
        sp.close,
        row_number() over (
            partition by d.entity_id, d.period_end
            order by sp.price_date desc
        ) as rn
    from derived d
    join {{ ref('stg_prices') }} sp
        on  sp.ticker = d.ticker
        and sp.price_date <= d.period_end
        and sp.price_date >= d.period_end - interval 10 day

),

nearest_price as (

    select entity_id, period_end, price_date, close
    from candidate_prices
    where rn = 1

),

priced as (

    select
        d.*,
        np.close as price_at_period_end,
        np.price_date as price_date,
        case
            when ff.entity_id is not null then null  -- 20-F filer: see header comment
            else np.close * d.shares_current_basis
        end as market_value_of_equity
    from derived d
    left join nearest_price np
        using (entity_id, period_end)
    left join foreign_filer ff
        using (entity_id)

),

factors as (

    select
        *,
        (current_assets - current_liabilities) / nullif(total_assets, 0)      as x1,
        retained_earnings / nullif(total_assets, 0)                           as x2,
        operating_income / nullif(total_assets, 0)                            as x3,
        market_value_of_equity / nullif(total_liabilities, 0)                 as x4,
        revenue / nullif(total_assets, 0)                                     as x5
    from priced

)

select
    entity_id,
    ticker,
    company_name,
    period_end,
    period_fiscal_year,
    price_date,
    price_at_period_end,
    market_value_of_equity,

    x1, x2, x3, x4, x5,

    (case when x1 is null then ['x1'] else []::varchar[] end)
        || (case when x2 is null then ['x2'] else []::varchar[] end)
        || (case when x3 is null then ['x3'] else []::varchar[] end)
        || (case when x4 is null then ['x4'] else []::varchar[] end)
        || (case when x5 is null then ['x5'] else []::varchar[] end)
                                                                        as missing_inputs,

    case
        when x1 is null or x2 is null or x3 is null or x4 is null or x5 is null
        then null
        else round(1.2 * x1 + 1.4 * x2 + 3.3 * x3 + 0.6 * x4 + 1.0 * x5, 3)
    end as z_score,

    case
        when x1 is null or x2 is null or x3 is null or x4 is null or x5 is null then null
        when (1.2 * x1 + 1.4 * x2 + 3.3 * x3 + 0.6 * x4 + 1.0 * x5) > 2.99 then 'safe'
        when (1.2 * x1 + 1.4 * x2 + 3.3 * x3 + 0.6 * x4 + 1.0 * x5) >= 1.81 then 'grey'
        else 'distress'
    end as zone

from factors
