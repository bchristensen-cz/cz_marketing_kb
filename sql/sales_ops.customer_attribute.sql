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

-- Native-app sessions in the trailing 90 days. Descriptive only since the 2026-09-22 revision
-- (feeds is_app_session_user, app_session_days_l90 and the app_user_type split; does not set
-- is_app_user). app_sessionstart is NOT app-only: the web SDK and landing pages log to the same
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
-- 2026-09-22 guest status (steward decision): NULL is_guest_order (Pulse feed gaps) counts as
-- authenticated, because the order still carries an identity we can reach.
, countif(not ifnull(po.is_guest_order, false)) as lifetime_authenticated_order_count
, countif(po.is_guest_order and po.business_date > date_sub(asof_date, interval 365 day)) as guest_orders_l365

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
    , ifnull(po.is_guest_order, false) as is_guest_order
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
    , ifnull(po.is_guest_order, false) as is_guest_order
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
-- 2026-09-23 (steward): catering orders never count as app purchases. 1,433 catering-only
-- accounts were qualifying as app users through catering orders placed in the app; the app-user
-- definition is about the in-store customer relationship, so is_catering orders are excluded from
-- both halves of the test (app order and scan) and from the lifetime counts and last dates.
, countif(po.order_source in ('iOS', 'Android') and not po.is_catering) as lifetime_app_order_count
, countif(po.in_store_scan = 1 and not po.is_catering) as lifetime_in_store_scan_count
, countif(po.order_source in ('iOS', 'Android') and not po.is_catering and po.business_date > date_sub(asof_date, interval 12 month)) as app_orders_l12m
, countif(po.in_store_scan = 1 and not po.is_catering and po.business_date > date_sub(asof_date, interval 12 month)) as in_store_scans_l12m
, max(if(po.order_source in ('iOS', 'Android') and not po.is_catering, po.business_date, null)) as last_app_order_date
, max(if(po.in_store_scan = 1 and not po.is_catering, po.business_date, null)) as last_in_store_scan_date

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

-- ---------- guest status (steward decision 2026-09-22) ----------
-- Customer-level reading of the order flag is_guest_order (first-party digital order by a
-- non-loyalty user with no SessionM identity; guest checkout exists from 2026-07-01).
-- Authentication wins: once a customer has placed an authenticated order we hold a reachable
-- identity, so a later forgotten login does not demote them.
--   guest            never authenticated: every identified order is a guest order
--   converted_guest  first identified order was a guest order, has since authenticated
--   account          authenticated first (an occasional later guest order keeps them here)
-- Measured 2026-07-01 to 09-14: 39,651 guest / 2,018 converted / 955 account-then-guest /
-- 243,615 authenticated only. The mixed cases only exist where sales_ops.cust_map tied the
-- guest email to an account, so they will grow when the email-based guest mapping deploys.
, ca.first_order.is_guest_order as first_order_was_guest
, ca.last_order.is_guest_order as last_order_was_guest
, ca.guest_orders_l365
, case
    when ca.lifetime_guest_order_count > 0 and ca.lifetime_authenticated_order_count = 0 then 'guest'
    when ca.first_order.is_guest_order and ca.lifetime_authenticated_order_count > 0 then 'converted_guest'
    else 'account'
  end as guest_status

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

-- ---------- app usage (canonical App User definition, steward decision 2026-09-17, revised 2026-09-22) ----------
-- is_app_user = app purchase (app order OR in-store scan, catering orders excluded) in the trailing 12 months.
-- 2026-09-22 revision (steward): a native-app session on its own no longer makes an app user.
-- Browsing without buying is not app usage. Session state is still carried in
-- is_app_session_user / app_session_days_l90 / last_app_session_date and inside app_user_type,
-- but it never sets is_app_user. The 27.5k 'session_only' customers on the 2026-09-21 build
-- flipped to is_app_user = false on the first build with this text (one-time hash move).
-- is_app_purchaser is kept as an alias of is_app_user for anything written against it.
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
, (ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 as is_app_user
-- app_user_type: engagement shape of an app user. NULL for anyone who is not an app user,
-- including session-only browsers (the former 'session_only' value is retired 2026-09-22).
, case
    when (ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 and aps.mapped_cust_id is not null then 'purchase_and_session'
    when (ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 then 'purchase_only'
    else null
  end as app_user_type
-- app_purchase_mode (added 2026-09-22): how the app user buys, the two halves of the purchase
-- test split out. Mutually exclusive; NULL for non-app users. Value analysis 2026-09-22 (window to
-- 09-14): 'app_orders_and_scans' 107k customers at 9.5 orders / $220 a year ex catering,
-- 'app_orders_only' 140k and 'scans_only' 170k both at ~4 orders / $92-97 a year.
, case
    when ca.app_orders_l12m > 0 and ca.in_store_scans_l12m > 0 then 'app_orders_and_scans'
    when ca.app_orders_l12m > 0 then 'app_orders_only'
    when ca.in_store_scans_l12m > 0 then 'scans_only'
    else null
  end as app_purchase_mode

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
  -- 2026-09-22: session no longer sets is_app_user; app_purchase_mode added. Hash moves once for
  -- every app user (new struct field) and for the former session-only rows.
  , (ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 as is_app_user
  , case
      when (ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 and aps.mapped_cust_id is not null then 'purchase_and_session'
      when (ca.app_orders_l12m + ca.in_store_scans_l12m) > 0 then 'purchase_only'
      else null
    end as app_user_type
  , case
      when ca.app_orders_l12m > 0 and ca.in_store_scans_l12m > 0 then 'app_orders_and_scans'
      when ca.app_orders_l12m > 0 then 'app_orders_only'
      when ca.in_store_scans_l12m > 0 then 'scans_only'
      else null
    end as app_purchase_mode
  -- 2026-09-22: guest_status added so a guest converting to an account is a pushable change.
  -- One-time hash move for every row on the first build with this field.
  , case
      when ca.lifetime_guest_order_count > 0 and ca.lifetime_authenticated_order_count = 0 then 'guest'
      when ca.first_order.is_guest_order and ca.lifetime_authenticated_order_count > 0 then 'converted_guest'
      else 'account'
    end as guest_status
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
