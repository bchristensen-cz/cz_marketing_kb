--****************************************************************************************************************************************
--****************************************************************************************************************************************
--****************************************************************************************************************************************
-- ITEM MARTS  -  sales_ops.item_daily  ->  sales_ops.items
-- Deployed 2026-09-14. Daily scheduled query, 07:30 America/Denver.
-- Sunday = full-history rebuild from 2018-08-07; every other day = trailing 8-day incremental.
-- Statement 1 rebuilds the item x day fact; statement 2 rebuilds the dimension from it in full every run.
--
-- Initial full-history load 2026-09-14, all six checks in sql/checks/items_build_checks.sql pass:
--   item_daily   1,314,070 rows (2018-08-13 -> today), 40.58 GiB scanned (the Sunday number; a weekday run is ~1 GiB).
--                Ties to order_lines exactly over 2026-08-10 -> 09-06: 5,134,823 units both sides,
--                unit diff 0, gross diff 0.00
--   items        3,242 rows = 3,242 distinct item_ids = 3,242 brinkItems ids, no fan-out.
--                2,234 ever sold / 1,008 never sold (962 of those still Active in Brink - mostly POS
--                config artifacts: '*** For 31 ***' guest-count markers, '** DEST TRAY **').
--                item_name and item_size agree with sales_ops.order_lines on 548 of 548 item_ids sold
--                in the trailing 45 days: zero mismatches, so the dimension joins 1:1 to the fact.
--   statement 2  152 MB - the dimension is rebuilt in full every day for nothing.
--
-- The old sales_ops.items (2,196 rows, item_id + rev_center_id grain, written once 2025-12-10 and
-- never refreshed) was dropped on 2026-09-14. A copy is parked at scratch.items_pre_20260914,
-- expiring 2026-12-13. rev_center_id is deliberately NOT part of the new grain: 5 item_ids move
-- revenue centre across stores, and keeping it would put the same item on several rows again.
-- Anything still joining on it fails loudly, which is the intent (steward call 2026-09-14).
--****************************************************************************************************************************************
--****************************************************************************************************************************************
--****************************************************************************************************************************************

-- history starts '2018-08-07';
declare run_dt datetime default current_datetime('America/Denver');
declare run_date date default date(run_dt);
declare start_date date;

set start_date = case
	when format_date('%A', run_date) = 'Sunday' then date '2018-08-07'
	else date_sub(run_date, interval 8 day)
end;


--****************************************************************************************************************************************
-- sales_ops.item_daily
-- item_id x business_date fact, 1,314,070 rows over full history (measured 2026-09-14).
-- Exists so the dimension below can recompute lifetime and trailing metrics every day for ~50 MB
-- instead of re-scanning order_lines (40.3 GB full history, measured 2026-09-14).
-- Excludes stores 1111 / 999 (locked exclusion) and the discount / promotion / surcharge line types:
-- on those lines order_lines.item_id holds a DiscountId / PromotionId / SurchargeId, NOT a brink item id.
-- That is the whole of the 131 sold item_ids with no brinkItems master row (27 + 73 + 31, measured 2026-09-14).
--****************************************************************************************************************************************

-- declare start_date date;
-- set start_date = '2018-08-07';
-- -- drop table `marketing-data-442316`.sales_ops.item_daily;
-- create or replace table `marketing-data-442316`.sales_ops.item_daily
-- partition by business_date
-- cluster by item_id
-- as

begin transaction;

delete `marketing-data-442316`.sales_ops.item_daily
where business_date >= start_date;

insert into `marketing-data-442316`.sales_ops.item_daily

select
ol.business_date
, ol.item_id
, count(distinct ol.store_id) as stores_selling
, count(distinct ol.brink_order_id) as orders
, sum(ol.qty) as units
, sum(ol.item_gross_sales) as gross_sales
, sum(ol.item_net_sales) as item_net_sales  -- does NOT reconcile to order-level net_sales; never quote it as net
, count(*) as lines_total
, countif(ol.line_item_type = 'item') as lines_as_item
, countif(ol.line_item_type = 'modifier') as lines_as_modifier
, countif(ol.line_item_type not in ('item','modifier')) as lines_as_other
, countif(ol.is_catering) as lines_catering
, sum(if(ol.is_catering, ol.qty, 0)) as units_catering
, sum(if(ol.is_catering, ol.item_gross_sales, 0)) as gross_sales_catering
, countif(ol.parent_rev_center_name = 'Try 2 Combo') as lines_in_combo
, count(distinct ol.item_name) as name_variants
, count(distinct ol.item_size) as size_variants
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date >= start_date
and ol.store_id not in (1111, 999)
and ol.line_item_type not in ('discount','promotion','surcharge')
group by 1,2;

commit transaction;


