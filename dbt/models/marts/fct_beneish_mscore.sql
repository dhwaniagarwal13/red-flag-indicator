-- Beneish M-Score: one row per (company, fiscal year).
--
-- M = -4.84 + 0.920*DSRI + 0.528*GMI + 0.404*AQI + 0.892*SGI + 0.115*DEPI
--            - 0.172*SGAI + 4.679*TATA - 0.327*LVGI
--
-- M > -1.78 is Beneish's published cutoff for "resembles a known earnings
-- manipulator" — a screening threshold from a statistical model, not a
-- verdict. See the README for what this can and can't tell you.
--
-- Point-in-time choice: every input uses each fiscal year's own
-- `is_first_report` value — the figure as originally filed for that year, not
-- a later-restated one. That means a company mid-restatement can show
-- inconsistent-looking year-over-year ratios; that inconsistency is itself
-- informative (see `fct_financials_pit.was_restated`), not a bug to smooth
-- over. A stricter point-in-time variant would additionally re-price the
-- prior year using only what was known as of the current year's filing date
-- (rather than that prior year's own first filing) — deferred; noted in the
-- README as a documented simplification.
--
-- AQI is computed as (1 - (current_assets + ppe_net)/total_assets), which
-- omits long-term investments/securities from the "productive asset" base —
-- we don't carry that concept. This is a standard simplification when full
-- data isn't available; it slightly overstates AQI for asset-heavy investors
-- but has no effect on the concepts this pilot's companies actually report.
--
-- Not well-suited to banks/insurers: COGS is not a meaningful concept for a
-- financial institution, so GMI (and therefore the composite) is expected to
-- come back incomplete for them — see `missing_inputs` below. That is
-- correct behaviour, not a pipeline gap.

with base as (

    select entity_id, ticker, company_name, concept, period_fiscal_year, value
    from {{ ref('fct_financials_pit') }}
    where is_first_report

),

pivoted as (

    select
        entity_id,
        any_value(ticker)       as ticker,
        any_value(company_name) as company_name,
        period_fiscal_year,

        max(value) filter (where concept = 'revenue')                   as revenue,
        max(value) filter (where concept = 'cogs')                      as cogs,
        max(value) filter (where concept = 'gross_profit')              as gross_profit_reported,
        max(value) filter (where concept = 'receivables')               as receivables,
        max(value) filter (where concept = 'current_assets')            as current_assets,
        max(value) filter (where concept = 'total_assets')              as total_assets,
        max(value) filter (where concept = 'ppe_net')                   as ppe_net,
        max(value) filter (where concept = 'depreciation_amortisation') as dep_amort,
        max(value) filter (where concept = 'sga')                       as sga,
        max(value) filter (where concept = 'current_liabilities')       as current_liabilities,
        max(value) filter (where concept = 'long_term_debt')            as long_term_debt,
        max(value) filter (where concept = 'total_liabilities')         as total_liabilities_reported,
        max(value) filter (where concept = 'net_income')                as net_income,
        max(value) filter (where concept = 'cfo')                       as cfo

    from base
    group by entity_id, period_fiscal_year

),

derived as (

    select
        *,
        coalesce(gross_profit_reported, revenue - cogs)                       as gross_profit,
        coalesce(total_liabilities_reported, current_liabilities + long_term_debt) as total_liabilities
    from pivoted

),

with_prior as (

    select
        curr.entity_id,
        curr.ticker,
        curr.company_name,
        curr.period_fiscal_year,

        curr.revenue,             prior.revenue             as revenue_prior,
        curr.cogs,                prior.cogs                as cogs_prior,
        curr.gross_profit,        prior.gross_profit        as gross_profit_prior,
        curr.receivables,         prior.receivables         as receivables_prior,
        curr.current_assets,      prior.current_assets      as current_assets_prior,
        curr.total_assets,        prior.total_assets        as total_assets_prior,
        curr.ppe_net,             prior.ppe_net             as ppe_net_prior,
        curr.dep_amort,           prior.dep_amort           as dep_amort_prior,
        curr.sga,                 prior.sga                 as sga_prior,
        curr.total_liabilities,   prior.total_liabilities   as total_liabilities_prior,
        curr.net_income,
        curr.cfo

    from derived curr
    left join derived prior
        on  curr.entity_id = prior.entity_id
        and curr.period_fiscal_year = prior.period_fiscal_year + 1

),

indices as (

    select
        *,

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
            / nullif(total_liabilities_prior / nullif(total_assets_prior, 0), 0)    as lvgi

    from with_prior

)

select
    entity_id,
    ticker,
    company_name,
    period_fiscal_year,

    dsri, gmi, aqi, sgi, depi, sgai, tata, lvgi,

    (case when dsri is null then ['dsri'] else []::varchar[] end)
        || (case when gmi  is null then ['gmi']  else []::varchar[] end)
        || (case when aqi  is null then ['aqi']  else []::varchar[] end)
        || (case when sgi  is null then ['sgi']  else []::varchar[] end)
        || (case when depi is null then ['depi'] else []::varchar[] end)
        || (case when sgai is null then ['sgai'] else []::varchar[] end)
        || (case when tata is null then ['tata'] else []::varchar[] end)
        || (case when lvgi is null then ['lvgi'] else []::varchar[] end)
                                                                        as missing_inputs,

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
    end                                                               as m_score

from indices
