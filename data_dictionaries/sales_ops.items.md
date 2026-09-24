# Data Dictionary: `marketing-data-442316.sales_ops.items`

**One row per Brink `item_id`.** The item dimension — naming, size, revenue centre, lifecycle
dates, lifetime and trailing sales, catering and combo profile, Brink menu config, and the
digital (Pulse) mapping. Join it to `order_lines` on `item_id` to describe an item without
re-deriving anything.

- **Grain:** one row per `item_id`. 3,242 rows = 3,242 distinct ids = 3,242 ids in
  `brink.brinkItems` (verified 2026-09-14). No fan-out.
- **Size:** well under 1 MB, no partition column. Full scans are fine; the "always filter the
  partition" rule does not apply. Filter the partition column on the table you join it to.
- **Build:** [`sql/sales_ops.items.sql`](../sql/sales_ops.items.sql), daily 07:30 America/Denver.
  Rebuilt in full every run (`create or replace`) off `sales_ops.item_daily`, 152 MB a run.
- **Documented / deployed:** 2026-09-14.

## What it replaced

The old `sales_ops.items`: 2,196 rows at `item_id` + `rev_center_id` grain, written once on
2025-12-10 and never refreshed. Dropped 2026-09-14; a copy sits at
`scratch.items_pre_20260914` until 2026-12-13. **`rev_center_id` is deliberately not part of the
new grain** — 5 item_ids move revenue centre across stores, so keeping it would put the same
item on several rows again. Anything still joining on both columns fails loudly. That is the
intent (steward call 2026-09-14).

## Columns

