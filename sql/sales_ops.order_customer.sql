-- Build script: `marketing-data-442316`.sales_ops.order_customer
-- Runs hourly at minute :02 (see schedule logic below).
-- Grain: one row per Brink order.
-- Documentation: data_dictionaries/sales_ops.order_customer.md

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
where businessdate >= start_date;

insert into `marketing-data-442316`.sales_ops.order_customer

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
, sum(case when t.id is null then boi.ItemNetSales end) as item_net_sales
, sum(case when t.id is null then boi.NetSales end) as item_netsales_with_mods
, sum(case when f.id is not null then boi.ItemGrossSales end) as total_fees_amount
, sum(case when t.id = 640943560 then boi.ItemGrossSales end) as total_delivery_tip_amount
, sum(case when t.id <> 640943560 then boi.ItemGrossSales end) as  total_other_tip_amount
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
, sum(boim.ItemNetSales) as mods_net_sales
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

, emp_discounts_root_offer_id as (
select distinct o.root_offer_id
from `marketing-data-442316`.sessionM.offers o
where 1=1
and (o.name like '%Meal%'
	or o.name like '%Emp%'
	or o.name like '%Team%')
)

, ref_ids as (
select uo.user_offers_id, uo.redeem_date
from `marketing-data-442316`.sessionM.user_offers uo
	join emp_discounts_root_offer_id r
	on r.root_offer_id = uo.root_offer_id
where 1=1
and uo.create_date >= start_date
)

