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
-- The gap between them is not automatically noise — but it is not
-- automatically signal either. Phase 1 computed it across ALL filings for a
-- period regardless of which XBRL tag reported the value, which produced
-- three confirmed false positives: Hertz's interest expense appeared to swing
-- from +70M to −608M purely because a later filing switched from the gross
-- `InterestExpense` tag to the net `InterestIncomeExpenseNet` tag — two
-- economically different figures, not a restatement. Phase 1b fixes this by
-- computing `restatement_pct` only across filings that used the SAME tag
-- (see `in_lineage` below), and surfacing tag changes as their own signal
-- (`tag_switch_detected`) instead of letting them masquerade as a value
-- change. Concepts prone to non-accounting-driven swings (share counts move
-- on stock splits) are marked `restatement_eligible = false` upstream in the
-- concepts seed and carried through here rather than silently dropped, so
-- consumers can decide whether to include them.
--
-- Genuine restatements survive this fix intact: GE's operating cash flow
-- moved from -244M to 1160M for FY2016 under the SAME tag across three
-- filings — that is GE's real, documented 2018-19 accounting restatement,
-- and it still shows up here.

-- Balance-sheet concepts (total_assets, receivables, ...) are XBRL *instant*
-- facts — an as-of-a-date snapshot with no duration — so period_type
-- classifies them 'instant', never 'annual'. The original version of this
-- model assumed any instant fact surviving the form filter (10-K/20-F) was,
-- by construction, a genuine fiscal-year-end snapshot. Kraft Heinz proved
-- that assumption wrong: its 10-Ks include a supplementary quarterly-data
-- table (a common post-merger recast disclosure — KHC merged with Heinz in
-- 2015), so instant facts dated at quarter-ends (2017-04-01, 2017-07-01, ...)
-- were being accepted as if they were annual snapshots, producing up to 16
-- spurious "period" rows for a single real fiscal year. Anchoring instant
-- facts to a period_end that a genuine annual *duration* fact (already
-- correctly restricted to 350-380-day periods) also reports for the same
-- filing fixes this: a quarter-end date with no matching annual duration fact
-- in the same accession is excluded.
with annual_period_ends as (

    select distinct entity_id, accession, period_end
    from {{ ref('stg_facts') }}
    where period_type = 'annual'
      and form in ('10-K', '10-K/A', '20-F', '20-F/A')

),

annual as (

    select sf.*
    from {{ ref('stg_facts') }} sf
    where sf.form in ('10-K', '10-K/A', '20-F', '20-F/A')
      and sf.unit in ('USD', 'shares')
      and (
            sf.period_type = 'annual'
            or (
                sf.period_type = 'instant'
                and exists (
                    select 1
                    from annual_period_ends ape
                    where ape.entity_id   = sf.entity_id
                      and ape.accession   = sf.accession
                      and ape.period_end  = sf.period_end
                )
            )
          )

),

-- Where several acceptable tags appear in the same filing for the same
-- concept, most concepts are *alternatives* (a filer uses one or the other,
-- never both) — keep the highest-priority one present (see concepts.py).
deduped_best as (

    select
        entity_id, ticker, company_name, concept, source_tag, tag_priority,
        unit, period_start, period_end, period_fiscal_year, filed_date, form,
        accession, value, restatement_eligible, sign_was_negative, filing_lag_days
    from (
        select
            *,
            row_number() over (
                partition by entity_id, concept, period_end, accession
                order by tag_priority asc, value desc
            ) as rn
        from annual
        where combine_mode = 'best'
    )
    where rn = 1

),

