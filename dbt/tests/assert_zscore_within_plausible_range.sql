-- Coarse sanity bound, and the backstop that would have caught the LKNCY
-- ADR/share-count bug (Z=55.9) before it needed a manual audit to find.
-- Asset-light, richly-valued companies can legitimately reach the high
-- teens (Adobe hits ~17 in this pilot); real operating companies essentially
-- never go beyond this bound. Anything outside it almost certainly means a
-- units/share-count mismatch, not a genuinely extreme company.
select *
from {{ ref('fct_altman_zscore') }}
where z_score is not null
  and (z_score < -30 or z_score > 50)
