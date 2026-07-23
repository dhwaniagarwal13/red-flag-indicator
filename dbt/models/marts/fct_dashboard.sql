-- One wide row per (company, fiscal year) -- the export this project's BI
-- layer (Power BI / Tableau Public, see the README's Phase 5 section) reads
-- from. Not a new calculation: every score here is pulled as-is from the
-- three already-validated marts (fct_beneish_mscore, fct_altman_zscore,
-- fct_piotroski_fscore) and just denormalised into one table, because a
-- dashboard tool joining three fact tables at render time is slower and
-- harder to reason about than joining them once here, in a place that's
-- dbt-tested.
--
-- Grain is a FULL OUTER JOIN across the three source marts, not an inner
-- join: a 20-F filer with no market_value_of_equity has no z_score row at
-- all some years (see fct_altman_zscore's header), and that absence is
-- meaningful -- it must show up as a null z_score in the dashboard, not
-- silently drop the company-year's m_score and f_score too.
--
-- m_score_flag / z_zone / f_band all use the same published, static
-- thresholds documented in each source mart's header (Beneish -1.78, Altman
-- 2.99/1.81, Piotroski 8/2) -- copied here as plain comparisons on the
-- final score, not re-derived from raw inputs, so there's no way for this
-- layer to compute a different m_score than fct_beneish_mscore did.

with keys as (

    select entity_id, ticker, company_name, period_fiscal_year from {{ ref('fct_beneish_mscore') }}
    union
    select entity_id, ticker, company_name, period_fiscal_year from {{ ref('fct_altman_zscore') }}
    union
    select entity_id, ticker, company_name, period_fiscal_year from {{ ref('fct_piotroski_fscore') }}

),

joined as (

    select
        k.entity_id,
        k.ticker,
        k.company_name,
        k.period_fiscal_year,
        coalesce(z.period_end, f.period_end) as period_end,

        m.m_score,
        z.z_score,
        z.zone      as z_zone,
        f.f_score,
        f.band      as f_band

    from keys k
    left join {{ ref('fct_beneish_mscore') }}   m on k.entity_id = m.entity_id and k.period_fiscal_year = m.period_fiscal_year
    left join {{ ref('fct_altman_zscore') }}    z on k.entity_id = z.entity_id and k.period_fiscal_year = z.period_fiscal_year
    left join {{ ref('fct_piotroski_fscore') }} f on k.entity_id = f.entity_id and k.period_fiscal_year = f.period_fiscal_year

),

flagged as (

    select
        *,

        case when m_score is null then null when m_score > -1.78 then true else false end as m_score_flag,
        case when z_zone is null then null when z_zone = 'distress' then true else false end as z_score_flag,
        case when f_band is null then null when f_band = 'weak' then true else false end as f_score_flag

    from joined

)

select
    flagged.entity_id,
    flagged.ticker,
    flagged.company_name,
    s.gics_sector,
    coalesce(cs.ticker is not null, false) as is_case_study,
    cs.case_study_note,

    period_fiscal_year,
    period_end,

    m_score,
    z_score, z_zone,
    f_score, f_band,

    m_score_flag,
    z_score_flag,
    f_score_flag,

    -- Null-tolerant: only counts models that actually produced a score, so a
    -- company-year with 1 of 3 models available reads as "1 flag out of 1
    -- scored", not artificially diluted against models that had no data.
    (coalesce(m_score_flag::int, 0) + coalesce(z_score_flag::int, 0) + coalesce(f_score_flag::int, 0))
        as red_flag_count,
    ((m_score_flag is not null)::int + (z_score_flag is not null)::int + (f_score_flag is not null)::int)
        as models_scored

from flagged
left join {{ ref('stg_company_sectors') }} s on flagged.ticker = s.ticker
left join {{ ref('case_studies') }} cs on flagged.ticker = cs.ticker