-- A few concepts (currently: cogs) instead see genuine *components* tagged
-- side by side in the same filing — six companies in this pilot (GE,
-- Honeywell, Lockheed, Cisco, Adobe, Bausch) split cost of revenue into
-- CostOfGoodsSold + CostOfServices as two simultaneous line items. Picking
-- one (the deduped_best approach) silently discards the other and understates
-- the total. Sum every distinct tag present instead. source_tag becomes a
-- synthetic label ("CostOfGoodsSold+CostOfServices") — this is deliberate: if
-- a company later switches to reporting one combined tag instead of the split
-- pair, that's a genuine presentation change and should still surface as a
-- tag switch downstream, not be silently absorbed as if nothing happened.
deduped_sum as (

    select
        entity_id,
        any_value(ticker)                                         as ticker,
        any_value(company_name)                                   as company_name,
        concept,
        string_agg(distinct source_tag, '+' order by source_tag)  as source_tag,
        min(tag_priority)                                         as tag_priority,
        any_value(unit)                                           as unit,
        any_value(period_start)                                   as period_start,
        period_end,
        any_value(period_fiscal_year)                             as period_fiscal_year,
        any_value(filed_date)                                     as filed_date,
        any_value(form)                                           as form,
        accession,
        sum(tag_value)                                            as value,
        any_value(restatement_eligible)                           as restatement_eligible,
        bool_or(sign_was_negative)                                as sign_was_negative,
        any_value(filing_lag_days)                                as filing_lag_days
    from (
        -- Collapse exact duplicate rows per tag first, so a repeated fact
        -- (shouldn't happen, but don't trust it blindly) can't double-count.
        select
            entity_id, concept, period_end, accession, source_tag,
            ticker, company_name, unit, period_start, period_fiscal_year,
            filed_date, form, tag_priority, restatement_eligible, filing_lag_days,
            max(value)                 as tag_value,
            bool_or(sign_was_negative) as sign_was_negative
        from annual
        where combine_mode = 'sum'
        group by
            entity_id, concept, period_end, accession, source_tag,
            ticker, company_name, unit, period_start, period_fiscal_year,
            filed_date, form, tag_priority, restatement_eligible, filing_lag_days
    )
    group by entity_id, concept, period_end, accession

),

deduped as (

    select * from deduped_best
    union all
    select * from deduped_sum

),

-- The tag used in the most recent filing for each (company, concept, period)
-- is treated as the "current" definition. Earlier filings that used a
-- different tag are real data — kept in the output — but excluded from the
-- restatement comparison below because they are not describing the same
-- thing.
tag_lineage as (

    select entity_id, concept, period_end, source_tag as latest_tag
    from (
        select
            entity_id, concept, period_end, source_tag,
            row_number() over (
                partition by entity_id, concept, period_end
                order by filed_date desc, accession desc
            ) as rn
        from deduped
    )
    where rn = 1

),

tag_counts as (

    select entity_id, concept, period_end, count(distinct source_tag) as n_distinct_tags
    from deduped
    group by 1, 2, 3

),

with_lineage as (

    select
        d.*,
        tl.latest_tag,
        tc.n_distinct_tags,
        d.source_tag = tl.latest_tag as in_lineage
    from deduped d
    join tag_lineage tl using (entity_id, concept, period_end)
    join tag_counts  tc using (entity_id, concept, period_end)

),

-- Restatement stats computed only within the in-lineage subsequence.
lineage_stats as (

    select
        entity_id,
        concept,
        period_end,
        accession,
        row_number() over w                      as report_version,
        count(*)      over w_all                 as n_reports,
        first_value(value)      over w           as first_reported_value,
        last_value(value)       over w_unbounded as latest_reported_value,
        first_value(filed_date) over w           as first_filed_date,
        last_value(filed_date)  over w_unbounded as latest_filed_date
    from with_lineage
    where in_lineage
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

),

