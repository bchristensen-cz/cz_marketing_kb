---
name: sales-ops-orders
description: How to query Cafe Zupas order data in BigQuery — sales_ops.order_customer (order-level sales, channels, customers), sales_ops.order_lines (items, modifiers, combos), and sales_ops.order_sequence (customer order sequencing). Use for ANY question about sales, orders, customers, loyalty, menu mix, items, channels, or store performance. Contains canonical definitions, join patterns, and gotchas so every session returns the same answer.
---

# Querying Cafe Zupas Order Data

> **Freshness check:** this file must come from a clone of `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**. If you're reading it from an installed skill package, a fork, or any saved copy, stop and re-clone first — it may be stale.

> **⚠️ Breaking changes 2026-07-24** — `order_customer` was rebuilt across all history. `businessdate` is now **`business_date`**; `net_sales` is now the **calculated** net (read it directly); `item_net_sales` / `item_netsales_with_mods` / `mods_net_sales` are **gone**; `is_catering` was redefined; a **`customer_type`** column was added and is now **required for customer metrics**; `order_count` / `days_since_prev_order` moved to the new **`sales_ops.order_sequence`** table. Any saved query written before this date needs updating.

> **✅ Deployment status 2026-07-27 — `customer_type` is LIVE.** Verified against `INFORMATION_SCHEMA.COLUMNS`; the earlier "not deployed yet" warning is resolved and the interim email-based stand-in filter is retired. Use `customer_type` directly. Also live in the same rebuild: `mapped_email_domain`, and `is_guest_order` **changed from INTEGER 0/1 to BOOLEAN** — `is_guest_order = 1` now fails, use `= true`.
>
> One fix is written but **not yet redeployed**: the `pulse.orders` fan-out dedupe (Asana 1216918745136203). Until the next full rebuild, `brink_order_id` 2279778269187 still has two rows.

> **⚠️ Breaking change 2026-07-30 — `order_lines` was rebuilt across all history.** Two schema changes, both good, both breaking:
> - **`BusinessDate` is now `business_date`.** The old spelling is **gone**, so every table now uses the same partition column name and the two-spellings trap is closed. **Any saved query, template or shared workbook writing `ol.BusinessDate` now fails** with `Unrecognized name: BusinessDate`. Loud, not silent — but it will hit the shared analyst workbook.
> - **`store_state` is now a native column.** "Market" questions need no `store_info` join on either side. It is NULL for stores missing from `store_info` (1111 and 999), so `store_id <> 1111` is now load-bearing for geography, not just for totals.
>
> `claude.order_lines` was simplified to a plain `select *` passthrough the same day.

> **🛑 Read the [pre-query clarification protocol](#pre-query-clarification-protocol-steward-rule-2026-07-28--mandatory) before running any query.** Five scope items — store 1111, date range, catering, Try 2 Combo inclusion, and named-product resolution — must be settled first. Items 4 and 5 were added 2026-07-28 after a session reported an item breakdown that was wrong by ~3x because it treated every `line_item_type = 'item'` row as a standalone sale and guessed at the product name.

Project: `marketing-data-442316`. The four approved tables for order/sales analysis:

- **`sales_ops.order_customer`** — one row per order. Sales, channel, customer identity. Default table for sales/order/customer questions.
- **`sales_ops.order_lines`** — one row per line element. Menu mix, items, modifiers, combos.
- **`sales_ops.order_sequence`** — one row per order that has a `mapped_cust_id` (all customer types). Order sequencing, recency, lifetime counts.
- **`sales_ops.customer_attribute`** — **one row per customer** (person only). Lifetime and trailing-window aggregates. **New 2026-07-29.** Use it for any "per customer" question — LTV, frequency, lapsed cohorts, store affinity — instead of re-aggregating `order_customer` by hand.

Full column docs in `data_dictionaries/`: `sales_ops.order_customer.md`, `sales_ops.order_lines.md`, `sales_ops.order_sequence.md`, `sales_ops.customer_attribute.md`. Read them before writing non-trivial queries.

## 🛑 First: which dataset can you actually read? (new 2026-07-29)

**Most users cannot read `sales_ops` at all.** Standard access is `roles/bigquery.dataViewer` on the **`claude` dataset only** — the curated interface layer of read-only views. The steward has direct `sales_ops` access; nobody else does.

So before writing a query, know which side you're on:

| If your access is | Query | Notes |
|---|---|---|
| `claude` dataset only (**standard user**) | `claude.order_customer`, `claude.order_lines`, `claude.loyalty_*` | Views over `sales_ops` / `sessionM`. Read the differences below |
| `sales_ops` direct (**steward only**) | `sales_ops.*` as documented throughout this skill | Full history, unmodified columns |

**How to tell:** if `select 1 from marketing-data-442316.sales_ops.order_customer limit 1` returns `Access Denied`, you're a standard user — use the `claude` views. Don't treat that error as a broken setup; it's the intended wall.

### The `claude` views are not byte-identical to their `sales_ops` parents

Three differences, each of which will make a `claude` answer disagree with a `sales_ops` answer. **Say which dataset you queried whenever a number is being compared to someone else's.**

1. **History is a rolling 3 years, and truncation is silent.** Both order views filter `business_date >= date_trunc(date_sub(current_date, interval 3 year), year)` — **2023-01-01** as of 2026-07-29. A question about 2022 returns **zero rows, not an error**, which presents as "no sales." Before reporting an empty or surprisingly small result, confirm the requested range sits inside the window, and state the floor when the question reaches near it.

2. **`revenue_category` is overridden in `claude`.** The view applies:
   ```sql
   case when oc.is_catering = true then 'Catering' else oc.revenue_category end as revenue_category
   ```
   So in `claude`, `revenue_category = 'Catering'` and `is_catering = true` are **equivalent**, and the documented superset/subset gotcha is collapsed away. In `sales_ops` they differ — `is_catering` is a superset (48 extra orders in June 2026 flagged catering on In-Store/Digital destinations). Consequence: a channel breakdown from `claude` assigns those orders to Catering; the same breakdown from `sales_ops` leaves them in In-Store/Digital. **Neither is wrong. They are different definitions.** Don't "fix" one to match the other — state which you used.

3. **`claude.order_lines` is now a plain passthrough.** It used to rename the partition column and left-join `store_info`; the 2026-07-30 full-history rebuild moved both upstream, so the view is `select *` over `sales_ops.order_lines` with the 3-year history filter. SQL written against either side is now identical apart from that floor.

4. **`store_state` is carried on both order views** (added 2026-07-30) — so **market questions need no join** in `claude`, while in `sales_ops` you must join `store_info`. There is also a new **`claude.store_info`** view for the attributes that aren't denormalised (city, zip, address, open date, comp status, lat/long, timezone); it carries a `market` column aliasing `store_state`, and drops three non-store rows. See [`data_dictionaries/claude.store_info.md`](../../data_dictionaries/claude.store_info.md).

   > **⚠️ `store_state` is NULL for store 1111 and 999.** Both order views `left join` `store_info`, which has no row for either, so a market breakdown **without `store_id <> 1111` grows a phantom tenth market** — 1,154 orders and **$117,196** over 2026-05-03 → 2026-06-27, appearing as an unnamed NULL group that reads like a data defect rather than the test store. Keep the filter and `coalesce` the label; never ship an unnamed group.

### `claude.order_customer` folds in the sequencing and lifetime columns

There is **no `claude.order_sequence` and no `claude.customer_attribute`.** They aren't missing — the view left-joins both onto the order grain, so a standard user gets sequencing, first-time-vs-repeat, recency and LTV from the single view.

Folded in: `customer_order_count`, `days_since_prev_order` (from `order_sequence`); `lifetime_order_count`, `lifetime_catering_order_count`, `lifetime_guest_order_count`, `lifetime_net_sales`, `lifetime_gross_sales`, `lifetime_avg_check`, `first_order_date`, `last_order_date`, `days_since_last_order`, `customer_tenure_days` (from `customer_attribute`); plus `account_type` (from `claude.loyalty_user.member_program`).

> **⚠️ Zero does not mean zero — the most likely way to get a wrong number off this view.** Five of those columns are wrapped in `coalesce(…, 0)`: `customer_order_count`, `days_since_prev_order`, `lifetime_order_count`, `lifetime_catering_order_count`, `lifetime_guest_order_count`. **`0` means "no matching upstream row," not "a customer with zero orders"** — no such customer exists.
>
> The two joins produce zeros on **different populations** (measured June 2026, 713,575 orders):
>
> - **`customer_order_count = 0` ⟺ `mapped_cust_id is null`** — exact, both directions, 330,944 orders (46.4%). A reliable "unidentified order" test.
> - **`lifetime_order_count = 0` is broader** — 367,205 orders (51.5%). It means "no `customer_attribute` row": every unidentified order, *plus* all 35,553 kiosk orders, most `internal`, most store-1111 person orders, and 231 aggregator. **36,261 orders have a valid sequence number but zero lifetime values.**
>
> Rules:
>
> - First-time orders: `customer_order_count = 1` ✅ (safe — 0 is the unidentified bucket)
> - Repeat orders: `customer_order_count > 1` ✅ (not `>= 1`)
> - **Never** `avg(lifetime_order_count)` across all rows — the zeros crush the mean. Filter `lifetime_order_count > 0` **and** `customer_type = 'person'` first.
> - **Never** present `lifetime_order_count = 0` as a customer segment. It's the unidentified-and-non-person population, not a behavioral cohort.
> - Don't reconcile the two counts against each other — different joins, different population rules.
>
> The FLOAT columns (`lifetime_net_sales`, `lifetime_gross_sales`, `lifetime_avg_check`) and the DATE columns are **not** coalesced — they stay NULL, so `avg()` over them skips absent customers correctly. That inconsistency is its own trap: two adjacent columns describing the same absent customer, one reading `0` and one reading `NULL`.
>
> Also: `customer_attribute` is built **as of yesterday**, so lifetime values exclude today's orders and won't tie to a `count(*)` you compute yourself.

Full column docs: [`data_dictionaries/claude.order_customer.md`](../../data_dictionaries/claude.order_customer.md).

Everything else in this skill — canonical metric definitions, the `customer_type` rule, the pre-query clarification protocol, store 1111, the combo taxonomy — **applies unchanged to the `claude` views.** They pass those columns through untouched.

## `sales_ops.customer_attribute` — the customer-grain table (new 2026-07-29)

**Reach for this before writing your own `group by mapped_cust_id`.** If a question is about
customers rather than orders — lifetime value, order frequency, how many stores someone
visits, who's lapsed — the aggregate already exists and every session will get the same
number from it. Rebuilt daily at 5am MT, 1,375,117 rows.

| Need | Column |
|---|---|
| Lifetime orders | `lifetime_order_count` |
| Lifetime spend / AOV | `lifetime_net_sales`, `lifetime_gross_sales`, `lifetime_avg_check` |
| First / last order | `first_order_datetime`, `last_order_datetime`, `first_order_date`, `last_order_date` |
| Recency | `days_since_last_order` |
| Tenure | `customer_tenure_days` |
| Acquisition context | `first_order_revenue_category`, `first_order_source`, `first_order_store_name` |
| Home store | `primary_store_id`, `primary_store_name` |
| Stores visited | `lifetime_store_count`, `lifetime_stores` (ARRAY of STRUCT — `unnest()` it) |
| Trailing activity | `orders_l30` / `l90` / `l365`, `net_sales_l30` / `l90` / `l365` |
| Braze key | `braze_external_id` |

Rules specific to this table:

1. **It is already person-only.** There is no `customer_type` column. Do **not** add
   `customer_type = 'person'` — it will fail. Conversely, never compute company sales from it:
   it excludes unidentified orders (~47%) plus all kiosk / internal / aggregator orders.
   **Sales totals still come from `order_customer`.**
2. **No partition column — it's a dimension.** The "always filter the partition column" rule
   doesn't apply. It's 687 MB; full scans are fine. Filter `business_date` on the *other*
   tables when you join.
3. **Check `attribute_asof_date` before trusting the window columns.** It should be
   *yesterday*. Anything older means the 5am build didn't run, and `orders_l30` is silently a
   window ending on a dead date while still looking perfectly healthy. This is the
   `max(business_date)` staleness check for this table.
4. **Windows are whole-day and anchored to `attribute_asof_date`, not to now.** `orders_l30`
   means the 30 days ending yesterday. `days_since_last_order` is likewise measured from
   yesterday, so it reads one lower than a live calculation.
5. **Catering is included** in every lifetime and window total. Net it out with
   `lifetime_catering_order_count` if the question excludes catering — and say which you did.
6. **`first_order_date` means first *identified* order.** Customer identity capture starts
   effectively 2023-03-06, so a customer may have ordered anonymously before that. Say so
   when presenting tenure or acquisition-cohort figures.
7. **Values shift between builds.** `order_customer`'s 4am reload restates the last 8 days
   (5 weeks Mondays, ~13 months on the 1st), so a customer's `lifetime_order_count` can move
   without them ordering. Don't promise a number will tie to a prior report.
8. **"Category" here is channel, not menu.** `first_order_revenue_category` is
   `revenue_category`. Menu-category attributes (`item_type` / `rev_center_name`) are v2 and
   not built yet — if someone asks what a customer's first *dish* category was, the table
   can't answer it.

**Top lifetime-value customers:**
```sql
select
  ca.mapped_cust_id
