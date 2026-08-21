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



delete `marketing-data-442316`.sales_ops.order_lines
where business_date >= start_date;

insert into `marketing-data-442316`.sales_ops.order_lines


-- declare start_date date;
-- set start_date = '2018-08-07';
-- -- drop table `marketing-data-442316`.sales_ops.order_lines;f
-- create or replace table `marketing-data-442316`.sales_ops.order_lines
-- partition by business_date
-- cluster by rev_center_name, item_name, parent_item_grp_name, parent_rev_center_name
-- as

with brink_order as (
select
oc.brink_order_id
, oc.business_date
, oc.store_id
, oc.destination_id
, oc.destination
, oc.is_catering
, oc.order_datetime_local
, oc.order_timestamp_utc
, oc.gross_sales
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date >= start_date
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

, promotions as ( -- '2026-07-31'  added promotion name
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
	      on boi.orderid = bo.brink_order_id
where 1=1
and boi.IsCleared = false
and boi.IsVoided = false
and boi.IsDeleted = false
)

, valid_order_lines as (  -- '2026-08-17' removes orders with 0 valid order items
select ol.order_id
, sum(ol.amount) as total_amount
from order_lines ol
group by 1
having (sum(ol.amount) > 0 or sum(ol.item_net_sales) > 0)
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
, coalesce(nullif(trim(bod.Name),''), 'Discount') as name  -- '2026-08-12' added null if for cleaner descriptions down stream
, bod.Amount * -1  as amount
, 0 as gross
, 0  as net
, 'none'
from `marketing-data-442316`.brink.brinkOrderDiscount bod
	join brink_order bo
	on bo.brink_order_id = bod.orderid
    join valid_order_lines vol  -- '2026-08-17' removes orders with 0 valid order items
    on vol.order_id = bod.orderid
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
	on bo.brink_order_id = gc.orderid

union all

select
p.orderId
, row_number() over(partition by p.OrderId, p.PromotionId order by p.id) as rn
, p.Id
, null
, 'promotion' as item_type
, p.PromotionId
, coalesce(pn.Name, 'Promotion') as description
, p.Amount * -1 as amount
, 0 as gross
, 0 as net
, 'none'
from `marketing-data-442316`.brink.brinkOrderPromotion p
	join brink_order bo
	on bo.brink_order_id = p.orderid
    left join promotions pn  -- '2026-07-31'  added promotion
    on pn.id = p.promotionid
    and pn.storeid = bo.store_id
      join valid_order_lines vol -- '2026-08-17' removes orders with 0 valid order items
      on vol.order_id = p.orderid

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
	on bo.brink_order_id = s.orderid
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

union all -- '2026-08-12' added discounts to items so we wouldn't have blank descriptions and have better item names

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
, bo.business_date
, bo.is_catering
, bo.order_datetime_local
, bo.order_timestamp_utc
, bo.gross_sales
, bo.store_id
, s.store_name
, bol.order_item_id
, bol.item_id_seq_num
, bol.line_item_type
, concat(cast(bo.brink_order_id as string),'-',cast(coalesce(bol.composite_item_id, bol.order_item_id) as string)) as combo_order_line_item_id
, bol.composite_item_id
, bol.description
, bol.item_id
, coalesce(bi.item_name, bol.description) as item_name
, coalesce(bi.item_grp_name, bol.description) as item_grp_name
, bi.item_size
, bol.item_modifier
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
	left join brink_order bo
	on bo.brink_order_id = bol.order_id
		left join `marketing-data-442316`.pulse.orders po
		on po.brink_order_id = bo.brink_order_id
		and po.brink_order_id > 0
			left join `marketing-data-442316`.sales_ops.store_info s
			on s.store_id = bo.store_id
					left join `marketing-data-442316`.pulse.customers c
					on c.id = po.customer_id
							left join `marketing-data-442316`.brink.brinkDestinations bd
							on bd.Id = bo.destination_id
							and bd.StoreID = bo.store_id
								left join brink_items bi
								on bi.StoreID = bo.store_id
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
, l.business_date
, l.order_datetime_local
, l.store_id
, l.store_name
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
and l.business_date >= start_date
;