--****************************************************************************************************************************************
-- sales_ops.items
-- One row per brink item_id, every item in the master whether it has ever sold or not
-- (3,242 master ids vs 2,234 ever sold, measured 2026-09-14).
-- Rebuilt in full every run - it reads only item_daily and the small brink/pulse master tables.
--****************************************************************************************************************************************

create or replace table `marketing-data-442316`.sales_ops.items
cluster by item_id, item_name
as

with item_master as (  -- brinkItems is store-scoped: 214,182 rows = 3,242 ids x 98 stores, (id, storeid) verified unique 2026-09-14
select
bi.id as item_id
, bi.storeid as store_id
, bi.name
, bi.revenuecenterid as rev_center_id
, bi.price
, bi.plu
, bi.active
, bi.isgiftcard as is_gift_card
, bi.nonrevenueitem as is_non_revenue
, bi.itemtype as brink_item_type
, bi.isolddata as is_old_data  -- 1 = legacy extract (66 stores, numeric ItemType codes); 0 = current API sync (98 stores)
from `marketing-data-442316`.brink.brinkItems bi
)

, item_store_detail as (
select
im.item_id
, im.store_id
, im.name
, im.price
, im.plu
, im.active
, im.is_gift_card
, im.is_non_revenue
, im.brink_item_type
, im.is_old_data
, im.rev_center_id
, brc.name as rev_center_name
from item_master im
	left join `marketing-data-442316`.brink.brinkRevenueCenter brc
	on brc.id = im.rev_center_id
	and brc.storeid = im.store_id
)

-- the same item_id carries DIFFERENT products at different stores (measured 2026-09-14):
-- 96 ids have more than one name, e.g. 640934279 = 'Combo Turkey Cranbry Sand' at 37 stores and
-- 'Combo Turkey Avocado Club' at 29. Winner = the name used by the most stores, current rows breaking ties.
, name_by_store_count as (
select
isd.item_id
, isd.name
, isd.rev_center_id
, isd.rev_center_name
, min(isd.is_old_data) as is_old_data
, count(distinct isd.store_id) as stores
from item_store_detail isd
group by 1,2,3,4
)

, item_name_winner as (
select
n.item_id
, n.name as item_name_raw
, n.rev_center_id
, n.rev_center_name
, n.stores as name_store_count
from name_by_store_count n
qualify row_number() over(partition by n.item_id order by n.stores desc, n.is_old_data asc, n.name) = 1
)

-- name / size parsing is a copy of the brink_items CTE in sql/sales_ops.order_marts.sql so that
-- items.item_name joins 1:1 to order_lines.item_name. Change one, change the other.
, item_name_parsed as (
select
w.item_id
, w.item_name_raw
, w.rev_center_id
, w.rev_center_name
, w.name_store_count
, trim(w.item_name_raw) as name_trimmed
, regexp_extract(w.item_name_raw, r'^(REG|Mini|LG|PRTY|HALF|Kids|LARGE|Medium|Tray|QUART) ') as size_prefix
from item_name_winner w
)

, item_name_resolved as (
select
p.item_id
, p.item_name_raw
, p.rev_center_id
, p.rev_center_name
, p.name_store_count
, case
	when lower(p.item_name_raw) like 'try 2 combo%' then 'Try 2 Combo'
	when p.item_name_raw like 'Kids Combo%' then 'Kids Combo'
	when p.size_prefix is not null then substr(p.item_name_raw, strpos(p.item_name_raw, ' ') + 1)
	else regexp_replace(p.name_trimmed, r'^(\.|--)\s*', '')
  end as item_name
, case
	when lower(p.item_name_raw) like 'try 2 combo%' then null
	when p.item_name_raw = 'Kids Combo' then null
	when p.size_prefix is not null then
		case trim(p.size_prefix)
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
  end as item_size_parsed
from item_name_parsed p
)

, size_families as (  -- an unparsed size reads 'Regular' only when the family has sized siblings, else 'Not Sized'
select
r.item_name
, logical_or(r.item_size_parsed is not null) as family_has_sizes
from item_name_resolved r
group by 1
)

, item_config as (
select
isd.item_id
, count(distinct isd.store_id) as store_count_configured
, count(distinct if(isd.is_old_data = 0, isd.store_id, null)) as store_count_current
, count(distinct if(isd.is_old_data = 0 and isd.active, isd.store_id, null)) as store_count_active
, count(distinct isd.name) as name_variant_count
, count(distinct isd.rev_center_id) as rev_center_variant_count
, count(distinct if(isd.is_old_data = 0, isd.price, null)) as price_variant_count
, min(if(isd.is_old_data = 0 and isd.active, isd.price, null)) as price_min
, max(if(isd.is_old_data = 0 and isd.active, isd.price, null)) as price_max
, logical_or(isd.is_gift_card) as is_gift_card
, logical_or(isd.is_non_revenue) as is_non_revenue
, max(if(isd.is_old_data = 0, isd.plu, null)) as plu
, max(if(isd.is_old_data = 0, isd.brink_item_type, null)) as brink_item_type
from item_store_detail isd
group by 1
)