, ca.lifetime_order_count
, ca.lifetime_net_sales
, ca.primary_store_name
, ca.days_since_last_order
from `marketing-data-442316`.sales_ops.customer_attribute ca
where 1=1
and ca.lifetime_order_count >= 5
order by ca.lifetime_net_sales desc
limit 50
```

**Lapsed customers who used to be frequent (win-back candidates):**
```sql
select
  ca.mapped_cust_id
, ca.mapped_email
, ca.lifetime_order_count
, ca.last_order_date
, ca.days_since_last_order
, ca.primary_store_name
from `marketing-data-442316`.sales_ops.customer_attribute ca
where 1=1
and ca.orders_l90 = 0
and ca.orders_l365 >= 6
order by ca.lifetime_net_sales desc
```

**Multi-store customers, with the store list expanded:**
```sql
select
  ca.mapped_cust_id
, ca.lifetime_store_count
, s.store_name
, s.orders
, s.last_order_date
from `marketing-data-442316`.sales_ops.customer_attribute ca
	cross join unnest(ca.lifetime_stores) s
where 1=1
and ca.lifetime_store_count >= 3
order by ca.mapped_cust_id, s.orders desc
```

## Hard rules (consistency guarantees)

1. **Never query upstream/raw datasets** (`brink.*`, `pulse.*`, `sessionM.*`) to answer business questions. They contain voided rows, duplicates, and unfiltered records that these marts already handle. If the marts can't answer the question, say so — don't improvise from raw tables.
2. **Always filter the partition column** on every table. It is **`business_date` everywhere** as of 2026-07-30 — `order_customer`, `order_sequence` and `order_lines` all agree. Never run unbounded scans.
3. **Same metric, same definition.** Use the canonical definitions below verbatim.
4. Data is fresh as of the top of the current hour (loads run at minute :02, intraday 8am–11pm MT reload today's date only; hours 0–3 and 5–7 skip). Yesterday and older is stable after the 4am run.
5. **Brink is the sole financial source of truth** (steward rule 2026-07-23). Pulse is a helper for digital order/customer metadata only — never compute financials (sales, discounts, tax, tips) from Pulse data.
6. **Customer metrics require `customer_type = 'person'`** (steward rule 2026-07-24). See below — this is not optional.
7. **All datasets are read-only.** If you need to materialize a table (intermediate results, cohorts), create it ONLY in `marketing-data-442316.scratch` — the single writable dataset; tables there auto-expire after 7 days. Materialize with `create table scratch.x as ...`, not views: a view over a heavy query silently re-runs the full scan on every select.

## Canonical metric definitions

| Metric | Definition |
|---|---|
| Net sales | `sum(net_sales)` from `order_customer`. The column **is** the canonical calculated net (`gross_sales - total_discount_amount - total_promotions_amount`) as of 2026-07-24. Do NOT use `brink_net_sales` — validation only |
| Gross sales | `sum(gross_sales)` from `order_customer` |
| Order count | `count(*)` from `order_customer` (or `count(distinct brink_order_id)` — see the grain defect note) |
| Average check | `sum(net_sales) / count(*)` from `order_customer` |
| Identified customers | `count(distinct mapped_cust_id)` where `mapped_cust_id is not null` **and `customer_type = 'person'`** |
| Guest orders | `is_guest_order = true` (BOOLEAN since 2026-07-27, was 0/1) |
| Catering | `is_catering = true` for the business line; `revenue_category = 'Catering'` for channel reporting (see gotchas — they differ slightly) |
| Channel | `revenue_category` (In-Store, Digital, Third_Party, Catering, Fundraiser) |
| Digital source | `order_source` (NULL = in-store POS) |
| First-time order | `order_sequence.customer_order_count = 1` **with `customer_type = 'person'`** — only back to 2023-03-06 (see gotchas) |
| Repeat order | `order_sequence.customer_order_count > 1` **with `customer_type = 'person'`** |
| Lifetime orders per customer | **`customer_attribute.lifetime_order_count`** — one row per person customer, already person-only and store-1111-excluded. **`order_sequence.lifetime_customer_order_count` was DROPPED 2026-07-29** — any query using it now errors |
| Items sold | `order_lines` where `line_item_type = 'item'`, measure `sum(qty)` or `count(*)` |
| Item sales | `sum(item_gross_sales)` from `order_lines`. Discounts/promotions are order-level lines with no per-item allocation, so per-item **net is not computable** from the mart — use gross for item mix. ⚠️ See the `item_net_sales` note below before telling a user the column doesn't exist |
| Menu mix name | `item_name` (size-normalized) + `item_size`; category via `item_type` or `rev_center_name` |

### Canonical `order_source` and `revenue_category` values (verified 2026-07-27)

Do not guess these, and do not rebuild the channel rollup yourself. Live values on a normal business day:

| `order_source` | Usual `revenue_category` | Note |
|---|---|---|
| `NULL` | In-Store (also Fundraiser, rare Third_Party) | In-store POS order |
| `Checkmate` | Third_Party | itsacheckmate aggregator feed (DoorDash/UberEats/GrubHub/Postmates) |
| `iOS` / `Android` | Digital | Native app |
| `Mobile Web` / `Web` | Digital (also Catering) | Web ordering; `Web` + Catering = online catering |
| `Outdoor Kiosk` | **In-Store** | Shared kiosk terminal — pairs with `customer_type = 'kiosk'`. Do NOT count as Digital |
| `Operator` | Catering (some Digital/In-Store) | Phone/manual order entry |
| `ezcater` | Catering | ezCater marketplace |

**Anti-pattern — do not reconstruct `revenue_category` from `destination`.** `revenue_category` is the canonical rollup and is already on `order_customer`. Hand-rolled `case when destination like '%Cater%' … end` classifiers were observed in analyst SQL 2026-07-27; they drift from the mart and are only needed on the legacy `OrderCustomer` table, which you should not be using. If a destination isn't landing in the category you expect, raise it as a `KB finding:` task instead of writing your own CASE.

### The `customer_type` rule (steward rule 2026-07-24)

`order_customer.customer_type` classifies the customer **on each order** as `person`, `kiosk`, `internal`, or `aggregator` (NULL when unidentified). **38% of identified orders belong to non-person ids** — shared outdoor-kiosk terminal accounts, employee/developer accounts, and the third-party ordering funnel (ezcater / doordash / itsacheckmate), dominated by pulse id `19192` at ~108K orders a month across 89 stores.

- **Customer-level metrics** (customer counts, frequency, retention, cohorts, LTV, first-time vs repeat) → filter `customer_type = 'person'`. Without it the numbers are materially wrong, not slightly off.
- **Sales / order / channel metrics** → do **not** filter. Those are real orders and real revenue; excluding them understates sales by ~$4.2M/month.

State which you did whenever it affects the answer.

**It's order-level, not customer-level** (steward decision 2026-07-27). The same `mapped_cust_id` can carry different types across its orders — June 2026: 30 ids / 108,313 orders, with `19192` splitting 107,807 `aggregator` + 196 `person`. This is deliberate: `19192` doesn't exist in `pulse.customers` (dev ticket open), so there's no reliable customer-level attribute to collapse onto. Practical effect: `count(distinct mapped_cust_id) where customer_type = 'person'` slightly overcounts. Filtering *orders* by `customer_type = 'person'` is still the correct rule. `order_sequence` applies its own customer-level guard, so sequencing and lifetime counts are unaffected.

## Pre-query clarification protocol (steward rule 2026-07-28 — MANDATORY)

**Before running the query that answers the question, confirm scope.** Every one of these has burned a real answer. Ask them together in ONE message (don't interrogate the user one item at a time), then query. If the user has already stated an item, don't re-ask it.

### 1. Store 1111 — never ask, always exclude

**`store_id <> 1111`** on whichever table you're querying. Test/training store. Not a question, not a default the user can override, and don't raise it as an assumption — just do it and note it in the assumptions line.

### 2. Date range — ask

Which dates the question covers. Never assume "last 30 days" or "this month" from silence. Also confirm the interpretation when a range is fuzzy ("May" = `2026-05-01` to `2026-05-31`; "last week" = the most recent **Mon–Sat**, see the business-week gotcha).

### 3. Catering — ask

Included or excluded, defined as **`is_catering = true` / `= false`** (BOOLEAN — `is_catering = 0` fails). It's a superset of `revenue_category = 'Catering'`; see the gotcha. Catering skews item questions hard: catering trays/box lunches carry the same `item_name` as the retail item at very different volumes and prices, so an unstated choice here silently changes the answer.

### 4. Try 2 Combos — ask whenever the question involves soups, sandwiches, or salads

Any question naming a soup, sandwich, or salad (or the `Soups` / `Sandwiches` / `Salads` revenue centers, or `item_type = 'Entree'`) must confirm: **does the user want only items sold standalone, or also the ones bundled inside a Try 2 Combo?**

This is not a rounding difference. For Ultimate Grilled Cheese, 2026-05-03 → 2026-06-27: **24,125 standalone vs 85,084 inside combos** — combos are ~78% of units. Answering the wrong one is off by 4x. See the combo line taxonomy below for the exact SQL, and **present the split** rather than a single blended number whenever combos are included.

**Bowls are NOT combo-eligible — don't ask the question for them** (verified 2026-07-30). `parent_rev_center_name = 'Try 2 Combo'` spans only these revenue centers over 2026-05-03 → 2026-06-27 (store 1111 excluded): `Combos` (863,383 lines), `Sandwiches` (705,355 / 14 items), `Modifiers` (684,714), `Soups` (565,433 / 14), `Salads` (465,498 / 10), `Sides/Misc Items` (114,094), `Non Food/Bev Mis` (54,845), `Desserts` (10,069). **`Bowls` never appears.** Confirmed at item level: `Power Bowl` and `Hot Honey Cottage Cheese Bowl` have **zero** `parent_rev_center_name = 'Try 2 Combo'` lines of either shape. So a question mixing sandwiches and bowls needs the combo fork asked **once and applied only to the eligible items**; say which items it affected. Asking it about a bowl is a dead question that makes the clarification protocol look like noise.

> **⚠️ "Zero combo lines" does NOT mean "zero modifier lines"** (corrected 2026-07-30 — the first draft of this note got it wrong and it's worth keeping the correction visible). Bowls **do** appear as zero-priced `line_item_type = 'modifier'` lines: 5,615 over 2026-05-03 → 2026-06-27 (Power Bowl 3,833, Hot Honey Cottage Cheese Bowl 1,782), **every one of them `is_catering = true` with `parent_rev_center_name = 'Box Lunches'`**. They are invisible under `is_catering = false`, which is exactly how the wrong conclusion was reached. **So the taxonomy row "Combo slot (zero-priced) = `line_item_type = 'modifier'`" is incomplete as written** — always qualify it with `parent_rev_center_name = 'Try 2 Combo'`, or Box Lunch units silently land in the combo bucket the moment catering is included.

### Discount lines masquerade as items — exclude them from item reports (steward rule 2026-07-30)

A discount applied to an item produces a line carrying **the item's own name** in `item_name`, with `rev_center_name = 'Discount'`, `line_item_type = 'discount'`, and — the trap — **`item_type` set to the item name too**, not to `'Entree'`. Over 2026-05-03 → 2026-06-27 the four-item test set had 319 such lines: $0 gross but **319 units**.

Two consequences. They inflate any unit count not filtered to `line_item_type in ('item','modifier')`. And, more insidiously, they surface as a **separate candidate row in the name-discovery query** (protocol item 5) — so a user resolving "Hot Honey Cottage Cheese Bowl" sees two entries for one product with no way to tell which is real. Filter them in **both** the discovery query and the metric query:

```sql
and ol.rev_center_name <> 'Discount'
and ol.item_type <> 'Discount'
and ol.line_item_type <> 'discount'
```

Because `item_type` is unreliable on these rows, don't rely on `item_type = 'Entree'` alone to exclude them.

### 5. Named products — resolve the name against the data FIRST, then confirm

When the user asks about a specific product by name, **do not guess the string and go straight to the metric query.** `item_name` values don't match how people speak, one spoken name can span several rows (sizes, catering variants, LTO renames, seasonal spellings), and a wrong guess returns a clean-looking wrong number — or zero rows presented as "no sales."

Run a cheap discovery query first, show the user the list, and get confirmation:

```sql
select
ol.item_name
, ol.rev_center_name
, ol.item_type
, count(*) as lines
, round(sum(ol.item_gross_sales), 0) as gross_sales
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date between @start and @end
and ol.store_id <> 1111
and lower(ol.item_name) like '%grilled cheese%'   -- broadest distinctive fragment, lowercased
group by 1, 2, 3
order by 4 desc
```

- Match on the **shortest distinctive fragment**, lowercased on both sides. `like '%ultimate grilled cheese%'` misses `Ultimate Grilled Cheese Box`; `like '%grilled cheese%'` finds the family.
- `item_name` is a **cluster field** — these filters are cheap. Still filter `business_date`.
- Show the candidate names with their volumes and revenue centers so the user can see what they're choosing between, then ask which to include. Zero rows = say so and widen the fragment; never report `$0`.
- Only after the name list is confirmed, run the metric query against the agreed `item_name in (...)` set.

**Worked example (verified 2026-07-28, 2026-05-03 → 2026-06-27, store 1111 excluded).** "Grilled cheese" resolves to **four** different items, which is exactly why this step exists:

| `item_name` | Standalone | Combo component | Bundle slot ($0)\* |
|---|---|---|---|
| `Brisket Grilled Cheese` | 28,891 | 44,874 | 31,181 |
| `Ultimate Grilled Cheese` | 24,125 | 47,461 | 39,113 |
| `Grilled Cheese Sandwich` | **52** | 28,340 | 65,041 |
| `Ultimate Grilled Cheese Box` | 43 | — | — |

\* All zero-priced `modifier` lines, both catering flags — i.e. Try 2 Combo **plus** Box Lunches. The Try 2 Combo–only subset for Ultimate Grilled Cheese is 37,623 (the figure used in the taxonomy below); the remaining 1,490 are Box Lunches. Scope your `parent_rev_center_name` filter deliberately.

Note `Grilled Cheese Sandwich` is effectively a **combo-only item** — 52 standalone lines against 93K combo appearances. If a user says "grilled cheese" and you silently pick one name, you can be off by an order of magnitude or answer about the wrong sandwich entirely.

**Also: `Ultimate Grilled Cheese Box` carries `is_catering = false`** despite being the catering box product. So `is_catering = false` does **not** reliably strip catering-only SKUs — the catering question (item 3) and the name question (item 5) are independent, and you need both.

Remaining defaults unless the user says otherwise: include employee-discount orders, all channels. State all assumptions in the answer when they matter.

## SQL style (steward rule 2026-07-23, extended 2026-07-29 — MANDATORY)

All SQL — shown to users or executed — follows the steward's format so he can diagnose any query quickly. Match the build scripts in `sql/`:

1. **Fully qualify everything — tables *and* every column reference.**
   - Tables: `` `marketing-data-442316`.dataset.table ``. Never rely on a default project or dataset.
   - **Backticks wrap the project only, not the whole path.** `` `marketing-data-442316`.sales_ops.order_customer oc `` — correct. `` `marketing-data-442316.sales_ops.order_customer` oc `` — wrong, even though BigQuery accepts both. The project id is the only part that *needs* quoting (the hyphens); ticking the whole path hides the dataset/table boundary. (Steward rule 2026-07-29. Note this governs **SQL**; in markdown prose a full table name inside a code span, like `sales_ops.order_customer`, is just formatting.)
   - Columns: every column in every clause (select, where, join, group by, order by, window, having) carries its table alias — `oc.net_sales`, never bare `net_sales` — **even in a single-table query**. Nobody should have to go searching for which table a field came from.
2. **Fixed aliases for the core tables**, in either dataset (`sales_ops` or `claude`) — don't invent new ones:
   - `order_customer` → **`oc`**
   - `order_lines` → **`ol`**
   - `order_sequence` → `os`, `customer_attribute` → `ca`, `store_info` → `si`
3. **Lowercase whenever possible**: keywords, functions, aliases, CTE names. Case only where the identifier or value requires it — schema column names as they actually exist (`business_date` on `order_lines`) and string literals being compared (`'Third Party'`).
4. **Layout**:
   - select list: one column per line, **leading commas**, first column on the line after `select`; column aliases use `as`
   - CTEs: `with name as (` … `)`, chained as `, next_name as (`
   - **`where 1=1` is always the first condition**, then each real condition on its own `and ...` line — so conditions can be added, removed, or commented out without touching the rest
   - each join on its own line with `on ...` on the line directly beneath it, **lined up with the `join`**
   - **indent one additional level for each successive join**, so nesting depth is readable at a glance

```sql
select
  oc.business_date
, oc.store_id
, ol.item_name
, count(distinct oc.brink_order_id) as orders
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.sales_ops.order_customer oc
	join `marketing-data-442316`.sales_ops.order_lines ol
	on ol.brink_order_id = oc.brink_order_id
		left join `marketing-data-442316`.sales_ops.order_sequence os
		on os.brink_order_id = oc.brink_order_id
where 1=1
and oc.business_date between @start and @end
and ol.business_date between @start and @end
and oc.store_id <> 1111
group by
  oc.business_date
, oc.store_id
, ol.item_name
order by
  oc.business_date
```

## Join patterns

**order_customer → order_lines** (partition-prune both sides — same column name on each since 2026-07-30):
```sql
select
...
from `marketing-data-442316`.sales_ops.order_lines ol
	join `marketing-data-442316`.sales_ops.order_customer oc
	on oc.brink_order_id = ol.brink_order_id
where 1=1
and ol.business_date between @start and @end
and oc.business_date between @start and @end   -- partition-prune BOTH tables
```

**order_customer → order_sequence** (always `left join` — a missing row means unidentified, not an error):
```sql
select
...
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
	and os.business_date = oc.business_date
where 1=1
and oc.business_date between @start and @end
and os.business_date between @start and @end
```

## Recipes

**Daily net sales by channel (last 30 days):**
```sql
select
oc.business_date
, oc.revenue_category
, round(sum(oc.net_sales), 2) as net_sales
, count(*) as orders
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 30 day)
and oc.store_id <> 1111
group by 1, 2
order by 1, 2
```

**Identified customer counts (person only):**
```sql
select
date_trunc(oc.business_date, month) as month
, count(distinct oc.mapped_cust_id) as customers
, count(*) as orders
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 365 day)
and oc.store_id <> 1111
and oc.mapped_cust_id is not null
and oc.customer_type = 'person'
group by 1
order by 1
```

**First-time vs repeat orders (last 30 days):**

`order_sequence` is not pre-filtered, so the `customer_type` test belongs in the CASE — without it every aggregator and kiosk order lands in "Repeat" and swamps the split.
```sql
select
oc.business_date
, case
    when os.brink_order_id is null then 'Unidentified'
    when os.customer_type <> 'person' then 'Non-person'
    when os.customer_order_count = 1 then 'First-time'
    else 'Repeat'
  end as guest_type
