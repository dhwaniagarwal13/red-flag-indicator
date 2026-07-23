-- GICS sector per ticker, straight from data/universe/sp500.csv
-- (redflag.fetch_sp500, scraped from Wikipedia's S&P 500 constituent table).
--
-- Read directly rather than copied into dbt/seeds, matching stg_facts /
-- stg_prices: it's a generated artefact, not something dbt owns or
-- hand-edits, and copying it would just be a second place for it to go
-- stale. Coverage is necessarily S&P-500-only -- case-study tickers that
-- have never been or are no longer index members (LKNCY, NKLA, BHC, HTZ)
-- get no sector here and are left null downstream, not guessed at.

select
    upper(ticker) as ticker,
    gics_sector

from read_csv_auto(
    '{{ env_var("REDFLAG_ROOT", "..") }}/data/universe/sp500.csv',
    header = true
)
