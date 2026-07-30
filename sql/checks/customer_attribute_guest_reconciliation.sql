-- =====================================================================================
-- CHECK: sales_ops.customer_attribute.lifetime_guest_order_count vs sales_ops.order_customer
--
-- Written 2026-07-29 to chase 43 customers that appeared not to reconcile after the
-- is_guest_order fix. THEY DO RECONCILE. The 43 were an artifact of the checking query,
-- not a defect in the mart — see the note at the bottom before using this file.
--
-- Query A reproduces the false alarm. Query B is the correct check.
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- A. WRONG — reproduces the phantom 43. Do not use this shape.
--    Aggregates the mart WITHOUT the two filters customer_attribute applies at read.
-- -------------------------------------------------------------------------------------
with mart_unfiltered as (
select
  oc.mapped_cust_id           as mapped_cust_id
, countif(oc.is_guest_order)  as mart_guest
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.mapped_cust_id is not null
group by 1
)
select
  ca.mapped_cust_id                                  as mapped_cust_id
, ca.lifetime_guest_order_count                      as ca_guest
, m.mart_guest                                       as mart_guest
, m.mart_guest - ca.lifetime_guest_order_count       as missing
from `marketing-data-442316`.sales_ops.customer_attribute ca
	inner join mart_unfiltered m
	on m.mapped_cust_id = ca.mapped_cust_id
where 1=1
and ca.lifetime_guest_order_count <> m.mart_guest
order by missing desc
;
-- Returns 43 rows / 1,268 orders. Every one is a false positive.


-- -------------------------------------------------------------------------------------
-- B. CORRECT — mirrors the build's person_orders CTE exactly.
--    Expect ZERO rows.
-- -------------------------------------------------------------------------------------
with person_orders as (
select
  oc.mapped_cust_id           as mapped_cust_id
, countif(oc.is_guest_order)  as mart_guest
, count(*)                    as mart_orders
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date between date '2018-08-07' and date_sub(current_date('America/Denver'), interval 1 day)
and oc.store_id <> 1111          -- build filter 1
and oc.customer_type = 'person'  -- build filter 2
and oc.mapped_cust_id is not null
group by 1
)
select
  ca.mapped_cust_id                              as mapped_cust_id
, ca.lifetime_guest_order_count                  as ca_guest
, m.mart_guest                                   as mart_guest
, m.mart_guest - ca.lifetime_guest_order_count   as guest_diff
, ca.lifetime_order_count                        as ca_orders
, m.mart_orders                                  as mart_orders
from `marketing-data-442316`.sales_ops.customer_attribute ca
	inner join person_orders m
	on m.mapped_cust_id = ca.mapped_cust_id
where 1=1
and (ca.lifetime_guest_order_count <> m.mart_guest
  or ca.lifetime_order_count <> m.mart_orders)
order by abs(m.mart_guest - ca.lifetime_guest_order_count) desc
;


-- =====================================================================================
-- WHY THE 43 WERE PHANTOMS
--
-- customer_attribute filters to customer_type = 'person' and store_id <> 1111 at read
-- (build header, steward 2026-07-28). Query A applied neither.
--
-- customer_type is ORDER-level, not customer-level — the same mapped_cust_id can carry
-- different values across its orders (documented in sales_ops.order_customer.md). All 43
-- were customers whose guest orders sat on NON-person orders while their other orders were
-- person. Aggregating with max(customer_type) makes the customer look like a 'person' while
-- the guest orders being counted are not, so the mart total exceeds the build's — by 1,268
-- orders, all of them in 2023.
--
-- The 2023 concentration looked like a history-window cutoff and is not: it is where the
-- mixed-type orders happen to live.
--
-- LESSON: when reconciling an aggregate table against its source, copy the build's WHERE
-- clause verbatim before concluding anything. Two separate false alarms in this session came
-- from comparing against a differently-filtered population.
-- =====================================================================================
