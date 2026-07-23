# Data Dictionary: `marketing-data-442316.sales_ops.order_lines`

**One row per order line element** — items, modifiers, fees, tips, discounts, gift cards, promotions, surcharges. This is the canonical table for product/menu-mix, item counts, modifier analysis, and combo composition. For order-level sales, use `sales_ops.order_customer` instead.

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per line element within an order (see line types below) |
| Row count | ~377M rows across ~49M orders, 2018-08-13 to present |
| Partitioned by | `BusinessDate` (DAY) — **always filter on it** |
| Clustered by | `rev_center_name`, `item_name`, `parent_item_grp_name`, `parent_rev_center_name` |
| Refresh | Hourly at minute :02. Intraday runs (8am–11pm MT) reload **today only**. 4am daily reloads 8 days; Monday 4am reloads 5 weeks; 1st of month 4am reloads ~13 months. |
| Source build script | `sql/sales_ops.order_lines.sql` in this repo |
| Upstream | `brink.*` (POS), `pulse.orders`, `sales_ops.store_info` |

## Line types (`line_item_type`)

| Value | ~1yr rows | What it is | Sales columns behavior |
|---|---|---|---|
| `item` | 36.3M | Sold menu items (voided/cleared/deleted excluded) | `item_gross_sales`/`item_net_sales` populated; tips rung as items zeroed out |
| `modifier` | 25.5M | Modifiers attached to items | `amount` = modifier gross; `item_gross_sales`/`item_net_sales` = modifier's item-level gross/net |
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
| `BusinessDate` | DATE | Operating day (partition column). |
| `order_datetime` | DATETIME | Local order time (same logic as `order_customer`). |
| `store_id`, `store_name` | | Store. **Store 1111 is a test/training store — ALWAYS exclude** (`store_id <> 1111`); no exceptions (steward rule 2026-07-23). |
| `is_catering` | BOOLEAN | Catering flag from pulse. |

### Item descriptors
| Column | Type | Description |
|---|---|---|
| `description` | STRING | Raw POS description of the line. |
| `item_name` | STRING | **Normalized item group name** — size prefix (REG/LG/HALF/…) stripped, leading `.`/`--` cleaned. Use this for menu-mix. Falls back to `description` when the item isn't in the item master. |
| `item_size` | STRING | Parsed size: `Half`, `Large`, `Regular`, `Kids`, `Mini`, `Party`, `Tray`, `Quart`, `Medium` or NULL (NULL for ~80% of rows — non-sized items, modifiers, fees, etc.). |
| `item_modifier` | STRING | Modifier code name (e.g. NO, EXTRA) for modifier lines; `'none'` otherwise. |
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
| `amount` | The line's raw amount. **Do not sum for sales** — includes tips and fees, and discounts/promotions are negative. |
| `item_gross_sales` | Line gross sales (0 for tips, discounts, promos, gift cards). **Canonical line-level sales measure.** |
| `item_net_sales` | Line net sales, Brink-given (same zeroing rules). **Validation-only (steward rule 2026-07-23)** — canonical net = gross minus discounts/promotions, but those are separate order-level lines with no per-item allocation, so per-item net isn't computable here. Use `item_gross_sales` for item mix. |
| `price` | Item master price (menu price). |
| `qty` | **Derived**: `round(item_gross_sales / price)`, floored at 1. Approximate — wrong when price is 0/missing or item was price-overridden. Good for menu-mix counts on `line_item_type='item'`. |

## Gotchas
- **Always filter `BusinessDate`** (partition). Cluster fields (`rev_center_name`, `item_name`, parent fields) make filters on them cheap.
- **Item counts**: filter `line_item_type = 'item'` — otherwise modifiers/fees inflate counts ~2x.
- **Order-level sales**: use `order_customer` — gross = `gross_sales`, net = calculated `gross_sales - total_discount_amount - total_promotions_amount` (the `net_sales` column is validation-only). Line-level sums won't exactly reconcile to order-level (order-level discounts, rounding).
- **Line-level net reconstruction (validated 2026-07-23, 90-day window):** best formula = `item/fee/surcharge item_gross_sales + modifier amount + discount/promotion amount`. Matches order-level calculated net exactly for 94% of orders that have lines; aggregate runs ~0.7% HIGH vs order-level (modifier gross is the noisy component — omitting modifiers drops exact match to 80%). Order-level remains the truth.
- **~1.3% of `order_customer` orders have NO rows in this table** — all carry exactly $0 calculated net (fully-voided orders; voided lines are excluded here). Benign for sales, but order counts from `order_lines` undercount vs `order_customer` (validated 2026-07-23 after the 07-22 load incident was repaired).
- **Combos**: components each carry their own sales; the parent combo line may carry the base price. For "how many Try 2 Combos sold", count distinct `combo_order_line_item_id` where `parent_rev_center_name = 'Try 2 Combo'`. For entrée mix inside combos, use component rows.
- `'Foutain Beverages'` (sic) in `rev_center_name`; corrected to `'Fountain Beverage'` only in `parent_item_grp_name`.
- `item_type` and `rev_center_name` fall back to raw `description` / NULL for a small tail (~7K rows/yr NULL) — filter to known buckets for clean rollups.
- No `order_timestamp_utc` here — join to `order_customer` if you need UTC.
- Voided, cleared, and deleted POS items are already excluded.
