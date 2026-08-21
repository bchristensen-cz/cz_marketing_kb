-- Build script: `marketing-data-442316`.sales_ops.customer_attribute
-- Grain: ONE ROW PER CUSTOMER (mapped_cust_id), person only. This is a dimension, not a fact.
-- Documentation: data_dictionaries/sales_ops.customer_attribute.md
--
-- Purpose: customer base table holding lifetime + trailing-window aggregates. Feeds
-- (a) analyst segmentation in BigQuery and (b) a daily custom_attributes push to Braze.
--
-- STATUS 2026-07-30: DEPLOYED. Refreshed daily at 5am
--
-- Design decisions (steward, 2026-07-28):
--   * FULL create-or-replace every run, not a MERGE. Measured cost is ~1.4 GB / run
--     (~$0.007). An incremental merge would only touch customers who ordered, which leaves
--     the trailing-window columns (orders_l30 etc.) stale for everyone who DIDN'T order -
--     and those are exactly the customers a lapsed/win-back campaign targets. Recomputing
--     everybody daily makes "crossing a date window" a non-event. Do not convert this to a
--     MERGE to save $0.007.
--   * PERSON ONLY (customer_type = 'person'), filtered at read. Deliberately the opposite
--     of the order_sequence decision, and for a specific reason: order_sequence is a
--     per-order table where the caller can still filter, so pre-filtering there would have
--     hidden data. Here the row IS the aggregate - if aggregator id 19192 were included it
--     would land a single row with ~2.5M lifetime orders, and no downstream filter can
--     unwind that. Filtering after aggregation does not renumber; filtering before does.
--   * Driven from order_customer, NOT order_sequence. order_sequence is the natural first
--     guess but it carries no financials, no store, and no revenue_category, so every
--     attribute except the order count needs order_customer anyway. Its
--     lifetime_customer_order_count is also computed across ALL customer types, so it is
--     wrong for the ~30 mixed ids. count(*) over the person-filtered set is correct by
--     construction and costs nothing extra. Verified 2026-07-28: zero person customers have
--     a first order before order_sequence's 2023-03-06 history start, so nothing is lost.
--   * Stores 1111 and 999 excluded (standing steward rule).
--   * Catering orders are INCLUDED in the lifetime totals, with
--     lifetime_catering_order_count carried alongside so downstream can net it out.

declare run_dt datetime default current_datetime('America/Denver');
declare run_date date default date(run_dt);
-- Anchored to YESTERDAY, not the run date (steward decision 2026-07-28). The job runs at
-- 5am MT but stores don't open until ~10am, so anchoring on today would make orders_l30
-- span 29 real business days plus an empty stub, and re-running the job in the afternoon
-- would silently change the answer. Anchoring to the last complete day makes every window
-- whole-day and independent of run time.
declare asof_date date default date_sub(run_date, interval 1 day);
declare history_start date default date '2018-08-07';

-- ---------------------------------------------------------------------------
-- sales_ops.customer_attribute
-- ---------------------------------------------------------------------------

create or replace table `marketing-data-442316`.sales_ops.customer_attribute
cluster by mapped_cust_id as

with person_orders as (
select
  oc.mapped_cust_id
, oc.brink_order_id
, oc.business_date
, oc.order_datetime_local
, oc.store_id
, oc.store_name
, oc.revenue_category
, oc.order_source
, oc.net_sales
, oc.gross_sales
, oc.is_catering
, oc.is_guest_order
, oc.mapped_email
, oc.mapped_email_domain
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date between history_start and asof_date
and oc.store_id not in (1111, 999)
and oc.mapped_cust_id is not null  -- '2026-07-29' redundant, you can't have a customer_type without a mapped_cust_id
and oc.customer_type = 'person'
)

-- one row per customer per store, so the store array can carry visit counts
, customer_store as (
select
  po.mapped_cust_id
, po.store_id
, po.store_name
, count(*) as store_order_count
, max(po.business_date) as store_last_order_date
from person_orders po
group by 1, 2, 3
)

-- store_name is 1:1 with store_id across full history (verified 2026-07-28), so no
-- store_info join is needed and the array cannot fan out on renames.
, customer_stores as (
select
  cs.mapped_cust_id
, count(*) as lifetime_store_count
, array_agg(
    struct(
      cs.store_id as store_id
    , cs.store_name as store_name
    , cs.store_order_count as orders
    , cs.store_last_order_date as last_order_date
    )
    order by cs.store_order_count desc, cs.store_last_order_date desc, cs.store_id
  ) as lifetime_stores
from customer_store cs
group by 1
)