, price_modal as (  -- 1,352 ids carry more than one price across stores; current_price = the most common active price
select
isd.item_id
, isd.price as current_price
from item_store_detail isd
where 1=1
and isd.is_old_data = 0
and isd.active
group by 1,2
qualify row_number() over(partition by isd.item_id order by count(*) desc, isd.price desc) = 1
)

-- pulse -> brink item map. Only full_brink_item_id / half_brink_item_id are usable ids;
-- new_full_brink_item_id / new_half_brink_item_id are SKU strings ('BO643636715LG'), not ids - never cast them.
-- 48 brink ids point at more than one pulse item, so a live/most-recent winner is picked.
, pulse_item_map as (
select
pi.full_brink_item_id as item_id
, pi.id as pulse_item_id
, pi.name as pulse_item_name
, pi.category_id as pulse_category_id
, 'full' as pulse_item_role
, 'individual' as pulse_menu
, pi.deleted_at
, pi.updated_at
, date(pi.created_at) as pulse_created_date
from `marketing-data-442316`.pulse.items pi
where pi.full_brink_item_id > 0

union all

select
pi.half_brink_item_id
, pi.id
, pi.name
, pi.category_id
, 'half'
, 'individual'
, pi.deleted_at
, pi.updated_at
, date(pi.created_at)
from `marketing-data-442316`.pulse.items pi
where pi.half_brink_item_id > 0

union all

select
ci.full_brink_item_id
, ci.id
, ci.name
, ci.category_id
, 'full'
, 'catering'
, ci.deleted_at
, ci.updated_at
, date(ci.created_at)
from `marketing-data-442316`.pulse.catering_items ci
where ci.full_brink_item_id > 0

union all

select
ci.half_brink_item_id
, ci.id
, ci.name
, ci.category_id
, 'half'
, 'catering'
, ci.deleted_at
, ci.updated_at
, date(ci.created_at)
from `marketing-data-442316`.pulse.catering_items ci
where ci.half_brink_item_id > 0
)

, pulse_item as (
select
m.item_id
, m.pulse_item_id
, m.pulse_item_name
, m.pulse_item_role
, m.pulse_menu
, m.pulse_created_date
, c.name as pulse_category_name
, m.deleted_at is null as is_on_digital_menu
from pulse_item_map m
	left join `marketing-data-442316`.pulse.categories c
	on c.id = m.pulse_category_id
qualify row_number() over(partition by m.item_id order by m.deleted_at is null desc, m.updated_at desc, m.pulse_item_id) = 1
)

, item_sales as (
select
d.item_id
, min(d.business_date) as first_sold_date
, max(d.business_date) as last_sold_date
, count(distinct d.business_date) as days_sold
, max(d.stores_selling) as peak_stores_selling
, sum(d.orders) as lifetime_orders
, sum(d.units) as lifetime_units
, sum(d.gross_sales) as lifetime_gross_sales
, sum(d.item_net_sales) as lifetime_item_net_sales
, sum(d.lines_total) as lifetime_lines
, sum(d.lines_as_item) as lines_as_item
, sum(d.lines_as_modifier) as lines_as_modifier
, sum(d.lines_as_other) as lines_as_other
, sum(d.lines_catering) as lines_catering
, sum(d.units_catering) as units_catering
, sum(d.gross_sales_catering) as gross_sales_catering
, sum(d.lines_in_combo) as lines_in_combo
from `marketing-data-442316`.sales_ops.item_daily d
group by 1
)

, item_trailing as (
select
d.item_id
, sum(if(d.business_date >= date_sub(run_date, interval 28 day), d.units, 0)) as units_28d
, sum(if(d.business_date >= date_sub(run_date, interval 28 day), d.gross_sales, 0)) as gross_sales_28d
, max(if(d.business_date >= date_sub(run_date, interval 28 day), d.stores_selling, 0)) as stores_selling_28d
, sum(if(d.business_date >= date_sub(run_date, interval 90 day), d.units, 0)) as units_90d
, sum(if(d.business_date >= date_sub(run_date, interval 90 day), d.gross_sales, 0)) as gross_sales_90d
, sum(if(d.business_date >= date_sub(run_date, interval 365 day), d.units, 0)) as units_365d
, sum(if(d.business_date >= date_sub(run_date, interval 365 day), d.gross_sales, 0)) as gross_sales_365d
from `marketing-data-442316`.sales_ops.item_daily d
where d.business_date >= date_sub(run_date, interval 365 day)
group by 1
)

