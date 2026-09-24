# Data Dictionary: `marketing-data-442316.sales_ops.items_snapshot`

**One row per `item_id` per `snapshot_date`.** A weekly copy of the structural columns of
[`sales_ops.items`](sales_ops.items.md), taken by the "Weekly menu drift check" scheduled task
(Mondays 07:00 America/Denver) so that renames, size changes, category moves, `item_type` moves,
price edits and digital-menu toggles are visible week over week.

- **Why it exists:** the item dimension is rebuilt in full every morning (`create or replace`), and
  the 5am full-history reload of `order_lines` rewrites `item_name` / `item_size` / `rev_center_name`
  on every historical line from the *current* Brink master. Neither table carries any history of
  what an item used to be called or where it used to sit. A rename or a category move is therefore
  invisible everywhere except in a diff of two snapshots.
- **Grain:** (`snapshot_date`, `item_id`). 3,242 rows per snapshot (one per Brink item).
- **Partition:** `snapshot_date`. **Clustered** on `item_id`. Filter the partition.
- **Build:** block 1 of [`sql/checks/menu_drift_weekly.sql`](../sql/checks/menu_drift_weekly.sql):
  `create table if not exists` + `delete` today's partition + `insert` from `sales_ops.items`.
  Idempotent within a day. Written by the scheduled task, not by a BigQuery scheduled query.
- **First snapshot:** 2026-09-24. Block 2 (the diff) returns nothing until a second snapshot exists.
- **Steward-only.** Not exposed in the `claude` dataset; nothing here is a business measure.

## Columns

All columns except `snapshot_date` are copied verbatim from `sales_ops.items` on the snapshot day.
Read that dictionary for their definitions. Columns kept: `item_id`, `item_name`, `item_name_raw`,
`item_size`, `rev_center_id`, `rev_center_name`, `item_type`, `brink_item_type`, `item_status`,
`sold_as`, `first_sold_date`, `launch_date`, `last_sold_date`, `current_price`,
`price_variant_count`, `name_variant_count`, `store_count_active`, `stores_selling_28d`, `units_28d`,
`avg_unit_price_90d`, `pulse_item_id`, `is_on_digital_menu`, `is_catering_item`,
`is_combo_component`.

`units_28d`, `stores_selling_28d` and `avg_unit_price_90d` are trailing measures as of the
snapshot day, kept so a diff row can be ranked by how much volume the changed item carries.

## How the diff reads it

```sql
-- newest two snapshots, full outer join on item_id; change_kind is the first differing attribute
-- in this order: new_id / id_gone / renamed / resized / category_moved / type_moved / repriced / digital_menu_toggled
```

See block 2 of the check script. A `renamed` row means every historical order line for that id
now carries the new name; a `category_moved` or `type_moved` row means the same for
`rev_center_name` / `item_type`. Any report saved before the change and re-run after it will
disagree with itself on that item.

## Gotchas

- `current_price` is the most common price among current active store rows, so a `repriced` row
  can also mean the store mix behind the winner changed. Check `price_variant_count` before
  calling it a price change.
- A weekly cadence means a rename and a rename-back inside one week are invisible. That is
  accepted; the daily builds are what would catch a same-day flip, and nothing today reads them.
- If the scheduled task does not fire (missed Monday), the next run compares against the last
  snapshot that exists, however old. The diff output states both snapshot dates so a wider gap is
  visible.
