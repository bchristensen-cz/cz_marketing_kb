# Data Dictionary: `marketing-data-442316.sales_ops.order_lines`

**One row per order line element** — items, modifiers, fees, tips, discounts, gift cards, promotions, surcharges. This is the canonical table for product/menu-mix, item counts, modifier analysis, and combo composition. For order-level sales, use `sales_ops.order_customer` instead.

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per line element within an order (see line types below) |
| Row count | ~377M rows across ~49M orders, 2018-08-13 to present |
| Partitioned by | `business_date` (DAY) — **always filter on it** |
| Clustered by | `rev_center_name`, `item_name`, `parent_item_grp_name`, `parent_rev_center_name` |
| Refresh | Hourly at minute :02. Intraday runs (8am–11pm MT) reload **today only**. 4am daily reloads 8 days; Monday 4am reloads 5 weeks; 1st of month 4am reloads ~13 months. |
| Source build script | `sql/sales_ops.order_lines.sql` in this repo |
| Upstream | `brink.*` (POS), `pulse.orders`, `sales_ops.store_info` |

## Line types (`line_item_type`)

| Value | ~1yr rows | What it is | Sales columns behavior |
|---|---|---|---|
| `item` | 36.3M | Sold menu items (voided/cleared/deleted excluded) | `item_gross_sales`/`item_net_sales` populated; tips rung as items zeroed out |
| `modifier` | 25.5M | Modifiers attached to items | `amount` = `item_gross_sales` = modifier's item-level gross (`brinkOrderItemModifier.ItemGrossSales`; switched from unreliable `GrossSales` 2026-07-23, full history rebuilt) |
| `tip` | 0.7M | Tip items (name matches `\btip\b`) | `amount` has the tip; gross/net forced to 0 |
| `discount` | 0.6M | Order discounts | `amount` is **negative**; gross/net = 0 |
| `fee` | 0.4M | Fee items (name matches `\bfee\b`) | Included in gross/net like items |
| `gift_card` | 13K | Gift card purchases | `amount` = card price; gross/net = 0 |
| `promotion` | 7K | Order promotions | `amount` is **negative**; gross/net = 0 |
| `surcharge` | rare | Surcharges | `amount` = gross = net |

## Columns

### Identifiers & keys
| Column | Type | Description |
|---|---|---|
| `brink_order_id` | INTEGER | Join key to `order_customer.brink_order_id`. |
| `pulse_order_id` | INTEGER | Digital order id (NULL for in-store). |
| `order_item_id` | INTEGER | Line id. Semantics vary by line type: for `item` it's the POS order-item id; for `modifier` it's the **parent item's** order-item id; for `discount`/`gift_card` it's that record's id; for `promotion`/`surcharge` it's a row_number. |
| `item_id_seq_num` | INTEGER | Disambiguator. 1 for items; the modifier record id for modifiers; row_numbers or record ids for the rest. Uniqueness = (`brink_order_id`, `line_item_type`, `order_item_id`, `item_id_seq_num`). |
| `composite_item_id` | INTEGER | For combo **components**, points at the parent combo line's order-item id. NULL on the parent line itself and on non-combo lines. |
| `combo_order_line_item_id` | STRING | `brink_order_id + '-' + coalesce(composite_item_id, order_item_id)`. Groups a combo parent with its components (and a standalone item with its modifiers). |
| `item_id` | INTEGER | Brink item/discount/promotion id, depending on line type. |

### Dates, store
| Column | Type | Description |
|---|---|---|
| `business_date` | DATE | Operating day (partition column). **Renamed from `BusinessDate` in the 2026-07-30 full-history rebuild** — the old spelling is gone and any saved query using it now fails outright. |
| `order_datetime` | DATETIME | Local order time (same logic as `order_customer`). |
| `store_id`, `store_name` | | Store. **Store 1111 is a test/training store — ALWAYS exclude** (`store_id <> 1111`); no exceptions (steward rule 2026-07-23). |
| `store_state` | STRING | Full state name (`Utah`, not `UT`). **This is "market"** — there is no market/region/DMA/metro column anywhere; see [`sales_ops.store_info`](sales_ops.store_info.md). Added in the 2026-07-30 rebuild, so item-by-market questions need no join. ⚠️ **NULL for stores absent from `store_info`** — 512 lines in 2026-06-01 → 2026-06-07, all store 1111 / 999. Without `store_id <> 1111` a market breakdown grows a phantom unnamed group; `coalesce` the label so nothing ships nameless. |
| `is_catering` | BOOLEAN | Catering flag from pulse. |

