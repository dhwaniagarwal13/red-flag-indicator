-- Sign-normalisation regression test (Phase 1b). Concepts flagged
-- sign_convention='always_positive' in the concepts seed (cogs, sga,
-- depreciation_amortisation, gross interest_expense) are abs()'d in
-- stg_facts.sql. This should return zero rows; a non-empty result means the
-- normalisation broke.
select *
from {{ ref('stg_facts') }}
where sign_convention = 'always_positive'
  and value < 0
