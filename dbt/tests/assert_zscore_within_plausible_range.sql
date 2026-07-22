-- Coarse sanity bound. Originally set at [-30, 50] from the 23-company pilot
-- — comfortably below that bound is exactly what caught the LKNCY ADR/
-- share-count bug (Z=55.9, see assert_20f_filers_excluded_from_zscore.sql).
--
-- Scaling to the S&P 500 broke that assumption: NVDA, PLTR, TPL, ISRG and
-- MPWR all legitimately score 50-195. Checked, not assumed — their
-- total_liabilities/total_assets ratios are entirely ordinary (10-25%), so
-- this isn't a near-zero-denominator numerical artifact the way the LKNCY
-- case was. It's simpler than that: X4 is market value of equity / total
-- liabilities, and these are some of the most richly-valued companies in the
-- market relative to a completely normal liability base — the market is
-- pricing in decades of expected growth that a 1968 model calibrated on
-- capital-intensive manufacturers was never built to represent. Real,
-- correctly-computed, extreme data, not a bug.
--
-- The bound below is widened to give that real behaviour headroom while
-- still catching what actually indicates a bug: an orders-of-magnitude scale
-- error (a units mismatch, a forgotten /1e6, an ADR-style share-count
-- mismatch), not "a very successful company." Treat a failure here as a
-- prompt to check the specific company's fundamentals the way NVDA/PLTR/TPL
-- were checked above, not as an automatic bug — but don't skip that check.
select *
from {{ ref('fct_altman_zscore') }}
where z_score is not null
  and (z_score < -50 or z_score > 500)
