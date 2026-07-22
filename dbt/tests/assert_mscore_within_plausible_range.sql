-- Coarse sanity bound, not a precision check: a real Beneish M-Score should
-- essentially never fall outside roughly [-15, 15] for an operating company.
-- Anything beyond that almost certainly means a formula sign error or a unit
-- mismatch slipped through, not a genuinely extreme company.
select *
from {{ ref('fct_beneish_mscore') }}
where m_score is not null
  and (m_score < -15 or m_score > 15)
