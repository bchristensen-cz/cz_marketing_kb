-- =====================================================================================
-- sales_ops.order_line_discount_detail — scheduled query. Deployed 2026-08-15.
-- History starts 2018-08-07. Same schedule as order_customer, wider reload windows.
--
-- GRAIN: one row per discount COMPONENT, not per Brink discount line. Brink emits exactly
-- ONE item_id = 643536109 line per order; where Pulse holds several components under it,
-- the Brink amount is split across them via discount_dist. Row count therefore runs ~1.5%
-- above the source line count (3,440,131 vs 3,388,269 full history, measured 2026-08-14).
--
-- discount_amount is the ONLY summable money column, and it reconciles to order_lines
-- exactly: -$25,693,161.50 on both sides, full history, identical filters (2026-08-15, after
-- the order_lines sellable-order guard). It read -$25,977,208.08 on the deployed table before
-- that guard; the -$284,046.58 difference is the fix, not a regression.
-- The un-prorated Brink amount is deliberately NOT emitted — it repeats on every split row
-- and summing it overstated July 2026 by 7.2% (-$504,903.90 vs a true -$471,017.34).
--
-- ⚠️ THE RECONCILIATION BELOW WAS WRITTEN AGAINST THE REPO SCRIPT, NOT A DEPLOYED TABLE. The
-- order_lines guard was committed 2026-08-15 but NOT deployed until 2026-08-17, so between
-- those dates this header described a tie-out that did not hold in production. It holds from
-- the 2026-08-17 full-history rebuild onward, and only if the deployed guard carries BOTH arms
-- (`sum(amount) > 0 or sum(item_net_sales) > 0`) — the gross arm alone leaves 61 orders /
-- $2,104.52 that order_customer bills and this table would not. Confirm against
-- INFORMATION_SCHEMA.JOBS_BY_PROJECT, not against the repo file.
--
-- ⚠️ IT NOW RECONCILES TO order_customer TOO — a NEW property, 2026-08-15. order_lines gained
-- a `valid_order_lines` guard that suppresses discount and promotion lines on orders whose
-- brinkOrderItem rows carry no sellable value. Before it, this table ran $753.68 ABOVE
-- order_customer's total_discount_amount + total_promotions_amount over 90 days across 80
-- orders. Cause: order_customer joins its discount and promotion CTEs on `boi.orderid`, so any
-- order its item CTE drops silently reports zero discount, while order_lines keyed on bo.id and
-- kept the money. Those orders are voided/comped shells — Brink zeroes the header (GrossSales /
-- NetSales / Subtotal / Total all 0) and voids the items but leaves the brinkOrderDiscount row
-- standing with isDeleted = false. Nothing was sold, so nothing was given away.
--
-- ⚠️ RUN THAT TIE-OUT ON CLOSED DAYS ONLY, AT ORDER GRAIN. The current business date drifts
-- ~47 orders / ~$438 against live brink because order_customer is a snapshot from its last
-- load. Date grain lets a compensating pair cancel out and read as a match. Assertion D below.
--
-- Full docs: data_dictionaries/claude.order_line_discount_detail.md
-- User-facing view: sql/claude.order_line_discount_detail.sql
--
-- ⚠️ THE 730-DAY FLOOR IS NOT THE WHOLE TABLE. 65.1% of rows (2,239,212 / -$15.6M) sit
-- before the widest reload window and are NEVER refreshed by any scheduled run. order_lines
-- was restated across full history three times in the month to 2026-08-14 (07-30, 07-31,
-- 08-12). Re-running the full-history build below is a REQUIRED step in the order_lines
-- rebuild checklist.
--
-- ⚠️ SOURCE LOOKBACK IS A BET. The source CTEs read start_date - 60 because
-- pulse.order_discounts.created_at is order PLACEMENT time while business_date is
-- FULFILLMENT time — catering is booked in advance (33 days observed max). The bet's alarm
-- is the 'Error' bucket: 0-1 lines on any closed day. See the assertions at the bottom.
-- =====================================================================================

declare run_dt datetime default current_datetime('America/Denver');
declare run_hour int64 default extract(hour from run_dt);
declare run_date date default date(run_dt);
declare start_date date;

set start_date = case
  -- 1st of month at 4am: ~24 month reload
  when extract(day from run_date) = 1 and run_hour = 4 then date_sub(run_date, interval 730 day)
  -- monday at 4am: ~13 month reload
  when format_date('%A', run_date) = 'Monday' and run_hour = 4 then date_sub(run_date, interval 380 day)
  -- daily at 4am: 120 day reload
  when run_hour = 4 then date_sub(run_date, interval 120 day)
  -- intraday: today only
  when run_hour between 8 and 23 then run_date
  -- all other hours: skip
  else null
