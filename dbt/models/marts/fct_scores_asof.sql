-- Beneish M-Score, Altman Z-Score and Piotroski F-Score recomputed on top of
-- `fct_financials_asof` -- i.e. "what would this screen have shown, using
-- only filings public as of each backtest event's `as_of_date`."
--
-- The formulas below are deliberately identical to fct_beneish_mscore.sql,
-- fct_altman_zscore.sql and fct_piotroski_fscore.sql -- copy-pasted, not
-- shared via macro. See fct_financials_asof.sql's header for why: this file
-- is protected from drifting out of sync with the production formulas by
-- `assert_asof_reconciles_with_production.sql`, which checks that the
-- `full_history` control event (as_of_date 2099-01-01, i.e. every filing
-- seen so far) reproduces the production marts exactly, company-year for
-- company-year. If that test passes, the duplication hasn't drifted; if it
-- ever fails, one of the two copies changed without the other.

with curr as (

    select * from {{ ref('fct_financials_asof') }}

),

-- Single self-join for every prior-year raw field any of the 3 models needs.
-- net_income, cfo, retained_earnings and operating_income are never compared
-- year-over-year by any model, so they're left out of the prior side.
with_prior as (

    select
        c.event_ticker, c.event_label, c.as_of_date, c.public_event_date,
        c.entity_id, c.ticker, c.company_name, c.form, c.period_end, c.period_fiscal_year,

        c.revenue, c.cogs, c.gross_profit, c.receivables, c.current_assets,
        c.total_assets, c.ppe_net, c.dep_amort, c.sga, c.current_liabilities,
        c.long_term_debt, c.total_liabilities, c.net_income, c.cfo,
        c.retained_earnings, c.operating_income, c.shares_current_basis,

        p.revenue             as revenue_prior,
        p.cogs                as cogs_prior,
        p.gross_profit        as gross_profit_prior,
        p.receivables         as receivables_prior,
        p.current_assets      as current_assets_prior,
        p.total_assets        as total_assets_prior,
        p.ppe_net             as ppe_net_prior,
        p.dep_amort           as dep_amort_prior,
        p.sga                 as sga_prior,
        p.current_liabilities as current_liabilities_prior,
        p.long_term_debt      as long_term_debt_prior,
        p.total_liabilities   as total_liabilities_prior,
        p.net_income          as net_income_prior,
        p.shares_current_basis as shares_prior

    from curr c
    left join curr p
        on  p.event_ticker  = c.event_ticker
        and p.event_label   = c.event_label
        and p.as_of_date    = c.as_of_date
        and p.public_event_date = c.public_event_date
        and p.entity_id     = c.entity_id
        and p.period_fiscal_year = c.period_fiscal_year - 1

),

-- Nearest trading-day close on or before period_end (same 10-day tolerance
-- as fct_altman_zscore) for the Z-Score market-value term. Not gated on
-- as_of_date: period_end is always well before as_of_date by construction
-- (a fiscal year's 10-K, and therefore its as_of_date, can't predate its own
-- period_end), so there is no lookahead risk in joining it unconditionally.
foreign_filer as (

    select distinct event_ticker, event_label, as_of_date, public_event_date, entity_id
    from with_prior
    where form in ('20-F', '20-F/A')

),

candidate_prices as (

    select
        wp.event_ticker, wp.event_label, wp.as_of_date, wp.public_event_date, wp.entity_id, wp.period_end,
        sp.price_date, sp.close,
        row_number() over (
            partition by wp.event_ticker, wp.event_label, wp.as_of_date, wp.entity_id, wp.period_end
            order by sp.price_date desc
        ) as rn
    from with_prior wp
    join {{ ref('stg_prices') }} sp
        on  sp.ticker = wp.ticker
        and sp.price_date <= wp.period_end
        and sp.price_date >= wp.period_end - interval 10 day

),

nearest_price as (

    select event_ticker, event_label, as_of_date, public_event_date, entity_id, period_end, close
    from candidate_prices
    where rn = 1

),