| Column | Type | Notes |
|---|---|---|
| `item_id` | INTEGER | Join key. Matches `order_lines.item_id` **on `item`, `modifier`, `fee`, `tip` and `gift_card` lines only** — see the id-space warning below |
| `item_name` | STRING | Size-stripped name, **identical to `order_lines.item_name`** for the same id. Verified on 548 of 548 ids sold in the trailing 45 days, zero mismatches (2026-09-14). Not unique: several ids share a name, which is the whole point of resolving on `item_id` |
| `item_size` | STRING | Same 10-value domain as `order_lines.item_size`, no NULLs. Per-item distribution 2026-09-14: `Not Sized` 2,324 / `Large` 428 / `Regular` 201 / `Kids` 144 / `Half` 70 / `Tray` 41 / `Quart` 16 / `Party` 13 / `Mini` 4 / `Medium` 1. ⚠️ `Quart` (16) and `Medium` (1) exist **here** but have never appeared on an order line — configured, never sold |
| `item_name_raw` | STRING | The winning Brink name before parsing, size prefix and any `.` / `--` lead intact. Use it when you need the name a store actually sees |
| `rev_center_id` | INTEGER | From the winning store's row |
| `rev_center_name` | STRING | 37 distinct, 0 NULLs. Note case drift across stores: `COMBOS` and `Combos` are both real |
| `item_type` | STRING | Same taxonomy as `order_lines.item_type`: `Other` 2,903 / `Entree` 186 / `Beverage` 151 / `Kids Meals` 2 |
| `first_sold_date` | DATE | First business date the item ever sold. NULL when `has_ever_sold` is false |
| `launch_date` | DATE | **Derived, not given** — see the launch-date section |
| `last_sold_date` | DATE | Most recent business date it sold |
| `days_since_last_sold` | INTEGER | Against the build's run date |
| `days_sold` | INTEGER | Count of distinct business dates with a sale |
| `has_ever_sold` | BOOLEAN | 2,234 true / 1,008 false |
| `item_status` | STRING | `discontinued` 1,571 (no sale in 365d) / `never_sold` 1,008 / `selling` 541 (sold in 28d) / `dormant` 122 (28-365d) |
| `lifetime_units` | FLOAT | From `order_lines.qty`, which is itself derived (`item_gross_sales / price`, floored at 1) |
| `lifetime_gross_sales` | FLOAT | |
| `lifetime_item_net_sales` | FLOAT | ⚠️ **Item-level net. Does NOT reconcile to `order_customer.net_sales`** — same limit as `order_lines.item_net_sales`. Never quote it as "net sales" |
| `lifetime_orders` | INTEGER | Distinct `brink_order_id`, summed by day, so an item bought on two days counts twice. A true lifetime distinct-order count needs `order_lines` |
| `units_28d`, `gross_sales_28d` | FLOAT | Trailing 28 days from the run date |
| `units_365d`, `gross_sales_365d` | FLOAT | Trailing 365 days |
| `avg_unit_price_90d` | FLOAT | Trailing-90-day gross ÷ units. **The column that makes a wrong item pick visible** — a Mini reading $10.25 instead of $9.00 means the name blended two ids |
| `sold_as` | STRING | `item` 800 / `modifier` 778 / `item & modifier` 645 / `other` 11 / NULL 1,008 (never sold). A `modifier`-only id will never appear in a menu-mix count built on `line_item_type = 'item'` |
| `is_catering_item` | BOOLEAN | **True when 100% of the item's lines are on catering orders: 60 ids** (e.g. every `Cater …` Box Lunch). This is the SKU-level catering flag `order_lines.is_catering` cannot give you — that column describes the *order*, not the item |
| `catering_unit_share` | FLOAT | 0 to 1. Use it instead of the boolean when you want "mostly catering", not "only catering" |
| `is_combo_component` | BOOLEAN | 344 ids have at least one line whose `parent_rev_center_name` is `Try 2 Combo` |
| `combo_line_share` | FLOAT | Share of the item's lines sold inside a combo |
| `store_count_configured` | INTEGER | Distinct stores with any master row, legacy included |
| `store_count_current` | INTEGER | Distinct stores with a current (`IsOldData = 0`) row |
| `store_count_active` | INTEGER | Current rows flagged Active. **Config, not sales** — 962 never-sold ids are Active somewhere |
| `is_active_anywhere` | BOOLEAN | `store_count_active > 0` |
| `stores_selling_28d` | INTEGER | Peak stores selling it on any single day in the last 28. This is the sales-side answer to "where is it available" |
| `current_price` | FLOAT | Most common price among current active store rows |
| `price_min`, `price_max` | FLOAT | Across current active store rows |
| `price_variant_count` | INTEGER | Distinct current prices. >1 on 16 ids. ⚠️ Counted over current rows only — across *all* rows including the legacy extract, 1,352 ids carry more than one price, so do not read 16 as "prices never vary" |
| `plu` | STRING | From a current row |
| `brink_item_type` | STRING | `Normal` / `Composite` / `GiftCard` from the current rows. Legacy rows carry numeric codes and are not used here |
| `is_gift_card`, `is_non_revenue` | BOOLEAN | True if true at any store |
| `name_variant_count` | INTEGER | Distinct names across stores. >1 on 96 ids |
| `is_name_ambiguous_across_stores` | BOOLEAN | 96 true — read the warning below before quoting those names |
| `name_store_count` | INTEGER | How many stores use the winning name. Compare it to `store_count_configured` to see how thin the win was |
| `pulse_item_id` | INTEGER | Digital menu id, 354 ids mapped |
| `pulse_item_name` | STRING | Upper-cased in Pulse (`CHOCOLATE STRAWBERRY CUP`) |
| `pulse_item_role` | STRING | `full` or `half` — which Brink id the Pulse item pointed at |
| `pulse_menu` | STRING | `individual` or `catering` |
| `pulse_category_name` | STRING | From `pulse.categories` |
| `pulse_created_date` | DATE | When the Pulse row was created. A weak launch proxy for digital items only |
| `is_on_digital_menu` | BOOLEAN | Pulse row not soft-deleted |
| `build_run_datetime` | DATETIME | Denver-local run stamp. If it is not today, the scheduled query did not fire |

## ⚠️ One item_id can be two different products

`brink.brinkItems` is store-scoped: 214,182 rows = 3,242 ids × 98 stores, and `(Id, StoreID)` is
unique. **96 ids carry more than one name, and not as typos:**

- `640934279` = `Combo Turkey Cranbry Sand` at 37 stores, `Combo Turkey Avocado Club` at 29
- `640949421` = `Combo Ckn & Sausage Gumbo` at 38 stores, `Combo Chickpea & Veg` at 29

Same defect class as the `brinkPromotions` (id, StoreId) problem fixed 2026-07-31. This table
resolves the name by **most stores**, current rows breaking ties (steward rule 2026-09-14), and
publishes `name_variant_count` / `is_name_ambiguous_across_stores` / `name_store_count` so the
ambiguity is visible instead of averaged away. **If a question is store-specific, join
`brink.brinkItems` on `(id, storeid)` yourself — this table cannot answer it.**

## ⚠️ `item_id` is three id spaces in `order_lines`, and only one of them is here