-- period_fiscal_year assumes one real annual period per company per label —
-- true almost always, false for a company whose fiscal year end genuinely
-- changed mid-history. L3Harris (LHX) is the clean example: Harris Corp
-- reported on a June 30 fiscal year through FY2019, then filed a real ~6-month
-- transition report ending 2020-01-03 to move onto a calendar-year basis —
-- both period_end dates are genuine, meaningful annual-ish periods, and both
-- naturally land under period_fiscal_year=2019. Fewer than ten companies in a
-- 500-company universe hit this (also seen as a much smaller, ~1-day version
-- of the same symptom — an XBRL instant tagged one day off a duration fact's
-- period_end, e.g. Deere's FY2016 ppe_net at 2016-10-31 vs. every other
-- FY2016 concept at 2016-10-30 — most likely inconsistent context-date
-- authoring between filings, not a second real period). Either way, without
-- a fix this produces two is_first_report rows for one company-year, which
-- fans out into duplicate rows in every model that self-joins year-over-year.
--
-- No date-arithmetic rule can correctly split a genuine fiscal-year change
-- into two distinct labels — there is no calendar-based way to know that
-- "2019" should sometimes mean two different real periods for one company.
-- Instead this picks exactly one canonical period_end per (entity,
-- period_fiscal_year): whichever date the *most other concepts* for that
-- company-year also report against, tie-broken toward the later date. The
-- losing period stays fully present in this table under its own period_end —
-- nothing is deleted — it just doesn't carry is_first_report for that label,
-- so it won't feed the scoring models' year-over-year pivots. For a
-- fiscal-year-change company this means one of the two real periods for the
-- transition year is invisible to M-Score/Z-Score/F-Score; documented as a
-- known limitation rather than silently dropped.
period_end_support as (

    select
        wl.entity_id,
        wl.period_fiscal_year,
        wl.period_end,
        count(distinct wl.concept) as n_concepts
    from with_lineage wl
    join lineage_stats ls
        using (entity_id, concept, period_end, accession)
    where ls.report_version = 1
    group by wl.entity_id, wl.period_fiscal_year, wl.period_end

),

canonical_period_end as (

    select entity_id, period_fiscal_year, period_end as canonical_period_end
    from (
        select
            *,
            row_number() over (
                partition by entity_id, period_fiscal_year
                order by n_concepts desc, period_end desc
            ) as rn
        from period_end_support
    )
    where rn = 1

)

select
    wl.entity_id,
    wl.ticker,
    wl.company_name,
    wl.concept,
    wl.source_tag,
    wl.period_start,
    wl.period_end,
    wl.period_fiscal_year,
    wl.filed_date,
    wl.filing_lag_days,
    wl.form,
    wl.accession,
    wl.value,
    wl.restatement_eligible,
    wl.sign_was_negative,

    wl.latest_tag,
    wl.n_distinct_tags,
    wl.in_lineage,
    wl.n_distinct_tags > 1                       as tag_switch_detected,

    ls.report_version,
    ls.n_reports,
    ls.first_reported_value,
    ls.latest_reported_value,
    ls.first_filed_date,
    ls.latest_filed_date,

    ls.report_version = 1
        and wl.period_end = cpe.canonical_period_end   as is_first_report,
    wl.filed_date = ls.latest_filed_date               as is_latest_report,

    -- How far the figure moved between first and final telling, WITHIN the
    -- current tag's lineage only. Null for out-of-lineage rows (no comparison
    -- was computed for them) and for concepts flagged non-eligible upstream.
    case
        when not wl.in_lineage then null
        when ls.first_reported_value is null or ls.first_reported_value = 0 then null
        else (ls.latest_reported_value - ls.first_reported_value)
             / abs(ls.first_reported_value)
    end                                           as restatement_pct,

    case
        when not wl.in_lineage then false
        when ls.first_reported_value is null or ls.first_reported_value = 0 then false
        -- 0.5% tolerance absorbs rounding and presentation changes
        else abs(ls.latest_reported_value - ls.first_reported_value)
             / abs(ls.first_reported_value) > 0.005
    end                                           as was_restated

from with_lineage wl
left join lineage_stats ls
    using (entity_id, concept, period_end, accession)
left join canonical_period_end cpe
    using (entity_id, period_fiscal_year)
