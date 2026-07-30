-- Build script: `marketing-data-442316`.sales_ops.order_customer (+ sales_ops.order_sequence)
-- Runs hourly at minute :02 (see schedule logic below). Both tables are built by this one
-- scheduled query, so order_sequence follows the exact same schedule and skips the same hours.
-- Grain: one row per Brink order.
-- Documentation: data_dictionaries/sales_ops.order_customer.md
--                data_dictionaries/sales_ops.order_sequence.md
--
-- history starts '2018-08-07'
--
-- 2026-07-24 changes:
--   * businessdate renamed to business_date (partition column)
--   * net_sales is now CALCULATED: gross_sales - total_discount_amount - total_promotions_amount
--   * Brink-given net retained as brink_net_sales (validation only)
--   * dropped item_net_sales, item_netsales_with_mods, mods_net_sales
--   * is_catering fixed: destination test now evaluates (was dead code behind a NULL/false branch)
--   * customer_type added (order-level; see note at the column)
--   * order_count / days_since_prev_order moved out to sales_ops.order_sequence
--
-- 2026-07-27 changes:
--   * delete predicate corrected to business_date
--   * pulse_orders CTE added (scoped + deduped)
--   * is_guest_order changed from INT64 0/1 to BOOL
--   * sm_external_user_map now carries the sessionM email; mapped_email falls back to it
--   * mapped_email_domain added
--   * customer_type reworked to match on order emails (ezcater / doordash / itsacheckmate)
--   * FAN-OUT FIX: pulse_orders now dedupes on brink_order_id, not po.id
--   * order_sequence: customer-level guard excluding ids that ever appear as non-person
--
-- 2026-07-29 changes (all deployed + full-history rebuild; audit in
-- design/sessionm_identity_pipeline_audit.md):
--   * CRITICAL: header_trans `create_date > start_date` -> `>=`. create_date is a DATE, so `>`
--     dropped the entire boundary day of every reload window and intraday runs matched nothing.
--     Cost ~7,900 orders/day their loyalty identity while all sales figures looked normal.
--   * lower() on user_id in all three all_trans_users branches and in sm_external_user_map
--     (only the discounts branch had it; the join target is 100% lowercase)
--   * lower() on mapped_email, ocs.email and cust_trans.email. pulse.customers.email was 8.7%
--     non-lowercase, creating 17,943 phantom identities and splitting 5,604 real people
--   * all five customer_type branches now compare lowercased (the three aggregator LIKEs were
--     case-sensitive while kiosk/internal were not) - defensive, reclassified nothing
--   * user_trans CTE removed, folded into cust_trans: resolve via inner joins first, then dedupe
--     once on pos_transaction_key. Verified output-equivalent
--   * order_sequence: dropped lifetime_customer_order_count (now customer_attribute only)
--   * VERIFIED after rebuild: 50,321,698 rows = 50,321,698 distinct brink_order_id, 0 duplicates
--     - the long-standing pulse fan-out grain defect is resolved

declare run_dt datetime default current_datetime('America/Denver');
declare run_hour int64 default extract(hour from run_dt);
declare run_date date default date(run_dt);
declare start_date date;

set start_date = case
  -- 1st of month at 4am: ~13 month reload
  when extract(day from run_date) = 1 and run_hour = 4 then date_sub(run_date, interval 380 day)
  -- monday at 4am: 5 week reload
  when format_date('%A', run_date) = 'Monday' and run_hour = 4 then date_sub(run_date, interval 35 day)
  -- daily at 4am: 8 day reload
  when run_hour = 4 then date_sub(run_date, interval 8 day)
  -- intraday: today only
  when run_hour between 8 and 23 then run_date
  -- all other hours: skip
  else null
end;

if start_date is null then
  return;
end if;


delete `marketing-data-442316`.sales_ops.order_customer
where business_date >= start_date;  -- '2026-07-27' updated to business_date

insert into `marketing-data-442316`.sales_ops.order_customer

-- declare start_date date;
-- set start_date = '2018-08-07';
-- -- drop table `marketing-data-442316`.sales_ops.order_customer
-- create or replace table `marketing-data-442316`.sales_ops.order_customer
-- partition by business_date
-- cluster by brink_order_id, mapped_cust_id, store_id, store_name
-- as