, count(*) as orders
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
	and os.business_date = oc.business_date
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 30 day)
and os.business_date >= date_sub(current_date('America/Denver'), interval 30 day)
and oc.store_id <> 1111
group by 1, 2
order by 1, 2
```

**Top items by quantity (entrées, last 90 days):**
```sql
select
ol.item_name
, ol.item_size
, sum(ol.qty) as qty
, round(sum(ol.item_gross_sales), 0) as gross_sales
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date >= date_sub(current_date('America/Denver'), interval 90 day)
and ol.store_id <> 1111
and ol.line_item_type = 'item'
and ol.item_type = 'Entree'
group by 1, 2
order by 3 desc
limit 25
```

**Entrée units split standalone vs inside a Try 2 Combo (verified 2026-07-28):**

An entrée appears in `order_lines` in **three** distinct shapes. Getting these wrong is the single easiest way to produce a confidently wrong item number — see the taxonomy note below.

```sql
select
date_trunc(ol.business_date, week(monday)) as week
, case
    when ol.line_item_type = 'item' and ol.composite_item_id is null then 'Standalone'
    when ol.line_item_type = 'item' and ol.composite_item_id is not null then 'Combo component (priced)'
    when ol.line_item_type = 'modifier' then 'Combo slot (zero-priced)'
  end as sale_shape