priced as (

    select
        wp.*,
        np.close as price_at_period_end,
        case
            when ff.entity_id is not null then null
            else np.close * wp.shares_current_basis
        end as market_value_of_equity
    from with_prior wp
    left join nearest_price np
        using (event_ticker, event_label, as_of_date, public_event_date, entity_id, period_end)
    left join foreign_filer ff
        using (event_ticker, event_label, as_of_date, public_event_date, entity_id)

),

indices as (

    select
        *,

        -- Beneish M-Score's 8 indices
        (receivables / nullif(revenue, 0))
            / nullif(receivables_prior / nullif(revenue_prior, 0), 0)               as dsri,
        (gross_profit_prior / nullif(revenue_prior, 0))
            / nullif(gross_profit / nullif(revenue, 0), 0)                          as gmi,
        (1 - (current_assets + ppe_net) / nullif(total_assets, 0))
            / nullif(1 - (current_assets_prior + ppe_net_prior) / nullif(total_assets_prior, 0), 0)
                                                                                      as aqi,
        revenue / nullif(revenue_prior, 0)                                          as sgi,
        (dep_amort_prior / nullif(dep_amort_prior + ppe_net_prior, 0))
            / nullif(dep_amort / nullif(dep_amort + ppe_net, 0), 0)                 as depi,
        (sga / nullif(revenue, 0))
            / nullif(sga_prior / nullif(revenue_prior, 0), 0)                       as sgai,
        (net_income - cfo) / nullif(total_assets, 0)                                as tata,
        (total_liabilities / nullif(total_assets, 0))
            / nullif(total_liabilities_prior / nullif(total_assets_prior, 0), 0)    as lvgi,

        -- Altman Z-Score's 5 factors
        (current_assets - current_liabilities) / nullif(total_assets, 0)      as x1,
        retained_earnings / nullif(total_assets, 0)                           as x2,
        operating_income / nullif(total_assets, 0)                            as x3,
        market_value_of_equity / nullif(total_liabilities, 0)                 as x4,
        revenue / nullif(total_assets, 0)                                     as x5,

        -- Piotroski F-Score's 9 signals: current-year and prior-year levels
        net_income / nullif(total_assets, 0)                    as roa,
        long_term_debt / nullif(total_assets, 0)                as leverage_ratio,
        current_assets / nullif(current_liabilities, 0)         as current_ratio,
        gross_profit / nullif(revenue, 0)                       as gross_margin,
        revenue / nullif(total_assets, 0)                       as asset_turnover,

        long_term_debt_prior / nullif(total_assets_prior, 0)              as leverage_ratio_prior,
        current_assets_prior / nullif(current_liabilities_prior, 0)       as current_ratio_prior,
        gross_profit_prior / nullif(revenue_prior, 0)                    as gross_margin_prior,
        revenue_prior / nullif(total_assets_prior, 0)                    as asset_turnover_prior,
        net_income_prior / nullif(total_assets_prior, 0)                 as roa_prior

    from priced

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
        case when shares_current_basis is null or shares_prior is null then null
             when shares_current_basis <= shares_prior then 1 else 0 end
            as signal_no_dilution,
        case when gross_margin is null or gross_margin_prior is null then null
             when gross_margin > gross_margin_prior then 1 else 0 end
            as signal_margin_improved,
        case when asset_turnover is null or asset_turnover_prior is null then null
             when asset_turnover > asset_turnover_prior then 1 else 0 end
            as signal_turnover_improved
    from indices

)

select
    event_ticker,
    event_label,
    as_of_date,
    public_event_date,
    ticker,
    company_name,
    period_fiscal_year,

    case
        when dsri is null or gmi is null or aqi is null or sgi is null
          or depi is null or sgai is null or tata is null or lvgi is null
        then null
        else round(
            -4.84
            + 0.920 * dsri + 0.528 * gmi + 0.404 * aqi + 0.892 * sgi
            + 0.115 * depi - 0.172 * sgai + 4.679 * tata - 0.327 * lvgi,
            3
        )
    end as m_score,

    case
        when x1 is null or x2 is null or x3 is null or x4 is null or x5 is null
        then null
        else round(1.2 * x1 + 1.4 * x2 + 3.3 * x3 + 0.6 * x4 + 1.0 * x5, 3)
    end as z_score,

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
    end as f_score

from signals
