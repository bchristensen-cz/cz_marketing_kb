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
, oc.in_store_scan
-- 2026-09-08: reads the claude.order_customer VIEW, not the sales_ops table. The identity rework
-- moved mapped_cust_id / customer_type off sales_ops.order_customer onto sales_ops.order_sequence;
-- the view joins them back (and excludes stores 1111/999, which the filter below repeats).
-- Scheduled 05:20 MT, after the 05:02 order_customer + order_sequence full rebuild.
from `marketing-data-442316`.claude.order_customer oc
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

-- Native-app sessions in the trailing 90 days (canonical App User definition, steward decision
-- 2026-09-17). app_sessionstart is NOT app-only: the web SDK and landing pages log to the same
-- table and web is ~4x the native user count, so platform in ('ios', 'android') is load-bearing.
-- Braze platform values are lowercase; the order mart's order_source values ('iOS', 'Android')
-- are mixed case. Join key is the customer id cast from external_user_id, never email.
-- Window is inclusive of asof_date: event_date > asof_date - 90 and <= asof_date.
, app_sessions as (
select
  safe_cast(s.external_user_id as int64) as mapped_cust_id
, count(distinct s.event_date) as app_session_days_l90
, max(s.event_date) as last_app_session_date
from `marketing-data-442316`.braze.app_sessionstart s
where 1=1
and s.event_date > date_sub(asof_date, interval 90 day)
and s.event_date <= asof_date
and s.workspace = 'cafe_zupas'
and s.platform in ('ios', 'android')
and safe_cast(s.external_user_id as int64) is not null
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

-- first order attributes: earliest by order_datetime, tie-broken by brink_order_id
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
-- ending today: business_date > asof_date - 30.
, countif(po.business_date > date_sub(asof_date, interval 30 day)) as orders_l30
, countif(po.business_date > date_sub(asof_date, interval 90 day)) as orders_l90
, countif(po.business_date > date_sub(asof_date, interval 365 day)) as orders_l365
, round(sum(if(po.business_date > date_sub(asof_date, interval 30 day), po.net_sales, 0)), 2) as net_sales_l30
, round(sum(if(po.business_date > date_sub(asof_date, interval 90 day), po.net_sales, 0)), 2) as net_sales_l90
, round(sum(if(po.business_date > date_sub(asof_date, interval 365 day), po.net_sales, 0)), 2) as net_sales_l365

-- catering subset of each window (added 2026-09-18) so the standard catering exclusion can be
-- honoured on a trailing-window figure: ex-catering = orders_lN - catering_orders_lN.
-- Same windows, same inclusivity, same is_catering the lifetime counterpart uses.
, countif(po.is_catering and po.business_date > date_sub(asof_date, interval 30 day)) as catering_orders_l30
, countif(po.is_catering and po.business_date > date_sub(asof_date, interval 90 day)) as catering_orders_l90
, countif(po.is_catering and po.business_date > date_sub(asof_date, interval 365 day)) as catering_orders_l365
, round(sum(if(po.is_catering and po.business_date > date_sub(asof_date, interval 30 day), po.net_sales, 0)), 2) as catering_net_sales_l30
, round(sum(if(po.is_catering and po.business_date > date_sub(asof_date, interval 90 day), po.net_sales, 0)), 2) as catering_net_sales_l90
, round(sum(if(po.is_catering and po.business_date > date_sub(asof_date, interval 365 day), po.net_sales, 0)), 2) as catering_net_sales_l365

-- app purchases (canonical App User definition, steward decision 2026-09-17): a native-app
-- order OR an in-store loyalty scan. The steward's stated assumption is that an in-store scan is
-- made with the app, so a scan counts as an app purchase. Trailing window is 12 months, inclusive
-- of asof_date, so it equals "business_date >= run_date - 12 months" as the KB's canonical query
-- writes it.
, countif(po.order_source in ('iOS', 'Android')) as lifetime_app_order_count
, countif(po.in_store_scan = 1) as lifetime_in_store_scan_count
, countif(po.order_source in ('iOS', 'Android') and po.business_date > date_sub(asof_date, interval 12 month)) as app_orders_l12m
, countif(po.in_store_scan = 1 and po.business_date > date_sub(asof_date, interval 12 month)) as in_store_scans_l12m
, max(if(po.order_source in ('iOS', 'Android'), po.business_date, null)) as last_app_order_date
, max(if(po.in_store_scan = 1, po.business_date, null)) as last_in_store_scan_date

from person_orders po
group by 1
)