-- launch_date = the first day the item was selling in at least 25% of the stores it ever reached.
-- Brink itself carries NO item dates: CreatedTime / StartDate / EndDate / LastEditedTime are blank on all
-- 111,508 legacy rows and null on all 102,674 current rows (measured 2026-09-14), so this is derived, not given.
-- It differs from first_sold_date whenever an item was tested in a handful of stores before rollout.
, item_launch as (
select
d.item_id
, min(d.business_date) as launch_date
from `marketing-data-442316`.sales_ops.item_daily d
	join item_sales s
	on s.item_id = d.item_id
where d.stores_selling >= 0.25 * s.peak_stores_selling
group by 1
)

select
r.item_id
, r.item_name
, case
	when f.family_has_sizes then coalesce(r.item_size_parsed, 'Regular')
	else coalesce(r.item_size_parsed, 'Not Sized')
  end as item_size
, r.item_name_raw
, r.rev_center_id
, r.rev_center_name
, case
	when r.rev_center_name in ('Bowls','Salads','Sandwiches','Soups') then 'Entree'
	when r.rev_center_name = 'Kids Meals' and r.item_name_raw = 'Kids Combo' then 'Kids Meals'
	when r.rev_center_name = 'Kids Meals' and r.item_name_raw <> 'Kids Combo' then 'Entree'
	when r.rev_center_name in ('Bottled Beverages','Foutain Beverages') then 'Beverage'
	else 'Other'
  end as item_type

-- lifecycle
, s.first_sold_date
, l.launch_date
, s.last_sold_date
, date_diff(run_date, s.last_sold_date, day) as days_since_last_sold
, s.days_sold
, s.item_id is not null as has_ever_sold
, case
	when s.item_id is null then 'never_sold'
	when s.last_sold_date >= date_sub(run_date, interval 28 day) then 'selling'
	when s.last_sold_date >= date_sub(run_date, interval 365 day) then 'dormant'
	else 'discontinued'
  end as item_status

-- sales rollups
, coalesce(s.lifetime_units, 0) as lifetime_units
, coalesce(s.lifetime_gross_sales, 0) as lifetime_gross_sales
, coalesce(s.lifetime_item_net_sales, 0) as lifetime_item_net_sales  -- item-level net; does NOT tie to order_customer.net_sales
, coalesce(s.lifetime_orders, 0) as lifetime_orders
, coalesce(t.units_28d, 0) as units_28d
, coalesce(t.gross_sales_28d, 0) as gross_sales_28d
, coalesce(t.units_365d, 0) as units_365d
, coalesce(t.gross_sales_365d, 0) as gross_sales_365d
, round(safe_divide(t.gross_sales_90d, nullif(t.units_90d, 0)), 4) as avg_unit_price_90d

-- line-type and catering profile
, case
	when s.item_id is null then null
	when s.lines_as_item > 0 and s.lines_as_modifier > 0 then 'item & modifier'
	when s.lines_as_item > 0 then 'item'
	when s.lines_as_modifier > 0 then 'modifier'
	else 'other'
  end as sold_as
, coalesce(s.lines_catering, 0) > 0 and coalesce(s.lines_catering, 0) = coalesce(s.lifetime_lines, 0) as is_catering_item  -- 60 ids sell ONLY on catering orders (measured 2026-09-14)
, round(safe_divide(s.units_catering, nullif(s.lifetime_units, 0)), 4) as catering_unit_share
, coalesce(s.lines_in_combo, 0) > 0 as is_combo_component
, round(safe_divide(s.lines_in_combo, nullif(s.lifetime_lines, 0)), 4) as combo_line_share

-- brink menu configuration
, c.store_count_configured
, c.store_count_current
, c.store_count_active
, c.store_count_active > 0 as is_active_anywhere
, coalesce(t.stores_selling_28d, 0) as stores_selling_28d
, p.current_price
, c.price_min
, c.price_max
, c.price_variant_count
, c.plu
, c.brink_item_type
, coalesce(c.is_gift_card, false) as is_gift_card
, coalesce(c.is_non_revenue, false) as is_non_revenue
, c.name_variant_count
, c.name_variant_count > 1 as is_name_ambiguous_across_stores
, r.name_store_count

-- digital / pulse menu
, pi.pulse_item_id
, pi.pulse_item_name
, pi.pulse_item_role
, pi.pulse_menu
, pi.pulse_category_name
, pi.pulse_created_date
, coalesce(pi.is_on_digital_menu, false) as is_on_digital_menu

, run_dt as build_run_datetime
from item_name_resolved r
	left join size_families f
	on f.item_name = r.item_name
		left join item_config c
		on c.item_id = r.item_id
			left join price_modal p
			on p.item_id = r.item_id
				left join item_sales s
				on s.item_id = r.item_id
					left join item_trailing t
					on t.item_id = r.item_id
						left join item_launch l
						on l.item_id = r.item_id
							left join pulse_item pi
							on pi.item_id = r.item_id
;
