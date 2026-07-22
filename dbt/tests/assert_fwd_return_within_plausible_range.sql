-- Coarse sanity bound on fct_accrual_returns.fwd_return_12m. A stock can't
-- lose more than 100% (-1.0); a bound of 10x (+1000%) comfortably covers even
-- a genuine multi-bagger single-name year without being wide enough to miss
-- the kind of bug this pattern has caught before (Apple's split-adjusted-
-- price-vs-unadjusted-share-count bug in fct_altman_zscore, and LKNCY's ADR
-- mismatch) -- both would show up here too, since a mispaired entry/exit
-- price ratio produces exactly this kind of order-of-magnitude artifact.
select *
from {{ ref('fct_accrual_returns') }}
where fwd_return_12m is not null
  and (fwd_return_12m < -1.0 or fwd_return_12m > 10.0)
