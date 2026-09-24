---
name: menu-drift-check
description: Weekly steward check for menu and item-structure changes (new ids, renames, category or item_type moves, price and line-type shifts, name splits) that silently break item growth rates. Run by the "Weekly menu drift check" scheduled task; usable by hand any time a growth number looks wrong.
---

# Menu drift check (steward routine)

> **Freshness:** written 2026-09-24 from the Kids Combo restructure. Re-measure the thresholds
> if the catalogue changes shape (they are tuned to ~90 stores and 500-600 selling ids).

## Why this exists

On 2026-06-01 the POS Kids Combo was restructured in Brink: a new `Composite` id **643647054**
(`item_name_raw = 'Kids Combo '`, trailing space, `$0.00`) took the POS half of Kids Combo volume
(digital and third-party orders stayed on 642361971, which is still live),
the price moved onto the kids entree lines (Grilled Cheese Sandwich / Chicken Tenders / Fruit Cup /
Soup went from `$0` modifiers to `$3.39` items), and because the build rule is
`bi.name = 'Kids Combo'` with no `trim()`, the new id landed in `item_type = 'Entree'` while the
old id 642361971 stayed `'Kids Meals'`.

Nothing broke and nothing was NULL, so no existing check fired. Sixteen weeks later:

| What a report measured | What it read | Reality |
|---|---|---|
| `item_type = 'Kids Meals'` units | **-55%** | flat: only the old id is in that bucket |
| `item_name = 'Kids Combo'` gross | **-50%** | flat: the new id carries $0 |
| Kids Grilled Cheese as `line_item_type = 'item'` | **+8,700%** | the same sandwiches, now priced lines |
| `rev_center_name = 'Kids Meals'` gross | -0.1% | this was the one true number |

Every one of those is a legitimate query against documented columns. The data was accurate; the
**structure** changed under the query. That class of change needs its own detector.

## What the check does

[`sql/checks/menu_drift_weekly.sql`](../../sql/checks/menu_drift_weekly.sql), eight blocks, each a
standalone statement. Run them **one at a time, in order**. Block 1 writes; 2-8 are read-only.
Everything reads `sales_ops.items`, `sales_ops.item_daily` and `sales_ops.items_snapshot` only.
Total cost is a few hundred MB. **Never widen it to `order_lines`** to get a finer answer; the
weekly window on `item_daily` is the whole point.

Window: **wk** = last complete Mon-Sun week (`date_sub(last_day(current_date('America/Denver'),
week(monday)), interval 7 day)` is its Sunday `week_ending`); **base** = the four weeks before it.

| Block | Catches | Threshold | Kids Combo backtest |
|---|---|---|---|
| 1 | (writes the weekly snapshot of `items`) | | |
| 2 | renames, resizes, `rev_center` / `item_type` moves, reprices, digital-menu toggles, new / gone ids | any change vs previous snapshot | n/a (first snapshot 2026-09-24) |
| 3 | new ids with real volume | `first_sold_date` within 35 days and (>= 250 units or >= 10 stores in wk) | 643647054: 5,751 units / 87 stores in week 1 |
| 4 | volume breaks per id | surge >= +100% at >= 1,000 units; collapse <= -30% on a >= 2,000/wk baseline | old id -33.7%, new id surge, both in week 1 |
| 5 | price or line-type shift on an existing id | avg unit price moves >= 15% and >= $0.25, or crosses zero, or `item` line share moves >= 15 pts; >= 500 units both windows | all four kids entrees `$0.03 -> $1.23`, kids drinks `line_type_shift` |
| 6 | a name whose set of selling ids / item_types / rev_centers changed, or spans two `item_type`s | count change vs base, or `item_types_wk > 1` | fired week ending 2026-05-10, the pilot week, four weeks before launch |
| 7 | one id under two names or sizes across stores | any `name_variants > 1` day | steady-state list of the store-scoped Brink defect |
| 8 | category totals (context, not alarms) | none | Kids Meals gross flat while every item moved |

Block 8 is the verdict line: **if the category is flat and the items moved, it is a restructure,
not a sales change**, and every item-level number in that category needs an id-aware rewrite.

## How to read a run

1. Blocks 3, 4, 5 and 6 together describe one event when the same ids or names appear in several.
   Group them by event before writing anything. LTO launches show up in 3 and 4 every few weeks
   and are **expected**: a new id with a real price, no partner id collapsing, no line-type shift.
   Say "LTO launch, no action" and move on.
2. A restructure looks like: a new `$0` or `Composite` id (3) **plus** a sibling with the same
   `item_name` collapsing (4) **plus** components whose price crossed zero or whose line type
   flipped (5) **plus** a name-split row (6), with the category flat (8).
