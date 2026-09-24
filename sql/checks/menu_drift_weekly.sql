-- Weekly menu / item-structure drift check.
-- Run by the scheduled task "Weekly menu drift check" (Mondays 07:00 America/Denver).
-- Reads only sales_ops.items, sales_ops.item_daily and sales_ops.items_snapshot. No order_lines scan.
-- Every block is a standalone statement; run them one at a time, in order. Block 1 writes, the rest read.
-- Window: wk = the last complete Mon-Sun week (Sunday = week_ending, steward rule 2026-09-09);
--         base = the four weeks before it. Thresholds are stated on each block.
-- Origin: the Kids Combo restructure of 2026-06-01 (new $0 Composite id 643647054 took half the volume,
-- the price moved onto the kids entree lines, and the new id landed in item_type = 'Entree' because its
-- raw name carries a trailing space). Nobody saw it for 16 weeks. Each block below would have fired in week 1.


-- 1. snapshot the dimension (idempotent: one row per item_id per snapshot_date). This is the only way to see
--    renames, size changes, category moves and price edits: the 5am full-history reload rewrites item_name on
--    every historical order line, so the fact table carries no rename history at all.
create table if not exists `marketing-data-442316`.sales_ops.items_snapshot
(
snapshot_date date
, item_id int64
, item_name string
, item_name_raw string
, item_size string
, rev_center_id int64
, rev_center_name string
, item_type string
, brink_item_type string
, item_status string
, sold_as string
, first_sold_date date
, launch_date date
, last_sold_date date
, current_price float64
, price_variant_count int64
, name_variant_count int64
, store_count_active int64
, stores_selling_28d int64
, units_28d float64
, avg_unit_price_90d float64
, pulse_item_id int64
, is_on_digital_menu bool
, is_catering_item bool
, is_combo_component bool
)
partition by snapshot_date
cluster by item_id;

delete from `marketing-data-442316`.sales_ops.items_snapshot
where snapshot_date = current_date('America/Denver');

insert into `marketing-data-442316`.sales_ops.items_snapshot
select
current_date('America/Denver') as snapshot_date
, i.item_id
, i.item_name
, i.item_name_raw
, i.item_size
, i.rev_center_id
, i.rev_center_name
, i.item_type
, i.brink_item_type
, i.item_status
, i.sold_as
, i.first_sold_date
, i.launch_date
, i.last_sold_date
, i.current_price
, i.price_variant_count
, i.name_variant_count
, i.store_count_active
, i.stores_selling_28d
, i.units_28d
, i.avg_unit_price_90d
, i.pulse_item_id
, i.is_on_digital_menu
, i.is_catering_item
, i.is_combo_component
from `marketing-data-442316`.sales_ops.items i;


-- 2. dimension diff: what changed on an item since the previous snapshot.
--    change_kind values: renamed / resized / category_moved / type_moved / repriced / digital_menu_toggled / new_id / id_gone.
--    Every row here is a structural change. Renames and category moves rewrite history at the next 5am reload.
--    Returns nothing until a second snapshot exists (first snapshot 2026-09-24).
with snaps as (
select
s.snapshot_date
, dense_rank() over(order by s.snapshot_date desc) as rn
from `marketing-data-442316`.sales_ops.items_snapshot s
where 1=1
and s.snapshot_date >= date_sub(current_date('America/Denver'), interval 60 day)
group by 1
)

, cur as (
select
s.*
from `marketing-data-442316`.sales_ops.items_snapshot s
where 1=1
and s.snapshot_date >= date_sub(current_date('America/Denver'), interval 60 day)
and s.snapshot_date = (select snapshot_date from snaps where rn = 1)
)

, prev as (
select
s.*
from `marketing-data-442316`.sales_ops.items_snapshot s
where 1=1
and s.snapshot_date >= date_sub(current_date('America/Denver'), interval 60 day)
and s.snapshot_date = (select snapshot_date from snaps where rn = 2)
)

select
coalesce(c.item_id, p.item_id) as item_id
, case
	when p.item_id is null then 'new_id'
	when c.item_id is null then 'id_gone'
	when c.item_name <> p.item_name or c.item_name_raw <> p.item_name_raw then 'renamed'
	when c.item_size <> p.item_size then 'resized'
	when c.rev_center_name <> p.rev_center_name then 'category_moved'
	when c.item_type <> p.item_type then 'type_moved'
	when ifnull(c.current_price, -1) <> ifnull(p.current_price, -1) then 'repriced'
	when c.is_on_digital_menu <> p.is_on_digital_menu then 'digital_menu_toggled'
	end as change_kind
