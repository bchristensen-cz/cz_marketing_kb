-- Build script: `marketing-data-442316`.sales_ops.order_lines
-- Runs hourly at minute :02 (see schedule logic below).
-- Grain: one row per order line element (item / modifier / fee / tip / discount / gift_card / promotion / surcharge).
-- Documentation: data_dictionaries/sales_ops.order_lines.md

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


-- ⚠️ 2026-07-30: this predicate MUST be `business_date`. The full-history rebuild that day
-- renamed the target column from BusinessDate to business_date; the old `businessdate`
-- spelling here failed with `Unrecognized name: businessdate` and would have broken the
-- hourly incremental load on its next run. Note `bo.BusinessDate` further down is a
-- DIFFERENT column on the raw brink.brinkOrder table, which still uses the old spelling —
-- do not "fix" those to match.
delete `marketing-data-442316`.sales_ops.order_lines
where business_date >= start_date;

insert into `marketing-data-442316`.sales_ops.order_lines


-- Full-history rebuild: comment out the delete + insert above and uncomment this block.
--drop table `marketing-data-442316`.sales_ops.order_lines;
-- declare start_date date;
-- set start_date = '2018-08-07';
-- create or replace table `marketing-data-442316`.sales_ops.order_lines
-- partition by business_date
-- cluster by rev_center_name, item_name, parent_item_grp_name, parent_rev_center_name
-- as

