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

> **🛑 Read the [pre-query clarification protocol](#pre-query-clarification-protocol-steward-rule-2026-07-28--mandatory) before running any query.** Five scope items — store 1111, date range, catering, Try 2 Combo inclusion, and named-product resolution — must be settled first. Items 4 and 5 were added 2026-07-28 after a session reported an item breakdown that was wrong by ~3x because it treated every `line_item_type = 'item'` row as a standalone sale and guessed at the product name.

Project: `marketing-data-442316`. The four approved tables for order/sales analysis:

- **`sales_ops.order_customer`** — one row per order. Sales, channel, customer identity. Default table for sales/order/customer questions.
- **`sales_ops.order_lines`** — one row per line element. Menu mix, items, modifiers, combos.
- **`sales_ops.order_sequence`** — one row per order that has a `mapped_cust_id` (all customer types). Order sequencing, recency, lifetime counts.
- **`sales_ops.customer_attribute`** — **one row per customer** (person only). Lifetime and trailing-window aggregates. **New 2026-07-29.** Use it for any "per customer" question — LTV, frequency, lapsed cohorts, store affinity — instead of re-aggregating `order_customer` by hand.

Full column docs in `data_dictionaries/`: `sales_ops.order_customer.md`, `sales_ops.order_lines.md`, `sales_ops.order_sequence.md`, `sales_ops.customer_attribute.md`. Read them before writing non-trivial queries.

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
2. **Always filter the partition column** on every table. `order_customer` and `order_sequence` use `business_date`; `order_lines` still uses `BusinessDate`. Never run unbounded scans.
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
| Lifetime orders per customer | `order_sequence.lifetime_customer_order_count` **with `customer_type = 'person'`** |
| Items sold | `order_lines` where `line_item_type = 'item'`, measure `sum(qty)` or `count(*)` |
| Item sales | `sum(item_gross_sales)` from `order_lines`. Discounts/promotions are order-level lines with no per-item allocation, so per-item **net is not computable** from the mart — use gross for item mix |
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
and ol.BusinessDate between @start and @end
and ol.store_id <> 1111
and lower(ol.item_name) like '%grilled cheese%'   -- broadest distinctive fragment, lowercased
group by 1, 2, 3
order by 4 desc
```

- Match on the **shortest distinctive fragment**, lowercased on both sides. `like '%ultimate grilled cheese%'` misses `Ultimate Grilled Cheese Box`; `like '%grilled cheese%'` finds the family.
- `item_name` is a **cluster field** — these filters are cheap. Still filter `BusinessDate`.
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

## SQL style (steward rule 2026-07-23 — MANDATORY)

All SQL — shown to users or executed — follows the steward's format so he can diagnose any query quickly. Match the build scripts in `sql/`:

1. **Fully qualify every table**: `` `marketing-data-442316`.dataset.table `` — never rely on a default project or dataset.
2. **Lowercase whenever possible**: keywords, functions, aliases. Column names as they exist in the schema (e.g. `business_date` on `order_customer`, `BusinessDate` on `order_lines`).
3. **Layout**:
   - select list: one column per line, **leading commas**, first column on the line after `select`; column aliases use `as`
   - CTEs: `with name as (` … `)`, chained as `, next_name as (`
   - `where 1=1`, then each condition on its own `and ...` line
   - each join on its own line, `on ...` on the next line, indented; short lowercase table aliases (`oc`, `ol`, `os`)

## Join patterns

**order_customer → order_lines** (note the two different partition column spellings):
```sql
select
...
from `marketing-data-442316`.sales_ops.order_lines ol
	join `marketing-data-442316`.sales_ops.order_customer oc
	on oc.brink_order_id = ol.brink_order_id
where 1=1
and ol.BusinessDate between @start and @end
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
and ol.BusinessDate >= date_sub(current_date('America/Denver'), interval 90 day)
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
date_trunc(ol.BusinessDate, week(monday)) as week
, case
    when ol.line_item_type = 'item' and ol.composite_item_id is null then 'Standalone'
    when ol.line_item_type = 'item' and ol.composite_item_id is not null then 'Combo component (priced)'
    when ol.line_item_type = 'modifier' then 'Combo slot (zero-priced)'
  end as sale_shape
, sum(ol.qty) as units
, round(sum(ol.item_gross_sales), 2) as gross_sales
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.BusinessDate between @start and @end
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
and ol.BusinessDate >= date_sub(current_date('America/Denver'), interval 30 day)
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

## 🔴 ACTIVE DEFECT — SessionM identity missing on recent days (found 2026-07-29)

**Before answering any customer-grain question that touches the last ~14 days, run the
detector below.** Whole business dates are landing with `sm_external_user_id` NULL, which
wipes out in-store loyalty scanners' identity (`mapped_cust_id` is
`coalesce(pulse_customer_id, sm_external_user_id)`). On an affected day, person orders fall
~38% — 2026-07-28 had 5,369 instead of the expected ~8,800.

**Sales, order counts and channel mix are completely unaffected and look normal.** Only
customer-grain metrics break: customer counts, first-time vs repeat, retention, recency,
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

Healthy is **~28–33%**. Under 15% means that date is corrupted — **say so in the answer and
exclude or caveat those dates** rather than reporting the number as-is. Two root causes are
logged (Asana 1216993827082929 boundary-day `>` vs `>=`, and 1216993694612234 intraday runs);
see `data_dictionaries/sales_ops.order_customer.md` for the full diagnosis.

## Gotchas checklist (scan before answering)

- **Partition columns differ by table**: `order_customer.business_date` and `order_sequence.business_date` vs `order_lines.BusinessDate`. A rename of `order_lines` is planned; until then, spell both correctly or the query fails or scans everything.
  - **It's the underscore, not the capitals.** BigQuery column references are case-insensitive, so `ol.businessdate` resolves fine against `BusinessDate`. The failure mode is mixing the two *names*: writing `BusinessDate` against `order_customer` gives `Unrecognized name: BusinessDate; Did you mean business_date?` (observed in an analyst MCP session 2026-07-27). Read the error literally — it names the table's real column.
- **`order_lines` has no `order_id`** — this now leads the gotcha list because it is the single most-repeated error in the query log: `Name order_id not found inside ol`, hit three more times on 2026-07-27/28 and **again on 2026-07-28 at 09:12** by the same analyst. The order key is `brink_order_id` on every one of these tables. The 2026-07-28 instance selected `ol.order_id` in a CTE and then joined `oc.brink_order_id = ol.order_id` — i.e. the correct column name was already in the query, on the other side of the join. Read your own join predicate before selecting.
- **Customer metrics need `customer_type = 'person'`**; sales metrics must NOT filter it. See the rule above.
- **Per-customer questions should use `sales_ops.customer_attribute`, not a hand-rolled `group by mapped_cust_id`** (new 2026-07-29). Lifetime orders, spend, AOV, recency, tenure, store affinity and trailing 30/90/365-day activity are all precomputed there — that's the whole point, so two sessions can't produce two different LTV numbers. It is already person-only (adding `customer_type = 'person'` errors), it has **no partition column**, and you must check `attribute_asof_date = yesterday` before trusting the window columns. See its section above.
- **Net sales is the `net_sales` column** — read it directly (calculated at build since 2026-07-24). `brink_net_sales` is Brink-given and validation-only; it runs ~0.0025% above calculated net ($479 on $18.9M in June 2026). There is no per-item or per-modifier net in the mart any more.
- **`is_catering = false` does not exclude catering-only items** (verified 2026-07-28). `Ultimate Grilled Cheese Box` — the catering box SKU — is flagged `is_catering = false` on `order_lines`. The flag describes the *order's* catering destination, not the *item's* nature, so catering-specific SKUs leak into non-catering item mix. Check the resolved item-name list for `Box` / `Tray` / `Party` variants explicitly.
- **`is_catering` is a superset of `revenue_category = 'Catering'`** — every catering-destination order is TRUE, plus a handful (48 in June 2026) that pulse flagged as catering on In-Store/Digital destinations. Before 2026-07-24 the flag missed all POS-only catering (641 orders / $70.7K net in June), so pre-rebuild catering numbers understate it.
- **Grain defect (1 order in ~50M):** `brink_order_id` 2279778269187 has two rows in `order_customer` — two pulse orders point at one Brink order, double-counting $263.99 across two customers. Immaterial to totals; use `count(distinct brink_order_id)` if exact uniqueness matters.
- **`order_sequence` history starts 2023-03-06**, not 2018. `customer_order_count = 1` means "first order since March 2023", not first-ever. Say so when presenting first-time-guest numbers.
- **`order_sequence` is a `left join`, never inner** — ~47% of orders have no `mapped_cust_id` and so no row; an inner join silently drops them.
- **`order_sequence` is NOT pre-filtered (changed 2026-07-27).** It holds every order with a `mapped_cust_id`, all customer types, and carries `customer_type` as a column. You must filter `customer_type = 'person'` yourself. Earlier versions were person-only — saved queries written against those are now wrong.
- **Sequence numbers are computed across all of a customer's orders, then you filter.** Filtering `customer_type = 'person'` selects rows but does not renumber them, so a mixed id (30 in June 2026) shows million-scale `customer_order_count` / `lifetime_customer_order_count` on its person rows — `19192` sits around 2.48M. Treat those as unreliable; recompute the window over person orders if you need true per-person sequencing.
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
  - **It is now also going stale**: on 2026-07-27 its `max(BusinessDate)` was **2026-07-25** while `order_customer` had loaded through 2026-07-27. Answers from it are silently 1–2 days short of current. Three separate users queried it during 2026-07-24 → 2026-07-26.
  - **🛑 If you are working from a saved query or a shared template, assume it targets this legacy table and rewrite it before running.** Query-log review counted **188 non-steward runs against `OrderCustomer` in the five business days 2026-07-24 → 2026-07-29**, and every one of the 115 raw-`pulse.*` wall breaches in that window came through it. The pattern is a *shared workbook* — byte-identical query text ran under two different users' accounts hours apart on 2026-07-28, eight of them inside a single minute (batch execution). Legacy schema is the tell: `businessdate`, `storeid`, `iscatering = 0`, `source`, `lifetime_order_cnt`, `first_order_datetime`. Translate to `business_date`, `store_id`, `is_catering = false`, `order_source`, and `order_sequence.lifetime_customer_order_count` — and if the template reached into `pulse.*` for identity, stop and say the mart can't answer it (Asana 1216992461499656).
  - `iscatering` on the legacy table is **INT64** (`iscatering = 0`); `is_catering` on the canonical mart is **BOOL** (`is_catering = false`). Writing `is_catering = 0` fails with `No matching signature for operator = for argument types: BOOL, INT64` (observed 2026-07-24) — a reliable sign a query was written against the legacy schema.
- **`sales_ops.store_info` column names are not the obvious ones** — it's `store_state`, not `state`; `store_city`, `store_zip`, `store_address`, `store_short_name`. Full column list: `store_id`, `store_name`, `store_address`, `store_city`, `store_state`, `store_zip`, `store_phone`, `store_short_name`, `store_tz`, `store_open_date`, `is_comp_store`, `latitude`, `longitude`, `weather_cluster_id`, `timezone_name`. Join `store_info.store_id = order_customer.store_id`. (Guessing `state` failed an analyst session 2026-07-24; a full dictionary is still pending — Asana 1216807058217060.)
- `sales_ops.order_discount` exists (order-level discount lines: `order_id`, `discount_id`, `name`, `amount`, `loyalty_reward_id`, …) but is **not yet documented** — join keys unverified. If a question needs it, treat answers as provisional until its dictionary lands.
- **Employee/test exclusion:** internal accounts are identifiable via `customer_type = 'internal'` (`@cafezupas.com`, `@tkxel.com`, `@tkxel.io`) — 119 ids / 736 orders in June 2026. The new `mapped_email_domain` column closes the old `mapped_domain` mart gap on this table. Unidentified internal orders still can't be flagged.
- The old `cowork_interim` and `nces_staging` scratch datasets were dropped 2026-07-22. Any saved query referencing them must be rebuilt against the marts (materialize intermediates in `scratch` if needed).

## When done

If you learned something new about these tables during the session (new gotcha, new canonical definition, data quality issue), do **not** edit this skill or any local copy — only the data steward commits to the repo, and session copies are discarded. Instead, create an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`) titled `KB finding: <short title>`, describing what you observed (include the query that surfaced it) and the proposed change. The steward reviews and merges vetted findings; the next session's fresh clone benefits automatically.