with brink_order as (
select bo.*
from `marketing-data-442316`.brink.brinkOrder bo
where 1=1
and bo.businessdate >= start_date
qualify row_number() over(partition by bo.id order by bo.insertionjob) = 1
)


, fee_items as (
select i.id, i.name
from `marketing-data-442316`.brink.brinkItems i
where regexp_contains(i.name, r'(?i)\bfee\b')
qualify row_number() over(partition by i.id order by i.name) = 1
)

, tip_items as (
select i.id, i.name
from `marketing-data-442316`.brink.brinkItems i
where regexp_contains(i.name, r'(?i)\btip\b')
qualify row_number() over(partition by i.id order by i.name) = 1
)


, brink_order_item as (
select
boi.orderId
, sum(case when t.id is null then boi.ItemGrossSales end) as item_gross_sales
-- , sum(case when t.id is null then boi.ItemNetSales end) as item_net_sales  -- '2026-07-24' net sales will now be a calc of gross sales - discounts - promotions
-- , sum(case when t.id is null then boi.NetSales end) as item_netsales_with_mods   -- '2026-07-24' net sales will now be a calc of gross sales - discounts - promotions
, sum(case when f.id is not null then boi.ItemGrossSales end) as total_fees_amount
, sum(case when t.id = 640943560 then boi.ItemGrossSales end) as total_delivery_tip_amount
, sum(case when t.id <> 640943560 then boi.ItemGrossSales end) as  total_other_tip_amount
--, sum(case when t.id is not null then boi.ItemGrossSales end) as total_tip_item_amount
from `marketing-data-442316`.brink.brinkOrderItem boi
	join brink_order bo
	on boi.orderid = bo.id
		left join fee_items f
		on f.id = boi.itemid
			left join tip_items t
			on t.id = boi.itemid
where 1=1
and boi.IsCleared = false
and boi.IsVoided = false
and boi.IsDeleted = false
group by 1
having sum(boi.ItemGrossSales) > 0 or sum(boi.ItemNetSales) > 0
)


, brink_order_item_modifiers as (
select
boim.orderid
, sum(boim.ItemGrossSales) as mods_gross_sales
--, sum(boim.ItemNetSales) as mods_net_sales -- '2026-07-24' net sales will now be a calc of gross sales - discounts - promotions
from `marketing-data-442316`.brink.brinkOrderItemModifier boim
	join brink_order_item boi
	on boim.orderid = boi.orderid
where 1=1
group by 1
)


, gift_card_purchase as (
select gc.orderid
, sum(gc.price) as total_gift_card_amount
from `marketing-data-442316`.brink.brinkOrderGiftCard gc
	join brink_order bo
	on bo.id = gc.orderid
group by 1
)

, emp_discounts_root_offer_id as (
select distinct o.root_offer_id
from `marketing-data-442316`.sessionM.offers o
where 1=1
and (o.name like '%Meal%'
	or o.name like '%Emp%'
	or o.name like '%Team%')
)

, ref_ids as (
select uo.user_offers_id, uo.redeem_date
from `marketing-data-442316`.sessionM.user_offers uo
	join emp_discounts_root_offer_id r
	on r.root_offer_id = uo.root_offer_id
where 1=1
and uo.create_date >= start_date
)

, discount_trans_id as (
select distinct d.transaction_id
from `marketing-data-442316`.sessionM.transaction_discounts d
	join ref_ids r
	on r.user_offers_id = d.discount_reference_id
where 1=1
and d.create_date >= start_date
)


, total_payment as (
select p.orderid as order_id
, sum(p.amount) as total_payment_amount
, sum(p.TipAmount) as total_tip_amount
, sum(p.change) as total_change
from `marketing-data-442316`.brink.brinkOrderPayment p
where 1=1
and p.businessdate >= start_date
group by 1
)


, instore_discount_codes as (
select distinct d.id
from `marketing-data-442316`.brink.brinkDiscounts d
where 1=1
and (d.name like '%Team%'
	or d.name like '%Employee%')
)

, instore_emp_discounts as (
select od.orderid as order_id
, sum(od.amount) as total_discount_amount
, max(case when cd.id is not null then 1 else 0 end) as is_employee_discount
--select *
from `marketing-data-442316`.brink.brinkOrderDiscount od
	left join instore_discount_codes cd
	on cd.id = od.DiscountId
where 1=1
and od.isdeleted = false
group by 1
)


