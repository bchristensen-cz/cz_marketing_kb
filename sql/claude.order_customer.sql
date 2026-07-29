-- =====================================================================================
-- claude.order_customer — Claude-facing authorized view over sales_ops.order_customer.
--
-- Interface layer, per the view-first strategy (steward 2026-07-22): `claude` exposes
-- authorized views over `sales_ops` materialized tables; materialize only for expensive
-- aggregations or marts with no `sales_ops` parent.
--
-- Adds to the base mart:
--   * revenue_category  — catering orders forced to 'Catering' regardless of destination
--   * order sequence    — customer_order_count, days_since_prev_order
--   * customer lifetime — from sales_ops.customer_attribute
--   * account_type      — CATERING vs INDIVIDUAL at the ACCOUNT level (new 2026-07-29)
--
-- Created 2026-07-29.
-- =====================================================================================

create or replace view `marketing-data-442316`.claude.order_customer as
select
  oc.* except(revenue_category)
-- An order flagged is_catering on a non-catering destination (pulse-flagged catering on an
-- In-Store/Digital destination) should still report as Catering in channel mix.
, case when oc.is_catering = true then 'Catering' else oc.revenue_category end as revenue_category
, coalesce(os.customer_order_count, 0)          as customer_order_count
, coalesce(os.days_since_prev_order, 0)         as days_since_prev_order
, coalesce(ca.lifetime_order_count, 0)          as lifetime_order_count
, coalesce(ca.lifetime_catering_order_count, 0) as lifetime_catering_order_count
, coalesce(ca.lifetime_guest_order_count, 0)    as lifetime_guest_order_count
, ca.lifetime_net_sales
, ca.lifetime_gross_sales
, ca.lifetime_avg_check
, ca.first_order_date
, ca.last_order_date
, ca.days_since_last_order
, ca.customer_tenure_days
-- ACCOUNT-level catering flag. Distinct from oc.is_catering, which is ORDER-level: a catering
-- account placing an ordinary dine-in order correctly has is_catering = false but
-- account_type = 'catering'. Worked example: brink_order_id 56569385453631 (2026-04-23,
-- store 171, To Stay, $55.16) on cater_kim.harston@merit.com — Silver catering member,
-- is_individual_member = false. June 2026: 343 such orders / $5,284 net / 234 accounts.
--
-- ⚠️ JOIN KEY IS sm_external_user_id, NOT mapped_cust_id (steward 2026-07-29).
-- mapped_cust_id = coalesce(pulse_customer_id, sm_external_user_id) mixes two id spaces, so
-- joining it to loyalty_user.sm_external_user_id compares Pulse ids to SessionM ids. Measured
-- June 2026: of 287,563 pulse-identified orders, 170,160 matched a loyalty row and 7,270 of
-- those matched an account whose email disagrees with the order's — wrong people attached to
-- real orders. A further 142,440 orders carry BOTH ids, and the coalesce throws away the
-- known-good SessionM one.
--
-- Cost of the correct key: account_type is NULL on pulse-only digital orders that never
-- scanned loyalty. That gap is real and is what the email bridge in
-- design/crm_identity_hygiene_plan.md exists to close. A NULL is recoverable; a wrong
-- attribution is not.
--
-- Depends on claude.loyalty_user being ONE ROW PER sm_external_user_id — enforced by the
-- qualify added to that view 2026-07-29. Without it, 420 duplicated external ids fan this
-- view out and break order_customer's one-row-per-brink_order_id guarantee.
, lu.member_program      as account_type
, lu.is_catering_member  as is_catering_account
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
		left join `marketing-data-442316`.sales_ops.customer_attribute ca
		on ca.mapped_cust_id = oc.mapped_cust_id
			left join `marketing-data-442316`.claude.loyalty_user lu
			on lu.sm_external_user_id = oc.sm_external_user_id
where 1=1
and oc.business_date >= date_trunc(date_sub(current_date, interval 3 year), year)
;


-- =====================================================================================
-- Post-deploy validation — grain must be preserved.
-- Expect: rows = distinct brink_order_id. Any gap means a join fanned out.
-- =====================================================================================
-- select
--   count(*)                          as rows_
-- , count(distinct v.brink_order_id)  as distinct_orders
-- , countif(v.account_type is not null) as with_account_type
-- , countif(v.is_catering_account)      as catering_account_orders
-- from `marketing-data-442316`.claude.order_customer v
-- where 1=1
-- and v.business_date between date '2026-06-01' and date '2026-06-30'
-- ;