end;

if start_date is null then
  return;
end if;

-- Explicit transaction: BigQuery scripts are not atomic. Without this, a failed insert
-- after a committed delete leaves a 120-day hole (730 on the 1st) that returns zeros
-- rather than an error, and the intraday runs only cover today so nothing heals it until
-- the next 4am pass.
begin transaction;

delete `marketing-data-442316`.sales_ops.order_line_discount_detail
where business_date >= start_date;

insert into `marketing-data-442316`.sales_ops.order_line_discount_detail

-- Initial full-history build (run once; also re-run after any order_lines full-history
-- restatement — see the frozen-block warning in the header):
-- declare start_date date;
-- set start_date = '2018-08-07';
-- create or replace table `marketing-data-442316`.sales_ops.order_line_discount_detail
-- partition by business_date
-- cluster by store_id, discount_type, discount_origin
-- as


with brink_discount_lines as (

select
ol.brink_order_id
, ol.pulse_order_id
, ol.is_catering
, ol.business_date
, ol.store_id
, ol.store_name
, ol.store_state
, oc.revenue_category
, oc.order_source
, ol.line_item_type
, ol.description
, ol.item_id
, ol.item_name
, round(ol.amount,2) as amount
from `marketing-data-442316`.sales_ops.order_lines ol
	left join `marketing-data-442316`.sales_ops.order_customer oc
	on oc.brink_order_id = ol.brink_order_id
	and oc.business_date = ol.business_date   -- partition-prunes the 50.7M-row side; oc is 1:1 on brink_order_id
where 1=1
and ol.line_item_type in ('discount','promotion')
and ol.business_date >= start_date
-- today IS loaded, deliberately, matching order_customer. Consequence: ~76% of today's
-- integrated lines read discount_type = 'Error' until the next 4am pass (531 of 694
-- measured 2026-08-14). Do not report today's discount mix intraday.
--and ol.business_date < current_date
and ol.store_id not in (1111, 999)   -- 999 has no store_info row -> NULL name/state
)

, pulse_discounts as (
select
od.order_id
, od.points
, od.`type`
, oi.name as discount_name
, upper(od.sessionM_user_offer_id) as sessionM_user_offer_id
, od.sessionM_root_offer_id
, safe_divide(round(od.amount, 2), round(sum(od.amount) over(partition by od.order_id), 2)) as discount_dist
from `marketing-data-442316`.pulse.order_discounts od
	left join `marketing-data-442316`.pulse.order_items oi
	on oi.id = od.order_item_id
where 1=1
and od.deleted_at is null
and od.amount > 0   -- guarantees the discount_dist denominator is non-zero
and od.created_at >= datetime(start_date - 60)
)

, header_trans as (
select safe_cast(h.pos_transaction_key as int64) as pos_transaction_key
, h.transaction_id
from `marketing-data-442316`.sessionM.transaction_headers h
where 1=1
and h.create_date >= start_date - 60
-- accepted loss: 2,535 keys carry >1 header; keeping the latest drops 13 USEROFFERID
-- discount rows across full history (measured 2026-08-14)
qualify row_number() over(partition by h.pos_transaction_key order by h.last_updated_at desc) = 1
)

, sm_discount_rel as (
select
d.transaction_discount_id
, d.discount_reference_id
, d.transaction_id
, t.pos_transaction_key
, d.discount_reference_type
, d.discount_source
, round(d.discount_amount,2) as discount_amount
, d.name as discount_name
from `marketing-data-442316`.sessionM.transaction_discounts d
	join header_trans t
	on t.transaction_id = d.transaction_id
where 1=1
and d.create_date >= start_date - 60
and t.pos_transaction_key > 78000000000
and d.discount_reference_type = 'USEROFFERID'
-- 1:1 on pos_transaction_key today (539,153 / 539,153, zero surplus, full history) but
-- nothing upstream enforces it. This join carries NO proration, so a second USEROFFERID
-- discount on one order would silently double discount_amount. Pin it, don't trust it.
qualify row_number() over(partition by t.pos_transaction_key order by d.discount_amount desc, d.transaction_discount_id) = 1
)


