-- Build/maintenance script: `marketing-data-442316.sales_ops.store_info`
-- Scheduled query, runs every 24 hours.
-- Grain: one row per store id. The store dimension. Guard 7a enforces it.
-- Documentation: data_dictionaries/sales_ops.store_info.md
--
-- Source feed is `brink.gblStore`. It supplies only:
--   StoreId, Name, Address, City, State, Zipcode, StorePhone
-- Everything else on this table is DERIVED here. Any derived column missing from
-- this script is a column that stays NULL forever on every new store, which is how
-- timezone_name went missing on 6 stores and silently NULLed order_timestamp_utc
-- (Asana 1217684772713570), and how store_short_name went missing on 7.
--
-- DELIBERATE: store_name, store_address, store_city, store_state and store_zip are
-- INSERT-ONCE. Nothing below re-syncs them from the feed. That is what makes the
-- 2026-08-20 cleanup stick - 8 street addresses normalised, store 191 renamed
-- 'Zupas San Tan Valley' -> 'Zupas San Tan Village'. The feed is STILL dirty
-- (city/state/zip embedded in the street field, POS abbreviations, store 194 carrying
-- the wrong zip). Do NOT add an address sync without cleaning the source first, or it
-- will overwrite the corrections.
--
-- Statement order matters: all maintenance runs first, all guards run last, so a
-- failing assert never prevents the statements below it from completing.

-- 1) New stores from the feed.
--    store_phone: gblStore.StorePhone is a STRING holding '801-613-3380', so a bare
--    safe_cast to INT64 returns NULL. Strip non-digits first; that reproduces the
--    existing sales_ops values exactly.
--    store_zip: gblStore.Zipcode is already STRING, so no cast is needed. Keep it that
--    way - an INT64 zip silently eats leading zeros and then fails the
--    geo_us_boundaries.zip_codes join in step 5.
insert into `marketing-data-442316.sales_ops.store_info`
  (store_id, store_name, store_address, store_city, store_state, store_zip, store_phone, is_comp_store)
select
  g.StoreId as store_id
  ,g.Name as store_name
  ,g.Address as store_address
  ,g.City as store_city
  ,g.State as store_state
  ,g.Zipcode as store_zip
  ,safe_cast(regexp_replace(g.StorePhone, r'[^0-9]', '') as int64) as store_phone
  ,0 as is_comp_store
from `marketing-data-442316.brink.gblStore` g
left join `marketing-data-442316.sales_ops.store_info` ss
  on ss.store_id = g.StoreId
where 1=1
  and ss.store_id is null
;

-- 2) is_comp_store / store_comp_date. A store goes comp on the first day of the year
--    following 18 months of trading, so this is derived from store_open_date, NOT read
--    from the feed. gblStore.IsCompStore is deliberately ignored.
--    `is distinct from` rather than `<>` so the sync still fires if either side is NULL
--    (0 NULLs on both sides as of 2026-08-20, so this is latent, not a live bug).
--    Note this reads store_open_date, which step 3 sets, so a brand-new store picks up
--    its comp date on the NEXT run. Harmless - comp dates land ~2.5 years out.
update `marketing-data-442316.sales_ops.store_info` t
set
  is_comp_store = s.is_comp_store
  ,store_comp_date = s.store_comp_date
from (
  select
    g.StoreId as store_id
    ,case when ss.store_open_date is null then 0
      when current_date() >= date_add(last_day(date_add(ss.store_open_date, interval 18 month), year), interval 1 day) then 1
      else 0
      end as is_comp_store
    ,case when ss.store_open_date is null then null
      else date_add(last_day(date_add(ss.store_open_date, interval 18 month), year), interval 1 day)
      end as store_comp_date
  from `marketing-data-442316.brink.gblStore` g
  left join `marketing-data-442316.sales_ops.store_info` ss
    on ss.store_id = g.StoreId
) s
where 1=1
  and t.store_id = s.store_id
  and (t.store_comp_date is distinct from s.store_comp_date
    or t.is_comp_store is distinct from s.is_comp_store)
;

