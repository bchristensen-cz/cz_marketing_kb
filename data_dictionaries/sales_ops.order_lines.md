# Data Dictionary: `marketing-data-442316.sales_ops.order_lines`

**One row per order line element** — items, modifiers, fees, tips, discounts, gift cards, promotions, surcharges. This is the canonical table for product/menu-mix, item counts, modifier analysis, and combo composition. For order-level sales, use `sales_ops.order_customer` instead.

> # 🚨 STALE — DO NOT REPORT RECENT ITEM NUMBERS FROM THIS TABLE (found 2026-08-25)
>
> **`max(business_date) = 2026-08-15`. There are ZERO rows for 2026-08-16 → 2026-08-25 (10 business days), and 2026-08-09 is also missing.** Verified on the full table (381,383,908 rows): 0 rows in that window, 0 NULL `business_date`, 0 future dates. `claude.order_lines` is a view over this table, so it is equally empty.
>
> **The build reports success the entire time.** `sql/sales_ops.order_lines.sql` ran 24 times a day every day through 2026-08-25 with **zero errors**, inserting 1.5M rows at the 4am reload and ~0.3–2.1M across the intraday runs — all of which land on partitions **on or before 2026-08-15**.
>
> ## ✅ ROOT CAUSE FOUND 2026-08-25 — `order_lines` reads `order_customer` mid-rebuild
>
> **It is not a Brink problem.** `brink.brinkOrder` and `brink.brinkOrderItem` hold complete data for every affected date — 126,330–147,723 item rows per business date across 08-17 → 08-25, with items on 99.3% of orders. `brinkOrder` partitions are written at **~00:57 MT**, three hours before the 4am run, and `brinkOrderItem` writes continuously. (Sunday partitions — 08-02, 08-09, 08-16, 08-23 — are near-empty or absent because the stores are closed. **The 2026-08-09 "hole" reported earlier today is not a defect; it is a closed day.**)
>
> **The collision is with `sales_ops.order_customer`.** This build sources its order header from the mart, not from Brink:
>
> ```sql
> with brink_order as (            -- sql/sales_ops.order_lines.sql line 44
>   select oc.brink_order_id, oc.business_date, …
>   from `marketing-data-442316`.sales_ops.order_customer oc
>   where oc.business_date >= start_date
> )
> …
> join brink_order bo              -- line 113: INNER join
> ```
>
> Both are **separate scheduled queries firing at minute :02 with identical window logic**, and `order_customer`'s `delete` + `insert` is **not wrapped in a transaction**. BigQuery gives the reader a snapshot as of query start, so `order_lines` snapshots `order_customer` with the DELETE applied and the INSERT not yet committed — the `brink_order` CTE returns the hole, and the INNER JOIN turns the hole into zero rows.
>
> **Measured over 23 consecutive runs (2026-08-24 → 08-25): `order_lines` began reading 5.5 to 14.8 seconds before `order_customer` committed. It lost the race 23 times out of 23.** Sample, 2026-08-25 04:02 MT:
>
> | Time (MT) | Event |
> |---|---|
> | 04:02:03.857 → 04.849 | `order_customer` DELETE removes 196,042 rows |
> | 04:02:05.198 → 06.091 | `order_lines` DELETE removes 1,499,662 rows |
> | 04:02:05.491 → **14.713** | `order_customer` INSERT restores 196,042 rows |
> | 04:02:06.**326** → 13.829 | `order_lines` INSERT reads `order_customer` **8.2 s before the restore commits** |
>
> **This is a ratchet, not a one-off.** Damage is confined to the intersection of the two delete windows, which is why deep history is intact: the 4am run deletes 8 days (35 on Mondays), reads the hole, and reinserts almost nothing, so the recent tail is wiped nightly and never replaced. The late intraday runs sometimes win enough of the snapshot to land a day (08-24 at 15:02 / 21:02 / 22:02 / 23:02 inserted 106,734 / 198,104 / 206,521 / 208,387 rows) — and the next 4am run deletes it again.
>
> **✅ Fix (1) SHIPPED 2026-08-25, 38 minutes after the commit that described it as open.** `order_customer` gained `begin transaction` / `commit transaction` in its first run at **13:02 MT**; `order_lines` gained its own at **13:07**, and the two builds were re-staggered to :02 / :07 (:12 for `order_line_discount_detail`). Verified across 25 / 25 / 48 consecutive runs through 2026-08-26 13:02 via `JOBS_BY_PROJECT.query`. Neither change is in this repo's `sql/` copies. ⚠️ **The reader now sees the *previous complete* state, not a hole — which is a new failure mode of its own** once `order_customer` moves to a daily full-history refresh (pending 2026-08-26): if order_customer is still inside its transaction at :07, `order_lines` builds that day from the pre-refresh snapshot and silently misses the restatement.
>
> **Fix, in order:** (1) ~~wrap `order_customer`'s delete+insert in `begin transaction` / `commit`~~ — done, see above. (2) Chain the four order-mart builds into one sequential script — the steward already owns this and the untransacted-reader hazard was named as its prerequisite (Asana 1217564375242412). (3) Full rebuild of 2026-08-16 → present. (4) Add the freshness assert below.
>
> **What this breaks right now:**
>
> - Every item / menu-mix / modifier / combo / VTO number for the last 10 days silently returns **nothing** rather than erroring — the `where business_date between …` predicate is satisfied, the partitions are just empty.
> - `sales_ops.order_customer` **is current through 2026-08-25**, so any analysis that puts orders and items side by side shows item volume collapsing to zero against healthy order volume. That looks like a business event. It is not.
> - The `item-sales-builder` artifact and any report keyed on item names inherit this directly.
>
> **Interim rule: cap every `order_lines` query at `business_date <= '2026-08-15'` and say so in the answer.** Do not describe the gap as a sales decline. If the question needs the last 10 days at item grain, the marts cannot answer it yet — say so.
>
> **This is a silent-zero-rows defect of exactly the class the KB has an open action for** (Asana 1216955196273978). A build that cannot fail is a build nobody checks: add a post-insert assert that `max(business_date) >= run_date - 1`, so the next occurrence errors instead of returning empty partitions. It also burns ~260–440 GiB/day: on 2026-08-24 sixteen intraday runs each scanned 14.16 GiB to insert **0** rows.