, customer_agg as (
select
  po.mapped_cust_id

-- lifetime volume
, count(*) as lifetime_order_count
, countif(po.is_catering) as lifetime_catering_order_count
, countif(po.is_guest_order) as lifetime_guest_order_count

-- lifetime value
, round(sum(po.net_sales), 2) as lifetime_net_sales
, round(sum(po.gross_sales), 2) as lifetime_gross_sales
, round(safe_divide(sum(po.net_sales), count(*)), 2) as lifetime_avg_check

-- first / last order timestamps
, min(po.order_datetime_local) as first_order_datetime
, max(po.order_datetime_local) as last_order_datetime
, min(po.business_date) as first_order_date
, max(po.business_date) as last_order_date

-- first order attributes: earliest by order_datetime_local, tie-broken by brink_order_id
-- (same ordering convention as order_sequence)
, array_agg(
    struct(
      po.revenue_category as revenue_category
    , po.store_id as store_id
    , po.store_name as store_name
    , po.order_source as order_source
    )
    order by po.order_datetime_local asc, po.brink_order_id asc
    limit 1
  )[offset(0)] as first_order

, array_agg(
    struct(
      po.revenue_category as revenue_category
    , po.store_id as store_id
    , po.store_name as store_name
    , po.order_source as order_source
    )
    order by po.order_datetime_local desc, po.brink_order_id desc
    limit 1
  )[offset(0)] as last_order

-- most recent non-null email wins
, array_agg(
    struct(po.mapped_email as mapped_email, po.mapped_email_domain as mapped_email_domain)
    order by case when po.mapped_email is null then 1 else 0 end, po.order_datetime_local desc
    limit 1
  )[offset(0)] as email_rec

-- trailing windows, anchored on asof_date. Inclusive of asof_date, so l30 is the 30 days
-- ending on asof_date (i.e. YESTERDAY, not today): business_date > asof_date - 30.
, countif(po.business_date > date_sub(asof_date, interval 30 day)) as orders_l30
, countif(po.business_date > date_sub(asof_date, interval 90 day)) as orders_l90
, countif(po.business_date > date_sub(asof_date, interval 365 day)) as orders_l365
, round(sum(if(po.business_date > date_sub(asof_date, interval 30 day), po.net_sales, 0)), 2) as net_sales_l30
, round(sum(if(po.business_date > date_sub(asof_date, interval 90 day), po.net_sales, 0)), 2) as net_sales_l90
, round(sum(if(po.business_date > date_sub(asof_date, interval 365 day), po.net_sales, 0)), 2) as net_sales_l365

from person_orders po
group by 1
)

select
-- ---------- identity ----------
  ca.mapped_cust_id
, cast(ca.mapped_cust_id as string) as braze_external_id
, ca.email_rec.mapped_email as mapped_email
, ca.email_rec.mapped_email_domain as mapped_email_domain

-- ---------- lifetime volume ----------
, ca.lifetime_order_count
, ca.lifetime_catering_order_count
, ca.lifetime_guest_order_count

-- ---------- lifetime value ----------
, ca.lifetime_net_sales
, ca.lifetime_gross_sales
, ca.lifetime_avg_check

-- ---------- dates ----------
, ca.first_order_datetime
, ca.last_order_datetime
, ca.first_order_date
, ca.last_order_date
, date_diff(asof_date, ca.last_order_date, day) as days_since_last_order
, date_diff(asof_date, ca.first_order_date, day) as customer_tenure_days

-- ---------- first / last order context ----------
, ca.first_order.revenue_category as first_order_revenue_category
, ca.first_order.order_source as first_order_source
, ca.first_order.store_id as first_order_store_id
, ca.first_order.store_name as first_order_store_name
, ca.last_order.revenue_category as last_order_revenue_category
, ca.last_order.order_source as last_order_source
, ca.last_order.store_id as last_order_store_id
, ca.last_order.store_name as last_order_store_name

-- ---------- stores ----------
, cst.lifetime_store_count
, cst.lifetime_stores                       -- ARRAY<STRUCT<store_id, store_name, orders, last_order_date>>
, cst.lifetime_stores[offset(0)].store_id   as primary_store_id
, cst.lifetime_stores[offset(0)].store_name as primary_store_name

-- Braze-ready serializations. Braze caps an array custom attribute at 25 elements, so both
-- are truncated to the top 25 stores by order count (16 customers exceeded 25 stores on
-- 2026-07-28; max observed was 89).
, to_json_string(
    array(
      select s.store_name
      from unnest(cst.lifetime_stores) s with offset o
      where o < 25
      order by o
    )
  ) as lifetime_store_names_json
, to_json_string(
    array(
      select struct(s.store_id as store_id, s.store_name as store_name, s.orders as orders)
      from unnest(cst.lifetime_stores) s with offset o
      where o < 25
      order by o
    )
  ) as lifetime_stores_json

-- ---------- trailing windows ----------
, ca.orders_l30
, ca.orders_l90
, ca.orders_l365
, ca.net_sales_l30
, ca.net_sales_l90
, ca.net_sales_l365

-- ---------- housekeeping ----------
, asof_date as attribute_asof_date
-- Change-detection key for the Braze export: only push customers whose hash moved since
-- the last successful send. Deliberately EXCLUDES days_since_last_order and the asof date,
-- which change every single day for everyone and would force a full 1.4M-profile push.
, farm_fingerprint(to_json_string(struct(
    ca.lifetime_order_count
  , ca.lifetime_net_sales
  , ca.last_order_date
  , ca.first_order_date
  , cst.lifetime_store_count
  , ca.orders_l30
  , ca.orders_l90
  , ca.orders_l365
  ))) as attribute_hash
, current_timestamp() as updated_at

from customer_agg ca
	join customer_stores cst
	on cst.mapped_cust_id = ca.mapped_cust_id
;
