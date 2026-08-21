-- Build/maintenance script: `marketing-data-442316`.sales_ops.store_info
-- Scheduled query, runs every 24 hours.
-- Grain: one row per store id. The store dimension.
-- Documentation: data_dictionaries/sales_ops.store_info.md
--
-- store_name / store_address / store_city / store_state / store_zip are INSERT-ONCE by
-- design. Do NOT add a sync for them from staging without cleaning staging first.
-- Maintenance statements run first, guards last.

-- 1) New stores from the staging feed.
INSERT INTO `marketing-data-442316`.sales_ops.store_info
(store_id, store_name, store_address, store_city, store_state, store_zip, store_phone, is_comp_store)
select
s.store_id
, s.store_name
, s.store_address
, s.store_city
, s.store_state
, cast(s.store_zip as string)
, safe_cast(regexp_replace(s.store_phone, r'[^0-9]', '') as int64)  -- '2026-08-20' strip formatting; a bare cast NULLs 82 of 100 rows
, s.is_comp_store
from `marketing-data-442316.staging.store_info` s
	left join `marketing-data-442316`.sales_ops.store_info ss
	on ss.store_id = s.store_id
where 1=1
and ss.store_id is null
;

-- 2) Comp-store status can change; keep it in sync with the feed.
UPDATE `marketing-data-442316`.sales_ops.store_info t
SET is_comp_store = s.is_comp_store
FROM `marketing-data-442316`.staging.store_info s
WHERE t.store_id = s.store_id
AND t.is_comp_store is distinct from s.is_comp_store  -- '2026-08-20' null-safe
;

-- 3) store_open_date: first business date with more than 150 orders. Is-null only.
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
  and oc.business_date >= date_sub(current_date('America/Denver'), interval 400 day)  -- '2026-08-20' 1.14 GiB -> 0.21 GiB
  group by 1,2
  having count(oc.brink_order_id) > 150
) soc
where 1=1
and soc.store_id = s.store_id
and soc.rn = 1
;

-- 4) timezone_name / store_tz derived from store_state. Is-null only.
--    Split-timezone states are deliberately absent so they stay NULL and trip guard 6a
--    rather than being guessed an hour wrong.
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

-- 5) weather_cluster_id: nearest metro cluster centroid, keyed on the store's own lat/long
--    where present else the ZIP centroid. Is-null only, so no assignment is ever restated.
--    Cluster 12 ('Unassigned (53005)') is excluded as a candidate - see the dictionary.
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

-- 6) Guards. Scoped to stores that took an order in the last 7 days.
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
) as 'store_info: a trading store has a NULL timezone_name -> order_timestamp_utc is NULL for every order it takes. Add its state to the map in step 4, or resolve it by city if it is a split-timezone state.'
;

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
) as 'store_info: a trading store has a NULL weather_cluster_id. Check that its store_zip resolves in bigquery-public-data.geo_us_boundaries.zip_codes.'
;

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
