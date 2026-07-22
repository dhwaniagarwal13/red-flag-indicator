-- Daily close prices, typed and deduplicated. See redflag/sources/prices.py
-- for why this is the split-adjusted-but-not-dividend-adjusted "Close"
-- column specifically, and why it must be paired with
-- fct_financials_pit.latest_reported_value (not .value) for shares_diluted —
-- both are on the same current-share-count basis; mixing an adjusted price
-- with an as-originally-filed share count would misstate market cap by
-- whatever split ratio occurred since.

select
    ticker,
    cast(date as date) as price_date,
    cast(close as double) as close
from read_parquet('{{ env_var("REDFLAG_ROOT", "..") }}/data/staging/prices.parquet')
where close is not null
