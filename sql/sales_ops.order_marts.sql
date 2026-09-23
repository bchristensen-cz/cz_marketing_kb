--****************************************************************************************************************************************
--****************************************************************************************************************************************
--****************************************************************************************************************************************
-- ORDER_CUSTOMER
--****************************************************************************************************************************************
--****************************************************************************************************************************************
--****************************************************************************************************************************************

-- history starts '2018-08-07';
declare run_dt datetime default current_datetime('America/Denver');
declare run_hour int64 default extract(hour from run_dt);
declare run_date date default date(run_dt);
declare start_date date;

set start_date = case
  -- 1st of month at 4am: ~13 month reload
--  when extract(day from run_date) = 1 and run_hour = 4 then date_sub(run_date, interval 380 day)
  -- monday at 4am: 5 week reload
--  when format_date('%A', run_date) = 'Monday' and run_hour = 4 then date_sub(run_date, interval 35 day)
  -- daily at 4am: 8 day reload
--  when run_hour = 4 then date_sub(run_date, interval 8 day)
  when run_hour = 5 then '2018-08-07'  -- '2026-08-26' merges change history, a full refresh is necessary :(
  -- intraday: today only
  when run_hour between 8 and 23 then run_date
  -- all other hours: skip
  else null
end;

if start_date is null then
  return;
end if;

begin transaction;

delete `marketing-data-442316`.sales_ops.order_customer
where business_date >= start_date;  -- '2026-07-27' updated to business_date

insert into `marketing-data-442316`.sales_ops.order_customer

-- declare start_date date;
-- set start_date = '2018-08-07';
-- -- drop table `marketing-data-442316`.sales_ops.order_customer
-- create or replace table `marketing-data-442316`.sales_ops.order_customer
-- partition by business_date
-- cluster by brink_order_id, pulse_customer_id, email, sm_email
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
--, sum(boim.ItemNetSales) as mods_net_sales -- '2026-07-24' net sales will now be a calc of gross sales + (discounts) + (promotions)
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


-- , instore_discount_codes as (
-- select distinct d.id
-- from `marketing-data-442316`.brink.brinkDiscounts d
-- where 1=1
-- and (d.name like '%Team%'
-- 	or d.name like '%Employee%')
-- )

, brink_discounts as (
select od.orderid as order_id
, sum(od.amount)*-1 as discount_amount  -- '2026-08-17' added the *-1 so i could sum the values with gross_sales to validate quickly
from `marketing-data-442316`.brink.brinkOrderDiscount od
	join brink_order bo
	on bo.id = od.orderid
	-- left join instore_discount_codes cd
	-- on cd.id = od.DiscountId
where 1=1
and od.isdeleted = false
group by 1
)


, brink_promotions as (
select p.orderid, sum(p.amount)*-1 as promotions_amount  -- '2026-08-17' added the *-1 so i could sum the values with gross_sales to validate quickly
from `marketing-data-442316`.brink.brinkOrderPromotion p
	join brink_order bo
	on bo.id = p.orderid
where 1=1
and p.isdeleted = false
group by 1
)

, all_trans_users as (
select
t.transaction_id
, lower(t.user_id) as user_id --'2026-07-29' added lower() for consistency
, t.last_updated_at AS updated_date
from `marketing-data-442316`.sessionM.user_point_transactions t
where  1=1
and t.transaction_id IS NOT NULL
and t.user_id IS NOT NULL
and t.last_updated_at >= timestamp(start_date)

union all

        -- Discounts
select
d.transaction_id
, lower(d.user_id)
, d.last_updated_at AS updated_date
from `marketing-data-442316`.sessionM.transaction_discounts d
where d.transaction_id IS NOT NULL
and d.user_id IS NOT NULL
and d.last_updated_at >= timestamp(start_date)


union all   -- switched from UNION → UNION ALL for performance

    -- Payments
select
tp.transaction_id
, lower(tp.user_id) --'2026-07-29' added lower() for consistency
, tp.last_updated_at as updated_date
from `marketing-data-442316`.sessionM.transaction_payments tp
where 1=1
and tp.transaction_id is not null
and tp.user_id IS NOT NULL
and tp.last_updated_at >= timestamp(start_date)
)


-- , user_trans as (  -- '2026-07-29' removed and moved to the cust_trans cte
-- select u.*
-- from all_trans_users u
-- qualify row_number() over(partition by u.transaction_id order by u.updated_date desc) = 1
-- )


, sm_external_user_map as (
select lower(u.user_id) as user_id
, u.external_user_id
--, lower(uu.email) as email  --'2026-07-29' added lower() for consistency
, regexp_replace(lower(trim(uu.email)), r'^cater_', '') as email --'2026-07-29' updated to make all catering emails the same
from `marketing-data-442316`.sessionM.external_user_mappings u
	join `marketing-data-442316`.`sessionM.users` uu
	on uu.user_id = u.user_id
where 1=1
and u.external_user_id_type = 'cafezupas'
qualify row_number() over(partition by u.user_id order by u.updated_at desc) = 1
)

, header_trans as (
select safe_cast(h.pos_transaction_key as int64) as pos_transaction_key
, h.transaction_id
from `marketing-data-442316`.sessionM.transaction_headers h
where 1=1
and h.create_date >= start_date --'2026-07-29' added =
qualify row_number() over(partition by h.pos_transaction_key order by h.last_updated_at desc) = 1
)

, cust_trans as (  -- '2026-07-29' updated to include all_trans_users
select
 h.pos_transaction_key
, safe_cast(m.external_user_id as int64) as external_user_id
, lower(m.email) as email
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


-- , employee_discount_offer as (
-- select distinct h.pos_transaction_key
-- from header_trans h
-- 	join discount_trans_id d
-- 	on d.transaction_id = h.transaction_id
-- )


, pulse_orders as (
select
cast(po.id as int64) as id
, po.business_date
, po.customer_id
, case when po.is_catering = 1 then true else false end as is_catering
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


, pulse_customer as (  -- i had to add since data was changed in source tables
select
c.id
, lower(trim(c.email)) as acct_email
, cast(c.phone as string) as acct_phone
, c.loyalty_signup_date
from `marketing-data-442316`.pulse.customers c
)


select
bo.Id as brink_order_id
, po.id as pulse_order_id
, case
	when lower(bd.name) like '%cater%' then true
	when bo.FKStoreId = 50 then true  -- '2026-08-17' including store 50 in the catering flag
	else coalesce(po.is_catering, false) end as is_catering
, case
		when ocs.is_loyalty_user = 0 and lower(po.source) in ('mobile_web_source', 'web_source', 'ios', 'android', 'mobile_source') and t.email is null
		then true else false end as is_guest_order  -- '2026-07-29' must be digital to be a guest and must not be a loyalty order
, po.customer_id as pulse_customer_id
--, t.external_user_id as sm_external_user_id  -- '2026-08-27' removed and will map using email address
, bo.BusinessDate as business_date
, case when date_diff(date(coalesce(bo.ClosedTime, bo.OpenedTime)), bo.BusinessDate, day) > 0 then coalesce(po.promise_time, bo.OpenedTime, datetime(bo.businessdate)) else coalesce(bo.ClosedTime, bo.OpenedTime) end as order_datetime_local  -- added _local so that other Claudes will know and use this field incorrectly.  also fixed nulls in this field and next field
, timestamp(case when date_diff(date(coalesce(bo.ClosedTime, bo.OpenedTime)), bo.BusinessDate, day) > 0 then coalesce(po.promise_time, bo.OpenedTime, datetime(bo.businessdate)) else coalesce(bo.ClosedTime, bo.OpenedTime) end , s.timezone_name) as order_timestamp_utc
, bo.FKStoreId as store_id
, s.store_name
, s.store_state  -- '2026-07-30' changed back to store_state for consistency with store_info and order_lines
, case   -- '2026-08-14' added reclassifications for finance for store 50 and then extended the pulse catering flag to destinations
		when bo.FKStoreId = 50 and coalesce(boi.total_fees_amount,0) > 0 then 642414069
--		when bo.FKStoreId = 50 then 999999999
		when bo.FKStoreId = 50 then 642414070
		else bo.DestinationId end as destination_id  -- '2026-08-13' added for finance
, case
--		when bo.FKStoreId = 50 then 'Middleton Mobile Catering'
		when bo.FKStoreId = 50 and coalesce(boi.total_fees_amount,0) > 0 then 'Catering Online Delivery'
		when bo.FKStoreId = 50 then 'Catering Online Takeout'
		else bd.name end as destination
, po.`source`
, case
    when lower(bd.name) like '%cater%' then 'Catering'
		when po.is_catering = true then 'Catering'
		when bo.FKStoreId = 50 then 'Catering' -- '2026-08-17' including store 50 in the catering rev cat
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
, case when po.id is null and t.email is not null then 1 else 0 end as in_store_scan
, bo.OpenedTime as opened_time
, bo.GrossSales as gross_sales
, coalesce(boi.item_gross_sales, 0) as item_gross_sales
, coalesce(boim.mods_gross_sales,0) as mods_gross_sales
, bo.subtotal as subtotal
, coalesce(gc.total_gift_card_amount,0) as total_gift_card_amount
, coalesce(d.discount_amount,0) as discount_amount
, coalesce(bp.promotions_amount,0) as promotions_amount
, coalesce(d.discount_amount,0) + coalesce(bp.promotions_amount,0) as total_discount_amount
-- , case
-- 	when do.pos_transaction_key is not null then 1
-- 	when d.is_employee_discount = 1 then 1 else 0 end as is_employee_discount  -- '2026-08-17' removed since we have the much better and more accurate order_line_discount_detail
, coalesce(p.total_tip_amount,0) as total_tip_amount
, coalesce(boi.total_delivery_tip_amount, 0) as total_delivery_tip_amount
, coalesce(boi.total_other_tip_amount, 0) as total_other_tip_amount
, bo.NetSales as brink_net_sales  -- **for vaidation only**  '2026-07-24' net sales will now be a calc of gross sales + (discounts) + (promotions)
, bo.GrossSales + coalesce(d.discount_amount,0) + coalesce(bp.promotions_amount,0) as net_sales
-- , boi.item_netsales_with_mods
-- , boi.item_net_sales
-- , boim.mods_net_sales
, bo.rounding
, bo.Tax as tax
, coalesce(boi.total_fees_amount,0) as total_fees_amount
, coalesce(p.total_payment_amount,0) as total_payment_amount
, coalesce(p.total_change, 0) as total_change
, case when boi.orderid is null then false else true end as has_order_items  --'2026-08-04' added for auditing
, lower(trim(ocs.email)) as email
, cast(ocs.phone as string) as phone
, c.acct_email
, c.acct_phone
, t.email as sm_email
, t.external_user_id as sm_external_user_id
, case
	when lower(trim(ocs.email)) like '%@guest.doordash.com' then 1
	when lower(trim(ocs.email)) like '%@itsacheckmate.com' then 1
	when lower(trim(ocs.email)) = 'support@doordash.com' then 1
	when lower(trim(ocs.email)) like '%outdoor%@cafezupas.com' then 1
	else 0
end as is_sys_order_email
, case
	when c.acct_email = 'checkmate_user@cafezupas.com'
	or c.acct_email like '%outdoor%@cafezupas.com' then 1
	else 0
end as is_sys_acct_email
, case when c.acct_email is null then 0 else 1 end as has_acct_email
, c.loyalty_signup_date
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
						left join pulse_customer c
						on c.id = po.customer_id
							left join `marketing-data-442316`.pulse.order_customers ocs
							on ocs.order_id = po.id
								left join cust_trans t
								on t.pos_transaction_key = coalesce(po.id, bo.id)
									left join `marketing-data-442316`.brink.brinkDestinations bd
									on bd.Id = bo.DestinationId
									and bd.StoreID = bo.FKStoreId
										left join brink_discounts d
										on d.order_id = boi.orderid
											-- left join employee_discount_offer do
											-- on do.pos_transaction_key = coalesce(po.id, bo.id)
												left join brink_promotions bp
												on bp.orderid = boi.orderid
													left join gift_card_purchase gc
													on gc.orderid = bo.id


;


commit transaction;


-- ---------------------------------------------------------------------------
-- sales_ops.order_sequence
-- Customer order sequencing, split out of order_customer 2026-07-24 so the window functions
-- are computed over FULL history every run instead of being scoped to the reload window.
-- Rebuilt in full on every run of this script (~420 MB / ~97 slot-seconds - measured
-- 2026-07-24). Restricted to customer_type = 'person': kiosk terminals, internal accounts and
-- the third-party aggregator id are not people and would poison sequence/lifetime counts.
-- ---------------------------------------------------------------------------



-- drop table `marketing-data-442316`.sales_ops.order_sequence;

create or replace table `marketing-data-442316`.sales_ops.order_sequence
partition by business_date
cluster by brink_order_id, mapped_cust_id as

with order_customer as (
select oc.brink_order_id
, oc.business_date
, oc.pulse_customer_id
, oc.email
, coalesce(
	case when oc.is_catering = true then coalesce(oc.pulse_customer_id, oc.sm_external_user_id) end -- catering accounts are their own identity population
	, case when oc.is_sys_order_email = 0 and oc.email is not null then m.acct_id end    -- the person, by the email on the order: guest, authenticated, or sys-account order alike
	, case when oc.is_sys_acct_email = 0 and oc.acct_email is not null then ma.acct_id end -- order email is a system email or missing: the person by the account's own email (kiosk / operator loyalty scans)
	, case when oc.sm_email is not null then coalesce(ms.acct_id, oc.sm_external_user_id) end                   -- no usable Pulse email anywhere: SessionM identity
	, case when oc.is_sys_order_email = 1 and oc.is_sys_acct_email = 1 then oc.pulse_customer_id end            -- pure system identities: kiosk terminal, checkmate
) as mapped_cust_id
, oc.order_datetime_local
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.cust_map m
	on m.email = oc.email                       -- the order email
		left join `marketing-data-442316`.sales_ops.cust_map ma
		on ma.email = oc.acct_email             -- the signed-in account's own email
			left join `marketing-data-442316`.sales_ops.cust_map ms
			on ms.email = oc.sm_email           -- the SessionM email
where 1=1
and oc.store_id not in (1111,999)
)


select
  oc.brink_order_id
, oc.business_date
, oc.mapped_cust_id
, lower(coalesce(c.email, oc.email)) as mapped_email
, split(lower(coalesce(c.email, oc.email)), '@')[safe_offset(1)] as mapped_email_domain
, case
		when coalesce(c.email, oc.email) like '%outdoor%@cafezupas.com' then 'kiosk'
		when coalesce(c.email, oc.email) like '%ezcater%@zupas.com' then 'aggregator'
		when coalesce(c.email, oc.email) = 'checkmate_user@cafezupas.com' then 'aggregator'
    when regexp_contains(coalesce(c.email, oc.email), r'(?i)@(cafezupas\.com|tkxel\.(com|io))$') then 'internal'
		else 'person'
		end as customer_type
, row_number() over w                                      as customer_order_count
, date_diff(oc.business_date, lag(oc.business_date) over w, day)  as days_since_prev_order
--, count(*) over(partition by oc.mapped_cust_id) as lifetime_customer_order_count  -- '2026-07-29' excluded because we have this column in customer_attributes
-- , min(oc.order_datetime) over(partition by oc.mapped_cust_id) as first_order_datetime
-- , max(oc.order_datetime) over(partition by oc.mapped_cust_id) as last_order_datetime
from order_customer oc
	left join `marketing-data-442316.pulse.customers` c
	on c.id = oc.mapped_cust_id
where 1=1
and oc.mapped_cust_id is not null
window w as (partition by oc.mapped_cust_id order by oc.order_datetime_local, oc.brink_order_id)
;





--****************************************************************************************************************************************
--****************************************************************************************************************************************
--****************************************************************************************************************************************
-- ORDER_LINES
--****************************************************************************************************************************************
--****************************************************************************************************************************************
--****************************************************************************************************************************************



begin transaction;

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
, cast(po.id as int64) as pulse_order_id
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

, size_families as (
select
	bi.item_grp_name
	, logical_or(bi.item_size is not null) as family_has_sizes
from brink_items bi
group by 1
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
--, coalesce(l.item_size, 'Regular') as item_size  -- '2026-08-27'  removed for the case below
, case
	when l.line_item_type not in ('item', 'modifier') then 'Not Applicable'
	when l.item_size is not null                      then l.item_size
	when f.family_has_sizes                           then 'Regular'
	else 'Not Sized'
  end as item_size  -- '2026-08-27'  added this case for better values in item_size
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
        left join size_families f
        on f.item_grp_name = l.item_grp_name
where 1=1
and l.business_date >= start_date
;

commit transaction;





--****************************************************************************************************************************************
--****************************************************************************************************************************************
--****************************************************************************************************************************************
-- DISCOUNT_DETAIL
--****************************************************************************************************************************************
--****************************************************************************************************************************************
--****************************************************************************************************************************************



begin transaction;

delete `marketing-data-442316`.sales_ops.order_line_discount_detail
where business_date >= start_date;

insert into `marketing-data-442316`.sales_ops.order_line_discount_detail

-- declare start_date date;
-- set start_date = '2018-08-07';
-- -- drop table `marketing-data-442316`.sales_ops.order_line_discount_detail
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
	and oc.business_date = ol.business_date
where 1=1
and ol.line_item_type in ('discount','promotion')
and ol.business_date >= start_date
--and ol.business_date < current_date
and ol.store_id not in (1111, 999)
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
and od.amount > 0
and od.created_at >= datetime(start_date - 60)
)

, header_trans as (
select safe_cast(h.pos_transaction_key as int64) as pos_transaction_key
, h.transaction_id
from `marketing-data-442316`.sessionM.transaction_headers h
where 1=1
and h.create_date >= start_date - 60 --'2026-08-14' added to include more stuff
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
	  and ro.root_offer_id = ro.offer_id
where 1=1
and uo.create_date >= start_date - 60 --'2026-08-14' added to include more stuff
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
, dl.amount * ifnull(pd.discount_dist,1) as discount_amount
, pd.points
, dl.item_id
, case
	when dl.order_source  = 'Outdoor Kiosk' then 'Outdoor Kiosk'
	when dl.revenue_category = 'Third_Party' then 'Third Party'
	when dl.item_id = 643536109 then 'Online'
	else 'In-Store' end as discount_origin
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
	when dl.item_id in (643529958, 640945199) then 'New Team Member Family Meal'
	when dl.item_id = 643529965 then 'Face To Face'
	when dl.item_id = 643571119 then 'Offline Cafe Zupas Rewards'
	else dl.item_name
end as discount_type
, ifnull(
    dl.item_id in (1, 2, 643529958, 640945199)
    or coalesce(r.discount_name, pd.discount_name, dl.item_name) = 'Team Member Meal'
    or regexp_contains(
         lower(coalesce(odr.offer_name, od.offer_name, '')), r'team member meal|\bemp.*(meal|lunch)'
       )
    , false
  ) as is_employee_meal_discount
, dl.item_name
, coalesce(r.discount_name, pd.discount_name, dl.item_name) as discount_name
, coalesce(odr.root_offer_id, od.root_offer_id, upper(pd.sessionM_root_offer_id)) as root_offer_id
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