, offer_detail as (
select
  uo.user_offers_id
, uo.root_offer_id
, ro.name as offer_name
from `marketing-data-442316`.sessionM.user_offers uo
  left join `marketing-data-442316`.sessionM.offers o
  on o.offer_id = uo.offer_id
	  left join `marketing-data-442316`.sessionM.offers ro
	  on ro.root_offer_id = uo.root_offer_id
	  and ro.root_offer_id = ro.offer_id   -- self-restriction keeps this 1:1; do not remove
where 1=1
-- uo.create_date is when the offer was ISSUED, not redeemed. Widening start_date is what
-- makes this safe: over a 5-week window only 2 of 27,772 redemptions referenced an offer
-- issued before the floor, and the oldest was issued 2024-10-28 / redeemed July 2026 —
-- a ~20-month gap that only the 730-day monthly reload reaches.
and uo.create_date >= start_date - 60
-- cuts the user_offers scan hard and is semantically right (this is a redemption lookup),
-- but creates a silent dependency: if sessionM ever lags on stamping redeem_date, offer
-- attribution degrades with no alarm. 4 of 27,772 affected as of 2026-08-14.
and uo.redeem_date is not null
)


select
dl.brink_order_id
, dl.pulse_order_id
, dl.business_date
, dl.is_catering
, dl.store_id
, dl.store_name
, dl.store_state
, dl.revenue_category
, dl.line_item_type
-- the prorated value; the only summable money column. Deliberately NOT rounded here —
-- rounding each split row to cents breaks exact reconciliation across 3.4M rows.
, dl.amount * ifnull(pd.discount_dist,1) as discount_amount
, pd.points
, dl.item_id
-- NOT a channel. The Outdoor Kiosk and Third Party arms key on the ORDER; Online and
-- In-Store key on the DISCOUNT. Kiosk therefore carries every discount type (9 distinct in
-- 30 days off 799 lines) while Online carries 4. revenue_category is the channel axis.
, case
	when dl.order_source  = 'Outdoor Kiosk' then 'Outdoor Kiosk'
	when dl.revenue_category = 'Third_Party' then 'Third Party'
	when dl.item_id = 643536109 then 'Online'
	else 'In-Store' end as discount_origin
-- Arm order is load-bearing: pd.type is tested BEFORE the Third_Party fallback, so a
-- third-party order carrying a real Pulse component type classifies by type.
-- 'Error' = an integrated line with neither a Pulse type nor a Third_Party category.
-- 0-1 lines on any closed day; a sustained non-zero on a closed day means the -60 source
-- lookback got too short.
, case
	when dl.item_id = 643536109 and pd.type = 'points' then 'In-cart Points Redemption'
	when dl.item_id = 643536109 and pd.type = 'reward' then 'Reward Redemption'
	when dl.item_id = 643536109 and pd.type = 'offer' then 'Offer'
	when dl.item_id = 643536109 and dl.revenue_category = 'Third_Party' then 'Third Party Discount'
	when dl.item_id = 643536109 then 'Error'
	when dl.item_id = 643571116 then 'Reward Redemption'
	when dl.line_item_type = 'promotion' then 'Promotion'
	when dl.item_id = 3 then 'Manager Discount'
	when dl.item_id = 2 then 'Employee Meal Discount'
	when dl.item_id = 643529939 then 'Guest Relations'
	when dl.item_id = 643529958 then 'New Team Member Family Meal'
	when dl.item_id = 643529965 then 'Face To Face'
	when dl.item_id = 643571119 then 'Offline Cafe Zupas Rewards'
	-- open domain by design: item_name carries the brinkDiscounts program name since the
	-- 2026-08-12 order_lines rebuild, so a new program surfaces NAMED on day one instead of
	-- vanishing into 'Other'. Zero NULLs across 3.44M rows (verified 2026-08-14).
	else dl.item_name
end as discount_type
, dl.item_name
, coalesce(r.discount_name, pd.discount_name, dl.item_name) as discount_name
, coalesce(odr.root_offer_id, pd.sessionM_root_offer_id) as root_offer_id
, coalesce(odr.offer_name, od.offer_name) as offer_name
from brink_discount_lines dl
	left join pulse_discounts pd
	on pd.order_id = dl.pulse_order_id
	and dl.item_id = 643536109
		left join offer_detail od
		on od.user_offers_id = pd.sessionM_user_offer_id
			left join sm_discount_rel r
			on r.pos_transaction_key = dl.brink_order_id
			and dl.item_id = 643571116
				left join offer_detail odr
				on odr.user_offers_id = r.discount_reference_id
;
commit transaction;