On `discount`, `promotion` and `surcharge` lines, `order_lines.item_id` holds a **DiscountId,
PromotionId or SurchargeId** — different id spaces that happen to share a column. That is
exactly the 131 sold ids with no master row (27 + 73 + 31, measured 2026-09-14). Joining
`items` to unfiltered `order_lines` silently drops those lines; joining the other way can
attach an item's name to a discount. Filter
`line_item_type not in ('discount','promotion','surcharge')` on the fact side, which is what
`item_daily` already does.

## launch_date is derived, because Brink has no item dates at all

`brinkItems.CreatedTime`, `StartDate`, `EndDate` and `LastEditedTime` are the **empty string on
all 111,508 legacy rows and NULL on all 102,674 current rows** (measured 2026-09-14). Zero
usable values in the entire table. Do not go looking for them again without re-measuring.

So `launch_date` = the first business date the item sold in **at least 25% of the stores it ever
reached**. It is not the same as `first_sold_date`: 1,565 of 2,234 sold items differ, because a
test in a handful of stores sets `first_sold_date` months before the chain rollout. Nourish Bowl
first sold 2023-11-21 and rolled out 2024-01-03.

Quote `first_sold_date` for "when did this ever appear" and `launch_date` for "when did we launch
it". If ops states a real launch date that disagrees, the heuristic loses — an override table is
a named gap, not a built feature.

## The never-sold population is mostly POS config

1,008 ids have never sold and 962 of those are still Active in Brink. Sampling them turns up
`*** For 31 ***` guest-count markers and `** DEST TRAY **`, not menu items. **`has_ever_sold` is
the filter that matters, not `is_active_anywhere`** — an item can be Active at 97 stores and have
never been rung up.

## Worked examples

```sql
-- what is the Mini Chocolate Strawberry Cup, and is it still selling?
select
i.item_id
, i.item_name
, i.item_size
, i.current_price
, i.avg_unit_price_90d
, i.units_28d
, i.item_status
from `marketing-data-442316`.sales_ops.items i
where 1=1
and i.item_name = 'Chocolate Strawberry Cup'
order by i.item_size;
```

```sql
-- items launched in the last 90 days, chain-wide, with their first 28 days of demand
select
i.item_name
, i.item_size
, i.rev_center_name
, i.first_sold_date
, i.launch_date
, date_diff(i.launch_date, i.first_sold_date, day) as test_days
, i.stores_selling_28d
, i.units_28d
from `marketing-data-442316`.sales_ops.items i
where 1=1
and i.launch_date >= date_sub(current_date('America/Denver'), interval 90 day)
order by i.launch_date desc, i.units_28d desc;
```

```sql
-- catering-only SKUs: the flag order_lines.is_catering cannot give you
select
i.item_name
, i.rev_center_name
, i.lifetime_units
, i.units_28d
from `marketing-data-442316`.sales_ops.items i
where 1=1
and i.is_catering_item
and i.item_status = 'selling'
order by i.units_28d desc;
```

## Weekly snapshot and drift check

This table is rebuilt in full every morning and carries no history of what an item used to be
called or where it sat. [`sales_ops.items_snapshot`](sales_ops.items_snapshot.md) keeps a weekly copy
(Mondays, from the "Weekly menu drift check" scheduled task) and
[`sql/checks/menu_drift_weekly.sql`](../sql/checks/menu_drift_weekly.sql) diffs it and scans
`item_daily` for new ids, volume breaks, price / line-type shifts and name splits. Worked example and
reading guide: `claude_skills/menu-drift-check/SKILL.md`. Standing fact from its first run: **`Kids Combo`
is two live ids split by channel** (642361971 `$6.79` `Normal` = Pulse digital and third party; 643647054
`$0` `Composite` = POS since 2026-06-01, Try 2-style header with priced components). Neither is old. Since the
2026-09-24 build fix (`trim(bi.name)`) both carry `item_name = 'Kids Combo'`, `item_size = 'Regular'` and
`item_type = 'Kids Meals'`; only `item_id` separates them. Try 2 Combo splits the same way (POS 642388932 /
642388929 / 642388930 `$0` composites vs Pulse 642361973 `$12.99`). See the `order_lines` dictionary Kids
Meals gotcha for the rules.

## Related

- [`sales_ops.item_daily`](sales_ops.item_daily.md) — the item × day fact this is built from
- [`sales_ops.order_lines`](sales_ops.order_lines.md) — the line fact; `item_name` / `item_size`
  parsing is duplicated between the two builds on purpose, so a change to one needs the same
  change to the other