> **⚠️ Changed 2026-07-31 (deployed + backfilled across full history).** Three changes, all verified live:
> - **Promotion lines are now named.** `description` / `item_name` carry the real promotion name (`Free Drink Sign`, `Grand Opening 100%`, …) instead of NULL, and `item_type` / `parent_rev_center_name` / `parent_item_grp_name` are all `'Promotion'`. **New consequence: promotion names now collide with item names in item reports** — see the gotcha below. Any item query must exclude them.
> - **`is_catering` now matches `order_customer`.** The destination test evaluates first, so POS-only catering is caught. June 2026: **+644 orders / +$71,586 gross** moved into catering on this table. From 2026-07-24 until this change the two marts disagreed on catering by that amount — a catering number pulled from `order_lines` in that window understates.
>
> **🚨 They disagree AGAIN as of 2026-08-17** — `order_customer` took finance's definition (store 50 = catering), this table did not. **793 orders / 30 days, all store 50.** Third instance of the same defect class (2026-07-24, 2026-07-31, 2026-08-17), and the reason the steward is merging the order-mart builds into one chained script so `is_catering` is derived **once**. Until then: catering questions run on `order_customer`.
> - **`item_type` and `rev_center_name` no longer have NULLs on promotion lines.** The entire `item_type` NULL population was unnamed promotion lines (1,111 of them over 2026-05-03 → 2026-06-27 — exactly the count previously documented). A **second pass the same day** stamped `rev_center_name = 'Promotion'` as well, so all three line-type markers now agree and the only NULL `rev_center_name` rows left are **2 surcharge lines** in that window (was 1,113).

