-- claude.item_daily
-- Authorized view exposing the item-by-day rollup (sales_ops.item_daily) to standard users.
--
-- Why it exists: sales_ops.item_daily (1 row per item_id x business_date, partitioned on
-- business_date, clustered on item_id, rebuilt daily 07:30 MT) is the cheap source for an
-- item trend line, an item's trailing run rate, and the per-category p90 benchmark used by
-- the validation step in claude_skills/ask-a-data-question (references/validation.md).
-- Until 2026-10-26 it had no claude view, so every such read was a second scan of
-- order_lines.
--
-- The claude dataset is authorized on sales_ops at the DATASET level (targetTypes: VIEWS),
-- so this view inherits access with no extra grant.
--
-- The only difference from the base table is the history window: rolling 3 years, same
-- rule as claude.order_customer and claude.order_lines. Truncation is SILENT (an older
-- range returns zero rows, not an error), so check the window before reporting an empty
-- result. Stores 1111 / 999 and discount / promotion / surcharge lines are already excluded
-- upstream in the build (sql/sales_ops.items.sql statement 1); do not re-apply them.
--
-- Deployed 2026-10-26.

create or replace view `marketing-data-442316`.claude.item_daily as
select
  *
from `marketing-data-442316`.sales_ops.item_daily d
where 1=1
and d.business_date >= date_trunc(date_sub(current_date, interval 3 year), year)
;