, brink_promotions as (
select p.orderid, sum(p.amount) as total_promotions_amount
from `marketing-data-442316`.brink.brinkOrderPromotion p
	join brink_order bo
	on bo.id = p.orderid
group by 1
)

, all_trans_users as (
select
t.transaction_id
, lower(t.user_id) as user_id  -- '2026-07-29' added lower() for consistency
, t.last_updated_at as updated_date
from `marketing-data-442316`.sessionM.user_point_transactions t
where  1=1
and t.transaction_id is not null
and t.user_id is not null
and t.last_updated_at >= timestamp(start_date)

union all

        -- Discounts
select
d.transaction_id
, lower(d.user_id)
, d.last_updated_at as updated_date
from `marketing-data-442316`.sessionM.transaction_discounts d
where d.transaction_id is not null
and d.user_id is not null
and d.last_updated_at >= timestamp(start_date)


union all   -- switched from UNION -> UNION ALL for performance

    -- Payments
select
tp.transaction_id
, lower(tp.user_id)  -- '2026-07-29' added lower() for consistency
, tp.last_updated_at as updated_date
from `marketing-data-442316`.sessionM.transaction_payments tp
where 1=1
and tp.transaction_id is not null
and tp.user_id is not null
and tp.last_updated_at >= timestamp(start_date)
)


-- '2026-07-29' user_trans CTE REMOVED - folded into cust_trans below. The old two-stage shape
-- picked one user per transaction_id by recency and only then checked whether that user
-- resolved to a mapping, so resolvability was incidental to the ordering. Verified equivalent
-- on 30 days (203,855 rows both ways, 0 links changed) - this is a robustness change, not a
-- recovery. See design/sessionm_identity_pipeline_audit.md finding #4.
-- , user_trans as (
-- select u.*
-- from all_trans_users u
-- qualify row_number() over(partition by u.transaction_id order by u.updated_date desc) = 1
-- )


-- '2026-07-27' joined sessionM.users to pick up the loyalty email. Verified safe: 0 of
-- 1,782,178 'cafezupas' mapping rows lack a users row, so the inner join drops nothing
-- (re-verified 2026-07-29, also 0 null emails).
, sm_external_user_map as (
select lower(u.user_id) as user_id, u.external_user_id, lower(uu.email) as email  -- '2026-07-29' added lower() for consistency
from `marketing-data-442316`.sessionM.external_user_mappings u
	join `marketing-data-442316`.`sessionM.users` uu
	on uu.user_id = u.user_id
where 1=1
and u.external_user_id_type = 'cafezupas'
-- NOTE: partitions on the RAW u.user_id while selecting lower(u.user_id). Harmless today -
-- the source is 100% lowercase - and cust_trans's pos_transaction_key dedupe below now caps
-- any fan-out. Partitioning on lower(u.user_id) would close it properly (Asana 1216995170178886).
qualify row_number() over(partition by u.user_id order by u.updated_at desc) = 1
)

, header_trans as (
select safe_cast(h.pos_transaction_key as int64) as pos_transaction_key
, h.transaction_id
from `marketing-data-442316`.sessionM.transaction_headers h
where 1=1
-- '2026-07-29' CRITICAL FIX: was `>`. create_date is a DATE, so `>` dropped the ENTIRE
-- boundary day of every reload window, and intraday runs (start_date = run_date) matched
-- nothing at all. Cost ~7,900 orders/day their loyalty identity while every sales figure
-- looked normal. Proven: start_date 2026-07-21 gave 0 links with `>` and 7,927 with `>=`.
and h.create_date >= start_date
qualify row_number() over(partition by h.pos_transaction_key order by h.last_updated_at desc) = 1
)

