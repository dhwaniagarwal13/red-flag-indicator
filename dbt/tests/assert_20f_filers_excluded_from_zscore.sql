-- Regression test for the ADR/share-count mismatch found via Luckin Coffee
-- (see fct_altman_zscore.sql header — it produced a Z-Score of 55.9 for an
-- admitted fraud before this fix). The exclusion is structural (any 20-F
-- filer, not a Luckin-specific patch), so this should hold for any foreign
-- private issuer this pilot or a future universe expansion ever includes.
select z.*
from {{ ref('fct_altman_zscore') }} z
join (
    select distinct entity_id
    from {{ ref('fct_financials_pit') }}
    where form in ('20-F', '20-F/A')
) ff using (entity_id)
where z.market_value_of_equity is not null
   or z.z_score is not null
