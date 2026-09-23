-- drop table `marketing-data-442316`.sales_ops.cust_map
create or replace table `marketing-data-442316`.sales_ops.cust_map
cluster by email, acct_id
as

-- one row per order email (and per account email with no orders). resolves the email to ONE pulse customer id:
--   1. authenticated_order : the customer_id signed in (is_loyalty_user) on an order carrying this email - latest such order wins
--   2. account_email       : a pulse.customers row carries this email but never authenticated on it - live row, then highest id
--   3. order_max           : only guest orders ever - highest customer_id on the email's orders

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

, customers as (
select
  c.id
, lower(trim(c.email)) as email
, c.deleted_at
, case
	when lower(trim(c.email)) = 'checkmate_user@cafezupas.com' then 1
	when lower(trim(c.email)) like '%outdoor%@cafezupas.com' then 1
	else 0
	end as is_sys_acct_email
from `marketing-data-442316`.pulse.customers c
where 1=1
and c.is_catering = false
)

, orders as (
select
  lower(trim(oc.email)) as email
, po.customer_id
, c.email as acct_email
, oc.is_loyalty_user
, oc.created_at
, coalesce(c.is_sys_acct_email, 0) as is_sys_acct_email
from pulse_orders po
	join `marketing-data-442316`.pulse.order_customers oc
	on oc.order_id = po.id
		left join customers c
		on c.id = po.customer_id
where 1=1
and oc.email is not null
and lower(trim(oc.email)) not like '%@guest.doordash.com'
and lower(trim(oc.email)) not like '%@itsacheckmate.com'
and lower(trim(oc.email)) <> 'support@doordash.com'
and lower(trim(oc.email)) not like '%outdoor%@cafezupas.com'
)

-- tier 1: an account authenticated on an order that carries this email
, auth_acct as (
select
  o.email
, o.customer_id as acct_id
, o.acct_email
, count(distinct o.customer_id) over(partition by o.email) as auth_acct_id_count
from orders o
where 1=1
and o.is_loyalty_user = true
and o.is_sys_acct_email = 0
and o.customer_id is not null
--qualify row_number() over(partition by o.email order by o.created_at desc, o.customer_id desc) = 1
qualify row_number() over(partition by o.email order by o.acct_email = o.email desc, o.created_at desc, o.customer_id desc) = 1
)

-- tier 2: an account whose own email is this email (whether or not it ever ordered)
, acct_by_email as (
select
  c.email
, c.id as acct_id
, c.email as acct_email
from customers c
where 1=1
and c.email is not null
and c.is_sys_acct_email = 0
qualify row_number() over(partition by c.email order by c.deleted_at is null desc, c.id desc) = 1
)

-- tier 3: highest customer id on the email's orders (guest-only emails end here)
, order_max as (
select
  o.email
, max(o.customer_id) as acct_id
, count(*) as order_count
from orders o
group by o.email
)

, emails as (
select email from order_max
union distinct
select email from acct_by_email
)

select
  e.email
, coalesce(a.acct_id, b.acct_id, x.acct_id) as acct_id
, coalesce(a.acct_email, b.acct_email, cx.email) as acct_email
, case
	when a.acct_id is not null then 'authenticated_order'
	when b.acct_id is not null then 'account_email'
	when x.acct_id is not null then 'order_max'
	end as map_source
, a.auth_acct_id_count
, b.acct_id as acct_by_email_id
, x.acct_id as order_max_cust_id
, x.order_count
-- deprecated aliases, keep until order_sequence reads acct_id
, coalesce(a.acct_id, b.acct_id, x.acct_id) as max_acct_id
, coalesce(a.acct_id, b.acct_id, x.acct_id) as final_acct_id
from emails e
	left join auth_acct a
	on a.email = e.email
	left join acct_by_email b
	on b.email = e.email
	left join order_max x
	on x.email = e.email
		left join customers cx
		on cx.id = x.acct_id
where 1=1
and coalesce(a.acct_id, b.acct_id, x.acct_id) is not null