-- '2026-07-29' rewritten: resolve identity FIRST via inner joins, then dedupe once at the
-- grain the consumer actually needs (pos_transaction_key - what the final SELECT joins on).
-- Only resolvable users can win, structurally. Safe because pos_transaction_key <-> transaction_id
-- is 1:1 after header_trans (verified: 731,353 rows, 731,353 distinct of each, 0 reuse).
, cust_trans as (
select
h.pos_transaction_key
, safe_cast(m.external_user_id as int64) as external_user_id
, lower(m.email) as email  -- '2026-07-29' added lower() for consistency
from header_trans h
	join all_trans_users u
	on u.transaction_id = h.transaction_id
		join sm_external_user_map m
		on m.user_id = u.user_id
qualify row_number() over(
  partition by h.pos_transaction_key
  order by u.updated_date desc
) = 1
)


, employee_discount_offer as (
select distinct h.pos_transaction_key
from header_trans h
	join discount_trans_id d
	on d.transaction_id = h.transaction_id
)


-- '2026-07-27' FAN-OUT FIX: dedupe on brink_order_id, not po.id. po.id was already unique, so
-- the previous `partition by po.id` was a no-op. The actual defect is two DIFFERENT pulse
-- orders pointing at one Brink order (e.g. brink_order_id 2279778269187 -> pulse 4545135 and
-- 4608051), which produced two mart rows, double-counted $263.99 and attributed one order to
-- two customers. HIGHEST pulse id wins (`order by po.id desc`) - steward's call: the later
-- pulse order is the one actually tied to the real order.
-- TODO: replace with a proper brink<->pulse map table that picks more intelligently.
--
-- Scoping note: `po.business_date >= start_date` is safe. Verified 2026-07-27 across June -
-- of the 55 orders where pulse and Brink business_date disagree, pulse is always the LATER
-- date (lag -1 to -42 days), never earlier, so no in-window Brink order loses its pulse row.
, pulse_orders as (
select
po.id
, po.business_date
, po.customer_id
, po.is_catering
, po.promise_time
, po.source
, po.brink_order_id
, po.created_at
from `marketing-data-442316`.pulse.orders po
where 1=1
and po.brink_order_id > 0
and po.business_date >= start_date
qualify row_number() over(partition by po.brink_order_id order by po.id desc) = 1
)


select
bo.Id as brink_order_id
, po.id as pulse_order_id
-- '2026-07-24' destination test moved first. Previously `when po.is_catering is null or
-- po.is_catering = false then false` fired first, making the destination branch dead code and
-- flagging POS-only catering orders (Catering Online Delivery, EZ Cater, ...) as false.
, case when lower(bd.name) like '%cater%' or po.is_catering = true then true
		else coalesce(po.is_catering, false) end as is_catering
-- '2026-07-29' FIXED. Guest checkout is a DIGITAL/PULSE concept only (steward definition) —
-- an in-store POS order has no guest/member distinction to make, so the flag is NULL there.
--
-- The old `ocs.is_loyalty_user is null` never tested loyalty at all. pulse.order_customers
-- .is_loyalty_user is a non-nullable boolean (4,224,215 true / 3,669,122 false / 0 null), so
-- `is null` could only fire when the pulse row was ABSENT. The column was therefore an exact
-- alias for `pulse_order_id is null`: June 2026 had 425,630 POS-only orders and 425,630
-- orders flagged guest — identical sets — while ZERO digital orders were ever flagged guest.
-- 94,754 loyalty-scanned POS orders ($2.21M net) were labelled guest; every real guest was
-- labelled member.
--
-- Adding `ocs.order_id is not null` to the old predicate does NOT fix it — it removes the
-- only case that ever satisfied `is null`, yielding false on every order (verified: 0 rows
-- match across all 7,893,337 pulse order_customers rows). The value wanted is the boolean
-- itself, negated.
--
-- '2026-07-29' NARROWED: guest also requires a FIRST-PARTY digital source. Third-party and
-- kiosk orders are non-loyalty by construction, not by guest choice, and would swamp the real
-- guest population. July 2026 (07-01..07-28) non-loyalty share by raw po.source:
--     checkmate          90,834 orders  100.0% non-loyalty  -> excluded (third party)
--     ezcater             1,118          100.0%             -> excluded (third party)
--     Outdoor Kiosk      34,024           88.7%             -> excluded (in-store terminal)
--     operator            1,869            0.0%             -> excluded (call center)
--     mobile_web_source  28,878           48.6%  <- guest checkout
--     web_source         15,983           19.9%  <- guest checkout
--     iOS                62,692            0.1%             (native app requires login)
--     Android            12,668            0.3%             (native app requires login)
-- Guest checkout is a WEB / MOBILE-WEB feature; the native apps still require login. July
-- guest orders under this definition: 17,320. Including Outdoor Kiosk would have added 30,165
-- in-store terminal orders and made the metric meaningless.
--
-- NOTE: 'iOS' and 'Android' ARE raw po.source values, not just the cleaned order_source
-- labels. 'mobile_source' is the legacy iOS value (1,518 orders, 2023 only) and is included
-- for full-history correctness — order_source maps it to 'iOS'.
--
-- MATCH IS CASE-INSENSITIVE by design. Full history holds exactly 10 distinct po.source
-- values, and one of them is 'IOS' — a single order on 2023-06-14 that a case-sensitive
-- in-list would drop. Same failure class as the case-SENSITIVE aggregator branches in
-- customer_type below: one oddly-cased value from upstream silently changes an order's
-- classification. lower() removes the whole category of problem.
--   guest-eligible : iOS 2,094,394 · mobile_web_source 950,282 · web_source 898,673
--                    Android 467,369 · mobile_source 1,518 · IOS 1
--   excluded       : checkmate 2,519,649 · Outdoor Kiosk 900,124 · operator 73,832
--                    ezcater 19,149
, case
    when ocs.is_loyalty_user = false
     and lower(po.source) in ('mobile_web_source','web_source','ios','android','mobile_source')
    then true else false end as is_guest_order
