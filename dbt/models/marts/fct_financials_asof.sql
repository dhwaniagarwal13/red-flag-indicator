-- Point-in-time "as of" panel: one row per (backtest event, company, fiscal
-- year), pivoted, restricted to only the fiscal years whose first-filed 10-K
-- (or 20-F) was actually public by that event's `as_of_date`.
--
-- Everything else in this project answers "what did we know about fiscal
-- year Y, as first filed" -- that's `is_first_report`, and it's a fixed
-- property of a row, not a function of *when you're asking*. This model adds
-- the missing dimension: a query date. A company's FY2015 10-K existing in
-- `fct_financials_pit` today says nothing about whether it existed on, say,
-- 2015-06-01 -- for that you need `first_filed_date <= as_of_date`, which is
-- the one thing genuinely new here.
--
-- `dbt/seeds/backtest_events.csv` supplies the (ticker, as_of_date) pairs to
-- evaluate -- one row per case-study company for "the day its most-recent
-- pre-scandal 10-K became public", plus one `full_history` control row per
-- company (as_of_date 2099-01-01, i.e. everything filed so far) whose scores
-- must reconcile exactly with the production marts -- see
-- `assert_asof_reconciles_with_production.sql`. That reconciliation test is
-- the reason `fct_scores_asof` is allowed to duplicate the M/Z/F formulas
-- instead of sharing macros with the three production models: duplicating a
-- dozen lines of arithmetic under a test that fails the moment it drifts is a
-- smaller risk than refactoring three already-validated, heavily-tested
-- models to share code with a new, unproven one.
--
-- Concept list is the union of everything fct_beneish_mscore,
-- fct_altman_zscore and fct_piotroski_fscore each pivot individually.

with events as (

    select * from {{ ref('backtest_events') }}

),

base as (

    select entity_id, ticker, company_name, form, concept, period_end,
           period_fiscal_year, value, latest_reported_value, first_filed_date
    from {{ ref('fct_financials_pit') }}
    where is_first_report

),

crossed as (

    select
        e.ticker         as event_ticker,
        e.event_label,
        e.as_of_date,
        e.public_event_date,
        e.event_description,
        b.*
    from events e
    join base b
        on  b.ticker = e.ticker
        and b.first_filed_date <= e.as_of_date

),

pivoted as (

    select
        event_ticker, event_label, as_of_date, public_event_date, event_description,
        entity_id,
        any_value(ticker)       as ticker,
        any_value(company_name) as company_name,
        any_value(form)         as form,
        period_end,
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
        max(value) filter (where concept = 'cfo')                       as cfo,
        max(value) filter (where concept = 'retained_earnings')         as retained_earnings,
        max(value) filter (where concept = 'operating_income')          as operating_income,
        max(latest_reported_value) filter (where concept = 'shares_diluted') as shares_current_basis

    from crossed
    group by event_ticker, event_label, as_of_date, public_event_date, event_description,
             entity_id, period_end, period_fiscal_year

)

select
    *,
    coalesce(gross_profit_reported, revenue - cogs)                            as gross_profit,
    coalesce(total_liabilities_reported, current_liabilities + long_term_debt) as total_liabilities
from pivoted
