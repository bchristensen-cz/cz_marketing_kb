-- sales_ops.vto_items
-- Items launched in the last 91 days. Scheduled query "create or replace vto items" (every mon 13:00 UTC).
-- Downstream: braze_ca_unique_vto_items_purchased -> braze.is_vto_cust (keys on item_grp_name, so sizes collapse).
--
-- Rewritten 2026-10-30 off sales_ops.item_daily / sales_ops.items instead of two order_lines scans
-- (~4 GB -> ~1 MB). item_daily already drops stores 1111 / 999 and discount / promotion / surcharge
-- lines, which the old version let through (promotion 643649914 "2$ off" was listed as a VTO).
--
-- Modifiers are excluded by rev center, not line type: digital Try 2 Combos ring entrees as $0 modifier
-- lines, so a line-type filter drops real items (Fall Bacon Sandwhich: 16 item lines vs 3,354 modifier).
-- A day-level `lines_as_item > 0` filter also flagged an old modifier (Plain Strawberry) as new.

create or replace table `marketing-data-442316`.sales_ops.vto_items as

with item_firsts as (
select
d.item_id
, min(if(d.lines_total > 25, d.business_date, null)) as first_active_date
, min(if(d.lines_total > 100, d.business_date, null)) as launch_date
from `marketing-data-442316`.sales_ops.item_daily d
where 1=1
and d.business_date >= '2024-11-01'
group by 1
)

select
f.launch_date
, f.item_id
, i.item_name
, i.item_size
, case when f.item_id = 643640548 then 'Dressed Up Chicken Tortilla Soup' else i.item_name end as item_grp_name
, i.rev_center_name
from item_firsts f
	join `marketing-data-442316`.sales_ops.items i
	on i.item_id = f.item_id
where 1=1
and f.first_active_date > current_date('America/Denver') - 91
and f.launch_date is not null
and i.rev_center_name <> 'Modifiers'
