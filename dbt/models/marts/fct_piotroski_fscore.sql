-- Piotroski F-Score: one row per (company, fiscal year). Nine binary signals,
-- 1 point each, summed 0-9. Unlike M-Score (manipulation) and Z-Score
-- (bankruptcy risk), this measures **fundamental strength** — it's the
-- positive counterweight in this project, not another way to find trouble.
-- F >= 8 "strong", F <= 2 "weak", otherwise "neutral" — again, bands from the
-- original study, not a verdict.
--
-- Profitability (4): positive ROA, positive CFO, ROA improved YoY, earnings
--   quality (CFO > net income — the same idea as M-Score's TATA, inverted
--   into "good" rather than "bad" accrual behaviour).
-- Leverage/liquidity (3): leverage ratio decreased, current ratio improved,
--   no new shares issued (dilution check).
-- Operating efficiency (2): gross margin improved, asset turnover improved.
--
-- All 9 signals compare each fiscal year's own `is_first_report` value
-- against the prior year's `is_first_report` value — consistent with the
-- rest of this project, and unlike Z-Score's X4 there's no price multiplied
-- in here, so there's no split-adjustment basis mismatch to worry about: a
-- same-convention year-over-year share count comparison is exactly what the
-- dilution signal needs.
--
-- f_score is null (never zero-filled) when any of the 9 signals can't be
-- computed, with missing_signals naming which — same discipline as the other
-- two models, for the same reason: a partial score that looks like a real
-- score is worse than a visible gap.

with base as (

    select entity_id, ticker, company_name, period_end, period_fiscal_year, concept, value
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

        max(value) filter (where concept = 'net_income')                    as net_income,
        max(value) filter (where concept = 'cfo')                          as cfo,
        max(value) filter (where concept = 'total_assets')                  as total_assets,
        max(value) filter (where concept = 'long_term_debt')                as long_term_debt,
        max(value) filter (where concept = 'current_assets')                as current_assets,
        max(value) filter (where concept = 'current_liabilities')           as current_liabilities,
        max(value) filter (where concept = 'shares_diluted')                as shares,
        max(value) filter (where concept = 'revenue')                       as revenue,
        max(value) filter (where concept = 'cogs')                          as cogs,
        max(value) filter (where concept = 'gross_profit')                  as gross_profit_reported

    from base
    group by entity_id, period_end, period_fiscal_year

),

derived as (

    select
        *,
        coalesce(gross_profit_reported, revenue - cogs)  as gross_profit,
        net_income / nullif(total_assets, 0)             as roa,
        long_term_debt / nullif(total_assets, 0)         as leverage_ratio,
        current_assets / nullif(current_liabilities, 0)  as current_ratio
    from pivoted

),

with_margin_turnover as (

    select
        *,
        gross_profit / nullif(revenue, 0)  as gross_margin,
        revenue / nullif(total_assets, 0)  as asset_turnover
    from derived

),

with_prior as (

    select
        curr.entity_id,
        curr.ticker,
        curr.company_name,
        curr.period_end,
        curr.period_fiscal_year,

        curr.net_income,
        curr.cfo,

        curr.roa,             prior.roa             as roa_prior,
        curr.leverage_ratio,  prior.leverage_ratio  as leverage_ratio_prior,
        curr.current_ratio,   prior.current_ratio   as current_ratio_prior,
        curr.shares,          prior.shares          as shares_prior,
        curr.gross_margin,    prior.gross_margin    as gross_margin_prior,
        curr.asset_turnover,  prior.asset_turnover  as asset_turnover_prior

    from with_margin_turnover curr
    left join with_margin_turnover prior
        on  curr.entity_id = prior.entity_id
        and curr.period_fiscal_year = prior.period_fiscal_year + 1

),

signals as (

    select
        *,

        case when net_income is null then null when net_income > 0 then 1 else 0 end
            as signal_positive_roa,
        case when cfo is null then null when cfo > 0 then 1 else 0 end
            as signal_positive_cfo,
        case when roa is null or roa_prior is null then null when roa > roa_prior then 1 else 0 end
            as signal_roa_improved,
        case when cfo is null or net_income is null then null when cfo > net_income then 1 else 0 end
            as signal_earnings_quality,
        case when leverage_ratio is null or leverage_ratio_prior is null then null
             when leverage_ratio < leverage_ratio_prior then 1 else 0 end
            as signal_leverage_decreased,
        case when current_ratio is null or current_ratio_prior is null then null
             when current_ratio > current_ratio_prior then 1 else 0 end
            as signal_liquidity_improved,
        case when shares is null or shares_prior is null then null
             when shares <= shares_prior then 1 else 0 end
            as signal_no_dilution,
        case when gross_margin is null or gross_margin_prior is null then null
             when gross_margin > gross_margin_prior then 1 else 0 end
            as signal_margin_improved,
        case when asset_turnover is null or asset_turnover_prior is null then null
             when asset_turnover > asset_turnover_prior then 1 else 0 end
            as signal_turnover_improved

    from with_prior

)

select
    entity_id,
    ticker,
    company_name,
    period_end,
    period_fiscal_year,

    signal_positive_roa, signal_positive_cfo, signal_roa_improved, signal_earnings_quality,
    signal_leverage_decreased, signal_liquidity_improved, signal_no_dilution,
    signal_margin_improved, signal_turnover_improved,

    (case when signal_positive_roa       is null then ['positive_roa']       else []::varchar[] end)
        || (case when signal_positive_cfo      is null then ['positive_cfo']      else []::varchar[] end)
        || (case when signal_roa_improved      is null then ['roa_improved']      else []::varchar[] end)
        || (case when signal_earnings_quality  is null then ['earnings_quality']  else []::varchar[] end)
        || (case when signal_leverage_decreased is null then ['leverage_decreased'] else []::varchar[] end)
        || (case when signal_liquidity_improved is null then ['liquidity_improved'] else []::varchar[] end)
        || (case when signal_no_dilution       is null then ['no_dilution']       else []::varchar[] end)
        || (case when signal_margin_improved   is null then ['margin_improved']   else []::varchar[] end)
        || (case when signal_turnover_improved is null then ['turnover_improved'] else []::varchar[] end)
                                                                                    as missing_signals,

    case
        when signal_positive_roa is null or signal_positive_cfo is null
          or signal_roa_improved is null or signal_earnings_quality is null
          or signal_leverage_decreased is null or signal_liquidity_improved is null
          or signal_no_dilution is null or signal_margin_improved is null
          or signal_turnover_improved is null
        then null
        else signal_positive_roa + signal_positive_cfo + signal_roa_improved
             + signal_earnings_quality + signal_leverage_decreased + signal_liquidity_improved
             + signal_no_dilution + signal_margin_improved + signal_turnover_improved
    end as f_score,

    case
        when signal_positive_roa is null or signal_positive_cfo is null
          or signal_roa_improved is null or signal_earnings_quality is null
          or signal_leverage_decreased is null or signal_liquidity_improved is null
          or signal_no_dilution is null or signal_margin_improved is null
          or signal_turnover_improved is null
        then null
        when (signal_positive_roa + signal_positive_cfo + signal_roa_improved
              + signal_earnings_quality + signal_leverage_decreased + signal_liquidity_improved
              + signal_no_dilution + signal_margin_improved + signal_turnover_improved) >= 8
        then 'strong'
        when (signal_positive_roa + signal_positive_cfo + signal_roa_improved
              + signal_earnings_quality + signal_leverage_decreased + signal_liquidity_improved
              + signal_no_dilution + signal_margin_improved + signal_turnover_improved) <= 2
        then 'weak'
        else 'neutral'
    end as band

from signals