, po.customer_id as pulse_customer_id
, t.external_user_id as sm_external_user_id
, bo.BusinessDate as business_date
, case when date_diff(date(bo.ClosedTime), bo.BusinessDate, day) > 0 then coalesce(po.promise_time, bo.OpenedTime) else bo.ClosedTime end as order_datetime
, timestamp(case when date_diff(date(bo.ClosedTime), bo.BusinessDate, day) > 0 then coalesce(po.promise_time, bo.OpenedTime) else bo.ClosedTime end , s.timezone_name) as order_timestamp_utc
, bo.FKStoreId as store_id
, s.store_name
, s.store_state   -- '2026-07-30' renamed from `state` for consistency with order_lines and store_info
, bd.name as destination
, po.`source`
, case
    when lower(bd.name) like '%cater%' then 'Catering'
    when bd.name like 'Drop Spot%' then 'Digital'
    when bd.name in ('Good Life Lane','Online Takeout','Curbside','CZ Delivery') then 'Digital'
    when bd.name in ('Fundraiser','Fundraiser Drive-Thru') then 'Fundraiser'
    when bd.name in ('Call in Takeout','Drive Thru','Kiosk Dine in','Kiosk Dine In',
                            'Kiosk Drive Thru','Kiosk To Go','TAKEOUT','Takeout','To Stay') then 'In-Store'
    when bd.name in ('DoorDash','Google','GrubHub','Postmates','UberEats') then 'Third_Party'
    else 'Other'
  end as revenue_category
, case
    when po.source in ('CallCenter','operator') then 'Operator'
    when po.source = 'mobile_source' then 'iOS'
    when po.source = 'mobile_web_source' then 'Mobile Web'
    when po.source = 'web_source' then 'Web'
    when po.source in ('ThirdParty','checkmate','Third Party Integration') then 'Checkmate'
    else po.source
  end as order_source
, case when po.id is null and t.external_user_id is not null then 1 else 0 end as in_store_scan
, bo.OpenedTime as opened_time
, bo.GrossSales as gross_sales
, boi.item_gross_sales
, boim.mods_gross_sales
, bo.subtotal as subtotal
, coalesce(gc.total_gift_card_amount,0) as total_gift_card_amount
, coalesce(d.total_discount_amount,0) as total_discount_amount
, coalesce(bp.total_promotions_amount,0) as total_promotions_amount
, case
	when do.pos_transaction_key is not null then 1
	when d.is_employee_discount = 1 then 1 else 0 end as is_employee_discount
