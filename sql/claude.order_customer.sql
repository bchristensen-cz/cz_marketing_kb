-- =====================================================================================
-- claude.order_customer — Claude-facing authorized view over sales_ops.order_customer.
--
-- Interface layer, per the view-first strategy (steward 2026-07-22): `claude` exposes
-- authorized views over `sales_ops` materialized tables; materialize only for expensive
-- aggregations or marts with no `sales_ops` parent.
--
-- Adds to the base mart:
--   * revenue_category  — catering orders forced to 'Catering' regardless of destination
--   * order sequence    — customer_order_count, days_since_prev_order
--   * customer lifetime — from sales_ops.customer_attribute
--   * account_type      — CATERING vs INDIVIDUAL at the ACCOUNT level (new 2026-07-29)
--   * store_state       — the canonical "market" dimension (new 2026-07-30)
--
-- Created 2026-07-29. store_state added 2026-07-30.
--
-- 2026-08-13 repo sync: the DEPLOYED view carries `and oc.store_id <> 1111` — the test store
-- is excluded at the view level, not left to each query. Found undocumented during the
-- order_customer script sync; now committed here. Standard users can no longer see 1111 at
-- all; the steward's sales_ops tables still contain it. Keep writing `store_id <> 1111` in
-- queries anyway — it is free here and load-bearing everywhere else.
--
-- Redeployed 2026-08-13 (identical logic) to refresh INFORMATION_SCHEMA metadata: the base
-- table gained destination_id and has_order_items, and column ADDS freeze out of `oc.*` view
-- metadata exactly like the 2026-07-30 rename did — the columns RESOLVED at query time but
-- were absent from INFORMATION_SCHEMA.COLUMNS until the redeploy.
--
-- Redeployed again 2026-08-17 (identical logic) for the same reason in the opposite direction:
-- the base table DROPPED is_employee_discount. `select *` kept working — `*` re-expands at query
-- time — but INFORMATION_SCHEMA.COLUMNS still advertised the column and `select is_employee_discount`
-- errored. Adds, renames AND drops all require the redeploy. Live view is now 57 columns.
--
-- ⚠️ 2026-08-17 REPO DRIFT FOUND AND CORRECTED. This file had fallen behind the DEPLOYED view in
-- two places, both in the safe direction, which is exactly why nobody noticed:
--   * store exclusion   — repo `oc.store_id <> 1111`, deployed `oc.store_id not in (1111, 999)`
--   * order_sequence    — repo joined on brink_order_id alone, deployed also `and os.business_date
--                         = oc.business_date` (partition predicate — the join key is the PAIR)
-- Redeploying from the repo copy would have quietly readmitted store 999 to every standard user's
-- view and dropped the partition predicate. The deployed text is authoritative and is what is
-- below. Diff this file against the live definition before every redeploy:
--   select v.view_definition from `marketing-data-442316`.claude.INFORMATION_SCHEMA.VIEWS v
--   where v.table_name = 'order_customer'
--
-- The `case when oc.is_catering then 'Catering'` override below is a NO-OP as of 2026-08-17: the
-- base table's revenue_category now stamps 'Catering' on pulse-flagged and store-50 orders itself,
-- so the two select identical sets. Kept deliberately as a belt-and-braces guard — if the base
-- definitions ever diverge again, the view still reports catering correctly.
-- =====================================================================================
--
-- ⚠️ 2026-09-08 THE VIEW WAS BROKEN FOR ~40 MINUTES AND THE REPO HAD DRIFTED A THIRD TIME.
-- At 16:16 MT the steward dropped and rebuilt sales_ops.order_customer with the identity rework:
-- mapped_cust_id, mapped_email, mapped_email_domain and customer_type LEFT the base table (they
-- now live on sales_ops.order_sequence, derived through sales_ops.cust_map). This view joined
-- customer_attribute and loyalty_user on oc.mapped_cust_id, so every standard-user query failed
-- with `Name mapped_cust_id not found inside oc` until the redeploy below (~16:55 MT). Fix: the
-- two joins key on os.mapped_cust_id, and the four columns are re-exposed from os.* so the view's
-- column contract to analysts is unchanged (NULL when the order has no mapped customer, as before).
-- Repo drift corrected in the same sync: the repo body still carried `except(revenue_category)`
-- plus a Catering override and lacked first_order_datetime / last_order_datetime; deployed had
-- `except(brink_net_sales)`, no override, and both datetimes. Body below is the DEPLOYED text.
-- =====================================================================================
--
-- 2026-09-17 23:20 MT: is_app_user and app_user_type exposed from customer_attribute (steward
-- decision, same session as the flag's deploy). Live definition diffed against this file first:
-- identical, no drift. Both columns are NULL on unidentified and non-person orders, deliberately
-- NOT coalesced: a BOOL false would read as "not an app user" when the truth is "no customer".
-- Test with `is_app_user is true` / `is_app_user is not true`, never `= false`. View is now 67
-- columns. gender / birthday / age remain unexposed (separate steward call).
--
-- 2026-09-17 23:40 MT: gender, birthday and age exposed too (steward call, same session). View is
-- now 70 columns. birthday year 1950 is the app's placeholder for "year not provided": month and
-- day are real, the year is not, and age is NULL on exactly those rows (151,258 of 279,164
-- birthdays on the 2026-09-16 build). Passed through unchanged so birthday-month work still
-- works; never compute an age from birthday yourself, read the age column.
--
-- 2026-09-18: orders_l365, net_sales_l365, catering_orders_l365, catering_net_sales_l365 exposed
-- from customer_attribute (Asana 1218627569715877 — an analyst rescanned order_customer for
-- trailing-365 spend tiers because no window column reached this view). Live definition diffed
-- against this file first: identical. Left NULL (not coalesced) on unidentified / non-person orders,
-- same convention as lifetime_net_sales. Window = 365 days to attribute_asof_date (yesterday).
-- View is now 74 columns.
--
-- 2026-09-22: app_purchase_mode exposed from customer_attribute (steward decision, same session as
-- the app-user revision: a session alone no longer makes an app user, so is_app_user is the
-- 12-month purchase test and app_user_type no longer emits 'session_only'). Live definition diffed
-- against this file first: identical. NULL on unidentified / non-person orders and on non-app
-- users, deliberately not coalesced. View is now 75 columns.
-- =====================================================================================

create or replace view `marketing-data-442316`.claude.order_customer as
select
oc.* except(brink_net_sales)
, os.mapped_cust_id
, os.mapped_email
, os.mapped_email_domain
, os.customer_type
, coalesce(os.customer_order_count, 0) as customer_order_count
, coalesce(os.days_since_prev_order, 0) as days_since_prev_order
, coalesce(ca.lifetime_order_count, 0) as lifetime_order_count
, coalesce(ca.lifetime_catering_order_count, 0) as lifetime_catering_order_count
, coalesce(ca.lifetime_guest_order_count, 0) as lifetime_guest_order_count
, ca.lifetime_net_sales
, ca.lifetime_gross_sales
, ca.lifetime_avg_check
, ca.first_order_date
, ca.first_order_datetime
, ca.last_order_date
, ca.last_order_datetime
, ca.days_since_last_order
, ca.customer_tenure_days
, ca.orders_l365
, ca.net_sales_l365
, ca.catering_orders_l365
, ca.catering_net_sales_l365
, ca.is_app_user
, ca.app_user_type
, ca.app_purchase_mode
, ca.gender
, ca.birthday
, ca.age
, lu.member_program as account_type
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
	and os.business_date = oc.business_date
		left join `marketing-data-442316`.sales_ops.customer_attribute ca
		on ca.mapped_cust_id = os.mapped_cust_id
			left join `marketing-data-442316`.claude.loyalty_user lu
			on lu.sm_external_user_id = os.mapped_cust_id
where 1=1
and oc.business_date >= date_trunc(date_sub(current_date, interval 3 year), year)
and oc.store_id not in (1111, 999)
;


-- =====================================================================================
-- Post-deploy validation — grain must be preserved.
-- Expect zero rows. Any row means a join fanned out.
-- =====================================================================================
-- select
--   oc.brink_order_id
-- , count(*) as cnt
-- from `marketing-data-442316`.claude.order_customer oc
-- where 1=1
-- group by 1
-- having count(*) > 1
-- order by count(*) desc
-- ;
