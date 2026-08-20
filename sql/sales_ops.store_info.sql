-- Build/maintenance script: `marketing-data-442316`.sales_ops.store_info
-- Scheduled query, runs every 24 hours.
-- Grain: one row per store id. The store dimension.
-- Documentation: data_dictionaries/sales_ops.store_info.md
--
-- Source feed is `staging.store_info`, which carries only 8 columns:
--   store_id, store_name, store_address, store_city, store_state, store_zip,
--   store_phone, is_comp_store
-- Everything else on this table is DERIVED here. Any derived column missing from
-- this script is a column that stays NULL forever on every new store, which is how
-- timezone_name went missing on 6 stores and silently NULLed order_timestamp_utc
-- (Asana 1217684772713570).
--
-- DELIBERATE: store_name, store_address, store_city, store_state and store_zip are
-- INSERT-ONCE. Nothing below re-syncs them from staging. That is what makes the
-- 2026-08-20 cleanup stick - 8 street addresses normalised, store 191 renamed
-- 'Zupas San Tan Valley' -> 'Zupas San Tan Village'. The staging feed is STILL dirty
-- (city/state/zip embedded in the street field, POS abbreviations, store 194 carrying
-- the wrong zip). Do NOT add an address sync from staging without cleaning staging
-- first, or it will overwrite the corrections.
--
-- Statement order matters: all maintenance runs first, all guards run last, so a
-- failing assert never prevents the statements below it from completing.

-- 1) New stores from the staging feed.
--    store_phone: staging holds '801-613-3380', so a bare safe_cast to INT64 returns
--    NULL - measured 2026-08-20, it would blank the phone on 82 of 100 staging rows.
--    Strip non-digits first; that reproduces the existing sales_ops values exactly.
INSERT INTO `marketing-data-442316`.sales_ops.store_info
(store_id, store_name, store_address, store_city, store_state, store_zip, store_phone, is_comp_store)
select
s.store_id
, s.store_name
, s.store_address
, s.store_city
, s.store_state
, cast(s.store_zip as string)
, safe_cast(regexp_replace(s.store_phone, r'[^0-9]', '') as int64)
, s.is_comp_store
from `marketing-data-442316.staging.store_info` s
	left join `marketing-data-442316`.sales_ops.store_info ss
	on ss.store_id = s.store_id
where 1=1
and ss.store_id is null
;

-- 2) Comp-store status can change; keep it in sync with the feed.
--    `is distinct from` rather than `<>` so the sync still fires if either side is NULL
--    (0 NULLs on both sides as of 2026-08-20, so this is latent, not a live bug).
UPDATE `marketing-data-442316`.sales_ops.store_info t
SET is_comp_store = s.is_comp_store
FROM `marketing-data-442316`.staging.store_info s
WHERE t.store_id = s.store_id
AND t.is_comp_store is distinct from s.is_comp_store
;

-- 3) store_open_date: first business date with more than 150 orders. Self-healing,
--    is-null only. Needs a few days of trading before it fires.
--    The 400-day bound takes this from 1.14 GiB to 0.21 GiB per run (dry-run measured
--    2026-08-20) and stops the script from carrying an unbounded scan of a 50M-row
--    partitioned table. Safe because a store missing an open date is by definition new:
--    verified 2026-08-20 that of the 10 stores with a NULL store_open_date, only 192
--    has any orders in 400 days (12 orders, max 11/day), and Corporate 101 plus kiosks
--    113/114 have zero, so the >150 threshold can never fire for them.
--    ⚠️ If a LONG-OPEN store ever turns up with a NULL open date, this bound would stamp
--    it with the window edge instead of its real first day. Re-check before widening.
UPDATE `marketing-data-442316`.sales_ops.store_info s
SET store_open_date=soc.store_open_date
from (
  select oc.store_id, oc.business_date as store_open_date, count(oc.brink_order_id) as order_count
  , row_number() over(partition by oc.store_id order by oc.business_date) as rn
  from `marketing-data-442316.sales_ops.order_customer` oc
    join `marketing-data-442316`.sales_ops.store_info ss
    on ss.store_id = oc.store_id
    and ss.store_open_date is null
  where 1=1
  and oc.business_date >= date_sub(current_date('America/Denver'), interval 400 day)
  group by 1,2
  having count(oc.brink_order_id) > 150
) soc
where 1=1
and soc.store_id = s.store_id
and soc.rn = 1
;

-- 4) timezone_name / store_tz. staging.store_info has no timezone column, so this must
--    be derived. State -> IANA is 1:1 for every state Cafe Zupas operates in (verified
--    2026-08-20 across 98 real stores). Split-timezone states are deliberately ABSENT
--    from this map so a store there stays NULL and trips the assert below, rather than
--    being guessed an hour wrong: north Idaho is Pacific, El Paso is Mountain, and
--    Oregon, the Dakotas, Kansas, Nebraska, Florida, Michigan, Indiana, Kentucky and
--    Tennessee are all split. A wrong-but-populated timezone is worse than a NULL,
--    because order_timestamp_utc then looks fine and is silently off by an hour.
UPDATE `marketing-data-442316`.sales_ops.store_info t
SET
  timezone_name = m.timezone_name
, store_tz = m.store_tz
from (
              select 'Utah'      as store_state, 'America/Denver'      as timezone_name, 'MDT' as store_tz
  union all   select 'Idaho'                   , 'America/Denver'                      , 'MDT'
  union all   select 'Arizona'                 , 'America/Phoenix'                     , 'MST'
  union all   select 'Nevada'                  , 'America/Los_Angeles'                 , 'PT'
  union all   select 'Illinois'                , 'America/Chicago'                     , 'CT'
  union all   select 'Minnesota'               , 'America/Chicago'                     , 'CT'
  union all   select 'Wisconsin'               , 'America/Chicago'                     , 'CT'
  union all   select 'Texas'                   , 'America/Chicago'                     , 'CT'
  union all   select 'Ohio'                    , 'America/New_York'                    , 'ET'
) m
where 1=1
and m.store_state = t.store_state
and t.timezone_name is null
;