, coalesce(p.total_tip_amount,0) as total_tip_amount
, coalesce(boi.total_delivery_tip_amount, 0) as total_delivery_tip_amount
, coalesce(boi.total_other_tip_amount, 0) as total_other_tip_amount
, bo.NetSales as brink_net_sales  -- **for validation only**  '2026-07-24' net sales will now be a calc of gross sales - discounts - promotions
, bo.GrossSales - coalesce(d.total_discount_amount,0) - coalesce(bp.total_promotions_amount,0) as net_sales
-- , boi.item_netsales_with_mods
-- , boi.item_net_sales
-- , boim.mods_net_sales
, bo.rounding
, bo.Tax as tax
, coalesce(boi.total_fees_amount,0) as total_fees_amount
, coalesce(p.total_payment_amount,0) as total_payment_amount
, coalesce(p.total_change, 0) as total_change
, lower(ocs.email) as email  -- '2026-07-29' added lower() for consistency
, ocs.phone
-- '2026-07-29' added lower(). pulse.customers.email was 8.7% non-lowercase (Braze and SessionM
-- are already 100% clean), which created 17,943 phantom duplicate identities in mapped_email and
-- split 5,604 real people across multiple mapped_cust_ids by letter case alone.
, lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, t.email)) as mapped_email
, split(lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, t.email)), '@')[safe_offset(1)] as mapped_email_domain
, coalesce(po.customer_id, t.external_user_id) as mapped_cust_id
-- '2026-07-24' customer_type: keeps non-person ids out of customer counts / frequency /
-- retention. NULL when the order has no identified customer.
--   kiosk      - shared outdoor-kiosk terminal accounts (NNN-outdoor-N@cafezupas.com)
--   internal   - employee / developer accounts (@cafezupas.com, @tkxel.com, @tkxel.io)
--   aggregator - third-party ordering funnel, matched on the order email: ezcater,
--                doordash.com / guest.doordash.com, itsacheckmate.com. Dominated by pulse
--                id 19192. (Matched by EMAIL, not by the old orphan-pulse-id test.)
--   person     - real guest, including sessionM-only in-store scanners
--
-- '2026-07-27' DELIBERATELY ORDER-LEVEL, NOT CUSTOMER-LEVEL (steward decision). The dominant
-- aggregator id 19192 does not exist in pulse.customers at all - it should, and there is an
-- open ticket with the dev team. Until that record exists there is no reliable customer-level
-- attribute to classify on, so resolving a single type per mapped_cust_id would just be
-- confidently wrong. Consequence: a mapped_cust_id CAN carry more than one customer_type
-- across its orders (30 ids / 108,313 orders in June 2026; 19192 alone is 107,807 aggregator
-- + 196 person). order_sequence compensates with its own customer-level guard - see below.
, case
    when coalesce(po.customer_id, t.external_user_id) is null then null
-- '2026-07-29' all five branches now compare against lower(...). The three aggregator LIKEs were
-- case-SENSITIVE while kiosk/internal used (?i) regex - so a partner sending EZCater@... would
-- have silently classified as 'person' and polluted every customer metric. Verified no
-- reclassification when applied (ci and cs counts matched exactly): purely defensive.
    when regexp_contains(lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, '')), r'(?i)^[0-9]+-outdoor-[0-9]+@cafezupas\.com$') then 'kiosk'
		when lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, '')) like '%ezcater%' then 'aggregator'
		when lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, '')) like '%doordash.com' then 'aggregator'
		when lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, '')) like '%itsacheckmate.com' then 'aggregator'
    when regexp_contains(lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, '')), r'(?i)@(cafezupas\.com|tkxel\.(com|io))$') then 'internal'
    else 'person'
  end as customer_type
, c.loyalty_signup_date
-- '2026-07-24' removed this section and added the new sequence table below which will be joined in the view
-- , case when coalesce(po.customer_id, t.external_user_id) is null then null else row_number() over(partition by coalesce(po.customer_id, t.external_user_id)
-- 	order by order_datetime, bo.id) end as customer_order_count
-- , date_diff(
--     bo.businessdate
--     , lag(bo.businessdate) over (
--         partition by coalesce(po.customer_id, t.external_user_id)
--         order by order_datetime
--       )
--     , day
--   ) as days_since_prev_order
from brink_order bo
	left join brink_order_item boi
	on boi.orderId = bo.id
		left join brink_order_item_modifiers boim
		on boim.orderid = boi.orderid
			left join pulse_orders po
			on po.brink_order_id = bo.Id
				left join `marketing-data-442316`.sales_ops.store_info s
				on s.store_id = bo.FKStoreId
					left join total_payment p
					on p.order_id = bo.Id
						left join `marketing-data-442316`.pulse.customers c
						on c.id = po.customer_id
							left join `marketing-data-442316`.pulse.order_customers ocs
							on ocs.order_id = po.id
								left join cust_trans t
								on t.pos_transaction_key = coalesce(po.id, bo.id)
									left join `marketing-data-442316`.brink.brinkDestinations bd
									on bd.Id = bo.DestinationId
									and bd.StoreID = bo.FKStoreId
										left join instore_emp_discounts d
										on d.order_id = boi.orderid
											left join employee_discount_offer do
											on do.pos_transaction_key = coalesce(po.id, bo.id)
												left join brink_promotions bp
												on bp.orderid = boi.orderid
													left join gift_card_purchase gc
													on gc.orderid = bo.id