> **⚠️ Changed 2026-08-12 (deployed + full history restated). Discount lines renamed — plus two 2026-07-31 second-pass changes that had never reached these docs, all verified live 2026-08-12.**
> - **`item_name` on discount lines is now the discount PROGRAM name** from the `brink.brinkDiscounts` master (`SessionM Loyalty`, `Online Discount`, `Team Member 100% Discount`, `Guest Relations`, …). `description` keeps the raw order-level POS discount name — free text that usually names the *redeemed thing* (`Protein Bowl`, `50% Off Try 2 Combo`) and on team-member discounts can carry an **employee's personal name**. Before this change `item_name` simply echoed `description`, which is what made discount lines collide with menu-item names in discovery queries. Program-level discount reporting is now `group by item_name` on `line_item_type = 'discount'`; per-redemption detail stays in `description`. Fallback when the master row is missing or blank: `description`, then `'Discount'` (~3–7% of a day's discount lines read the generic `'Discount'`; 7 missing master ids in the trailing 35 days, measured 2026-08-12). Join safety verified 2026-08-12: `brinkDiscounts` (Id, StoreID) is unique, and discount ids collide with zero item/promotion/surcharge/gift-card ids — no fan-out (0 duplicate keys in the trailing 3 days).
> - **`price` on discount lines is now the discount's configured amount** from the master (was NULL). `qty` is unaffected (still 1 — the derived floor).
> - **`item_type` collapsed to a closed 7-value domain** (2026-07-31 second pass, now restated across full history): `Entree`, `Kids Meals`, `Beverage`, `Discount`, `Promotion`, `Surcharge`, `Other`. The old `else coalesce(rev_center, description)` fallback is **gone** — `Modifiers`, `Desserts`, `Gift Cards` etc. no longer appear in `item_type` (284.2M lines back to 2018-08-13 are now `Other`). **Any filter like `item_type = 'Desserts'` returns zero rows** — use `rev_center_name` for menu categories.
> - **Surcharge lines are stamped** `rev_center_name = item_type = 'Surcharge'` (2026-07-31 second pass). The "2 NULL `rev_center_name` surcharge lines" are gone: **zero** NULL `rev_center_name` and `item_type` since 2026-05-01 (measured 2026-08-12, 18.0M lines).
> - **`parent_rev_center_name` case-order defect fixed** — Discount/Promotion now evaluate before the `'Combos'` rename (0 leaks since 2026-05-01). `parent_item_grp_name` still evaluates `'Combos'` first, so the 1 known colliding discount line still leaks there.

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
| `discount` | 0.6M | Order discounts | `amount` is **negative**; gross/net = 0. `item_name` = discount **program** (master); `description` = raw POS name (2026-08-12) |
| `fee` | 0.4M | Fee items (name matches `\bfee\b`) | Included in gross/net like items |
| `gift_card` | 13K | Gift card purchases | `amount` = card price; gross/net = 0 |
| `promotion` | 7K | Order promotions | `amount` is **negative**; gross/net = 0; `qty` = 1 (derived floor), so they inflate unit counts |
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
| `item_id` | INTEGER | Brink item/discount/promotion id, depending on line type. Discount ids resolve against `brink.brinkDiscounts` per (id, store) as of 2026-08-12. |

