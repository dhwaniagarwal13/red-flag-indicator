-- Coarse sanity bound. Originally [-15, 15] from the 23-company pilot.
--
-- Scaling to the S&P 500 broke that assumption too: Carnival (CCL, FY2022,
-- -21.7) and Norwegian Cruise Line (NCLH, FY2021, +98.2) both blow past it.
-- Root cause, checked not assumed: both are cruise operators whose revenue
-- collapsed to near-zero during COVID-era shutdowns. Several of the 8
-- Beneish indices are year-over-year *ratios of ratios* (DSRI, GMI); when the
-- prior year's revenue sits near zero in the denominator of one of those
-- inner ratios, the composite index — and therefore the whole score — can
-- swing to an extreme, real value with no data error involved. This is a
-- known, documented weakness of ratio-based accounting formulas applied
-- across a near-total revenue disruption, not specific to this pipeline.
--
-- The bound below gives that real behaviour headroom while still catching
-- what actually indicates a bug: an orders-of-magnitude scale error, not "a
-- company that lived through 2020." A failure here is a prompt to check the
-- specific company the way CCL/NCLH were checked (was there a real,
-- near-zero-revenue year in the comparison?), not an automatic bug.
select *
from {{ ref('fct_beneish_mscore') }}
where m_score is not null
  and (m_score < -50 or m_score > 150)