-- 3) store_open_date: first business date with more than 150 orders. Self-healing,
--    is-null only. Needs a few days of trading before it fires.
--    row_number() is evaluated AFTER having, so rn = 1 is the first date that CLEARED
--    the 150 threshold, not the first date the store appears. Verified 2026-09-10.
--    The 400-day bound takes this from 1.14 GiB to 0.21 GiB per run (dry-run measured
--    2026-08-20) and stops the script from carrying an unbounded scan of a 51M-row
--    partitioned table. Safe because a store missing an open date is by definition new:
--    verified 2026-08-20 that of the stores with a NULL store_open_date, only 192 has
--    any orders in 400 days (12 orders, max 11/day), and Corporate 101 plus kiosks
--    113/114 have zero, so the >150 threshold can never fire for them.
--    WARNING: if a LONG-OPEN store ever turns up with a NULL open date, this bound would
--    stamp it with the window edge instead of its real first day. Re-check before widening.
update `marketing-data-442316.sales_ops.store_info` s
set store_open_date = soc.store_open_date
from (
  select
    oc.store_id
    ,oc.business_date as store_open_date
    ,count(oc.brink_order_id) as order_count
    ,row_number() over(partition by oc.store_id order by oc.business_date) as rn
  from `marketing-data-442316.sales_ops.order_customer` oc
  join `marketing-data-442316.sales_ops.store_info` ss
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

-- 4) timezone_name / store_tz. The feed has no timezone column, so this is derived from
--    state. Every state Cafe Zupas operates in gets a mapping - a trading store must
--    have a timezone or order_timestamp_utc is NULL for every order it takes.
--    Verified 2026-09-10: all 7 Idaho stores are southern (Boise, Meridian, Nampa,
--    Ammon, Rexburg = Mountain) and the single Texas store is McKinney/DFW (Central),
--    so the state-level mapping is correct for the current estate.
--    RE-CHECK THIS MAP when opening in a split-timezone state: northern Idaho is
--    Pacific, El Paso is Mountain, and Oregon, the Dakotas, Kansas, Nebraska, Florida,
--    Michigan, Indiana, Kentucky and Tennessee are all split. Add a city-level row
--    rather than letting the state default guess an hour wrong.
update `marketing-data-442316.sales_ops.store_info` t
set
  timezone_name = m.timezone_name
  ,store_tz = m.store_tz
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
--    Chicago and nothing in Milwaukee's outskirts is close to it. Stores 185 and 194 both
--    sit in placeholder cluster 12 today and would re-derive elsewhere (194 Oconomowoc to
--    cluster 8 'Madison' at 47.9 mi, 185 to cluster 4); they keep 12 only because this
--    statement is is-null only. Splitting that corridor cluster would make the derivation
--    trustworthy for the whole Milwaukee area.
--    Re-verified 2026-09-10: the single-source point below reproduces 96 of 98 existing
--    assignments; the only 2 misses are 185 and 194, i.e. the cluster-12 holders above.
--
--    The point is built from ONE source - the store's own geocode when it has both
--    coordinates, otherwise the ZIP centroid. Never mix a real latitude with a ZIP
--    longitude. A store whose zip does not resolve and has no geocode stays NULL here;
--    that is intentional and guards 7c/7d are what catch it.
update `marketing-data-442316.sales_ops.store_info` t
set weather_cluster_id = d.cluster_id
from (
  with centroids as (
    select
      z.cluster_id
      ,any_value(z.cluster_lat) as c_lat
      ,any_value(z.cluster_lon) as c_lon
    from `marketing-data-442316.marketing_ops.zip_weather_cluster` z
    where 1=1
      and z.cluster_id <> 12
    group by z.cluster_id
  )
  ,store_point as (
    select
      si.store_id
      ,case when si.latitude is not null and si.longitude is not null
        then st_geogpoint(si.longitude, si.latitude)
        else pz.internal_point_geom
        end as geo
    from `marketing-data-442316.sales_ops.store_info` si
    left join `bigquery-public-data.geo_us_boundaries.zip_codes` pz
      on pz.zip_code = si.store_zip
    where 1=1
      and si.weather_cluster_id is null
      and si.store_id not in (0, 901, 9001)
  )
  select
    sp.store_id
    ,c.cluster_id
  from store_point sp
  cross join centroids c
  where 1=1
    and sp.geo is not null
  qualify row_number() over(
            partition by sp.store_id
            order by st_distance(sp.geo, st_geogpoint(c.c_lon, c.c_lat))
          ) = 1
) d
where 1=1
  and d.store_id = t.store_id
;