, p.item_name_raw as prev_name_raw
, c.item_name_raw as cur_name_raw
, p.item_size as prev_size
, c.item_size as cur_size
, p.rev_center_name as prev_rev_center
, c.rev_center_name as cur_rev_center
, p.item_type as prev_item_type
, c.item_type as cur_item_type
, p.current_price as prev_price
, c.current_price as cur_price
, p.is_on_digital_menu as prev_digital
, c.is_on_digital_menu as cur_digital
, coalesce(c.units_28d, p.units_28d) as units_28d
, coalesce(c.stores_selling_28d, p.stores_selling_28d) as stores_selling_28d
, p.snapshot_date as prev_snapshot
, c.snapshot_date as cur_snapshot
from cur c
	full outer join prev p
	on p.item_id = c.item_id
where 1=1
and exists (select 1 from snaps where rn = 2)
and (
	p.item_id is null
	or c.item_id is null
	or c.item_name <> p.item_name
	or c.item_name_raw <> p.item_name_raw
	or c.item_size <> p.item_size
	or c.rev_center_name <> p.rev_center_name
	or c.item_type <> p.item_type
	or ifnull(c.current_price, -1) <> ifnull(p.current_price, -1)
	or c.is_on_digital_menu <> p.is_on_digital_menu
)
order by units_28d desc;


-- 3. new sellers: ids whose first sale is inside the last 35 days and that already move real volume.
--    A new id at >= 250 units or >= 10 stores in one week is a launch or a restructure, not a one-store test.
--    (643647054 hit 5,751 units / 91 stores in its first full week.)
with p as (
select
date_sub(last_day(current_date('America/Denver'), week(monday)), interval 7 day) as wk_end
)

select
i.item_id
, i.item_name
, i.item_size
, i.rev_center_name
, i.item_type
, i.brink_item_type
, i.first_sold_date
, i.launch_date
, sum(d.units) as units_wk
, round(sum(d.gross_sales), 2) as gross_wk
, max(d.stores_selling) as peak_stores_wk
, round(safe_divide(sum(d.gross_sales), sum(d.units)), 2) as avg_unit_price_wk
, sum(d.lines_as_item) as lines_as_item_wk
, sum(d.lines_as_modifier) as lines_as_modifier_wk
from `marketing-data-442316`.sales_ops.item_daily d
	cross join p
	join `marketing-data-442316`.sales_ops.items i
	on i.item_id = d.item_id
where 1=1
and d.business_date between date_sub(p.wk_end, interval 6 day) and p.wk_end
and i.first_sold_date >= date_sub(p.wk_end, interval 35 day)
group by 1, 2, 3, 4, 5, 6, 7, 8
having sum(d.units) >= 250 or max(d.stores_selling) >= 10
order by units_wk desc;


-- 4. volume breaks: last week vs the prior-4-week average, per id.
--    flag = 'surge' at >= +100% with >= 1,000 units/wk, 'collapse' at <= -30% with a >= 2,000 units/wk baseline.
--    (642361971 read -34% in the first week of the restructure; the collapse rule catches that, a -50% rule would not.)
with p as (
select
date_sub(last_day(current_date('America/Denver'), week(monday)), interval 7 day) as wk_end
)

, agg as (
select
d.item_id
, sum(if(d.business_date > date_sub(p.wk_end, interval 7 day), d.units, 0)) as units_wk
, sum(if(d.business_date <= date_sub(p.wk_end, interval 7 day), d.units, 0)) / 4 as units_base_avg
, sum(if(d.business_date > date_sub(p.wk_end, interval 7 day), d.gross_sales, 0)) as gross_wk
, sum(if(d.business_date <= date_sub(p.wk_end, interval 7 day), d.gross_sales, 0)) / 4 as gross_base_avg
from `marketing-data-442316`.sales_ops.item_daily d
	cross join p
where 1=1
and d.business_date between date_sub(p.wk_end, interval 34 day) and p.wk_end
group by 1
)

select
a.item_id
, i.item_name
, i.item_size
, i.rev_center_name
, i.item_type
, case
	when a.units_wk >= 1000 and a.units_wk >= 2 * a.units_base_avg then 'surge'
	when a.units_base_avg >= 2000 and a.units_wk <= 0.7 * a.units_base_avg then 'collapse'
	end as flag