;

-- ---------------------------------------------------------------------------
-- sales_ops.order_sequence
-- Customer order sequencing, split out of order_customer 2026-07-24 so the window functions
-- are computed over FULL history every run instead of being scoped to the reload window.
-- Rebuilt in full on every run of this script (~420 MB / ~97 slot-seconds - measured
-- 2026-07-24).
--
-- SCOPE: every order with a mapped_cust_id. ALL customer types are included - the only filter
-- is `mapped_cust_id is not null`. customer_type is carried as a column so the CALLER filters.
-- Customer metrics still require customer_type = 'person'; that filter belongs downstream.
--
-- '2026-07-27 SCOPE CHANGE (steward decision): NO customer_type filter here. Rationale: don't
-- bake compensation for upstream bad data into the mart - the earlier person-filter plus
-- customer-level guard was chasing pulse's missing customer record for id 19192, and that
-- belongs in the dev fix, not here.
--
-- '2026-07-29 the unfiltered scope is INTENTIONAL - DO NOT add a customer_type filter here.
-- Non-person ids appearing in this table are a symptom of pulse.customers not being maintained
-- correctly upstream (ETL team aware). Leaving them visible keeps that breakage measurable as
-- an ongoing data-source accuracy check; filtering here would hide the defect and remove the
-- signal that tells us when it is fixed. Their counts shrinking on their own IS the measurement.
-- Current reading: person 7,196,157 rows / aggregator 2,517,397 / kiosk 785,364 / internal 23,684.
--
-- CONSEQUENCE - the window functions run over ALL of a customer's orders regardless of type.
-- Filtering customer_type = 'person' AFTER the fact selects rows but does NOT renumber them, so
-- a mixed id still shows million-scale customer_order_count on its person rows.
-- Canonical rule for customer metrics is unchanged: filter customer_type = 'person'.
--
-- '2026-07-29 DROPPED lifetime_customer_order_count - it lives on sales_ops.customer_attribute
-- as lifetime_order_count, so there is one unambiguous source. NOTE the two are NOT the same
-- number: customer_attribute is person-only, excludes store 1111, and is as-of YESTERDAY, while
-- this table spans all customer types and all stores at current freshness. They agree for
-- 1,374,231 of 1,376,394 shared customers (99.84%); 1,434 non-person ids now have no lifetime
-- count anywhere and must be counted from order_customer directly if ever needed.
-- ---------------------------------------------------------------------------


-- drop table `marketing-data-442316`.sales_ops.order_sequence;
create or replace table `marketing-data-442316`.sales_ops.order_sequence
partition by business_date
cluster by brink_order_id, mapped_cust_id as
select
  oc.brink_order_id
, oc.business_date
, oc.mapped_cust_id
, oc.customer_type
, row_number() over w                                      as customer_order_count
, date_diff(oc.business_date, lag(oc.business_date) over w, day)  as days_since_prev_order
--, count(*) over(partition by oc.mapped_cust_id) as lifetime_customer_order_count  -- '2026-07-29' excluded - use sales_ops.customer_attribute.lifetime_order_count
-- , min(oc.order_datetime) over(partition by oc.mapped_cust_id) as first_order_datetime
-- , max(oc.order_datetime) over(partition by oc.mapped_cust_id) as last_order_datetime
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.mapped_cust_id is not null
window w as (partition by oc.mapped_cust_id order by oc.order_datetime, oc.brink_order_id)
;
