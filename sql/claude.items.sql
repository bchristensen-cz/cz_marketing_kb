-- claude.items
-- Authorized view exposing the item dimension (sales_ops.items) to standard users.
--
-- Why it exists: sales_ops.items (1 row per Brink item_id, rebuilt daily 07:30 MT) is the
-- cheap way to resolve a name to its real item_ids, read launch_date / item_status /
-- avg_unit_price_90d, and find "new items". Until 2026-10-26 it had no claude view, so
-- standard users could not reach it and every item benchmark was a second scan of
-- order_lines. Built for the validation step in claude_skills/ask-a-data-question
-- (references/validation.md): the new-item fork and the p90 benchmark read this view.
--
-- The claude dataset is authorized on sales_ops at the DATASET level (targetTypes: VIEWS),
-- so this view inherits access with no extra grant.
--
-- Straight pass-through: no PII, no partition column, 3,242 rows (2026-09-14 count). Nothing
-- is dropped or renamed; the sales_ops.items dictionary applies verbatim. Remember that
-- item_id on discount / promotion / surcharge lines of order_lines is NOT an item id, so
-- join this view only to line_item_type in ('item', 'modifier', 'fee', 'tip', 'gift_card').
--
-- Deployed 2026-10-26.

create or replace view `marketing-data-442316`.claude.items as
select
  *
from `marketing-data-442316`.sales_ops.items i
;