, sum(ol.qty) as units
, round(sum(ol.item_gross_sales), 2) as gross_sales
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date between @start and @end
and ol.store_id <> 1111
and ol.item_name = 'Ultimate Grilled Cheese'
and ol.is_catering = false
group by 1, 2
order by 1, 2
```

### Combo line taxonomy — the three shapes (steward finding 2026-07-28)

| Shape | Filter | Carries revenue? |
|---|---|---|
| **Standalone** | `line_item_type = 'item'` and `composite_item_id is null` | Yes — full menu price |
| **Combo component (priced)** | `line_item_type = 'item'` and `composite_item_id is not null`, `parent_rev_center_name = 'Try 2 Combo'` | **Yes** — real allocated price (~$6.64/line for UGC) |
| **Combo slot (zero-priced)** | `line_item_type = 'modifier'` | No — ~$0.01/line; the entrée recorded as a modifier selection |

- **`line_item_type = 'item'` is NOT the same as "standalone."** For Ultimate Grilled Cheese over 2026-05-03 → 2026-06-27: 71,586 `item` lines, but only **24,125** were standalone — the other **47,461** were priced combo components. Treating all `item` lines as standalone overstates standalone units ~3x and understates combo units.
- **The two combo shapes are mutually exclusive per `combo_order_line_item_id`** (verified: 47,461 groups have exactly one priced component line and zero modifier lines; 37,623 have exactly one modifier line and zero component lines). So **combo units = component lines + modifier lines, with no double-counting.** Both shapes appear across all 88 stores in both months and both combo types, so this is a per-combo-slot POS structure, not a config migration or a store/size split.
- **Revenue lives in the first two shapes, not just the first.** The priced combo components carried $315,280 of gross for UGC in that window vs $215,890 standalone — so "essentially all revenue is in standalone lines" is false. For revenue-per-unit, divide by standalone + component lines; exclude the zero-priced modifier lines.
- Box Lunches (catering) also surface entrées as zero-priced `modifier` lines with `parent_rev_center_name = 'Box Lunches'` — another reason to settle the catering question up front.

**Try 2 Combo count and composition:**
```sql
select
ol.parent_item_grp_name
, count(distinct ol.combo_order_line_item_id) as combos
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date >= date_sub(current_date('America/Denver'), interval 30 day)
and ol.store_id <> 1111
and ol.parent_rev_center_name = 'Try 2 Combo'
group by 1
order by 2 desc
```

## Guest checkout (launched 2026-06-25) — known gap

Guest checkout (web/mobile-web ordering without signing in) went live around **2026-06-25**, with the first orders landing **2026-06-29**. A guest-checkout order looks like this on `order_customer`:

```sql
and oc.order_source in ('Web', 'Mobile Web')   -- `source` on the legacy table
and oc.email is null
and oc.mapped_email is null
```

> **Corrected 2026-07-28.** This block previously said `order_source in ('mobile_web_source', 'web_source')`. **Those values do not exist** — the filter silently returned **zero rows**, so any answer built on it reported "no guest-checkout orders" rather than failing. The real values are `'Web'` and `'Mobile Web'` (verified against `business_date = 2026-07-27`, and they always matched `data_dictionaries/sales_ops.order_customer.md`). If you produced a guest-checkout number before this date, recheck it.
>
> **Blast radius (measured 2026-07-29):** the bad filter ran **118 times** across two analysts between 2026-07-24 and 2026-07-28 (jelgie@ 69, dgetz@ 49), zero times on 2026-07-29 — so the correction took. It sat inside a CTE feeding a guest-checkout arm that was `union all`'d to a known-customer arm in a weekly second-order report, so **every run returned a full, plausible result set with the guest arm contributing nothing.** No error, no empty output, just a number understated by the entire guest population. Lesson: when a `union all` arm can go empty, check each arm's row count independently before trusting the total (Asana 1216992671864463).
>
> **Where the bad values came from** — they are the *raw pulse* values. `sql/sales_ops.order_customer.sql` lines 358–359 map `po.source = 'mobile_web_source' → 'Mobile Web'` and `'web_source' → 'Web'`. Someone documented the upstream side of the mapping instead of the mart side. General lesson: **filter values you write must come from the mart's own dictionary, never from a build script's source expressions** — the whole point of the mart is that it renamed them.

**The mart carries no email or identity for these orders**, so you cannot tell a brand-new guest from a lapsed known customer using the approved tables alone. The two known workarounds both leave the walls and are therefore **not approved for business answers**:

1. `pulse.order_customers.email` joined on `cast(oc.pulse_order_id as string) = cast(po.order_id as string)` (note the cast — the types differ).
2. Braze `customevent` where `name = 'guest_email_from_order'`, `$.order_id` in `properties`; also `users.custom_attributes.guest_test_email`.

If a question needs guest-checkout identity, say the mart can't answer it and point at Asana 1216806056925588 (cohort mart with guest-checkout linkage). Three separate analysts hand-rolled workaround #1 on 2026-07-24.

## SessionM identity health check (defect fixed 2026-07-29 — check still recommended)

A defect that nulled `sm_external_user_id` on whole business dates was found and fixed on
2026-07-29 (`create_date > start_date` → `>=`). All affected dates are repaired and verified.
Full audit: `design/sessionm_identity_pipeline_audit.md`.

**Keep running the detector before customer-grain answers covering recent dates.** The failure
mode is worth guarding against because it is invisible in every financial number — sales, order
counts and channel mix all looked completely normal while person orders fell ~38%. Only
customer-grain metrics broke: customer counts, first-time vs repeat, retention, recency,
lifetime counts, and everything in `customer_attribute`.

```sql
select
  oc.business_date