3. Block 2 rows are always structural. A `renamed` / `category_moved` / `type_moved` row means
   history was rewritten at the last 5am reload: any saved query that filters on the old value now
   returns a different number than it did last week.
4. Block 7 is informational unless a high-volume id is new to it.

## What to do with a finding

For each **event** (not each row):

- **Asana task** on the Claude Data board (project `1216769551099591`), titled
  `Menu drift: <item or family> - <one-line what changed> (wk ending <date>)`. Body: the rows from
  each block that describe it, the affected canonical columns (`item_type`, `item_name`,
  `rev_center_name`, `line_item_type`), which KB rules or dictionaries need a sentence, and the
  proposed build change if one is obvious. Search the board first (`Menu drift:` + the item id) and
  add a comment instead of a duplicate when the event is already logged.
- **Do not edit the build scripts or the KB from the scheduled run.** The steward decides. The run
  reports and logs.
- The Monday summary to the steward lists events, not rows: item, what changed, which reports are
  now wrong and in which direction, the Asana link. One line each. "No structural change" is a
  valid and common result.

## Standing findings from the first run (2026-09-24)

- **Kids Combo is two LIVE ids, split by ordering channel. Neither is old.** 642361971 (`$6.79`,
  Brink `Normal`) is what Pulse digital and every third-party menu send: one priced header line,
  selections as `$0` modifiers. 643647054 (`$0.00`, Brink `Composite`, raw name `'Kids Combo '` with a
  trailing space) is what the POS menu has rung since 2026-06-01: a `$0` header with the two food
  selections as priced `item` components at `$3.40` each, the Try 2 Combo construct
  (`composite_item_id` points at the header). Week ending 2026-09-20: POS 10,328 vs 1,040 (Drive Thru)
  on the two ids; digital 5,263 and third party 3,056, all on 642361971. A kids-combo count is header
  lines `item_id in (642361971, 643647054)`; kids-combo **revenue** is `rev_center_name = 'Kids Meals'`
  or `parent_item_grp_name = 'Kids Combo'` over header plus components, because on POS the price sits
  on the entree lines. Component `price` is `0.00`; use `item_gross_sales`.
- **Build defect FIXED 2026-09-24** (Asana 1218830982693996): `bi.name = 'Kids Combo'` missed the
  trailing space, so the POS header was `item_type = 'Entree'` and `item_type = 'Kids Meals'` was a
  digital-plus-drive-thru number for 16 weeks. `sql/sales_ops.order_marts.sql` now trims `bi.name` in
  the `brink_items` CTE; history restated by a manual full reload at 13:51 MT and the config redeployed
  at 14:16 MT (the 14:02 hourly run in between had already rewritten the day back to `Entree`, which
  is why the deployed text, not the table, is the thing to verify). Side effect: the POS id's
  `item_size` moved from `Kids` to `Regular`, so both ids now read `Kids Combo / Regular / Kids Meals`
  and only `item_id` separates them.
- Kids entree items (`Grilled Cheese Sandwich` / `Chicken Tenders` / `Fruit Cup` / `Soup`, size
  `Kids`) now sell about 55-70% as priced `item` lines. Any "kids entree attach" measure built on
  `line_item_type = 'modifier'` lost the POS half of its population on 2026-06-01. The sale-shape
  test `parent_rev_center_name <> rev_center_name` reads those POS components as sold alone; use
  `composite_item_id is not null` for "inside a combo".
- **Try 2 Combo splits the same way and always has**: POS rings three `$0` composite headers
  (642388932 Sandwiches & Soups, 642388929 Salads & Sandwiches, 642388930 Salads & Soups); Pulse and
  third party send the single priced header 642361973 at `$12.99` with `$0` modifier selections. The
  `sales-ops-orders` skill documented the POS-vs-digital shape split on 2026-07-30; the id split is the
  same fact seen from the dimension side.
- **General rule this proved:** the same product can carry a different `item_id` per ordering
  channel, because the Pulse digital menu and the Brink POS menu are configured separately. When
  block 6 shows one name on several ids, break the ids out by `order_customer.destination` before
  calling either one old or new. I called 642361971 "old" on the first pass and was wrong; the
  channel split is what the data actually said.

## Running it by hand

Any time an item growth rate looks implausible, run blocks 3-6 with `p.wk_end` pinned to the
first week the number moved (replace the `date_sub(last_day(...))` expression with
`date '<sunday>'`). If a row for that item appears, the growth rate is measuring a structure
change; say so before anyone acts on it.