### Item descriptors
| Column | Type | Description |
|---|---|---|
| `description` | STRING | Raw POS description of the line. |
| `item_name` | STRING | **Normalized item group name** — size prefix (REG/LG/HALF/…) stripped, leading `.`/`--` cleaned. Use this for menu-mix. Falls back to `description` when the item isn't in the item master. |
| `item_size` | STRING | Parsed size: `Half`, `Large`, `Regular`, `Kids`, `Mini`, `Party`, `Tray`, `Quart`, `Medium` or NULL (NULL for ~80% of rows — non-sized items, modifiers, fees, etc.). |
| `item_modifier` | STRING | Modifier code on modifier lines; `'none'` otherwise. Seven values: `With`, `No`, `Add`, `Substitute`, `Extra`, `None`, `For`. **`With` is a required build selection (bread choice, combo entrée slot), NOT a customization** — it fires on 99.9% of digital sandwiches. A real customer modification is `No`/`Add`/`Substitute`/`Extra` **and** `rev_center_name = 'Modifiers'` (verified 2026-07-30). |
| `rev_center_name` | STRING | Revenue center: Sandwiches, Soups, Salads, Bowls, Combos, Modifiers, Kids Meals, Desserts, Bottled Beverages, **Foutain Beverages** (misspelled in source — match as-is), Sides/Misc Items, Non Food/Bev Mis, Box Lunches, Party Trays & Food, Cater Desserts, Cater Beverages, Gift Cards, Discount. |
| `item_type` | STRING | Reporting rollup: Bowls/Salads/Sandwiches/Soups → `Entree`; Kids Combo → `Kids Meals` (other kids items → `Entree`); beverages → `Beverage`; else the revenue center, else raw description (long tail of one-off values — filter to the big buckets for clean reporting). |

### Combo rollups (parent = the line in the combo group with `composite_item_id IS NULL` and `line_item_type = 'item'`)
| Column | Type | Description |
|---|---|---|
| `parent_rev_center_name` | STRING | Parent line's revenue center; `'Combos'` renamed to `'Try 2 Combo'`. For non-combo lines this is the line's own value. |
| `parent_item_grp_name` | STRING | Parent's item group. For Try 2 Combos, includes the composition, e.g. `Try 2 Combo Salads & Soups` (built from the component entrée rev centers, non-catering only). `'Foutain Beverages'` → `'Fountain Beverage'`. |

### Amounts (FLOAT, dollars)
| Column | Description |
|---|---|
| `amount` | The line's amount. For `item`/`fee`/`surcharge`/`modifier` it equals the line's gross contribution; `tip` and `gift_card` carry their own amounts; `discount`/`promotion` are negative. Don't sum blindly across all line types — filter by `line_item_type` (see reconstruction gotcha). |
| `item_gross_sales` | Line gross sales (0 for tips, discounts, promos, gift cards). **Canonical line-level sales measure.** |
| `item_net_sales` | Line net sales, Brink-given (same zeroing rules). **Reportable on request (steward ruling 2026-07-30, superseding the 2026-07-23 validation-only rule)** — fully populated, zero nulls. But it does **not** reconcile to order-level `net_sales`: order-level discounts and promotions are separate lines with no per-item allocation, so `order_customer.net_sales` stays the only quotable/tie-out net. Default to `item_gross_sales` for item mix. ⚠️ The gross→net spread **varies by sale shape** — Ultimate Grilled Cheese 2026-05-03→06-27 non-catering: sold alone 2.30%, in-combo paid 3.35%, free slot 3.83% — so it is not a flat rate and the gap must not be described as "the discount." Open question: why wider on combo components than standalone. |
| `price` | Item master price (menu price). |
| `qty` | **Derived**: `round(item_gross_sales / price)`, floored at 1. Approximate — wrong when price is 0/missing or item was price-overridden. Good for menu-mix counts on `line_item_type='item'`. |

