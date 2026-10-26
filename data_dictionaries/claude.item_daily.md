# Data Dictionary: `marketing-data-442316.claude.item_daily`

**One row per `item_id` x `business_date`.** Authorized view over
[`sales_ops.item_daily`](sales_ops.item_daily.md), exposing the item-by-day rollup to standard
users. Build script: [`sql/claude.item_daily.sql`](../sql/claude.item_daily.sql). Deployed
2026-10-26.

## Why it exists

An item trend line, an item's trailing run rate, and the per-category p90 benchmark used by the
validation step in `claude_skills/ask-a-data-question` (Step 4, `references/validation.md`) all
want item-by-day numbers. Reading them off `order_lines` costs a scan of the line fact every
time; this table holds the same numbers pre-rolled, partitioned on `business_date` and
clustered on `item_id`, so a week reads in a few MB. It ties out to `order_lines` exactly under
the same filters (parent dictionary, "Tie-out": 5,134,823 units both sides, diff 0).

The `claude` dataset is authorized on `sales_ops` at the dataset level
(`targetTypes: ["VIEWS"]`), so the view inherited access with no extra grant.

## Divergence from the parent

One: the history window is a **rolling 3 years**, `business_date >= date_trunc(date_sub(
current_date, interval 3 year), year)`, the same rule as `claude.order_customer` and
`claude.order_lines`. On 2026-10-26 that is 2023-01-01 forward, 501,611 rows = 501,611 in the
parent over the same window. Truncation is **silent**: an older range returns zero rows, not an
error, which reads as "no sales". Check the window before reporting an empty result.

## Columns

Identical to the [`sales_ops.item_daily` dictionary](sales_ops.item_daily.md). The ones the
validation step uses:

| Column | Notes |
|---|---|
| `business_date` | Partition column. Always filter it |
| `item_id` | Joins to `claude.items.item_id` |
| `units`, `gross_sales` | All kept lines, catering included |
| `units_catering`, `gross_sales_catering` | The catering slice. Non-catering = `units - units_catering` |
| `orders` | Distinct `brink_order_id` **within the day**. Summing across days is exact for orders (an order cannot span days) and an upper bound for customers |
| `stores_selling` | What `launch_date` is derived from |
| `lines_as_item`, `lines_as_modifier`, `lines_in_combo` | The sale-shape split without re-reading `order_lines` |

Stores 1111 / 999 and `discount` / `promotion` / `surcharge` lines are already excluded in
the build. Do not re-apply those filters here.

## Reload width

Mon-Sat the parent rebuilds only the trailing 8 days; Sunday reloads full history. A
restatement of `order_lines` outside the 8-day window does not reach this table until Sunday.
If a benchmark and an `order_lines` answer disagree on an older window, that is why.
