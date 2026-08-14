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
--   * store_state       — the canonical "market" dimension (new 2026-07-30)
--
-- Created 2026-07-29. store_state added 2026-07-30.
--
-- 2026-08-13 repo sync: the DEPLOYED view carries `and oc.store_id <> 1111` — the test store
-- is excluded at the view level, not left to each query. Found undocumented during the
-- order_customer script sync; now committed here. Standard users can no longer see 1111 at
-- all; the steward's sales_ops tables still contain it. Keep writing `store_id <> 1111` in
-- queries anyway — it is free here and load-bearing everywhere else.
--
-- Redeployed 2026-08-13 (identical logic) to refresh INFORMATION_SCHEMA metadata: the base
-- table gained destination_id and has_order_items, and column ADDS freeze out of `oc.*` view
-- metadata exactly like the 2026-07-30 rename did — the columns RESOLVED at query time but
-- were absent from INFORMATION_SCHEMA.COLUMNS until the redeploy.
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
-- JOIN KEY IS mapped_cust_id, and that is correct (verified 2026-07-29 against the live
-- deduped view). pulse_customer_id and sm_external_user_id are the SAME id space, not two:
-- of 142,386 June orders carrying both, 142,127 (99.8%) hold an identical value. Only 259
-- differ and just 26 of those resolve to a loyalty account either way.
--
-- mapped_cust_id also covers materially more: 27,953 June orders are pulse-identified with no
-- sm_external_user_id, and the order email agrees with the matched loyalty account on 26,632
-- of them (95.3%) — real matches, not id-range coincidence. Joining on sm_external_user_id
-- instead silently drops all of them.
--
-- ⚠️ Do NOT "fix" this to sm_external_user_id on the basis of an email-mismatch count. Of the
-- 7,568 June orders where lower(mapped_email) <> loyalty_user.email, 7,088 (93.7%) are the
-- cater_ prefix and nothing else: sm_external_user_map strips it (regexp_replace ... r'^cater_')
-- while loyalty_user.email retains it, so mapped_email equals email_normalized exactly. Compare
-- against email_normalized, not email. Only 480 are genuinely different addresses, and the
-- sm_external_user_id join carries 6,275 mismatches of its own — the key is not the cause.
--
-- Depends on claude.loyalty_user being ONE ROW PER sm_external_user_id — enforced by the
-- qualify added to that view 2026-07-29 and verified live (1,775,284 rows = 1,774,963 distinct
-- external ids + 321 NULL). Without it this view fans out.
, lu.member_program as account_type
-- NO store_info join here. "Market" = store_state, and it arrives free through `oc.*` —
-- sales_ops.order_customer already joins store_info in its own build script.
--
-- History, because it churned inside one day (2026-07-30) and the scar tissue is the useful
-- part:
--   1. A store_info join was added here to expose store_state, on the belief that no market
--      dimension existed. An INFORMATION_SCHEMA sweep for %market%/%region%/%dma%/%metro%
--      had found nothing.
--   2. It was then found that order_customer ALREADY carried the state, under the column
--      name `state` — documented all along. The join was a pure duplicate: 1,326,905 orders
--      over 2026-05-03 → 2026-06-27, zero disagreements, identical nulls.
--   3. The join was dropped and the base column renamed `state` -> `store_state`, so every
--      table now agrees: order_customer, order_lines, store_info.
--
-- Lesson: the dimension existed the whole time under a name nobody searched for. Grep the
-- dictionaries for the CONCEPT, not just the warehouse for the WORD. This is now step 1 of
-- the ask-a-data-question skill.
--
-- ⚠️ Deployment trap: this view is `oc.* except(...)`, and BigQuery expands and FREEZES `*`
-- at creation time. After the base rename the view still advertised `state` in
-- INFORMATION_SCHEMA.COLUMNS while `select oc.state` errored and `select oc.store_state`
-- worked — metadata and behaviour disagreed. A `create or replace view` with identical text
-- is required to refresh it. Redeploy every `select *` view after any base-column rename.
--
-- ⚠️ store_state is NULL for stores 1111 and 999 (absent from store_info). A market
-- breakdown without `store_id <> 1111` grows a phantom tenth market — 1,154 orders /
-- $117,196 over 2026-05-03 → 2026-06-27 — presenting as an unnamed NULL group that reads
-- like a data defect rather than the test store.
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
		left join `marketing-data-442316`.sales_ops.customer_attribute ca
		on ca.mapped_cust_id = oc.mapped_cust_id
			left join `marketing-data-442316`.claude.loyalty_user lu
			on lu.sm_external_user_id = oc.mapped_cust_id
where 1=1
and oc.business_date >= date_trunc(date_sub(current_date, interval 3 year), year)
and oc.store_id <> 1111  -- 2026-08-13 sync: deployed view excludes the test store entirely
;


-- =====================================================================================
-- Post-deploy validation — grain must be preserved.
-- Expect zero rows. Any row means a join fanned out.
-- =====================================================================================
-- select
--   oc.brink_order_id
-- , count(*) as cnt
-- from `marketing-data-442316`.claude.order_customer oc
-- where 1=1
-- group by 1
-- having count(*) > 1
-- order by count(*) desc
-- ;
