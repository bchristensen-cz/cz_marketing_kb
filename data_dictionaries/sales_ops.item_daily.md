# Data Dictionary: `marketing-data-442316.sales_ops.item_daily`

**One row per `item_id` × `business_date`.** A thin rollup of `order_lines` that exists so
[`sales_ops.items`](sales_ops.items.md) can recompute lifetime and trailing metrics every day
without re-scanning the line fact. Also usable directly for item trend questions.

- **Grain:** one row per (`item_id`, `business_date`). 1,314,070 rows, 2018-08-13 → today
  (verified 2026-09-14).
- **Partition:** `business_date`. **Clustered** on `item_id`. Filter the partition.
- **Build:** [`sql/sales_ops.items.sql`](../sql/sales_ops.items.sql) statement 1, daily 07:30
  America/Denver. Sunday reloads full history from 2018-08-07 (40.58 GiB); Mon-Sat is a
  trailing 8-day `delete` + `insert` inside a transaction (~1 GiB).
- **Documented / deployed:** 2026-09-14.

## Scope, and why the exclusions matter

```sql
and ol.store_id not in (1111, 999)
and ol.line_item_type not in ('discount','promotion','surcharge')
```

- Stores 1111 and 999 are the locked exclusion (no `store_info` row, NULL name and state).
- The three excluded line types do **not** carry item ids. `order_lines.item_id` holds a
  DiscountId / PromotionId / SurchargeId on those lines, which is the entire population of 131
  sold ids with no `brinkItems` master row (27 + 73 + 31, measured 2026-09-14).

Fee, tip and gift-card lines **are** real Brink items and are kept. They show up as
`sold_as = 'other'` on the dimension.

## Columns

| Column | Type | Notes |
|---|---|---|
| `business_date` | DATE | Partition column |
| `item_id` | INTEGER | Joins to `sales_ops.items.item_id` |
| `stores_selling` | INTEGER | Distinct stores that sold it that day. This is what `launch_date` is derived from |
| `orders` | INTEGER | Distinct `brink_order_id` **within the day**. Summing across days over-counts an order only if it spans days, which it cannot, but summing across days does over-count *customers* |
| `units` | FLOAT | `sum(order_lines.qty)`, itself derived (`item_gross_sales / price`, floored at 1) |
| `gross_sales` | FLOAT | |
| `item_net_sales` | FLOAT | ⚠️ Item-level net. **Does not reconcile to `order_customer.net_sales`** |
| `lines_total` | INTEGER | All kept line types |
| `lines_as_item` | INTEGER | `line_item_type = 'item'` |
| `lines_as_modifier` | INTEGER | `line_item_type = 'modifier'` |
| `lines_as_other` | INTEGER | fee / tip / gift_card |
| `lines_catering` | INTEGER | Lines on catering orders |
| `units_catering`, `gross_sales_catering` | FLOAT | Catering slice of the day |
| `lines_in_combo` | INTEGER | Lines whose `parent_rev_center_name` is `Try 2 Combo` |
| `name_variants` | INTEGER | Distinct `item_name` values seen that day for the id. >1 means the same id was ringing under two names across stores |
| `size_variants` | INTEGER | Same, for `item_size` |

## Tie-out

Straight rollup, so it must match `order_lines` exactly under the same filters. Measured
2026-08-10 → 2026-09-06: **5,134,823 units on both sides, unit diff 0, gross diff 0.00.** A
non-zero diff means a reload-width problem, not a definition problem — check what last wrote the
partitions on both tables before changing anything.

## Reload width is a real constraint

Mon-Sat only the trailing 8 days are rebuilt. If `order_lines` is restated outside that window,
this table stays stale until the Sunday full reload repairs it. That is the accepted trade
(steward call 2026-09-14): 40.58 GiB once a week rather than every day.
