-- red_flag_count and models_scored are both derived by summing three
-- booleans-or-null (m_score_flag, z_score_flag, f_score_flag), so each must
-- land in [0, 3] and red_flag_count can never exceed models_scored -- a
-- violation here would mean the null-tolerant coalesce()/is-not-null logic
-- in fct_dashboard.sql has come apart (e.g. counting a model that actually
-- had no score, or double-counting one that did).
select *
from {{ ref('fct_dashboard') }}
where red_flag_count < 0 or red_flag_count > 3
   or models_scored < 0 or models_scored > 3
   or red_flag_count > models_scored
