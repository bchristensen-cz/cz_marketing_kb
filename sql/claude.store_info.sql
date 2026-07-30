-- claude.store_info
-- Authorized view exposing the store dimension to standard users.
--
-- Why it exists: `sales_ops.store_info` is the only source of store geography, and it was
-- not exposed in the `claude` interface layer. That made every "by market", "by state",
-- or "by city" question unanswerable for a standard user — the dimension simply wasn't
-- reachable (found 2026-07-30 while testing a real user question).
--
-- The `claude` dataset is authorized on `sales_ops` at the DATASET level
-- (targetTypes: VIEWS), so this view inherits access with no extra grant.
--
-- Divergences from the `sales_ops` parent — documented, deliberate, and stated in
-- data_dictionaries/claude.store_info.md:
--   1. `market` is added as an explicit alias of `store_state`. "Market" is the word
--      users say; putting it in the schema makes the canonical mapping impossible to
--      get wrong.
--   2. Three non-store rows are dropped: store_id 0 (`Company`, every field blank —
--      the source of the nameless group in any geography breakdown), 901 (`Zupas Lab2`)
--      and 9001 (`Zupas automation test`). All three carried zero orders.
--      Store 101 (Corporate) and 113/114 (mall kiosks) are KEPT — they are real
--      locations with real addresses.
--   3. Store 1111 (test/training) is absent from the parent table entirely, so it is
--      absent here too. Keep the explicit `store_id <> 1111` filter on the fact table
--      regardless — a left join or an unjoined query still lets it through.
--
-- Deployed 2026-07-30.

create or replace view `marketing-data-442316`.claude.store_info as
select
  si.store_id
, si.store_name
, si.store_short_name
, si.store_address
, si.store_city
, si.store_state
, si.store_state as market
, si.store_zip
, si.store_open_date
, si.is_comp_store
, si.latitude
, si.longitude
, si.weather_cluster_id
, si.timezone_name
from `marketing-data-442316`.sales_ops.store_info si
where 1=1
and si.store_id not in (0, 901, 9001)