-- =====================================================================================
-- Post-load assertions. Run after any logic change and after every order_lines
-- full-history rebuild.
--
-- ⚠️ Every date function here is pinned to America/Denver. Bare `current_date` is UTC, and
-- the intraday runs fire 8pm-11pm Denver = 2am-5am the NEXT UTC day, so a bare
-- `current_date` silently means "tomorrow" for a third of the schedule. This bit during
-- review 2026-08-14: three test builds either side of the UTC rollover picked different
-- windows and the comparison read as a logic regression when it was a clock difference.
-- =====================================================================================

-- A. discount_amount must reconcile to order_lines exactly.
--    Full history 2026-08-15: -$25,693,161.50 both sides (was -$25,977,208.08 on the deployed
--    table before the order_lines sellable-order guard).
-- select
--   round(sum(dd.discount_amount), 2) as mart_total
-- , (
--     select round(sum(ol.amount), 2)
--     from `marketing-data-442316`.sales_ops.order_lines ol
--     where 1=1
--     and ol.line_item_type in ('discount', 'promotion')
--     and ol.store_id not in (1111, 999)
--   ) as source_truth
-- from `marketing-data-442316`.sales_ops.order_line_discount_detail dd
-- ;

-- B. 'Error' on a CLOSED day should be 0-1 lines. Today is expected to spike (~76%).
-- select
--   dd.business_date
-- , countif(dd.discount_type = 'Error') as error_lines
-- , round(safe_divide(countif(dd.discount_type = 'Error'), countif(dd.item_id = 643536109)) * 100, 2) as pct_of_online_bucket
-- from `marketing-data-442316`.sales_ops.order_line_discount_detail dd
-- where 1=1
-- and dd.business_date >= date_sub(current_date('America/Denver'), interval 14 day)
-- group by
--   dd.business_date
-- order by
--   dd.business_date desc
-- ;

-- C. Offer attribution must not move when the reload window changes. Run on a Monday
--    (380d pass) and again on a Tuesday (120d pass) — the numbers must match. They did
--    not before the windowing fix (275 rows differed over an 8-day window).
-- select
--   dd.business_date
-- , countif(dd.offer_name is null) as null_offer_name
-- , countif(dd.root_offer_id is null) as null_root_offer_id
-- , count(*) as lines
-- from `marketing-data-442316`.sales_ops.order_line_discount_detail dd
-- where 1=1
-- and dd.business_date between date_sub(current_date('America/Denver'), interval 380 day)
--                          and date_sub(current_date('America/Denver'), interval 121 day)
-- group by
--   dd.business_date
-- order by
--   dd.business_date desc
-- ;

-- D. '2026-08-15' NEW. Must tie to sales_ops/claude.order_customer at ORDER grain.
--    Expect zero rows.
--    ⚠️ CLOSED DAYS ONLY — the current business date drifts ~47 orders / ~$438 against live
--    brink because order_customer is a snapshot from its last load. Not a defect.
--    ⚠️ Store 999 must be excluded on the order_customer side: this table drops it upstream,
--    claude.order_customer drops only 1111. Leaving it in costs $13.49 / 90 days.
--    ⚠️ ORDER grain, not date grain — date grain lets a compensating pair cancel out.
-- with dd as (
-- select
--   dd.business_date
-- , dd.brink_order_id
-- , abs(round(sum(dd.discount_amount), 2)) as amount
-- from `marketing-data-442316`.sales_ops.order_line_discount_detail dd
-- where 1=1
-- and dd.business_date between date_sub(current_date('America/Denver'), interval 90 day)
--                          and date_sub(current_date('America/Denver'), interval 2 day)
-- group by
--   dd.business_date
-- , dd.brink_order_id
-- )
-- , oc as (
-- select
--   oc.business_date
-- , oc.brink_order_id
-- , round(oc.total_discount_amount + oc.total_promotions_amount, 2) as order_discount
-- from `marketing-data-442316`.claude.order_customer oc
-- where 1=1
-- and oc.business_date between date_sub(current_date('America/Denver'), interval 90 day)
--                          and date_sub(current_date('America/Denver'), interval 2 day)
-- and oc.store_id not in (1111, 999)
-- )
-- select
--   dd.business_date
-- , dd.brink_order_id
-- , dd.amount
-- , oc.order_discount
-- from dd
-- 	full outer join oc
-- 	on oc.business_date = dd.business_date
-- 	and oc.brink_order_id = dd.brink_order_id
-- where 1=1
-- and ifnull(dd.amount, 0) <> ifnull(oc.order_discount, 0)
-- ;