-- 6) store_short_name: store_name with the leading 'Zupas ' stripped. Derived rather
--    than fed - gblStore's own short columns do not match the convention
--    (ShortStoreName carries state suffixes and abbreviations, 'Lake Mead, NV' and
--    'Corporate Offc'; ShortName is camelCase-prefixed, 'zupRidgedale').
--    Verified 2026-09-10: this rule reproduces all 94 existing values exactly, 0 misses.
--    Is-null only, so a hand-edited short name is never restated.
--    nullif guards a store named exactly 'Zupas', which would otherwise write ''.
update `marketing-data-442316.sales_ops.store_info` t
set store_short_name = s.store_short_name
from (
  select
    si.store_id
    ,nullif(trim(regexp_replace(si.store_name, r'^Zupas\s+', '')), '') as store_short_name
  from `marketing-data-442316.sales_ops.store_info` si
  where 1=1
    and si.store_short_name is null
) s
where 1=1
  and t.store_id = s.store_id
  and s.store_short_name is not null
;

-- ============================================================================
-- 7) GUARDS. Deliberately last, so every statement above completes even when a guard
--    fails. A failing assert marks the scheduled run as failed; that is the point.
--    Note a script stops at the FIRST failing assert, so fix 7a before trusting 7b-7d.
--
--    trading_stores is the single definition of "a store we care about": it took an
--    order in the last 7 days. Building it once means order_customer (51M rows, 2787
--    partitions) is scanned once for the whole guard section instead of three times,
--    and the non-store exclusion list lives in exactly one place.
--    Excluded ids: 0 'Company', 901 'Zupas Lab2', 9001 'Zupas automation test'.
-- ============================================================================

create temp table trading_stores as
select distinct oc.store_id
from `marketing-data-442316.sales_ops.order_customer` oc
where 1=1
  and oc.business_date >= date_sub(current_date('America/Denver'), interval 7 day)
  and oc.store_id not in (0, 901, 9001)
;

-- 7a) Grain. This table is one row per store and every downstream join assumes it.
--     BigQuery has no primary keys, so one duplicated feed row silently doubles a
--     store and inflates every metric joined to it. Checked first because a broken
--     grain makes the other three guards untrustworthy.
assert (
  select count(*) = 0
  from (
    select store_id
    from `marketing-data-442316.sales_ops.store_info`
    group by store_id
    having count(*) > 1
  )
) as 'store_info: duplicate store_id - the one-row-per-store grain is broken. Check brink.gblStore for a duplicated StoreId, and de-duplicate before trusting anything joined to this table.'
;

-- 7b) A trading store must have a timezone, or order_timestamp_utc is NULL for every
--     order it takes and it vanishes silently from all Braze / UTC analysis.
assert (
  select count(*) = 0
  from `marketing-data-442316.sales_ops.store_info` s
  where 1=1
    and s.timezone_name is null
    and s.store_id in (select store_id from trading_stores)
) as 'store_info: a trading store has a NULL timezone_name -> order_timestamp_utc is NULL for every order it takes. Add its state to the timezone map in step 4, or add a city-level row if it sits in a split-timezone state.'
;

-- 7c) A trading store must have a weather cluster.
assert (
  select count(*) = 0
  from `marketing-data-442316.sales_ops.store_info` s
  where 1=1
    and s.weather_cluster_id is null
    and s.store_id in (select store_id from trading_stores)
) as 'store_info: a trading store has a NULL weather_cluster_id. Check that its store_zip resolves in bigquery-public-data.geo_us_boundaries.zip_codes, and that the zip is actually right for the city.'
;

-- 7d) A trading store must have BOTH coordinates. Checking only latitude would let a
--     half-geocoded store through, and step 5 would then have to fall back to the ZIP
--     centroid for it. This one CANNOT be auto-repaired - the feed carries no coordinate
--     column and the ZIP centroid is up to 70 miles off - so it is a prompt for a human
--     geocode. Method and the confidence check (an exact Google Maps /maps/place/ match
--     versus a /maps/search/ viewport fallback) are in the dictionary.
assert (
  select count(*) = 0
  from `marketing-data-442316.sales_ops.store_info` s
  where 1=1
    and (s.latitude is null or s.longitude is null)
    and s.store_id in (select store_id from trading_stores)
) as 'store_info: a trading store has a NULL latitude or longitude. Geocode its address and write it in - BigQuery cannot derive this.'
;