, a.units_wk
, round(a.units_base_avg, 0) as units_base_avg
, round(safe_divide(a.units_wk - a.units_base_avg, a.units_base_avg) * 100, 1) as units_pct_change
, round(a.gross_wk, 2) as gross_wk
, round(a.gross_base_avg, 2) as gross_base_avg
, i.first_sold_date
from agg a
	join `marketing-data-442316`.sales_ops.items i
	on i.item_id = a.item_id
where 1=1
and (
	(a.units_wk >= 1000 and a.units_wk >= 2 * a.units_base_avg)
	or (a.units_base_avg >= 2000 and a.units_wk <= 0.7 * a.units_base_avg)
)
order by abs(a.units_wk - a.units_base_avg) desc;


-- 5. price / line-type shifts on an existing id: gross per unit or the item-vs-modifier line mix moved.
--    flag when avg unit price moves >= 15% and >= $0.25 (or crosses zero) or the 'item' share of lines moves >= 15 points,
--    on ids with >= 500 units in both windows. This is the signal that a price moved between parent and component
--    (kids entrees went from $0 modifiers to $3.39 items; the paid combo stayed $6.79 while the new one is $0).
with p as (
select
date_sub(last_day(current_date('America/Denver'), week(monday)), interval 7 day) as wk_end
)

, agg as (
select
d.item_id
, sum(if(d.business_date > date_sub(p.wk_end, interval 7 day), d.units, 0)) as units_wk
, sum(if(d.business_date <= date_sub(p.wk_end, interval 7 day), d.units, 0)) as units_base
, safe_divide(sum(if(d.business_date > date_sub(p.wk_end, interval 7 day), d.gross_sales, 0)), sum(if(d.business_date > date_sub(p.wk_end, interval 7 day), d.units, 0))) as aup_wk
, safe_divide(sum(if(d.business_date <= date_sub(p.wk_end, interval 7 day), d.gross_sales, 0)), sum(if(d.business_date <= date_sub(p.wk_end, interval 7 day), d.units, 0))) as aup_base
, safe_divide(sum(if(d.business_date > date_sub(p.wk_end, interval 7 day), d.lines_as_item, 0)), sum(if(d.business_date > date_sub(p.wk_end, interval 7 day), d.lines_total, 0))) as item_share_wk
, safe_divide(sum(if(d.business_date <= date_sub(p.wk_end, interval 7 day), d.lines_as_item, 0)), sum(if(d.business_date <= date_sub(p.wk_end, interval 7 day), d.lines_total, 0))) as item_share_base
from `marketing-data-442316`.sales_ops.item_daily d
	cross join p
where 1=1
and d.business_date between date_sub(p.wk_end, interval 34 day) and p.wk_end
group by 1
)

select
a.item_id
, i.item_name
, i.item_size
, i.rev_center_name
, i.item_type
, case
	when (a.aup_wk = 0) <> (a.aup_base = 0) then 'price_crossed_zero'
	when abs(a.aup_wk - a.aup_base) >= 0.25 and abs(safe_divide(a.aup_wk - a.aup_base, a.aup_base)) >= 0.15 then 'price_shift'
	when abs(a.item_share_wk - a.item_share_base) >= 0.15 then 'line_type_shift'
	end as flag
, round(a.aup_base, 2) as avg_unit_price_base
, round(a.aup_wk, 2) as avg_unit_price_wk
, round(a.item_share_base * 100, 1) as item_line_share_base_pct
, round(a.item_share_wk * 100, 1) as item_line_share_wk_pct
, a.units_wk
, a.units_base
from agg a
	join `marketing-data-442316`.sales_ops.items i
	on i.item_id = a.item_id
where 1=1
and a.units_wk >= 500
and a.units_base >= 500
and (
	(a.aup_wk = 0) <> (a.aup_base = 0)
	or (abs(a.aup_wk - a.aup_base) >= 0.25 and abs(safe_divide(a.aup_wk - a.aup_base, a.aup_base)) >= 0.15)
	or abs(a.item_share_wk - a.item_share_base) >= 0.15
)
order by a.units_wk desc;


-- 6. name collisions that changed: an item_name whose count of selling ids, item_types or rev_centers differs
--    between last week and the base, or that spans more than one item_type (the closed rollup) at all.
--    A name-keyed report double-counts or blends the moment a second id appears under the same name
--    (Kids Combo: one id until 2026-05-05, two since, and they sit in two different item_type values).
--    A name spanning two rev_centers by size (Kids soup in 'Kids Meals', Half/Large in 'Soups') is normal and
--    only reported when the count changes.
with p as (
select
date_sub(last_day(current_date('America/Denver'), week(monday)), interval 7 day) as wk_end
)

