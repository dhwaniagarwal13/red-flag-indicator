-- Bitemporal annual fact table: one row per (company, concept, fiscal period,
-- filing that reported it).
--
-- The same fiscal year is typically reported three times — once in its own
-- annual report, then twice more as a comparative in the following two. Most
-- pipelines collapse that to one row and lose the ability to ask the only
-- question that matters for a backtest: *what did we know, and when?*
--
-- Two bases fall out of keeping all of it:
--   as-first-reported  — what the market actually saw on filing day
--   as-latest-reported — the figure after any subsequent revision
--
-- The gap between them is not noise. A company whose reported numbers move
-- materially after the fact is telling you something, so `restatement_pct` is
-- carried forward as a red flag in its own right.

with annual as (

    select *
    from {{ ref('stg_facts') }}
    where period_type = 'annual'
      and form in ('10-K', '10-K/A', '20-F', '20-F/A')
      and unit in ('USD', 'shares')

),

-- Where several acceptable tags appear in the same filing for the same concept,
-- keep the highest-priority one (see concepts.py for the ordering rationale).
deduped as (

    select *
    from (
        select
            *,
            row_number() over (
                partition by entity_id, concept, period_end, accession
                order by tag_priority asc, value desc
            ) as rn
        from annual
    )
    where rn = 1

),

versioned as (

    select
        entity_id,
        ticker,
        company_name,
        concept,
        source_tag,
        period_start,
        period_end,
        period_fiscal_year,
        filed_date,
        filing_lag_days,
        form,
        accession,
        value,

        row_number() over w                     as report_version,
        count(*)      over w_all                as n_reports,
        first_value(value)    over w            as first_reported_value,
        last_value(value)     over w_unbounded  as latest_reported_value,
        first_value(filed_date) over w          as first_filed_date,
        last_value(filed_date)  over w_unbounded as latest_filed_date

    from deduped
    window
        w as (
            partition by entity_id, concept, period_end
            order by filed_date, accession
        ),
        w_all as (
            partition by entity_id, concept, period_end
        ),
        w_unbounded as (
            partition by entity_id, concept, period_end
            order by filed_date, accession
            rows between unbounded preceding and unbounded following
        )

)

select
    entity_id,
    ticker,
    company_name,
    concept,
    source_tag,
    period_start,
    period_end,
    period_fiscal_year,
    filed_date,
    filing_lag_days,
    form,
    accession,
    value,
    report_version,
    n_reports,
    first_reported_value,
    latest_reported_value,
    first_filed_date,
    latest_filed_date,

    report_version = 1                  as is_first_report,
    filed_date = latest_filed_date      as is_latest_report,

    -- How far the figure moved between first and final telling.
    case
        when first_reported_value is null or first_reported_value = 0 then null
        else (latest_reported_value - first_reported_value)
             / abs(first_reported_value)
    end                                 as restatement_pct,

    case
        when first_reported_value is null or first_reported_value = 0 then false
        -- 0.5% tolerance absorbs rounding and presentation changes
        else abs(latest_reported_value - first_reported_value)
             / abs(first_reported_value) > 0.005
    end                                 as was_restated

from versioned