### Dates, store
| Column | Type | Description |
|---|---|---|
| `business_date` | DATE | Operating day (partition column). **Renamed from `BusinessDate` in the 2026-07-30 full-history rebuild** — the old spelling is gone and any saved query using it now fails outright. |
| `order_datetime_local` | DATETIME | Store-local order time (same logic as `order_customer`). **Renamed from `order_datetime` 2026-08-20/21, base table included** — verified against deployed `INFORMATION_SCHEMA.COLUMNS` 2026-08-21. There is still **no UTC column at line grain**: join `order_customer` for `order_timestamp_utc` before comparing to any UTC source. |
| `store_id`, `store_name` | | Store. **Store 1111 is a test/training store — ALWAYS exclude** (`store_id <> 1111`); no exceptions (steward rule 2026-07-23). |
| `store_state` | STRING | Full state name (`Utah`, not `UT`). **This is "market"** — there is no market/region/DMA/metro column anywhere; see [`sales_ops.store_info`](sales_ops.store_info.md). Added in the 2026-07-30 rebuild, so item-by-market questions need no join. ⚠️ **NULL for stores absent from `store_info`** — 512 lines in 2026-06-01 → 2026-06-07, all store 1111 / 999. Without `store_id <> 1111` a market breakdown grows a phantom unnamed group; `coalesce` the label so nothing ships nameless. |
| `is_catering` | BOOLEAN | Catering order flag. `true` when the Brink destination name contains `cater` **or** `pulse.orders.is_catering = true`, else the pulse flag, else `false`. The destination test is what catches POS-only catering (pulse only sees digital orders). Describes the **order**, not the item — catering-only SKUs like `Ultimate Grilled Cheese Box` can still sit on `is_catering = false` orders. **🚨 OUT OF SYNC WITH `order_customer` SINCE 2026-08-17** — finance's definition added **store 50 (Middleton Mobile)** to `order_customer.is_catering`, and this column was not changed. Measured 2026-08-17 over the trailing 30 closed days: **793 orders disagree, every one store 50**, `order_customer` true / here false. **Catering questions belong on `order_customer` until the marts are merged.** It matched `order_customer` exactly between 2026-07-31 and 2026-08-17. |

