-- Every reported fact, cleaned but not yet deduplicated.
--
-- Two corrections happen here, both of which matter more than they look:
--
-- 1. `fiscal_year` as returned by the SEC is the fiscal year of the *filing
--    document*, not of the period the fact describes. A FY2022 figure appearing
--    as a comparative in the FY2024 10-K carries fy=2024. Grouping on it silently
--    mixes periods. We derive the period's own fiscal year from `period_end`.
--
-- 2. Duration facts (revenue, net income) arrive at mixed frequencies — annual,
--    quarterly, and occasionally odd stub periods. We classify by day count
--    rather than trusting `fiscal_period`, which filers populate inconsistently.

with raw as (

    select *
    from read_parquet('{{ var("staging_path", "../data/staging/facts.parquet") }}')

),

typed as (

    select
        entity_id,
        ticker,
        company_name,
        concept,
        source_tag,
        tag_priority,
        unit,
        cast(period_start as date)              as period_start,
        cast(period_end   as date)              as period_end,
        cast(filed_date   as date)              as filed_date,
        form,
        accession,
        cast(value as double)                   as value,

        -- the period's own fiscal year, not the filing's
        year(cast(period_end as date))          as period_fiscal_year,

        case
            when period_start is null then null
            else date_diff('day', cast(period_start as date), cast(period_end as date))
        end                                     as period_days

    from raw
    where value is not null
      and period_end is not null
      and filed_date is not null

),

classified as (

    select
        *,
        case
            when period_days is null            then 'instant'
            when period_days between 350 and 380 then 'annual'
            when period_days between 80  and 100 then 'quarter'
            when period_days between 170 and 195 then 'half'
            when period_days between 260 and 285 then 'three_quarter'
            else 'other'
        end as period_type,

        date_diff('day', period_end, filed_date) as filing_lag_days

    from typed

)

select *
from classified
where period_fiscal_year >= {{ var("min_fiscal_year") }}
  -- A fact filed before the period it describes has ended is impossible;
  -- such rows indicate a tagging error and would poison point-in-time logic.
  and filing_lag_days >= {{ var("min_filing_lag_days") }}