select
-- ---------- identity ----------
  ca.mapped_cust_id
, cast(ca.mapped_cust_id as string) as braze_external_id
, ca.email_rec.mapped_email as mapped_email
, ca.email_rec.mapped_email_domain as mapped_email_domain

-- ---------- demographics (deployed 2026-09-15, synced to the repo 2026-09-18) ----------
, c.gender as gender
, c.birthday as birthday
, case when extract(year from c.birthday) = 1950 then null
      else date_diff(current_date(), c.birthday, year)
  end as age

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
-- catering subset of the same windows (2026-09-18). Not in attribute_hash: it moves with the
-- parent window columns already.
, ca.catering_orders_l30
, ca.catering_orders_l90
, ca.catering_orders_l365
, ca.catering_net_sales_l30
, ca.catering_net_sales_l90
, ca.catering_net_sales_l365

-- ---------- app usage (canonical App User definition, steward decision 2026-09-17) ----------
-- is_app_user = app purchase (app order OR in-store scan) in the trailing 12 months
--            OR native-app session in the trailing 90 days.
-- Grain caveat: this table only holds customers with at least one identified person order, so a
-- Braze session user who has never placed an identified order is an app user by the canonical
-- query but has no row here.
, ca.lifetime_app_order_count
, ca.lifetime_in_store_scan_count
, ca.app_orders_l12m
, ca.in_store_scans_l12m
, ca.last_app_order_date
, ca.last_in_store_scan_date
, coalesce(aps.app_session_days_l90, 0) as app_session_days_l90
, aps.last_app_session_date as last_app_session_date
, (ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 as is_app_purchaser
, aps.mapped_cust_id is not null as is_app_session_user
, ((ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 or aps.mapped_cust_id is not null) as is_app_user
, case
    when (ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 and aps.mapped_cust_id is not null then 'purchase_and_session'
    when (ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 then 'purchase_only'
    when aps.mapped_cust_id is not null then 'session_only'
    else null
  end as app_user_type

-- ---------- housekeeping ----------
, asof_date as attribute_asof_date
-- Change-detection key for the Braze export: only push customers whose hash moved since
-- the last successful send. Deliberately EXCLUDES days_since_last_order and the asof date,
-- which change every single day for everyone and would force a full 1.37M-profile push.
, farm_fingerprint(to_json_string(struct(
    ca.lifetime_order_count
  , ca.lifetime_net_sales
  , ca.last_order_date
  , ca.first_order_date
  , cst.lifetime_store_count
  , ca.orders_l30
  , ca.orders_l90
  , ca.orders_l365
  -- 2026-09-18: app-user state added so the Braze delta push fires when someone becomes or
  -- stops being an app user. One-time hash move for every row on the first build.
  , ((ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 or aps.mapped_cust_id is not null) as is_app_user
  , case
      when (ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 and aps.mapped_cust_id is not null then 'purchase_and_session'
      when (ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 then 'purchase_only'
      when aps.mapped_cust_id is not null then 'session_only'
      else null
    end as app_user_type
  ))) as attribute_hash
, current_timestamp() as updated_at

from customer_agg ca
	join customer_stores cst
	on cst.mapped_cust_id = ca.mapped_cust_id
		left join `marketing-data-442316`.pulse.customers c
		on c.id = ca.mapped_cust_id
			left join app_sessions aps
			on aps.mapped_cust_id = ca.mapped_cust_id
;