### Item descriptors
| Column | Type | Description |
|---|---|---|
| `description` | STRING | Raw POS description of the line. On `promotion` lines this is the **promotion name** from `brink.brinkPromotions`, resolved per (promotion id, store) — names are store-specific, e.g. id 642425436 is `50% off Lunch QR Craig rd` at store 164 and `50% off Blue Diamond` at store 168. Falls back to `'Promotion'` for the 4 lines in all history with no name master row. (Before 2026-07-31 this came from `brinkOrderPromotion.Name`, which is NULL on 71.4% of rows.) On `discount` lines this is the order-level POS discount name (blank → `'Discount'` since 2026-08-12) — free text that usually names the redeemed item and can carry a **team-member's personal name** on employee discounts; don't surface it in shared reports without checking. |
| `item_name` | STRING | **Normalized item group name** — size prefix (REG/LG/HALF/…) stripped, leading `.`/`--` cleaned. Use this for menu-mix. Falls back to `description` when the item isn't in the item master — and those fallback rows keep any size word in the name while `item_size` reads `'Not Sized'` or `'Regular'` rather than the size the name announces (e.g. `Mini Chocolate Chips`, which is a Mini). ⚠️ **Not a product key.** Measured 2026-08-27 over the trailing 30 days (sellable lines, stores 1111/999 excluded), **140 of 373 names span more than one `item_id`** and those names carry **50.1% of all units**: 49 split by `item_size`, 91 split by something else. `Chocolate Strawberry Cup` = two ids at $9.00 and $14.00; `Dubai Cup` = $12.00 and $18.00; `Kids Combo` = a $0.00 `Kids` bundle slot and a $7.27 `Regular` paid combo (the paid one is `Regular` because the family has a `Kids` sibling). Resolve to `item_id` before measuring, and show the average unit price in the discovery query so a wrong pick is visible. On `discount` lines (2026-08-12) this is the **discount program name** from `brink.brinkDiscounts` (`SessionM Loyalty`, `Online Discount`, …) — group on it for discount-program reporting. |
| `item_size` | STRING | **Closed 9-value domain, no NULLs** (rebuilt 2026-08-27): `Regular`, `Half`, `Large`, `Kids`, `Mini`, `Party`, `Tray`, plus **`Not Sized`** and **`Not Applicable`**. (`Quart` and `Medium` exist in the build's CASE but have no rows.) The build resolves it in four steps: non-`item`/`modifier` lines → `'Not Applicable'`; a parsed size prefix → that size; otherwise, if the item's family has sized SKUs in the item master → `'Regular'`; else `'Not Sized'`. **Size is stripped out of `item_name`** (regex `^(REG\|Mini\|LG\|PRTY\|HALF\|Kids\|LARGE\|Medium\|Tray\|QUART) `, case-sensitive, applied once), so the spoken name and the column disagree: `item_name = 'Mini Chocolate Strawberry Cup'` returns **zero rows**; the product is `item_name = 'Chocolate Strawberry Cup' and item_size = 'Mini'`. **`Regular` now means an actual regular size** — a base size in a family that has other sizes, or a genuine `REG` prefix. It no longer absorbs unsized items or non-product lines, which is what `Not Sized` and `Not Applicable` are for. Distribution, 2026-08-20 → 2026-08-26, stores 1111/999 excluded (measured 2026-08-27): `Not Sized` 807,653 (62.5%) / `Half` 168,233 (13.0%) / **`Regular` 151,034 (11.7%)** / `Kids` 66,052 (5.1%) / `Large` 56,593 (4.4%) / `Not Applicable` 33,877 (2.6%) / `Mini` 6,861 (0.5%) / `Party` 1,113 / `Tray` 30. ⚠️ **Two earlier semantics shipped and were replaced the same day** — NULL-for-unparsed (before 2026-08-27 ~10:53 MT) and `coalesce(..., 'Regular')` which made `Regular` 76.3% of lines (10:53 → 12:35 MT). A query written against either will still run and return a different number. `item_size is null` in particular is now **dead** — it returns zero rows, not the unsized items. **Required as a dimension on any item-specific question** — 49 names / 21.0% of units span more than one size, and a name-only answer blends price points (Mini cup $9.00 vs Regular $14.00 → a $10.23 average that is not a real price). |
| `item_modifier` | STRING | Modifier code on modifier lines; `'none'` otherwise. Seven values: `With`, `No`, `Add`, `Substitute`, `Extra`, `None`, `For`. **`With` is a required build selection (bread choice, combo entrée slot), NOT a customization** — it fires on 99.9% of digital sandwiches. A real customer modification is `No`/`Add`/`Substitute`/`Extra` **and** `rev_center_name = 'Modifiers'` (verified 2026-07-30). |
| `rev_center_name` | STRING | Revenue center: Sandwiches, Soups, Salads, Bowls, Combos, Modifiers, Kids Meals, Desserts, Bottled Beverages, **Foutain Beverages** (misspelled in source — match as-is), Sides/Misc Items, Non Food/Bev Mis, Box Lunches, Party Trays & Food, Cater Desserts, Cater Beverages, Gift Cards, Discount, **Promotion** (added 2026-07-31), **Surcharge** (added in the 2026-07-31 second pass). **Zero NULLs** anywhere since the surcharge stamping (verified 2026-08-12 over 2026-05-01 → present; the previously documented "2 NULL surcharge lines" are gone). |
| `item_type` | STRING | Reporting rollup — **closed 7-value domain** since the 2026-07-31 second pass (verified across full history 2026-08-12): Bowls/Salads/Sandwiches/Soups → `Entree`; Kids Combo → `Kids Meals` (other kids items → `Entree`); beverages → `Beverage`; `discount`/`promotion`/`surcharge` lines → `Discount`/`Promotion`/`Surcharge`; **everything else → `Other`** (284.2M lines, 2018-08-13 → present — modifiers, sides, desserts, gift cards, fees, tips, …). Zero NULLs. ⚠️ The pre-2026-07-31 behavior (`else` the revenue center, else raw description) is gone — a filter like `item_type = 'Desserts'` or `= 'Modifiers'` now returns **zero rows**; use `rev_center_name` for menu categories. |

### Combo rollups (parent = the line in the combo group with `composite_item_id IS NULL` and `line_item_type = 'item'`)
| Column | Type | Description |
|---|---|---|
| `parent_rev_center_name` | STRING | Parent line's revenue center; `'Combos'` renamed to `'Try 2 Combo'`. `'Discount'` on discount lines (2026-07-30) and `'Promotion'` on promotion lines (2026-07-31). For other non-combo lines this is the line's own value. ⚠️ **Open domain — 196 distinct values over 2026-05-01 → 2026-07-30** (measured 2026-07-31), not the ~20 you'd expect: tip/fee/gift_card lines and orphaned modifiers fall back to raw description (see gotcha). Group-bys must filter to the known value list. |
| `parent_item_grp_name` | STRING | Parent's item group. For Try 2 Combos, includes the composition, e.g. `Try 2 Combo Salads & Soups` (built from the component entrée rev centers, non-catering only). `'Foutain Beverages'` → `'Fountain Beverage'`; `'Discount'` / `'Promotion'` on those line types. ⚠️ Same open-domain fallbacks as `parent_rev_center_name` (354 distinct values in the same window), **plus its only NULLs: 95 `Try 2 Combo` lines where no composition was computed** — `'Try 2 Combo ' \|\| attr_list` NULLs out when `attr_list` is NULL (catering combos and combos without ≥2 entrée component rows are excluded from the composition CTE by construction). |

### Amounts (FLOAT, dollars)
| Column | Description |
|---|---|
| `amount` | The line's amount. For `item`/`fee`/`surcharge`/`modifier` it equals the line's gross contribution; `tip` and `gift_card` carry their own amounts; `discount`/`promotion` are negative. Don't sum blindly across all line types — filter by `line_item_type` (see reconstruction gotcha). |
| `item_gross_sales` | Line gross sales (0 for tips, discounts, promos, gift cards). **Canonical line-level sales measure.** |
| `item_net_sales` | Line net sales, Brink-given (same zeroing rules). **Reportable on request (steward ruling 2026-07-30, superseding the 2026-07-23 validation-only rule)** — fully populated, zero nulls. But it does **not** reconcile to order-level `net_sales`: order-level discounts and promotions are separate lines with no per-item allocation, so `order_customer.net_sales` stays the only quotable/tie-out net. Default to `item_gross_sales` for item mix. ⚠️ The gross→net spread **varies by sale shape** — Ultimate Grilled Cheese 2026-05-03→06-27 non-catering: sold alone 2.30%, in-combo paid 3.35%, free slot 3.83% — so it is not a flat rate and the gap must not be described as "the discount." Open question: why wider on combo components than standalone. |
| `price` | Item master price (menu price). On `discount` lines (2026-08-12): the discount's **configured amount** from `brink.brinkDiscounts` (was NULL) — not a menu price. |
| `qty` | **Derived**: `round(item_gross_sales / price)`, floored at 1. Approximate — wrong when price is 0/missing or item was price-overridden. Good for menu-mix counts on `line_item_type='item'`. |

## Gotchas
- **Always filter `business_date`** (partition). Cluster fields (`rev_center_name`, `item_name`, parent fields) make filters on them cheap.
- **Item counts**: filter `line_item_type = 'item'` — otherwise modifiers/fees inflate counts ~2x.
- **Order-level sales**: use `order_customer` — gross = `gross_sales`, net = calculated `gross_sales - total_discount_amount - total_promotions_amount` (the `net_sales` column is validation-only). Line-level sums won't exactly reconcile to order-level (order-level discounts, rounding).
- **Line-level reconstruction (revalidated 2026-07-23 after the modifier-gross fix):** gross = `sum(amount)` over `item/fee/surcharge/modifier` lines; net = gross + `discount/promotion` amounts (negative). Matches order-level for **99.99% of orders that have lines** (90d: gross diff −$1.5K, net diff −$0.4K on $55M). Order-level `order_customer` remains the truth for reported sales.
- **~1.3% of `order_customer` orders have NO rows in this table** — all carry exactly $0 calculated net (fully-voided orders; voided lines are excluded here). Benign for sales, but order counts from `order_lines` undercount vs `order_customer` (validated 2026-07-23 after the 07-22 load incident was repaired).
- **Discount and promotion lines are suppressed on non-sellable orders (`valid_order_lines` guard, deployed 2026-08-17 with a full-history rebuild).** An order emits `discount` / `promotion` lines only if its surviving `brinkOrderItem` rows clear `sum(gross) > 0 or sum(net) > 0`. This is what makes discount money here reconcile to `order_customer` and to `order_line_discount_detail` — verified 2026-08-17 at order grain, full history, closed days, `store_id not in (1111, 999)`: **all three at -$25,720,068.34, zero orders disagreeing**. It removes 42,179 lines / -$239,178.71 (orders with no surviving item rows) plus 2,705 lines / -$45,348.22 (surviving items all $0) — `order_customer` bills zero discount on every one of those 30,697 orders, so both are correct suppressions. `item` / `modifier` / `gift_card` / `surcharge` lines are **not** guarded — a gift-card-only order is legitimately item-less and its card is a real sale. ⚠️ Both arms are load-bearing: 61 orders / -$2,104.52 (all 2019-2023) have zeroed item gross but real header revenue and are held in by the net arm alone; `order_customer` bills discount on all 61. A one-arm `sum(gross) > 0` guard ties out on the 8- and 35-day reloads and only breaks on a full-history rebuild (verified 2026-08-17). ⚠️ The guard was committed to the repo 2026-08-15 but not deployed until 08-17 — **the built table alone cannot tell you whether a guard is live**; check the scheduled query's actual text in `INFORMATION_SCHEMA.JOBS_BY_PROJECT`.
- **Combos**: components each carry their own sales; the parent combo line may carry the base price. For "how many Try 2 Combos sold", count distinct `combo_order_line_item_id` where `parent_rev_center_name = 'Try 2 Combo'`. For entrée mix inside combos, use component rows.
- **An entrée has THREE line shapes, and `line_item_type = 'item'` ≠ standalone** (verified 2026-07-28, Ultimate Grilled Cheese, 2026-05-03 → 2026-06-27, store 1111 excluded):

  | Shape | Filter | Lines | Gross |
  |---|---|---|---|
  | Standalone | `line_item_type='item'` and `composite_item_id is null` | 24,125 | $215,890 |
  | Combo component (priced) | `line_item_type='item'` and `composite_item_id is not null` | 47,461 | $315,280 |
  | Combo slot (zero-priced) | `line_item_type='modifier'`, parent `Try 2 Combo` | 37,623 | $386 |

  The two combo shapes are **mutually exclusive per `combo_order_line_item_id`**, so combo units = 47,461 + 37,623 = 85,084 with no double count; combos were ~78% of units. Both shapes occur across all 88 stores in both months and both combo compositions — it's a per-combo-slot POS structure, not a store, size, or date split. **Priced combo components hold more gross than standalone**, so don't assume revenue sits only in standalone lines. Catering Box Lunches also emit zero-priced `modifier` entrée lines (`parent_rev_center_name = 'Box Lunches'`).
- `'Foutain Beverages'` (sic) in `rev_center_name`; corrected to `'Fountain Beverage'` only in `parent_item_grp_name`.
- **Promotion lines masquerade as items — exclude them** (new 2026-07-31). Since promotion lines got real names they look like menu items in every item-shaped query: `item_name` = the promotion name, `qty` = 1, `item_gross_sales` = 0, `amount` negative. Names like `Free Try 2 Combo`, `Free Mini Strawberry Cup`, `Free Dubai Cup` will surface in item searches and add phantom zero-dollar units to unit counts. They also pass the standalone-sale test (`parent_rev_center_name` = `rev_center_name` = `'Promotion'`), so a sale-shape breakdown counts them as sold-alone items — same as discount lines already did. Use all three markers:

  ```sql
  and ifnull(ol.item_type, '') not in ('Discount','Promotion')
  and ifnull(ol.rev_center_name, '') not in ('Discount','Promotion')
  and ifnull(ol.line_item_type, '') not in ('discount','promotion')
  ```

  Volume is small (1,111 lines over 2026-05-03 → 2026-06-27; ~2K–17K/quarter) but it lands in *item name* space, so it shows up in discovery lists and named-item answers rather than averaging out.
- **Promotion reporting is now possible and wasn't before.** "Sales/units given away by promotion" is answerable off `line_item_type = 'promotion'` grouped by `description`, full history — 240,191 lines back to 2018-08-28. `amount` is the negative promotion value; `item_gross_sales` is 0, so never use it here.
- `item_type` no longer falls back to raw `description` at all — it is a **closed 7-value domain** (`else 'Other'` since the 2026-07-31 second pass, full history restated), and `rev_center_name` has **zero NULLs** since surcharge stamping. Both verified 2026-08-12. Menu categories (Desserts, Sides, Modifiers, Gift Cards, …) exist only in `rev_center_name`.
- **Modifier detail is DIGITAL-ONLY** (verified 2026-07-30). In-store POS lines carry essentially no modifiers: 25 explicit ingredient changes on 65,276 standalone POS sandwich lines vs 23,453 on 63,027 digital, and **zero** on 210,154 priced combo components. Any modification/customization rate must filter `pulse_order_id is not null` and be labelled digital-only; a company-wide rate is wrong by ~2x. Capture gap, not behavior — open upstream question.
- **Modifiers join to their parent on (`brink_order_id`, `order_item_id`)** — the modifier row's `order_item_id` is the *parent item's* id, and `item_id_seq_num` is the modifier's own record id. Not `combo_order_line_item_id`, which groups the whole combo.
- **The parent rollup fields (`parent_rev_center_name` / `parent_item_grp_name`) leak raw descriptions in three ways** (measured 2026-07-31 over 2026-05-01 → 2026-07-30, stores 1111/999 excluded; 15.8M lines):
  1. **Structural fallback**: `tip` / `fee` / `gift_card` lines have no `line_item_type = 'item'` parent, so the parent self-join misses and both fields fall back to the line's own description — `Pay at window tip`, `Dispatch Delivery Fee`, `Service Fee`, `Gift Card Issue`. 254,281 lines in the window. Predictable values, but off-definition.
  2. **Orphaned modifiers on priced combo components** — the real noise source. A modifier's `combo_order_line_item_id` points at its parent item's `order_item_id`, but when that parent is a priced combo component (`composite_item_id is not null`) the parent join — which requires `composite_item_id is null` — finds nothing, and the parent fields become the modifier's *own description*. **50,734 lines / 171 distinct values in the window, and 100% verified to have a combo-component parent** (0 standalone, 0 missing). Mostly POS Kids Combo selections (`Kids Tomato Basil Soup`, `Sprite`, …). This is why `parent_rev_center_name` has 196 distinct values instead of ~20. These lines should logically roll up to their combo, but don't.
  3. **Case-order defect — half fixed by 2026-08-12**: in `parent_rev_center_name` the Discount/Promotion overrides now evaluate *before* the `'Combos'` → `'Try 2 Combo'` rename (0 leaking discount lines since 2026-05-01, verified 2026-08-12). `parent_item_grp_name` still evaluates the rename first, so a discount/promotion line whose `combo_order_line_item_id` collides with a real combo parent's id can still get a combo-flavored (or NULL) `parent_item_grp_name` — 1 discount line in the window.

  Consequences: any `group by parent_rev_center_name` needs a known-list filter, and the orphaned modifiers **match the sale-shape "in a catering box" test** (`composite_item_id is null and parent <> rev_center` and parent not in the combo/discount/promotion list) — a shape breakdown of an item that appears as a kids-combo or drink selection will misfile these lines as catering-box. Restrict shape analysis to lines whose `parent_rev_center_name` is in the known rev-center list.
- **Within a Try 2 Combo, modifiers are flat siblings of the entrée slots under the combo parent** — they cannot be attributed to a specific entrée. 143,123 of 143,124 sandwich-bearing combos (2026-06-30 → 2026-07-29, non-catering) also held a soup/salad/bowl, and soup/salad ingredients (`Add Salad Tortilla Strips`, `Add Radiatore Noodle`) appear among their top changes. Per-entrée modifier rates are only exact for standalone lines.
- **The two combo shapes track CHANNEL**: POS emits the priced component (209,982 sandwich lines vs 29 slots), digital emits the zero-priced slot (143,097 vs 172). ~99.9% clean both ways, so filtering to one combo shape silently filters to one channel.
- No `order_timestamp_utc` here — join to `order_customer` if you need UTC.
- Voided, cleared, and deleted POS items are already excluded.
