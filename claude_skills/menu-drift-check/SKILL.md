---
name: menu-drift-check
description: Weekly steward check for menu and item-structure changes (new ids, renames, category or item_type moves, price and line-type shifts, name splits) that silently break item growth rates. Run by the "Weekly menu drift check" scheduled task; usable by hand any time a growth number looks wrong.
---

# Menu drift check (steward routine)

> **Freshness:** written 2026-09-24 from the Kids Combo restructure. Re-measure the thresholds
> if the catalogue changes shape (they are tuned to ~90 stores and 500-600 selling ids).

## Why this exists

On 2026-06-01 the Kids Combo was restructured in Brink: a new `Composite` id **643647054**
(`item_name_raw = 'Kids Combo '`, trailing space, `$0.00`) took about half of Kids Combo volume,
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

- **Kids Combo is two ids.** 642361971 (`Regular`, `$6.79`, `item_type = 'Kids Meals'`, the
  priced combo) and 643647054 (`Kids`, `$0.00`, `Composite`, `item_type = 'Entree'`, the
  restructured header). A kids-combo count is `item_id in (642361971, 643647054)` by units; a
  kids-combo **revenue** number must use `rev_center_name = 'Kids Meals'` at the order or line
  level, because half the price now sits on the entree lines.
- **Build defect, steward call open:** `sql/sales_ops.order_marts.sql` line ~807,
  `when brc.name = 'Kids Meals' and bi.name = 'Kids Combo' then 'Kids Meals'` misses the
  trailing-space name. Proposed fix: `trim(bi.name) = 'Kids Combo'` on both branches, deploy and
  commit together, then the 5am reload restates history. Until then `item_type = 'Kids Meals'`
  undercounts kids combos by ~52% for every week since 2026-06-01.
- Kids entree items (`Grilled Cheese Sandwich` / `Chicken Tenders` / `Fruit Cup` / `Soup`, size
  `Kids`) now sell about 55-70% as priced `item` lines. Any "kids entree attach" measure built on
  `line_item_type = 'modifier'` lost half its population on 2026-06-01.

## Running it by hand

Any time an item growth rate looks implausible, run blocks 3-6 with `p.wk_end` pinned to the
first week the number moved (replace the `date_sub(last_day(...))` expression with
`date '<sunday>'`). If a row for that item appears, the growth rate is measuring a structure
change; say so before anyone acts on it.