-- 5) weather_cluster_id: nearest metro cluster centroid. Keyed on the store's own
--    lat/long where it has one, else the ZIP centroid from bigquery-public-data, so
--    cluster assignment never waits on the geocoding backlog. Is-null only, so no
--    existing assignment is ever restated.
--
--    Verified 2026-08-20: reproduces 87 of 87 existing assignments once cluster 12
--    ('Unassigned (53005)', a hand-made cluster of one at Brookfield WI) is excluded as
--    a candidate. Leave that exclusion in place until 53005 is folded into cluster 4 -
--    without it, Menomonee Falls (10.3 mi) and Greenfield (7.4 mi) both get pulled into
--    the placeholder instead of the Chicago/Milwaukee Corridor (Asana 1217699704979785).
--
--    Known weakness: cluster 4 spans Illinois AND Wisconsin, so its centroid sits near
--    Chicago and nothing in Milwaukee's outskirts is close to it. Store 194 (Oconomowoc)
--    would derive to cluster 8 'Madison' at 47.9 mi; it keeps its hand-assigned cluster 4
--    only because this statement is is-null only. Splitting that corridor cluster would
--    make the derivation trustworthy for the whole Milwaukee area.
--
--    A store whose store_zip does not resolve in geo_us_boundaries.zip_codes and has no
--    geocode stays NULL here. That is intentional and guard 6b is what catches it.
UPDATE `marketing-data-442316`.sales_ops.store_info t
SET weather_cluster_id = d.cluster_id
from (
  with centroids as (
    select
      z.cluster_id
    , any_value(z.cluster_lat) as c_lat
    , any_value(z.cluster_lon) as c_lon
    from `marketing-data-442316`.marketing_ops.zip_weather_cluster z
    where 1=1
    and z.cluster_id <> 12
    group by z.cluster_id
  )
  select
    si.store_id
  , c.cluster_id
  from `marketing-data-442316`.sales_ops.store_info si
      left join `bigquery-public-data`.geo_us_boundaries.zip_codes pz
      on pz.zip_code = si.store_zip
    cross join centroids c
  where 1=1
  and si.weather_cluster_id is null
  and si.store_id not in (0, 901, 9001)
  and coalesce(si.latitude, st_y(pz.internal_point_geom)) is not null
  qualify row_number() over(
            partition by si.store_id
            order by st_distance(
                       st_geogpoint(coalesce(si.longitude, st_x(pz.internal_point_geom))
                                  , coalesce(si.latitude , st_y(pz.internal_point_geom)))
                     , st_geogpoint(c.c_lon, c.c_lat))
          ) = 1
) d
where 1=1
and d.store_id = t.store_id
;

-- ============================================================================
-- 6) GUARDS. Deliberately last, so every statement above completes even when a guard
--    fails. A failing assert marks the scheduled run as failed; that is the point.
--    All three are scoped to stores that took an order in the last 7 days, so a
--    pre-opening store, a retired kiosk or the Corporate row never reddens the run
--    (Corporate 101 and kiosks 113/114 have had zero orders in 400 days).
-- ============================================================================

-- 6a) A trading store must have a timezone, or order_timestamp_utc is NULL for every
--     order it takes and it vanishes silently from all Braze / UTC analysis.
assert (
  select count(*) = 0
  from `marketing-data-442316`.sales_ops.store_info s
  where 1=1
  and s.timezone_name is null
  and s.store_id not in (0, 901, 9001)
  and exists (
        select 1
        from `marketing-data-442316`.sales_ops.order_customer oc
        where 1=1
        and oc.store_id = s.store_id
        and oc.business_date >= date_sub(current_date('America/Denver'), interval 7 day)
      )
) as 'store_info: a trading store has a NULL timezone_name -> order_timestamp_utc is NULL for every order it takes. Add its state to the timezone map in step 4, or resolve it by city if it sits in a split-timezone state.'
;

-- 6b) A trading store must have a weather cluster.
assert (
  select count(*) = 0
  from `marketing-data-442316`.sales_ops.store_info s
  where 1=1
  and s.weather_cluster_id is null
  and s.store_id not in (0, 901, 9001)
  and exists (
        select 1
        from `marketing-data-442316`.sales_ops.order_customer oc
        where 1=1
        and oc.store_id = s.store_id
        and oc.business_date >= date_sub(current_date('America/Denver'), interval 7 day)
      )
) as 'store_info: a trading store has a NULL weather_cluster_id. Check that its store_zip resolves in bigquery-public-data.geo_us_boundaries.zip_codes, and that the zip is actually right for the city.'
;

-- 6c) A trading store must have coordinates. This one CANNOT be auto-repaired - staging
--     carries no coordinate column and the ZIP centroid is up to 70 miles off - so it is
--     a prompt for a human geocode. Method and the confidence check (an exact Google Maps
--     /maps/place/ match versus a /maps/search/ viewport fallback) are in the dictionary.
assert (
  select count(*) = 0
  from `marketing-data-442316`.sales_ops.store_info s
  where 1=1
  and s.latitude is null
  and s.store_id not in (0, 901, 9001)
  and exists (
        select 1
        from `marketing-data-442316`.sales_ops.order_customer oc
        where 1=1
        and oc.store_id = s.store_id
        and oc.business_date >= date_sub(current_date('America/Denver'), interval 7 day)
      )
) as 'store_info: a trading store has a NULL latitude/longitude. Geocode its address and write it in - BigQuery cannot derive this.'
;