, count(*) as all_orders
, countif(oc.sm_external_user_id is not null) as sm_linked
, countif(oc.customer_type = 'person') as person_orders
, round(100 * countif(oc.sm_external_user_id is not null) / count(*), 1) as pct_sm_linked
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 14 day)
and oc.store_id <> 1111
group by 1
order by 1
```

Healthy is **~28–33%**. Under 15% on a **completed** day means that date is corrupted — **say so
in the answer and exclude or caveat those dates** rather than reporting the number as-is.

> ### 🔑 Exclude today — SessionM loads once per day (~03:00 MT)
>
> **Today's date will always read ~2% and that is normal.** SessionM data for a given day lands
> in the *next* morning's load, so today's orders have essentially no loyalty identity:
> 2026-07-29 at 13:20 MT had 9,758 Brink orders and 195 SessionM links, against 7,868 (30.0%)
> for 2026-07-28.
>
> - **Never apply the 15% rule to the current business date** — it is a guaranteed false positive.
> - **Never answer a customer-grain question about today.** Customer counts, `mapped_cust_id`,
>   first-time vs repeat, and anything from `order_sequence` / `customer_attribute` are ~98%
>   under-identified for today. If asked about today, answer through **yesterday** and say why.
> - **Sales, order counts and channel mix for today are fine** — those come from Brink, which
>   loads intraday every hour.

## Gotchas checklist (scan before answering)

- **Know which dataset you can read before you write SQL.** Standard users have the **`claude` dataset only**; `sales_ops` returns `Access Denied` for them and that is intended, not a broken setup. See the `claude` interface-views section near the top.
- **`claude` history starts 2023-01-01 and truncates silently.** The order views filter `business_date >= date_trunc(date_sub(current_date, interval 3 year), year)`. An older range returns **zero rows, not an error** — which reads as "no sales." Check the window before reporting an empty result.
- **`revenue_category` means something different in `claude` than in `sales_ops`.** The `claude` view forces it to `'Catering'` whenever `is_catering = true`, making the two equivalent; in `sales_ops`, `is_catering` is a superset (48 extra orders in June 2026). Channel breakdowns from the two datasets will legitimately disagree — state which you queried instead of reconciling them.
- **In `claude.order_customer`, `0` in a folded count column means "no upstream row," not zero orders.** `customer_order_count = 0` ⟺ unidentified (46.4% of June 2026 orders); `lifetime_order_count = 0` is broader at 51.5% — it also catches all kiosk, most internal, and most store-1111 orders, so 36,261 orders have a real sequence number but zero lifetime. Never `avg()` a lifetime column unfiltered; never present `lifetime_order_count = 0` as a cohort. The FLOAT/DATE lifetime columns are *not* coalesced and stay NULL, so the same absent customer reads `0` in one column and `NULL` in the next. Details in `data_dictionaries/claude.order_customer.md`.
- **There is no `claude.order_sequence` or `claude.customer_attribute`** — both are folded into `claude.order_customer`. Don't tell a user the data is unavailable; it's on the order view.
- **The partition column is `business_date` on every table** as of 2026-07-30. `order_lines` was rebuilt across full history that day and its `BusinessDate` column is **gone** — the long-standing two-spellings trap is closed. ⚠️ **Any saved query, template or workbook still writing `ol.BusinessDate` now fails outright** with `Unrecognized name: BusinessDate`. That is the good failure mode (loud, not silent), but it will hit the shared analyst workbook — read the error literally and swap in `business_date`.
- **`order_lines` has no `order_id`** — this now leads the gotcha list because it is the single most-repeated error in the query log: `Name order_id not found inside ol`, hit three more times on 2026-07-27/28 and **again on 2026-07-28 at 09:12** by the same analyst. The order key is `brink_order_id` on every one of these tables. The 2026-07-28 instance selected `ol.order_id` in a CTE and then joined `oc.brink_order_id = ol.order_id` — i.e. the correct column name was already in the query, on the other side of the join. Read your own join predicate before selecting.
- **Customer metrics need `customer_type = 'person'`**; sales metrics must NOT filter it. See the rule above.
- **Always `lower()` an email before matching, grouping, or counting it** (audited 2026-07-29). `order_customer.mapped_email` and `email` are **not** normalised — 4% of `mapped_email` values are not lowercase, and `count(distinct mapped_email)` **overstates by ~17,900** because the same address in different case counts twice. `mapped_email_domain` *is* already lowercase and is safe as-is. Root cause is Pulse (8.7% non-lowercase); Braze and SessionM emails are 100% clean. Also relevant to identity: 5,604 emails have one person split across several `mapped_cust_id`s by case alone.
- **Per-customer questions should use `sales_ops.customer_attribute`, not a hand-rolled `group by mapped_cust_id`** (new 2026-07-29). Lifetime orders, spend, AOV, recency, tenure, store affinity and trailing 30/90/365-day activity are all precomputed there — that's the whole point, so two sessions can't produce two different LTV numbers. It is already person-only (adding `customer_type = 'person'` errors), it has **no partition column**, and you must check `attribute_asof_date = yesterday` before trusting the window columns. See its section above.
- **⚠️ UNRESOLVED — `order_lines.item_net_sales` exists and is fully populated, but this skill tells users per-item net isn't computable** (found 2026-07-30). The column is live on **both** `sales_ops.order_lines` and `claude.order_lines`, with **zero nulls**: for 2026-06-01 → 2026-06-07, `line_item_type = 'item'`, store 1111 excluded — 712,458 lines, $4,291,648 gross vs **$4,178,409 net**, a 2.6% spread. The 2026-07-24 breaking-change note says `item_net_sales` is "gone," but that removal applied to the **order-level** rollups on `order_customer`, not to the line-level column here. Until the steward rules on what the 2.6% represents (item-level discount only? tax? something else?) and whether it reconciles to order-level `net_sales`: **keep using `item_gross_sales` for item mix, and do not present `item_net_sales` as a net-sales figure.** But don't tell a user the column doesn't exist — they can see it in the schema, and that answer destroys trust in the rest of this skill. Say it's undocumented and unvalidated (Asana: `KB finding: item_net_sales is live but undocumented`).
- **Net sales is the `net_sales` column** — read it directly (calculated at build since 2026-07-24). `brink_net_sales` is Brink-given and validation-only; it runs ~0.0025% above calculated net ($479 on $18.9M in June 2026). There is no per-item or per-modifier net in the mart any more.
- **`is_catering = false` does not exclude catering-only items** (verified 2026-07-28). `Ultimate Grilled Cheese Box` — the catering box SKU — is flagged `is_catering = false` on `order_lines`. The flag describes the *order's* catering destination, not the *item's* nature, so catering-specific SKUs leak into non-catering item mix. Check the resolved item-name list for `Box` / `Tray` / `Party` variants explicitly.
- **`is_catering` is a superset of `revenue_category = 'Catering'`** — every catering-destination order is TRUE, plus a handful (48 in June 2026) that pulse flagged as catering on In-Store/Digital destinations. Before 2026-07-24 the flag missed all POS-only catering (641 orders / $70.7K net in June), so pre-rebuild catering numbers understate it.
- **Grain defect (1 order in ~50M):** `brink_order_id` 2279778269187 has two rows in `order_customer` — two pulse orders point at one Brink order, double-counting $263.99 across two customers. Immaterial to totals; use `count(distinct brink_order_id)` if exact uniqueness matters.
- **`order_sequence` history starts 2023-03-06**, not 2018. `customer_order_count = 1` means "first order since March 2023", not first-ever. Say so when presenting first-time-guest numbers.
- **`order_sequence` is a `left join`, never inner** — ~47% of orders have no `mapped_cust_id` and so no row; an inner join silently drops them.
- **`order_sequence` is NOT pre-filtered (changed 2026-07-27).** It holds every order with a `mapped_cust_id`, all customer types, and carries `customer_type` as a column. You must filter `customer_type = 'person'` yourself. Earlier versions were person-only — saved queries written against those are now wrong.
- **Sequence numbers are computed across all of a customer's orders, then you filter.** Filtering `customer_type = 'person'` selects rows but does not renumber them, so a mixed id (30 in June 2026) shows million-scale `customer_order_count` on its person rows — `19192` sits around 2.48M. Treat those as unreliable; recompute the window over person orders if you need true per-person sequencing.
- **`order_sequence.lifetime_customer_order_count` was DROPPED 2026-07-29.** Querying it now errors. Use **`customer_attribute.lifetime_order_count`** instead — but note it is person-only, excludes store 1111, and is as-of *yesterday*, so it won't tie exactly to the old column (they agreed on 99.84% of shared customers). It is the more correct figure; that's why the old one was removed.
- `order_lines.amount` sums to order gross ONLY when filtered to `line_item_type in ('item','fee','surcharge','modifier')` — tip and gift_card lines carry non-sales amounts, discounts/promotions are negative. For item mix, `item_gross_sales` on `line_item_type = 'item'` is still the measure.
- Item counts need `line_item_type = 'item'`, else modifiers ~double the count.
- **`line_item_type = 'item'` does not mean "sold standalone"** (verified 2026-07-28). It includes priced Try 2 Combo component lines, which for Ultimate Grilled Cheese were 66% of all `item` lines. Split on `composite_item_id is null` to isolate true standalone sales. See the combo line taxonomy in Recipes — an answer built on the wrong shape is off by multiples, not percentages.
- **Ask about Try 2 Combo inclusion on every soup / sandwich / salad question** before querying (pre-query protocol item 4). Combos were ~78% of Ultimate Grilled Cheese units.
- **Resolve product names with a `like` discovery query before measuring them** (pre-query protocol item 5). Never hard-code a guessed `item_name`; a near-miss returns a clean wrong number or a silent zero.
- `qty` is derived from price and approximate; fine for mix, not for inventory-grade counts.
- Line-level sums won't exactly reconcile to `order_customer` order-level sales (order-level discounts, rounding). Order-level `net_sales` from `order_customer` is the truth for sales. Quantified 2026-07-23 (post modifier-gross fix): ~1.3% of orders have no `order_lines` rows (all $0-net fully-voided orders — benign); on the rest, line reconstruction matches 99.99% of orders (aggregate within ~$1.5K on $55M/90d). Still: report sales totals from `order_customer`, not `order_lines`.
- `rev_center_name = 'Foutain Beverages'` is misspelled in source — match it as-is.
- `is_guest_order` is loyalty-based (91% of all-time orders are guest); `mapped_cust_id` coverage is ~53% over the last year, and only ~62% of *that* is a real person.
- **Store 1111 is a test/training store — ALWAYS exclude it** (`store_id <> 1111`) in all sales, order, and item metrics on all tables. No exceptions (steward rule 2026-07-23). Note `order_sequence` sequence numbers are built without that exclusion.
- Store footprint: ~90 stores in UT, AZ, MN, NV, WI, ID, IL, OH, TX. Store attributes come from `sales_ops.store_info`.
- **Business week is Monday–Saturday** — all stores are closed Sunday. "Last week" means the most recent Mon–Sat; weekly averages divide by 6 days, not 7. Don't use Sun-anchored `date_trunc(..., week)` for CZ weeks (observed in analyst SQL 2026-07-22; steward-confirmed pending). Use `date_trunc(d, week(monday))` to bucket weeks.
- **Year-over-year offset is 364 days, not 1 year** — `date_sub(d, interval 364 day)` (52 × 7) keeps the day-of-week aligned, which matters because the week is Mon–Sat and Sundays are zero. `date_sub(d, interval 1 year)` shifts the weekday and drags a Sunday into the comparison window. Convention observed in analyst SQL 2026-07-24.
- Timezone: business runs on `America/Denver` for schedule logic; each store's local time is in `order_datetime`, UTC in `order_customer.order_timestamp_utc`.
- There is **no `order_id` column** on any of these tables — the order key is `brink_order_id` (multiple users have hit this error).
- A legacy table `sales_ops.OrderCustomer` also exists (different schema: `netsales`, `iscatering`, `storeid`, `lifetime_order_cnt`, `first_order_datetime`, `order_count`, `mapped_domain`, `source`, …). **Do not use it** — it predates this mart and gives different answers. `sales_ops.order_customer` (lowercase) is the only canonical order table.
  - **It is now also going stale**: on 2026-07-27 its `max(business_date)` was **2026-07-25** while `order_customer` had loaded through 2026-07-27. Answers from it are silently 1–2 days short of current. Three separate users queried it during 2026-07-24 → 2026-07-26.
  - **🛑 If you are working from a saved query or a shared template, assume it targets this legacy table and rewrite it before running.** Query-log review counted **188 non-steward runs against `OrderCustomer` in the five business days 2026-07-24 → 2026-07-29**, and every one of the 115 raw-`pulse.*` wall breaches in that window came through it. The pattern is a *shared workbook* — byte-identical query text ran under two different users' accounts hours apart on 2026-07-28, eight of them inside a single minute (batch execution). Legacy schema is the tell: `businessdate`, `storeid`, `iscatering = 0`, `source`, `lifetime_order_cnt`, `first_order_datetime`. Translate to `business_date`, `store_id`, `is_catering = false`, `order_source`, and `order_sequence.lifetime_customer_order_count` — and if the template reached into `pulse.*` for identity, stop and say the mart can't answer it (Asana 1216992461499656).
  - `iscatering` on the legacy table is **INT64** (`iscatering = 0`); `is_catering` on the canonical mart is **BOOL** (`is_catering = false`). Writing `is_catering = 0` fails with `No matching signature for operator = for argument types: BOOL, INT64` (observed 2026-07-24) — a reliable sign a query was written against the legacy schema.
- **`sales_ops.store_info` column names are not the obvious ones** — it's `store_state`, not `state`; `store_city`, `store_zip`, `store_address`, `store_short_name`. Full column list: `store_id`, `store_name`, `store_address`, `store_city`, `store_state`, `store_zip`, `store_phone`, `store_short_name`, `store_tz`, `store_open_date`, `is_comp_store`, `latitude`, `longitude`, `weather_cluster_id`, `timezone_name`. Join `store_info.store_id = order_customer.store_id`. Full dictionary: [`data_dictionaries/sales_ops.store_info.md`](../../data_dictionaries/sales_ops.store_info.md). (Guessing `state` failed an analyst session 2026-07-24.)
- **"Market" means `store_state`** (steward decision 2026-07-30). There is **no** `market` / `region` / `dma` / `metro` column anywhere in `sales_ops` — verified against `INFORMATION_SCHEMA.COLUMNS`. When a user asks for anything "by market," join `store_info` and group by `si.store_state`, and **say in the answer that market = state**. Ten values, one of which is **blank** (one store has no `store_state`) — it becomes a nameless row in any breakdown, so exclude or label it. Caveat worth stating: Utah is 35 of ~90 stores across 28 cities, so one "Utah" row hides most of the geographic spread. `store_city` is finer but `West Valley` and `West Valley City` are separate values for the same metro. A real metro/DMA rollup is an open KB gap — don't invent one per-session.
- `sales_ops.order_discount` exists (order-level discount lines: `order_id`, `discount_id`, `name`, `amount`, `loyalty_reward_id`, …) but is **not yet documented** — join keys unverified. If a question needs it, treat answers as provisional until its dictionary lands.
- **Employee/test exclusion:** internal accounts are identifiable via `customer_type = 'internal'` (`@cafezupas.com`, `@tkxel.com`, `@tkxel.io`) — 119 ids / 736 orders in June 2026. The new `mapped_email_domain` column closes the old `mapped_domain` mart gap on this table. Unidentified internal orders still can't be flagged.
- The old `cowork_interim` and `nces_staging` scratch datasets were dropped 2026-07-22. Any saved query referencing them must be rebuilt against the marts (materialize intermediates in `scratch` if needed).

## When done

If you learned something new about these tables during the session (new gotcha, new canonical definition, data quality issue), do **not** edit this skill or any local copy — only the data steward commits to the repo, and session copies are discarded. Instead, create an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`) titled `KB finding: <short title>`, describing what you observed (include the query that surfaced it) and the proposed change. The steward reviews and merges vetted findings; the next session's fresh clone benefits automatically.