, sold as (
select
d.item_id
, d.business_date > date_sub(p.wk_end, interval 7 day) as is_wk
, sum(d.units) as units
from `marketing-data-442316`.sales_ops.item_daily d
	cross join p
where 1=1
and d.business_date between date_sub(p.wk_end, interval 34 day) and p.wk_end
group by 1, 2
having sum(d.units) >= if(is_wk, 100, 400)
)

, by_name as (
select
i.item_name
, count(distinct if(s.is_wk, s.item_id, null)) as ids_wk
, count(distinct if(not s.is_wk, s.item_id, null)) as ids_base
, count(distinct if(s.is_wk, i.item_type, null)) as item_types_wk
, count(distinct if(not s.is_wk, i.item_type, null)) as item_types_base
, count(distinct if(s.is_wk, i.rev_center_name, null)) as rev_centers_wk
, count(distinct if(not s.is_wk, i.rev_center_name, null)) as rev_centers_base
, string_agg(distinct if(s.is_wk, concat(cast(s.item_id as string), ' ', i.item_size, ' ', i.item_type, ' $', cast(ifnull(i.current_price, 0) as string)), null), ' | ') as ids_wk_detail
, sum(if(s.is_wk, s.units, 0)) as units_wk
from sold s
	join `marketing-data-442316`.sales_ops.items i
	on i.item_id = s.item_id
group by 1
)

select
b.item_name
, b.ids_base
, b.ids_wk
, b.item_types_base
, b.item_types_wk
, b.rev_centers_base
, b.rev_centers_wk
, b.units_wk
, b.ids_wk_detail
from by_name b
where 1=1
and b.ids_wk > 1
and (
	b.ids_wk <> b.ids_base
	or b.item_types_wk <> b.item_types_base
	or b.rev_centers_wk <> b.rev_centers_base
	or b.item_types_wk > 1
)
order by b.units_wk desc;


-- 7. same id ringing under two names or sizes across stores last week (the brinkItems store-scoped defect).
with p as (
select
date_sub(last_day(current_date('America/Denver'), week(monday)), interval 7 day) as wk_end
)

select
d.item_id
, i.item_name
, i.item_size
, max(d.name_variants) as max_name_variants_day
, max(d.size_variants) as max_size_variants_day
, sum(d.units) as units_wk
, i.is_name_ambiguous_across_stores
from `marketing-data-442316`.sales_ops.item_daily d
	cross join p
	join `marketing-data-442316`.sales_ops.items i
	on i.item_id = d.item_id
where 1=1
and d.business_date between date_sub(p.wk_end, interval 6 day) and p.wk_end
and (d.name_variants > 1 or d.size_variants > 1)
group by 1, 2, 3, 7
order by units_wk desc;


-- 8. category totals, for the verdict line: did the category move, or only the items inside it?
--    (Kids Meals rev-center gross was flat through the restructure while every item under it moved 30-9,000%.)
with p as (
select
date_sub(last_day(current_date('America/Denver'), week(monday)), interval 7 day) as wk_end
)

select
i.rev_center_name
, sum(if(d.business_date > date_sub(p.wk_end, interval 7 day), d.units, 0)) as units_wk
, round(sum(if(d.business_date <= date_sub(p.wk_end, interval 7 day), d.units, 0)) / 4, 0) as units_base_avg
, round(sum(if(d.business_date > date_sub(p.wk_end, interval 7 day), d.gross_sales, 0)), 2) as gross_wk
, round(sum(if(d.business_date <= date_sub(p.wk_end, interval 7 day), d.gross_sales, 0)) / 4, 2) as gross_base_avg
, round(safe_divide(sum(if(d.business_date > date_sub(p.wk_end, interval 7 day), d.gross_sales, 0)) - sum(if(d.business_date <= date_sub(p.wk_end, interval 7 day), d.gross_sales, 0)) / 4, sum(if(d.business_date <= date_sub(p.wk_end, interval 7 day), d.gross_sales, 0)) / 4) * 100, 1) as gross_pct_change
, count(distinct if(d.business_date > date_sub(p.wk_end, interval 7 day), d.item_id, null)) as ids_selling_wk
from `marketing-data-442316`.sales_ops.item_daily d
	cross join p
	join `marketing-data-442316`.sales_ops.items i
	on i.item_id = d.item_id
where 1=1
and d.business_date between date_sub(p.wk_end, interval 34 day) and p.wk_end
group by 1
order by gross_wk desc;
