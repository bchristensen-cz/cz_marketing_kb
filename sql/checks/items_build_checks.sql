-- Checks for the sales_ops.item_daily -> sales_ops.items build.
-- Run after every deploy and after the first Sunday full rebuild. Each block states what a pass looks like.


-- 1. grain: one row per item_id, no fan-out.
--    pass = row_ct = distinct_item_ids = the brinkItems id count (3,242 on 2026-09-14)
select
count(*) as row_ct
, count(distinct item_id) as distinct_item_ids
, (select count(distinct id) from `marketing-data-442316`.brink.brinkItems) as master_item_ids
from `marketing-data-442316`.sales_ops.items;


-- 2. the dimension joins 1:1 to the fact on name and size.
--    pass = missing_from_dimension = 0, name_mismatch = 0, size_mismatch = 0
with fact as (
select
ol.item_id
, ol.item_name
, ol.item_size
, count(*) as lines
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date >= date_sub(current_date('America/Denver'), interval 45 day)
and ol.store_id not in (1111, 999)
and ol.line_item_type in ('item','modifier')
group by 1,2,3
qualify row_number() over(partition by ol.item_id order by lines desc) = 1
)

select
count(*) as sold_item_ids
, countif(i.item_id is null) as missing_from_dimension
, countif(i.item_name <> f.item_name) as name_mismatch
, countif(i.item_size <> f.item_size) as size_mismatch
from fact f
	left join `marketing-data-442316`.sales_ops.items i
	on i.item_id = f.item_id;


-- 3. units and gross tie back to order_lines over a recent window.
--    pass = both diffs are 0 (item_daily is a straight rollup, so any gap means a reload-width problem)
with dim as (
select
sum(d.units) as units
, sum(d.gross_sales) as gross_sales
from `marketing-data-442316`.sales_ops.item_daily d
where d.business_date between date_sub(current_date('America/Denver'), interval 35 day) and date_sub(current_date('America/Denver'), interval 8 day)
)

, fact as (
select
sum(ol.qty) as units
, sum(ol.item_gross_sales) as gross_sales
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date between date_sub(current_date('America/Denver'), interval 35 day) and date_sub(current_date('America/Denver'), interval 8 day)
and ol.store_id not in (1111, 999)
and ol.line_item_type not in ('discount','promotion','surcharge')
)

select
f.units as fact_units
, d.units as daily_units
, f.units - d.units as unit_diff
, round(f.gross_sales - d.gross_sales, 2) as gross_diff
from fact f
	cross join dim d;


-- 4. staleness: the incremental path must move last_sold_date every day.
--    pass = max_last_sold_date is yesterday or today, and build_run_datetime is today
select
max(last_sold_date) as max_last_sold_date
, max(build_run_datetime) as build_run_datetime
, countif(item_status = 'selling') as selling_items
from `marketing-data-442316`.sales_ops.items;


-- 5. no foreign id spaces leaked in. Discount / promotion / surcharge ids are NOT brink item ids
--    and must never appear in item_daily.
--    pass = 0
select count(*) as foreign_ids
from `marketing-data-442316`.sales_ops.item_daily d
where not exists (select 1 from `marketing-data-442316`.brink.brinkItems bi where bi.id = d.item_id);


-- 6. launch_date sanity. launch_date is derived (Brink carries no item dates at all), so it must never
--    precede first_sold_date.
--    pass = 0
select count(*) as launch_before_first_sold
from `marketing-data-442316`.sales_ops.items
where launch_date < first_sold_date;