with brink_order as (
-- '2026-07-31' FKStoreId added so the promotion branch can resolve names per store.
select distinct bo.Id, bo.FKStoreId as storeid
from `marketing-data-442316`.brink.brinkOrder bo
where 1=1
and bo.businessdate >= start_date
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

-- '2026-07-31' promotion name lookup. `brinkOrderPromotion.Name` is NULL on 171,522 of
-- 240,191 rows (71.4%) and empty on 319 more, which is why promotion lines used to land with
-- a NULL description / item_name / item_type. brinkPromotions is the name master: 5,792 rows,
-- 83 promotion ids, and (Id, StoreId) is UNIQUE — so the join below is exact, one row, and
-- deterministic. Store scope matters: promotion names are store-specific (id 642425436 is
-- '50% off Lunch QR Craig rd' at store 164 and '50% off Blue Diamond' at store 168), so an
-- id-only lookup mislabels 47 lines of full history and, on a name-count tie, can pick a
-- different winner on each rebuild. Verified 2026-07-31: (Id, StoreId) matches 240,187 of
-- 240,191 promotion lines; the 4 misses fall back to 'Promotion'.
, promotions as (
with prom_cnt as (
select p.id, p.StoreID
, p.Name
, count(*) as cnt
from `marketing-data-442316`.brink.brinkPromotions p
group by 1,2,3
)

select p.id
, p.storeid
, p.name
, p.cnt
, row_number() over(partition by p.id, p.storeid order by p.cnt desc) as rn
from prom_cnt p
qualify rn = 1
)

, order_lines as (
select
boi.orderid as order_id
, boi.id as order_item_id
, 1 as item_id_seq_num
, boi.compositeorderitemid as composite_item_id
, case when f.id is not null then 'fee'
		when t.id is not null then 'tip' else 'item' end as line_item_type
, boi.ItemId as item_id
, boi.Description as description
, boi.ItemGrossSales as amount
, case when coalesce(t.id) is not null
		then 0 else boi.ItemGrossSales end as item_gross_sales
, case when coalesce(t.id) is not null
		then 0 else boi.ItemNetSales end as item_net_sales
, 'none' as item_modifier
from `marketing-data-442316`.brink.brinkOrderItem boi
	left join fee_items f
	on f.id = boi.itemid
		left join tip_items t
		on t.id = boi.itemid
	join brink_order bo
	on boi.orderid = bo.id
where 1=1
and boi.IsCleared = false
and boi.IsVoided = false
and boi.IsDeleted = false
)

-- SELLABLE-ORDER GUARD. Orders whose brinkOrderItem rows carry no sellable value. Discount and
-- promotion lines are suppressed for these orders (see the two `join valid_order_lines` below);
-- item / modifier / gift_card / surcharge lines are NOT touched — a gift-card-only order is
-- legitimately item-less and its gift card is a real sale.
--
-- ⚠️ DEPLOYMENT HISTORY — this sat in the repo UNDEPLOYED for two days. Committed 2026-08-15
-- under the name `sellable_orders` (223b774); the scheduled query kept running without it, so
-- the repo tie-out numbers below described a table that did not exist yet. Brent deployed the
-- guard himself 2026-08-17 as `valid_order_lines`, with a full-history CTAS rebuild; the repo
-- CTE was renamed that day to match the deployed name. Authoritative check on whether a
-- guard is actually live — the built table alone will mislead you:
--   select regexp_contains(j.query, r'(?i)valid_order_lines') from `region-us`.INFORMATION_SCHEMA.JOBS_BY_PROJECT j
--   where j.query like '%sales_ops.order_lines%' and j.query like '%brinkOrderPromotion%'
--   order by j.creation_time desc
--
-- WHY: sales_ops.order_customer joins its discount and promotion CTEs on `boi.orderid`, where
-- boi is a CTE carrying this exact `having` guard. An order the guard drops therefore reports
-- total_discount_amount = 0 and total_promotions_amount = 0 over there even though the
-- brinkOrderDiscount rows exist with isDeleted = false. Emitting the discount line here for
-- such an order is what made order_line_discount_detail run $753.68 ABOVE order_customer over
-- the trailing 90 days (80 orders, measured 2026-08-15). The orders are voided/comped shells:
-- Brink zeroes the header (GrossSales / NetSales / Subtotal / Total all 0) and voids the items
-- but leaves the discount row standing, so nothing was sold and nothing was given away.
--
-- WHY THE AMOUNT TEST AND NOT JUST ROW PRESENCE: 78 of the 80 had every item row
-- IsCleared/IsVoided/IsDeleted, so row presence alone would catch them. The other 2 carried a
-- single surviving 'Online Details Memo' line at $0.00 gross — a placeholder, not a sale.
-- Row presence alone leaves those 2 ($15.84 / 90 days) unreconciled; the amount test ties to $0.
--
-- VERIFIED 2026-08-15: this guard reproduces order_customer.has_order_items EXACTLY —
-- 2,050,577 orders over 90 days, zero disagreements in either direction.
--
-- RE-VERIFIED 2026-08-17 over FULL HISTORY, at discount grain, against order_customer. Every
-- order carrying a live brinkOrderDiscount row, bucketed by what the guard sees:
--
--   bucket                          orders     order_customer bills discount?
--   1. no surviving item rows       29,092     0 of 29,092  → suppress (both arms agree)
--   2. items all zero/negative       1,605     0 of  1,605  → suppress (both arms agree)
--   3. gross <= 0 but net > 0           61     61 of     61  → KEEP (net arm only)
--   4. sellable                  3,101,131     2,762,087     → keep
--
-- Buckets 1 and 2 are why the guard exists and both arms drop them. Bucket 3 is the entire
-- reason the second arm is not optional. With both arms, bucket 4 ties to the penny:
-- order_customer $23,457,616.95 vs order_lines -$23,457,616.95.
--
-- SCOPE: removes 42,092 discount/promotion lines / -$238,698.36 over full history (orders with
-- no surviving item rows) plus 2,701 lines / -$45,348.22 (orders whose surviving items are all
-- $0). The second bucket is concentrated in 2019-2022; it is -$58.17 in 2026 and -$396.97 in
-- 2025. Post-change full-history discount total: -$25,693,161.50 (was -$25,967,881.35).
--
-- ⚠️ BOTH ARMS ARE LOAD-BEARING. DO NOT SIMPLIFY THIS TO `having sum(ol.amount) > 0`.
-- THE VERSION DEPLOYED 2026-08-17 HAD THE GROSS ARM ONLY — if the live scheduled query still
-- reads `having sum(ol.amount) > 0`, it is short this arm and owes a full-history rebuild.
-- (Corrected 2026-08-17. The note that stood here claimed the arms "only diverge on a tip-only
-- order with non-positive gross, which the gross arm already excludes" — that is WRONG. The
-- divergent orders carry ZERO tip rows.)
--
-- `ol.amount` on item/fee/tip lines IS the raw boi.ItemGrossSales, so the gross arm mirrors
-- order_customer. The net arm alone keeps 61 orders / 61 discount lines / -$2,104.52 over full
-- history: orders whose surviving brinkOrderItem rows ALL carry ItemGrossSales = 0 while the
-- order HEADER records real revenue — GrossSales $8,136.30 and Total $6,446.83 across the 61.
-- ItemNetSales survives on them as rounding crumbs ($4.38 total), and that is the only thing
-- holding them on the sellable side. They are real sales with a zeroed item-level gross, not
-- voided shells. sales_ops.order_customer reports a non-zero total_discount_amount for ALL 61
-- (+$2,104.52, verified 2026-08-17), so dropping the net arm re-opens an order_lines vs
-- order_customer gap — in the OPPOSITE direction from the one this guard was built to close.
--
-- ⚠️ A ONE-ARM GUARD HIDES ON EVERY DAILY RUN. All 61 orders fall in 2019-2023 (9/10/15/25/2
-- by year). The 8-day and 35-day reloads tie out perfectly without the net arm; only the
-- 380-day and full-history rebuilds break. The zero-disagreement check above ran over 90 days
-- and therefore could not have covered a single one of them — it validated the guard, not the
-- choice between one arm and two.
, valid_order_lines as (
select
  ol.order_id
from order_lines ol
group by
  ol.order_id
having sum(ol.amount) > 0 or sum(ol.item_net_sales) > 0
)

, brink_order_item_lines as (
select *
from order_lines

union all

select
boim.orderId
, boim.orderitemid
, boim.id
, null
, 'modifier' as item_type
, boim.ItemId
, i.Name
, boim.ItemGrossSales as amount  -- was boim.GrossSales; ItemGrossSales is the true modifier contribution (verified 2026-07-23: order gross match 94.2% -> 99.99%)
, boim.ItemGrossSales as gross
, boim.ItemNetSales as net
, mc.name as item_modifier
from `marketing-data-442316`.brink.brinkOrderItemModifier boim
	join (select distinct ol.order_item_id, ol.order_id from order_lines ol) ol
	on ol.order_item_id = boim.orderitemid
	and ol.order_id = boim.orderid
			left join (select i.id, i.name from `marketing-data-442316`.brink.brinkItems i
						qualify row_number() over(partition by i.id order by i.storeid) = 1) i
			on i.id = boim.ItemId
				left join (select distinct mc.id, mc.name from `marketing-data-442316`.brink.brinkModifierCode mc) mc
				on mc.id = boim.ModifierCodeId

union all

select
bod.OrderId
, bod.id
, row_number() over(partition by bod.OrderId, bod.DiscountId order by bod.id) as rn
, null
, 'discount' as item_type
, bod.DiscountId
, coalesce(nullif(trim(bod.Name),''), 'Discount') as name  -- '2026-08-12' added nullif for cleaner descriptions down stream (bare coalesce missed empty strings)
, bod.Amount * -1  as amount
, 0 as gross
, 0  as net
, 'none'
from `marketing-data-442316`.brink.brinkOrderDiscount bod
	join brink_order bo
	on bo.id = bod.orderid
		join valid_order_lines so   -- '2026-08-15' see the guard above; ties this table to order_customer
		on so.order_id = bod.orderid
where 1=1
and bod.isDeleted = false

union all

select
gc.orderId
, gc.id
, row_number() over(partition by gc.OrderId, gc.itemid order by gc.id) as rn
, null
, 'gift_card' as item_type
, gc.ItemId
, gc.Description
, gc.Price as amount
, 0 as gross
, 0 as net
, 'none'
from `marketing-data-442316`.brink.brinkOrderGiftCard gc
	join brink_order bo
	on bo.id = gc.orderid

union all

select
p.orderId
, row_number() over(partition by p.OrderId, p.PromotionId order by p.id) as rn
, p.Id
, null
, 'promotion' as item_type
, p.PromotionId
, coalesce(pn.Name, 'Promotion') as description  -- '2026-07-31' was p.Name, NULL 71.4% of the time
, p.Amount * -1 as amount
, 0 as gross
, 0 as net
, 'none'
from `marketing-data-442316`.brink.brinkOrderPromotion p
	join brink_order bo
	on bo.id = p.orderid
		join valid_order_lines so   -- '2026-08-15' see the guard above; ties this table to order_customer
		on so.order_id = p.orderid
    left join promotions pn  -- '2026-07-31' name master, joined per store
    on pn.id = p.promotionid
    and pn.storeid = bo.storeid

union all

select
s.orderId
, row_number() over(partition by s.OrderId order by s.id) as rn
, s.Id
, null
, 'surcharge'
, s.SurchargeId
, s.Name
, s.Amount
, s.Amount
, s.Amount
, 'none'
from `marketing-data-442316`.brink.brinkOrderSurcharge s
	join brink_order bo
	on bo.id = s.orderid
)

, brink_items as (
 with items as (
  select
    bi.id
    , bi.name
    , bi.revenuecenterid
    , bi.storeid
    , trim(bi.name) as name_trimmed
    , regexp_extract(bi.name, r'^(REG|Mini|LG|PRTY|HALF|Kids|LARGE|Medium|Tray|QUART) ') as size_prefix
    , bi.price
  from `marketing-data-442316`.brink.brinkItems bi

union all -- '2026-08-12' added discounts to items so we wouldn't have blank descriptions and have better item names.
-- Discount lines now resolve item_name from the brink.brinkDiscounts master (program-level names
-- like 'SessionM Loyalty', 'Online Discount') instead of echoing the order-level bod.Name.
-- Safety verified 2026-08-12: (Id, StoreID) is UNIQUE in brinkDiscounts (no fan-out); discount ids
-- collide with zero brinkItems / promotion / surcharge / gift-card ids; no discount names are blank
-- or hit the '.'-prefix / size-prefix / combo cleaning branches below.
-- ⚠️ revenuecenterid 1000000000001 is a SENTINEL that must never exist in brinkRevenueCenter
-- (verified absent 2026-08-12). If Brink ever issues that id as a real revenue center, discount
-- lines would pick up its name and could misroute in item_type (the brc.name branches evaluate
-- before the line_item_type branches). A plain `null as revenuecenterid` would be immune.

select
d.Id
, d.Name
, 1000000000001 as revenuecenterid
, d.StoreID
, trim(d.Name) as name_trimmed
, null as size
, d.Amount
from `marketing-data-442316`.brink.brinkDiscounts d


)
select
  i.id
  , i.name
  , i.revenuecenterid
  , i.storeid
  , case
      when i.name like '.%' then trim(substr(i.name_trimmed, 2))
      else i.name
    end as item_name
  , case
      when lower(i.name) like 'try 2 combo%' then 'Try 2 Combo'
      when i.name like 'Kids Combo%' then 'Kids Combo'
      when i.size_prefix is not null then substr(name, strpos(i.name, ' ') + 1)
      else regexp_replace(i.name_trimmed, r'^(\.|--)\s*', '')
    end as item_grp_name
  , case
      when lower(i.name) like 'try 2 combo%' then null
      when i.name = 'Kids Combo' then null
      when i.size_prefix is not null then
        case trim(i.size_prefix)
          when 'REG'    then 'Regular'
          when 'Mini'   then 'Mini'
          when 'LG'     then 'Large'
          when 'LARGE'  then 'Large'
          when 'PRTY'   then 'Party'
          when 'HALF'   then 'Half'
          when 'Kids'   then 'Kids'
          when 'Medium' then 'Medium'
          when 'Tray'   then 'Tray'
          when 'QUART'  then 'Quart'
        end
      else null
    end as item_size
    , i.price
from items i
)

, order_lines_detail as (
select
bol.order_id as brink_order_id
, po.id as pulse_order_id
, bo.BusinessDate
-- '2026-07-31' is_catering now matches sales_ops.order_customer's definition (fixed there
-- 2026-07-24). The destination test evaluates FIRST; previously `when po.is_catering is null
-- or po.is_catering = false then false` fired first, making the destination branch dead code
-- and missing every POS-only catering order. June 2026 effect on this table: +644 orders /
-- +$71,586 gross moved into catering. Until this change the two marts disagreed on catering.
--, case when po.is_catering is null or po.is_catering = false then false else true end as is_catering
, case when lower(bd.name) like '%cater%' or po.is_catering = true then true
		else coalesce(po.is_catering, false) end as is_catering
, case when date_diff(date(bo.ClosedTime), bo.BusinessDate, day) > 0 then coalesce(po.promise_time, bo.OpenedTime) else bo.ClosedTime end as order_datetime
, timestamp(case when date_diff(date(bo.ClosedTime), bo.BusinessDate, day) > 0 then coalesce(po.promise_time, bo.OpenedTime) else bo.ClosedTime end , s.timezone_name) as order_timestamp_utc
, bo.GrossSales
, bo.FKStoreId as store_id
, s.store_name
, bol.order_item_id
, bol.item_id_seq_num
, bol.line_item_type
, concat(cast(bo.Id as string),'-',cast(coalesce(bol.composite_item_id, bol.order_item_id) as string)) as combo_order_line_item_id
, bol.composite_item_id
, bol.description
, bol.item_id
, coalesce(bi.item_name, bol.description) as item_name
, coalesce(bi.item_grp_name, bol.description) as item_grp_name
, bi.item_size
, bol.item_modifier
-- '2026-07-31' (second pass) surcharge stamped too, so every line type has a non-NULL
-- rev_center_name — the last 2 NULL surcharge lines are gone (verified 2026-08-12: zero NULLs
-- since 2026-05-01).
, case
  when bol.line_item_type = 'discount' then 'Discount'
  when bol.line_item_type = 'promotion' then 'Promotion'  -- '2026-07-31'  added promotion
  when bol.line_item_type = 'surcharge' then 'Surcharge'  -- '2026-07-31'  added surcharge
  else brc.name end as rev_center_name
, bol.item_gross_sales
, bi.price
, round(
case when coalesce(safe_divide(bol.item_gross_sales,bi.price),0) < 1 then 1 else safe_divide(bol.item_gross_sales,bi.price) end
,0) as qty
, bol.amount
, bol.item_net_sales
-- '2026-07-31' (second pass) `else 'Other'` replaced the old `else coalesce(brc.name,
-- bol.description)` fallback. item_type is now a CLOSED 7-value domain: Entree, Kids Meals,
-- Beverage, Discount, Promotion, Surcharge, Other. Rev-center names (Modifiers, Desserts,
-- Gift Cards, ...) no longer appear in item_type — use rev_center_name for menu categories.
, case
    when brc.name in ('Bowls','Salads','Sandwiches','Soups') then 'Entree'
    when brc.name = 'Kids Meals' and bi.name = 'Kids Combo' then 'Kids Meals'
    when brc.name = 'Kids Meals' and bi.name <> 'Kids Combo' then 'Entree'
    when brc.name in ('Bottled Beverages','Foutain Beverages') then 'Beverage'
    when bol.line_item_type = 'discount' then 'Discount' -- '2026-07-30'  added discount
    when bol.line_item_type = 'promotion' then 'Promotion' -- '2026-07-31'  added promotion
    when bol.line_item_type = 'surcharge' then 'Surcharge'  -- '2026-07-31'  added surcharge
    else 'Other' -- '2026-07-31'  added other
  end as item_type
from brink_order_item_lines bol
	left join `marketing-data-442316`.brink.brinkOrder bo
	on bo.id = bol.order_id
		left join `marketing-data-442316`.pulse.orders po
		on po.brink_order_id = bo.id
		and po.brink_order_id > 0
			left join `marketing-data-442316`.sales_ops.store_info s
			on s.store_id = bo.FKStoreId
					left join `marketing-data-442316`.pulse.customers c
					on c.id = po.customer_id
							left join `marketing-data-442316`.brink.brinkDestinations bd
							on bd.Id = bo.DestinationId
							and bd.StoreID = bo.FKStoreId
								left join brink_items bi
								on bi.StoreID = bo.FKStoreId
								and bi.id = bol.item_id
									left join `marketing-data-442316`.brink.brinkRevenueCenter brc
									on brc.id = bi.RevenueCenterId
									and brc.StoreID = bi.StoreID
)

