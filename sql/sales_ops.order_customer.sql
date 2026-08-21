-- history starts '2018-08-07';
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
, sum(od.amount)*-1 as total_discount_amount
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
select p.orderid, sum(p.amount)*-1 as total_promotions_amount
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


union all   -- switched from UNION -> UNION ALL for performance

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


, pulse_customer as (  -- i had to add since data was changed in source tables
select
c.id
, case when c.email = 'nan' then null else c.email end as email
, case when c.phone = 'nan' then null else c.phone end as phone
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
		when ocs.is_loyalty_user = false and lower(po.source) in ('mobile_web_source', 'web_source', 'ios', 'android', 'mobile_source')
		then true else false end as is_guest_order  -- '2026-07-29' must be digital to be a guest and must not be a loyalty order
, po.customer_id as pulse_customer_id
, t.external_user_id as sm_external_user_id
, bo.BusinessDate as business_date
, case when date_diff(date(coalesce(bo.ClosedTime, bo.OpenedTime)), bo.BusinessDate, day) > 0 then coalesce(po.promise_time, bo.OpenedTime, datetime(bo.businessdate)) else coalesce(bo.ClosedTime, bo.OpenedTime) end as order_datetime_local
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
, case when po.id is null and t.external_user_id is not null then 1 else 0 end as in_store_scan
, bo.OpenedTime as opened_time
, bo.GrossSales as gross_sales
, coalesce(boi.item_gross_sales, 0) as item_gross_sales
, coalesce(boim.mods_gross_sales,0) as mods_gross_sales
, bo.subtotal as subtotal
, coalesce(gc.total_gift_card_amount,0) as total_gift_card_amount
, coalesce(d.total_discount_amount,0) as discount_amount
, coalesce(bp.total_promotions_amount,0) as promotions_amount
, coalesce(d.total_discount_amount,0) + coalesce(bp.total_promotions_amount,0) as total_discount_amount
-- , case
-- 	when do.pos_transaction_key is not null then 1
-- 	when d.is_employee_discount = 1 then 1 else 0 end as is_employee_discount  -- '2026-08-17' removed since we have the much better and more accurate order_line_discount_detail
, coalesce(p.total_tip_amount,0) as total_tip_amount
, coalesce(boi.total_delivery_tip_amount, 0) as total_delivery_tip_amount
, coalesce(boi.total_other_tip_amount, 0) as total_other_tip_amount
, bo.NetSales as brink_net_sales  -- **for vaidation only**  '2026-07-24' net sales will now be a calc of gross sales - discounts - promotions
, bo.GrossSales + coalesce(d.total_discount_amount,0) as net_sales
-- ⚠️ '2026-08-20' KNOWN GAP: the comment above says net sales = gross - discounts - promotions, but this
-- expression only subtracts discounts. promotions_amount is NOT deducted, so net_sales does not equal
-- gross_sales + total_discount_amount on the 1,287 orders per week that carry a promotion
-- ($15,805.69 over 2026-08-11..08-16). Steward decision pending - see Asana 1217700106208956.
-- , boi.item_netsales_with_mods
-- , boi.item_net_sales
-- , boim.mods_net_sales
, bo.rounding
, bo.Tax as tax
, coalesce(boi.total_fees_amount,0) as total_fees_amount
, coalesce(p.total_payment_amount,0) as total_payment_amount
, coalesce(p.total_change, 0) as total_change
, case when boi.orderid is null then false else true end as has_order_items  --'2026-08-04' added for auditing
, lower(ocs.email) as email
, cast(ocs.phone as string) as phone
, lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, t.email)) as mapped_email
, split(lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, t.email)), '@')[safe_offset(1)] as mapped_email_domain
, coalesce(po.customer_id, t.external_user_id) as mapped_cust_id
-- '2026-07-24' customer_type: keeps non-person ids out of customer counts / frequency /
-- retention. NULL when the order has no identified customer.
--   kiosk      - shared outdoor-kiosk terminal accounts (NNN-outdoor-N@cafezupas.com)
--   internal   - employee / developer accounts (@cafezupas.com, @tkxel.com, @tkxel.io)
--   aggregator - orphan pulse customer id (referenced on orders, absent from pulse.customers);
--                third-party funnel, dominated by id 19192 (itsacheckmate.com)
--   person     - real guest, including sessionM-only in-store scanners
, case
    when coalesce(po.customer_id, t.external_user_id) is null then null
    when regexp_contains(lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, '')), r'(?i)^[0-9]+-outdoor-[0-9]+@cafezupas\.com$') then 'kiosk'
		when lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, '')) like '%ezcater%' then 'aggregator'
		when lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, '')) like '%doordash.com' then 'aggregator'
		when lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, '')) like '%itsacheckmate.com' then 'aggregator'
		when lower(coalesce(c.email, ocs.booking_customer_email,ocs.email, '')) = 'checkmate_user@cafezupas.com' then 'aggregator'
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
select
  oc.brink_order_id
, oc.business_date
, oc.mapped_cust_id
, oc.customer_type
, row_number() over w                                      as customer_order_count
, date_diff(oc.business_date, lag(oc.business_date) over w, day)  as days_since_prev_order
--, count(*) over(partition by oc.mapped_cust_id) as lifetime_customer_order_count  -- '2026-07-29' excluded because we have this column in customer_attributes
-- , min(oc.order_datetime_local) over(partition by oc.mapped_cust_id) as first_order_datetime
-- , max(oc.order_datetime_local) over(partition by oc.mapped_cust_id) as last_order_datetime
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.mapped_cust_id is not null
window w as (partition by oc.mapped_cust_id order by oc.order_datetime_local, oc.brink_order_id)
;
