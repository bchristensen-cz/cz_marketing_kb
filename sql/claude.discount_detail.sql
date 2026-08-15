-- =====================================================================================
-- claude.discount_detail — Claude-facing authorized view over sales_ops.discount_detail.
--
-- Interface layer, per the view-first strategy (steward 2026-07-22). Deployed 2026-08-15.
--
-- Two differences from the base mart, both matching what claude.order_customer already does
-- so that a channel breakdown off this view ties to one off order_customer:
--
--   1. History window — rolling 3 years, floor 2023-01-01 as of 2026-08-15. Truncation is
--      SILENT: an older range returns zero rows, not an error, which reads to a user as
--      "no discounts". Check the window before reporting an empty result.
--
--   2. revenue_category is catering-overridden. In this view
--      `revenue_category = 'Catering'` and `is_catering = true` are equivalent; in
--      sales_ops they are not (is_catering is a superset). Neither is wrong — they are
--      different definitions. State which dataset you queried whenever a number is being
--      compared to someone else's.
--
-- ACCESS: sales_ops already carries {dataset: claude, targetTypes: [VIEWS]} in its access
-- list, so no new authorized-dataset grant is required here — unlike
-- claude.order_payment_tender, which reads pulse/brink and needed one.
--
-- ⚠️ `select * except(...)` is EXPANDED AND FROZEN at view-creation time. If a column is
-- added to or renamed on sales_ops.discount_detail, this view keeps advertising the old
-- schema in INFORMATION_SCHEMA while erroring at query time. Redeploy with an identical
-- `create or replace` after any base-table schema change, then check INFORMATION_SCHEMA
-- rather than assuming. (Trap hit on claude.order_customer 2026-07-30.)
--
-- ⚠️ Column ORDER differs from the base table: the overridden revenue_category is appended
-- last rather than sitting in its original position. Anything doing positional column
-- access must not assume base-table order.
-- =====================================================================================

create or replace view `marketing-data-442316`.claude.discount_detail as
select
  dd.* except(revenue_category)
, case when dd.is_catering = true then 'Catering' else dd.revenue_category end as revenue_category
from `marketing-data-442316`.sales_ops.discount_detail dd
where 1=1
and dd.business_date >= date_trunc(date_sub(current_date, interval 3 year), year)
;


-- =====================================================================================
-- Post-deploy validation.
--
-- 1. Reconciliation — discount_amount must tie to order_lines exactly on the same filters.
--    Verified on the full-history build 2026-08-14: -$25,967,881.35 both sides.
-- 2. 'Error' must be 0-1 lines on every CLOSED business day. Today always spikes (~76% of
--    the integrated bucket) because pulse has not caught up; that is expected and
--    self-heals at the next 4am pass.
-- 3. discount_type must have zero NULLs (the build falls back to item_name, not 'Other').
-- =====================================================================================
-- select
--   round(sum(dd.discount_amount), 2) as mart_total
-- , (
--     select round(sum(ol.amount), 2)
--     from `marketing-data-442316`.sales_ops.order_lines ol
--     where 1=1
--     and ol.line_item_type in ('discount', 'promotion')
--     and ol.business_date >= date_trunc(date_sub(current_date, interval 3 year), year)
--     and ol.store_id not in (1111, 999)
--   ) as source_truth
-- , countif(dd.discount_type is null) as null_discount_type
-- from `marketing-data-442316`.claude.discount_detail dd
-- ;