, combo_attrs as (
  select
    l.combo_order_line_item_id
    , string_agg(distinct l.rev_center_name, ' & ' order by l.rev_center_name) as attr_list
    , count(*) as cnt
  from order_lines_detail l
  where l.rev_center_name in ('Salads','Sandwiches','Soups')
  and l.is_catering = false
  group by l.combo_order_line_item_id
  having count(*) > 1
)

select
l.brink_order_id
, l.pulse_order_id
, l.is_catering
, l.BusinessDate as business_date
, l.order_datetime
, l.store_id
, l.store_name
-- "Market" = store_state (steward decision 2026-07-30). Denormalised here so item-by-market
-- questions need no join. NULL for stores absent from store_info (1111, 999) — so
-- `store_id <> 1111` is load-bearing for geography, not just for totals.
, si.store_state
, l.order_item_id
, l.item_id_seq_num
, l.line_item_type
, l.combo_order_line_item_id
, l.composite_item_id
, l.description
, l.item_id
, l.item_grp_name as item_name
, l.item_modifier
, l.item_size
, l.amount
, l.rev_center_name
, l.item_gross_sales
, l.price
, l.qty
, l.item_net_sales
, l.item_type
-- Discount/Promotion now evaluate BEFORE the 'Combos' rename, fixing the case-order defect
-- where a discount line whose combo_order_line_item_id collided with a real combo parent got
-- 'Try 2 Combo' (verified 2026-08-12: 0 leaks since 2026-05-01). parent_item_grp_name below
-- still evaluates 'Combos' first — the 1 known colliding line still leaks there.
, case
  when l.item_type = 'Discount' then 'Discount' -- '2026-07-30'  added discount
  when l.item_type = 'Promotion' then 'Promotion' -- '2026-07-31'  added promotion
  when coalesce(c.rev_center_name, l.description) = 'Combos' then 'Try 2 Combo'
	else coalesce(c.rev_center_name, l.description) end as parent_rev_center_name
, case
	when coalesce(c.rev_center_name, l.description) = 'Combos' then 'Try 2 Combo ' || ca.attr_list
	when coalesce(c.rev_center_name, l.description) = 'Foutain Beverages' then 'Fountain Beverage'
  when l.item_type = 'Discount' then 'Discount' -- '2026-07-30'  added discount
when l.item_type = 'Promotion' then 'Promotion' -- '2026-07-31'  added promotion
	else coalesce(c.item_grp_name, l.description) end as parent_item_grp_name
from order_lines_detail l
	left join order_lines_detail c
	on c.combo_order_line_item_id = l.combo_order_line_item_id
	and c.composite_item_id is null
	and c.line_item_type = 'item'
		left join combo_attrs ca
		on ca.combo_order_line_item_id = l.combo_order_line_item_id
      left join `marketing-data-442316.sales_ops.store_info` si
      on si.store_id = l.store_id
where 1=1
and l.BusinessDate >= start_date
;
