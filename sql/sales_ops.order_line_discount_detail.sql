-- sales_ops.order_line_discount_detail — scheduled query, deployable as-is.
-- Docs, gotchas and post-load assertions: data_dictionaries/claude.order_line_discount_detail.md
-- User-facing view: sql/claude.order_line_discount_detail.sql

-- history starts '2018-08-07';
declare run_dt datetime default current_datetime('America/Denver');
declare run_hour int64 default extract(hour from run_dt);
declare run_date date default date(run_dt);
declare start_date date;

set start_date = case
  -- 1st of month at 4am: ~13 month reload
  when extract(day from run_date) = 1 and run_hour = 4 then date_sub(run_date, interval 730 day)
  -- monday at 4am: 5 week reload
  when format_date('%A', run_date) = 'Monday' and run_hour = 4 then date_sub(run_date, interval 380 day)
  -- daily at 4am: 8 day reload
  when run_hour = 4 then date_sub(run_date, interval 120 day)
  -- intraday: today only
  when run_hour between 8 and 23 then run_date
  -- all other hours: skip
  else null
end;

if start_date is null then
  return;
end if;

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
, coalesce(odr.root_offer_id, pd.sessionM_root_offer_id) as root_offer_id
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