## Gotchas
- **Always filter `business_date`** (partition). Cluster fields (`rev_center_name`, `item_name`, parent fields) make filters on them cheap.
- **Item counts**: filter `line_item_type = 'item'` — otherwise modifiers/fees inflate counts ~2x.
- **Order-level sales**: use `order_customer` — gross = `gross_sales`, net = calculated `gross_sales - total_discount_amount - total_promotions_amount` (the `net_sales` column is validation-only). Line-level sums won't exactly reconcile to order-level (order-level discounts, rounding).
- **Line-level reconstruction (revalidated 2026-07-23 after the modifier-gross fix):** gross = `sum(amount)` over `item/fee/surcharge/modifier` lines; net = gross + `discount/promotion` amounts (negative). Matches order-level for **99.99% of orders that have lines** (90d: gross diff −$1.5K, net diff −$0.4K on $55M). Order-level `order_customer` remains the truth for reported sales.
- **~1.3% of `order_customer` orders have NO rows in this table** — all carry exactly $0 calculated net (fully-voided orders; voided lines are excluded here). Benign for sales, but order counts from `order_lines` undercount vs `order_customer` (validated 2026-07-23 after the 07-22 load incident was repaired).
- **Combos**: components each carry their own sales; the parent combo line may carry the base price. For "how many Try 2 Combos sold", count distinct `combo_order_line_item_id` where `parent_rev_center_name = 'Try 2 Combo'`. For entrée mix inside combos, use component rows.
- **An entrée has THREE line shapes, and `line_item_type = 'item'` ≠ standalone** (verified 2026-07-28, Ultimate Grilled Cheese, 2026-05-03 → 2026-06-27, store 1111 excluded):

  | Shape | Filter | Lines | Gross |
  |---|---|---|---|
  | Standalone | `line_item_type='item'` and `composite_item_id is null` | 24,125 | $215,890 |
  | Combo component (priced) | `line_item_type='item'` and `composite_item_id is not null` | 47,461 | $315,280 |
  | Combo slot (zero-priced) | `line_item_type='modifier'`, parent `Try 2 Combo` | 37,623 | $386 |

  The two combo shapes are **mutually exclusive per `combo_order_line_item_id`**, so combo units = 47,461 + 37,623 = 85,084 with no double count; combos were ~78% of units. Both shapes occur across all 88 stores in both months and both combo compositions — it's a per-combo-slot POS structure, not a store, size, or date split. **Priced combo components hold more gross than standalone**, so don't assume revenue sits only in standalone lines. Catering Box Lunches also emit zero-priced `modifier` entrée lines (`parent_rev_center_name = 'Box Lunches'`).
- `'Foutain Beverages'` (sic) in `rev_center_name`; corrected to `'Fountain Beverage'` only in `parent_item_grp_name`.
- `item_type` and `rev_center_name` fall back to raw `description` / NULL for a small tail (~7K rows/yr NULL) — filter to known buckets for clean rollups.
- **Modifier detail is DIGITAL-ONLY** (verified 2026-07-30). In-store POS lines carry essentially no modifiers: 25 explicit ingredient changes on 65,276 standalone POS sandwich lines vs 23,453 on 63,027 digital, and **zero** on 210,154 priced combo components. Any modification/customization rate must filter `pulse_order_id is not null` and be labelled digital-only; a company-wide rate is wrong by ~2x. Capture gap, not behavior — open upstream question.
- **Modifiers join to their parent on (`brink_order_id`, `order_item_id`)** — the modifier row's `order_item_id` is the *parent item's* id, and `item_id_seq_num` is the modifier's own record id. Not `combo_order_line_item_id`, which groups the whole combo.
- **Within a Try 2 Combo, modifiers are flat siblings of the entrée slots under the combo parent** — they cannot be attributed to a specific entrée. 143,123 of 143,124 sandwich-bearing combos (2026-06-30 → 2026-07-29, non-catering) also held a soup/salad/bowl, and soup/salad ingredients (`Add Salad Tortilla Strips`, `Add Radiatore Noodle`) appear among their top changes. Per-entrée modifier rates are only exact for standalone lines.
- **The two combo shapes track CHANNEL**: POS emits the priced component (209,982 sandwich lines vs 29 slots), digital emits the zero-priced slot (143,097 vs 172). ~99.9% clean both ways, so filtering to one combo shape silently filters to one channel.
- No `order_timestamp_utc` here — join to `order_customer` if you need UTC.
- Voided, cleared, and deleted POS items are already excluded.
