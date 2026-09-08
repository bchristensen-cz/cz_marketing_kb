create or replace table `marketing-data-442316`.sales_ops.cust_map 
cluster by email, acct_email, max_acct_id, final_acct_id
as 

with map as (

	with pulse_orders as ( 
	select 
	po.id
	, po.customer_id
	from `marketing-data-442316`.pulse.orders po
	where 1=1
	and po.brink_order_id > 0
	and po.is_catering = false
	qualify row_number() over(partition by po.brink_order_id order by po.id desc) = 1
	)
	
	, customer as (
	select 
	c.id
	, lower(trim(c.email)) as email
	, case
		when c.email = 'checkmate_user@cafezupas.com'
		or c.email like '%outdoor%@cafezupas.com' then 1
		else 0
	end as is_sys_acct_email
	from `marketing-data-442316`.pulse.customers c
	where 1=1
	and c.is_catering = false
	)
	
	, order_customer as (
	select 
	lower(trim(oc.email)) as email
	, lower(trim(c.email)) as acct_email
	, oc.customer_id as pulse_customer_id
	, case
		when lower(trim(oc.email)) like '%@guest.doordash.com' then 1
		when lower(trim(oc.email)) like '%@itsacheckmate.com' then 1
		when lower(trim(oc.email)) = 'support@doordash.com' then 1
		when lower(trim(oc.email)) like '%outdoor%@cafezupas.com' then 1  
		else 0
	end as is_sys_order_email
	, c.is_sys_acct_email
	, case when c.email is null then 0 else 1 end as has_acct_email
	, oc.created_at
	from pulse_orders po
		left join `marketing-data-442316`.pulse.order_customers oc
		on oc.order_id = po.id
			left join customer c
			on c.id = po.customer_id
	)
	
	, map_orders as (
	select
	oc.email 
	, oc.acct_email
	, 2 as priority
	, max(oc.pulse_customer_id) over(partition by oc.email) as max_acct_id
	from order_customer oc
	where 1=1
	and oc.is_sys_order_email = 0
	qualify row_number() over(partition by oc.email order by oc.is_sys_acct_email, oc.has_acct_email desc, oc.created_at desc) = 1
	) 
	
	, cust_final as (
	select
	lower(trim(c.email)) as email
	, lower(trim(c.email)) as acct_email
	, 1 as priority
	, c.id as acct_id
	from `marketing-data-442316`.pulse.customers c
	where 1=1
	and c.email is not null
	and c.is_catering = false
	qualify row_number() over(partition by lower(trim(c.email)) order by c.id desc) = 1
	)
	
	, cust_final_final as (
	select * from map_orders
	union all 
	select * from cust_final
	) 
	
	
	select * 
	from cust_final_final f
	qualify row_number() over(partition by f.email order by f.priority) = 1
)

, cust_final as (
	select
	lower(trim(c.email)) as email
	, lower(trim(c.email)) as acct_email
	, 1 as priority
	, c.id as acct_id
	from `marketing-data-442316`.pulse.customers c
	where 1=1
	and c.email is not null
	and c.is_catering = false
	qualify row_number() over(partition by lower(trim(c.email)) order by c.id desc) = 1
	)


select 
m.email
--, m.acct_email
, coalesce(m.acct_email, f1.email) as acct_email
, m.max_acct_id
, coalesce(f.acct_id, f1.acct_id) as final_acct_id
from map m
	left join cust_final f
	on f.email = m.acct_email
		left join cust_final f1
		on f1.email = m.email
