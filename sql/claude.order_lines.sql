-- =====================================================================================
-- claude.order_lines — Claude-facing authorized view over sales_ops.order_lines.
--
-- Interface layer, per the view-first strategy (steward 2026-07-22).
--
-- The only difference from the base mart is the history window:
--   * rolling 3 years, floor 2023-01-01 as of 2026-07-30. Truncation is SILENT — an older
--     range returns zero rows, not an error, which reads to a user as "no sales". Check the
--     window before reporting an empty result.
--
-- Simplified 2026-07-30. The view previously renamed BusinessDate -> business_date and
-- left-joined store_info for store_state; the steward's full-history rebuild of
-- sales_ops.order_lines on 2026-07-30 moved BOTH upstream, so the view is now a passthrough.
-- See the breaking-change note in claude_skills/sales-ops-orders/SKILL.md.
-- =====================================================================================

create or replace view `marketing-data-442316`.claude.order_lines as
select
  *
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date >= date_trunc(date_sub(current_date, interval 3 year), year)
;


-- =====================================================================================
-- Post-rebuild validation. Both were verified 2026-07-30 after the full-history rebuild.
--
-- 1. Grain preserved — 1,247,320 lines for 2026-06-01 → 2026-06-07, identical to the
--    pre-rebuild count.
-- 2. store_state is NULL only for stores absent from store_info — 512 lines in that week,
--    all store 1111 / 999. A market breakdown without `store_id <> 1111` therefore grows a
--    phantom market group; the exclusion filter is load-bearing for geography.
-- =====================================================================================
-- select
--   min(ol.business_date)                 as earliest
-- , max(ol.business_date)                 as latest
-- , count(*)                              as lines
-- , countif(ol.store_state is null)       as null_state
-- from `marketing-data-442316`.sales_ops.order_lines ol
-- where 1=1
-- and ol.business_date between '2026-06-01' and '2026-06-07'
-- ;