, discount_trans_id as (
select distinct d.transaction_id
from `marketing-data-442316.sessionM.transaction_discounts` d
	join ref_ids r
	on r.user_offers_id = d.discount_reference_id
where 1=1
and d.create_date >= start_date
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

, instore_discount_codes as (
select distinct d.id
from `marketing-data-442316`.brink.brinkDiscounts d
where 1=1
and (d.name like '%Team%'
	or d.name like '%Employee%')
)

, instore_emp_discounts as (
select od.orderid as order_id
, sum(od.amount) as total_discount_amount
, max(case when cd.id is not null then 1 else 0 end) as is_employee_discount
from `marketing-data-442316`.brink.brinkOrderDiscount od
	left join instore_discount_codes cd
	on cd.id = od.DiscountId
where 1=1
and od.isdeleted = false
group by 1
)

, brink_promotions as (
select p.orderid, sum(p.amount) as total_promotions_amount
from `marketing-data-442316`.brink.brinkOrderPromotion p
	join brink_order bo
	on bo.id = p.orderid
group by 1
)

, all_trans_users as (
select
t.transaction_id
, t.user_id
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
, tp.user_id
, tp.last_updated_at as updated_date
from `marketing-data-442316`.sessionM.transaction_payments tp
where 1=1
and tp.transaction_id is not null
and tp.user_id IS NOT NULL
and tp.last_updated_at >= timestamp(start_date)
)

, user_trans as (
select u.*
from all_trans_users u
qualify row_number() over(partition by u.transaction_id order by u.updated_date desc) = 1
)

, sm_external_user_map as (
select u.user_id, u.external_user_id
from `marketing-data-442316`.sessionM.external_user_mappings u
where 1=1
and u.external_user_id_type = 'cafezupas'
qualify row_number() over(partition by u.user_id order by u.updated_at desc) = 1
)

, header_trans as (
select safe_cast(h.pos_transaction_key as int64) as pos_transaction_key
, h.transaction_id
from `marketing-data-442316`.sessionM.transaction_headers h
where 1=1
and h.create_date > start_date
qualify row_number() over(partition by h.pos_transaction_key order by h.last_updated_at desc) = 1
)

, cust_trans as (
select
h.pos_transaction_key
, safe_cast(m.external_user_id as int64) as external_user_id
from header_trans h
	left join user_trans t
	on t.transaction_id = h.transaction_id
		left join sm_external_user_map m
		on m.user_id = t.user_id
where 1=1
and m.external_user_id is not null
)

, employee_discount_offer as (
select distinct h.pos_transaction_key
from header_trans h
	join discount_trans_id d
	on d.transaction_id = h.transaction_id
)

select
bo.Id as brink_order_id
, po.id as pulse_order_id
, case when po.is_catering is null or po.is_catering = false then false else true end as is_catering
, case when c.loyalty_user_id is null then 1 else 0 end as is_guest_order
, po.customer_id as pulse_customer_id
, t.external_user_id as sm_external_user_id
, bo.BusinessDate
, case when date_diff(date(bo.ClosedTime), bo.BusinessDate, day) > 0 then coalesce(po.promise_time, bo.OpenedTime) else bo.ClosedTime end as order_datetime
, timestamp(case when date_diff(date(bo.ClosedTime), bo.BusinessDate, day) > 0 then coalesce(po.promise_time, bo.OpenedTime) else bo.ClosedTime end , s.timezone_name) as order_timestamp_utc
, bo.FKStoreId as store_id
, s.store_name
, s.store_state as state
, bd.name as destination
, po.`source`
, case
    when bd.name like '%Cater%' then 'Catering'
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
, boi.item_gross_sales
, boim.mods_gross_sales
, bo.subtotal as subtotal
, coalesce(gc.total_gift_card_amount,0) as total_gift_card_amount
, coalesce(d.total_discount_amount,0) as total_discount_amount
, coalesce(bp.total_promotions_amount,0) as total_promotions_amount
, case
	when do.pos_transaction_key is not null then 1
	when d.is_employee_discount = 1 then 1 else 0 end as is_employee_discount
, coalesce(p.total_tip_amount,0) as total_tip_amount
, coalesce(boi.total_delivery_tip_amount, 0) as total_delivery_tip_amount
, coalesce(boi.total_other_tip_amount, 0) as total_other_tip_amount
, bo.NetSales as net_sales
, boi.item_netsales_with_mods
, boi.item_net_sales
, boim.mods_net_sales
, bo.rounding
, bo.Tax as tax
, coalesce(boi.total_fees_amount,0) as total_fees_amount
, coalesce(p.total_payment_amount,0) as total_payment_amount
, coalesce(p.total_change, 0) as total_change
, ocs.email
, ocs.phone
, coalesce(c.email, ocs.booking_customer_email,ocs.email) as mapped_email
, coalesce(po.customer_id, t.external_user_id) as mapped_cust_id
, c.loyalty_signup_date
, case when coalesce(po.customer_id, t.external_user_id) is null then null else row_number() over(partition by coalesce(po.customer_id, t.external_user_id)
	order by case when date_diff(date(bo.ClosedTime), bo.BusinessDate, day) > 0 then coalesce(po.promise_time, bo.OpenedTime) else bo.ClosedTime end) end as order_count
, date_diff(
    bo.businessdate
    , lag(bo.businessdate) over (
        partition by coalesce(po.customer_id, t.external_user_id)
        order by case when date_diff(date(bo.ClosedTime), bo.BusinessDate, day) > 0 then coalesce(po.promise_time, bo.OpenedTime) else bo.ClosedTime end
      )
    , day
  ) as days_since_prev_order
from brink_order bo
	left join brink_order_item boi
	on boi.orderId = bo.id
		left join brink_order_item_modifiers boim
		on boim.orderid = boi.orderid
			left join `marketing-data-442316`.pulse.orders po
			on po.brink_order_id = bo.Id
			and po.brink_order_id > 0
				left join `marketing-data-442316`.sales_ops.store_info s
				on s.store_id = bo.FKStoreId
					left join total_payment p
					on p.order_id = bo.Id
						left join `marketing-data-442316`.pulse.customers c
						on c.id = po.customer_id
							left join `marketing-data-442316`.pulse.order_customers ocs
							on ocs.order_id = po.id
								left join cust_trans t
								on t.pos_transaction_key = coalesce(po.id, bo.id)
									left join `marketing-data-442316`.brink.brinkDestinations bd
									on bd.Id = bo.DestinationId
									and bd.StoreID = bo.FKStoreId
										left join instore_emp_discounts d
										on d.order_id = boi.orderid
											left join employee_discount_offer do
											on do.pos_transaction_key = coalesce(po.id, bo.id)
												left join brink_promotions bp
												on bp.orderid = boi.orderid
													left join gift_card_purchase gc
													on gc.orderid = bo.id
;
