# Data Dictionary: `marketing-data-442316.claude.items`

**One row per Brink `item_id`.** Authorized view over
[`sales_ops.items`](sales_ops.items.md), exposing the item dimension to standard users. Build
script: [`sql/claude.items.sql`](../sql/claude.items.sql). Deployed 2026-10-26.

## Why it exists

`sales_ops.items` is the cheap way to resolve a product name to its real `item_id`s (with
`avg_unit_price_90d` beside each candidate, which is what makes a wrong pick visible), to read
`launch_date`, `item_status` and `is_catering_item`, and to list "new items". Until 2026-10-26
it had no `claude` view, so standard users could not reach it and every item benchmark was a
second scan of `order_lines`. The validation step in `claude_skills/ask-a-data-question`
(Step 4, `references/validation.md`) reads this view for the new-item candidate list and joins
it to `claude.item_daily` for the p90 benchmark.

The `claude` dataset is authorized on `sales_ops` at the dataset level
(`targetTypes: ["VIEWS"]`), so the view inherited access with no extra grant.

## Columns

Identical to the [`sales_ops.items` dictionary](sales_ops.items.md): the view is `select *`
with nothing dropped, renamed or filtered. 3,249 rows = 3,249 in the parent (verified
2026-10-26; the parent was 3,242 when documented on 2026-09-14 and grows as Brink adds ids).
No partition column; full scans are fine. Filter the partition on the table you join it to.

## Three things to know

1. **`item_name` is still not a product key.** Resolve to `item_id` first. Several ids share
   a name (sizes, kids versions, catering boxes, modifiers); this view just makes resolving
   cheap.
2. **`launch_date` is derived**: the first business date the item sold in at least 25% of the
   stores it ever reached. A product sold at a handful of stores since March that crossed 25%
   last week shows a `launch_date` of last week. Always show `first_sold_date` beside it. On
   2026-10-26 the 28-day new-item list held five Box sandwiches with `first_sold_date` in
   March for exactly this reason.
3. **Join only to sellable lines.** `order_lines.item_id` is a DiscountId / PromotionId /
   SurchargeId on `discount` / `promotion` / `surcharge` lines, not an item id. Join on
   `line_item_type in ('item', 'modifier', 'fee', 'tip', 'gift_card')`.

`rev_center_name` has two spellings per category (`COMBOS` and `Combos` are both real), and the
split is by era, not by store (measured 2026-10-28): ALL-CAPS ids last sold 2023-02-16 (`COMBOS`
2023-05-24), mixed-case ids first sold 2023-01-06 and are the only ones live. Filter and group on
`upper(rev_center_name)` whenever the window reaches back before 2023-02-17.
