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


-- drop table `marketing-data-442316`.sales_ops.order_lines;
-- set start_date = '2018-08-07';
-- create or replace table `marketing-data-442316`.sales_ops.order_lines
-- partition by businessdate
-- cluster by rev_center_name, item_name, parent_item_grp_name, parent_rev_center_name
-- as

delete `marketing-data-442316`.sales_ops.order_lines
where businessdate >= start_date;

insert into `marketing-data-442316`.sales_ops.order_lines

with brink_order as (
select distinct bo.Id
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
, coalesce(bod.Name, 'Discount') as name
, bod.Amount * -1  as amount
, 0 as gross
, 0  as net
, 'none'
from `marketing-data-442316`.brink.brinkOrderDiscount bod
	join brink_order bo
	on bo.id = bod.orderid
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
, p.Name
, p.Amount * -1 as amount
, 0 as gross
, 0 as net
, 'none'
from `marketing-data-442316`.brink.brinkOrderPromotion p
	join brink_order bo
	on bo.id = p.orderid

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
, case when po.is_catering is null or po.is_catering = false then false else true end as is_catering
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
, case when bol.line_item_type = 'discount' then 'Discount' else brc.name end as rev_center_name
, bol.item_gross_sales
, bi.price
, round(
case when coalesce(safe_divide(bol.item_gross_sales,bi.price),0) < 1 then 1 else safe_divide(bol.item_gross_sales,bi.price) end
,0) as qty
, bol.amount
, bol.item_net_sales
, case
    when brc.name in ('Bowls','Salads','Sandwiches','Soups') then 'Entree'
    when brc.name = 'Kids Meals' and bi.name = 'Kids Combo' then 'Kids Meals'
    when brc.name = 'Kids Meals' and bi.name <> 'Kids Combo' then 'Entree'
    when brc.name in ('Bottled Beverages','Foutain Beverages') then 'Beverage'
    else coalesce(brc.name, bol.description)
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
, l.BusinessDate
, l.order_datetime
, l.store_id
, l.store_name
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
, case
	when coalesce(c.rev_center_name, l.description) = 'Combos' then 'Try 2 Combo'
	else coalesce(c.rev_center_name, l.description) end as parent_rev_center_name
, case
	when coalesce(c.rev_center_name, l.description) = 'Combos' then 'Try 2 Combo ' || ca.attr_list
	when coalesce(c.rev_center_name, l.description) = 'Foutain Beverages' then 'Fountain Beverage'
	else coalesce(c.item_grp_name, l.description) end as parent_item_grp_name
from order_lines_detail l
	left join order_lines_detail c
	on c.combo_order_line_item_id = l.combo_order_line_item_id
	and c.composite_item_id is null
	and c.line_item_type = 'item'
		left join combo_attrs ca
		on ca.combo_order_line_item_id = l.combo_order_line_item_id
;
