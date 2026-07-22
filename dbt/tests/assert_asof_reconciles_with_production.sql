-- fct_scores_asof.sql duplicates the M/Z/F formulas from the three
-- production marts (see its header for why) rather than sharing macros with
-- them. This is the test that makes that duplication safe: the
-- `full_history` control event in backtest_events.csv sets as_of_date to
-- 2099-01-01, which makes every filed-so-far row visible -- economically
-- identical to what is_first_report already gives the production marts with
-- no date filter at all. If the two formula copies agree here, they haven't
-- drifted; a failure means one copy changed and the other didn't.
with asof_scores as (
    select ticker, period_fiscal_year, m_score, z_score, f_score
    from {{ ref('fct_scores_asof') }}
    where event_label = 'full_history'
),
production as (
    select
        m.ticker, m.period_fiscal_year, m.m_score,
        z.z_score,
        f.f_score
    from {{ ref('fct_beneish_mscore') }} m
    join {{ ref('fct_altman_zscore') }} z
        using (ticker, period_fiscal_year)
    join {{ ref('fct_piotroski_fscore') }} f
        using (ticker, period_fiscal_year)
    where m.ticker in (select distinct ticker from asof_scores)
),
compared as (
    select
        coalesce(a.ticker, p.ticker) as ticker,
        coalesce(a.period_fiscal_year, p.period_fiscal_year) as period_fiscal_year,
        a.m_score as asof_m, p.m_score as prod_m,
        a.z_score as asof_z, p.z_score as prod_z,
        a.f_score as asof_f, p.f_score as prod_f
    from asof_scores a
    full outer join production p
        using (ticker, period_fiscal_year)
)
select *
from compared
where abs(coalesce(asof_m, 0) - coalesce(prod_m, 0)) > 0.001
   or abs(coalesce(asof_z, 0) - coalesce(prod_z, 0)) > 0.001
   or coalesce(asof_f, -1) != coalesce(prod_f, -1)
