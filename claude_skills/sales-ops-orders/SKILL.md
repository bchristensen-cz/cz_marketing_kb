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
>
>   **Observed failure mode 2026-08-12 — fix the name, never drop the filter.** An analyst MCP session hit the rename error (`Name businessdate not found inside ol`) and retried by **deleting the `order_lines` partition filter entirely** instead of correcting the spelling — a **14.5 GB** unbounded scan that then returned a plausible-looking answer. If a partition filter errors on the column name, the fix is `business_date`; removing the filter converts a loud error into a silent cost-and-correctness problem (the join to a 90-day CTE hid the unbounded scan from the result, not from the bill).
> - **`store_state` is now a native column.** "Market" questions need no `store_info` join on either side. It is NULL for stores missing from `store_info` (1111 and 999), so `store_id <> 1111` is now load-bearing for geography, not just for totals.
>
> `claude.order_lines` was simplified to a plain `select *` passthrough the same day.

> **⚠️ Changed 2026-07-31 — `order_lines` rebuilt again across full history. No schema change; two value changes and one new capability.**
> - **`is_catering` now matches `order_customer`.** The destination test evaluates first, so POS-only catering is finally caught on this table. June 2026: **+644 orders / +$71,586 gross** into catering. **Between 2026-07-24 and 2026-07-31 the two marts disagreed on catering** — `order_customer` had the fix, `order_lines` didn't. Any catering item number pulled from `order_lines` in that window understates, and a catering figure that mixed the two tables was internally inconsistent. Re-verified 2026-07-31: June 2026, 703,524 orders present in both, **zero disagreements**, 6,991 catering orders each side.
> - **Promotion lines are named** and stamped `'Promotion'` in `item_type`, `rev_center_name`, `parent_rev_center_name` and `parent_item_grp_name`. This **removes** essentially every NULL on those columns (only 2 surcharge lines keep a NULL `rev_center_name`), and **adds** a new way to get item numbers wrong — promotion names now collide with item names, and promotion lines pass the standalone-sale test. See [the exclusion rule](#discount-and-promotion-lines-masquerade-as-items--exclude-both-from-item-reports-steward-rule-2026-07-30-extended-2026-07-31).
> - **New: promotion-level reporting** off `line_item_type = 'promotion'` grouped by `description`.

> **⚠️ Changed 2026-08-12 — `order_lines` rebuilt across full history again. Discount lines renamed; `item_type` is now a closed 7-value domain (the latter deployed in a 2026-07-31 second pass but documented only now).**
> - **Discount lines no longer masquerade in `item_name`.** `item_name` is now the discount **program** name from the `brink.brinkDiscounts` master (`SessionM Loyalty`, `Online Discount`, `Team Member 100% Discount`, …), not the redeemed item's name. The redeemed-item text stays in `description` (which can also carry a team-member's personal name on employee discounts). Name-discovery no longer surfaces phantom *discount* rows; **promotion lines still do**. New capability: **discount-program reporting** — `group by item_name` on `line_item_type = 'discount'`, value = `sum(amount)` (negative), mirroring the promotion recipe.
> - **`item_type` is a closed 7-value domain across full history**: `Entree`, `Kids Meals`, `Beverage`, `Discount`, `Promotion`, `Surcharge`, `Other`. Rev-center names (`Desserts`, `Modifiers`, `Gift Cards`, …) **no longer appear in it** — a filter like `item_type = 'Desserts'` returns zero rows; menu categories live only in `rev_center_name`. Surcharge lines are stamped `'Surcharge'` on both columns, and `rev_center_name` / `item_type` have **zero NULLs** since 2026-05-01 (measured 2026-08-12).(#pre-query-clarification-protocol-steward-rule-2026-07-28--mandatory) before running any query.** Six scope items — store 1111, date range, catering, Try 2 Combo inclusion, named-product resolution, and the meaning of "delivery" — must be settled first. Items 4 and 5 were added 2026-07-28 after a session reported an item breakdown that was wrong by ~3x because it treated every `line_item_type = 'item'` row as a standalone sale and guessed at the product name.

> **🛠️ Steward checklist — any full-history rebuild of `order_lines` must be followed by a full-history rebuild of `sales_ops.discount_detail`** (added 2026-08-15). `discount_detail` is derived from `order_lines`, and its widest scheduled reload is 730 days — **65.1% of its rows (2,239,212 / −$15.6M) sit before that floor and are never refreshed by any scheduled run.** `order_lines` was restated across full history three times in the month to 2026-08-14 (07-30, 07-31, 08-12); each one silently changes the parent beneath that frozen block. The full-history build is the commented header in [`sql/sales_ops.discount_detail.sql`](../../sql/sales_ops.discount_detail.sql).

Project: `marketing-data-442316`. The five approved tables for order/sales analysis:

- **`sales_ops.order_customer`** — one row per order. Sales, channel, customer identity. Default table for sales/order/customer questions.
- **`sales_ops.order_lines`** — one row per line element. Menu mix, items, modifiers, combos.
- **`sales_ops.order_sequence`** — one row per order that has a `mapped_cust_id` (all customer types). Order sequencing, recency, lifetime counts.
- **`sales_ops.customer_attribute`** — **one row per customer** (person only). Lifetime and trailing-window aggregates. **New 2026-07-29.** Use it for any "per customer" question — LTV, frequency, lapsed cohorts, store affinity — instead of re-aggregating `order_customer` by hand.
- **`sales_ops.discount_detail`** — **one row per discount COMPONENT** (not per line, not per order). Discounts and promotions with loyalty / offer attribution. **New 2026-08-15.** Use it for any "what did we give away, and through what?" question. Users query **`claude.discount_detail`**.

Full column docs in `data_dictionaries/`: `sales_ops.order_customer.md`, `sales_ops.order_lines.md`, `sales_ops.order_sequence.md`, `sales_ops.customer_attribute.md`, `claude.discount_detail.md`. Read them before writing non-trivial queries.

## 🛑 First: which dataset should you query? (updated 2026-08-04 — routed by ROLE, not by access)

**Business questions run on the `claude` dataset — for everyone except the steward.** The `claude` views (`claude.order_customer`, `claude.order_lines`, `claude.loyalty_*`, `claude.store_info`, `claude.order_payment_tender`, `claude.discount_detail`) are the curated interface layer, and they are the only place a business answer should come from.

| Your role | Query | Notes |
|---|---|---|
| Anyone answering a business question (**all users — including accounts whose IAM happens to reach further**) | `claude.order_customer`, `claude.order_lines`, `claude.loyalty_*` | Views over `sales_ops` / `sessionM`. Read the differences below |
| The steward, building or validating marts (**that work only**) | `sales_ops.*` as documented throughout this skill | Full history, unmodified columns |

**Being able to read `sales_ops` is not a routing signal.** This section used to say "probe `sales_ops`; if it succeeds, use it." That broke on 2026-08-04, when a non-steward account with broader-than-standard IAM ran business queries against `sales_ops.order_customer` — the probe succeeded, so the old rule routed them to the tables. A successful `select` proves permission, not correctness: the two sides legitimately disagree (the `revenue_category` override, the 2023-01-01 history floor), so routing by access breaks the same-question-same-answer guarantee this KB exists for.

If `sales_ops` returns `Access Denied`, that's the wall working as designed — not a broken setup. If the `claude` views can't answer the question (pre-2023 history, a column they don't expose), say so and log it as a KB finding on the Claude Data Asana board — don't fall through to `sales_ops` or the raw datasets.

### The `claude` views are not byte-identical to their `sales_ops` parents

Three differences, each of which will make a `claude` answer disagree with a `sales_ops` answer. **Say which dataset you queried whenever a number is being compared to someone else's.**

1. **History is a rolling 3 years, and truncation is silent.** Both order views filter `business_date >= date_trunc(date_sub(current_date, interval 3 year), year)` — **2023-01-01** as of 2026-07-29. A question about 2022 returns **zero rows, not an error**, which presents as "no sales." Before reporting an empty or surprisingly small result, confirm the requested range sits inside the window, and state the floor when the question reaches near it.

2. **`revenue_category` is overridden in `claude`.** The view applies:
   ```sql
   case when oc.is_catering = true then 'Catering' else oc.revenue_category end as revenue_category
   ```
   So in `claude`, `revenue_category = 'Catering'` and `is_catering = true` are **equivalent**, and the documented superset/subset gotcha is collapsed away. In `sales_ops` they differ — `is_catering` is a superset (48 extra orders in June 2026 flagged catering on In-Store/Digital destinations). Consequence: a channel breakdown from `claude` assigns those orders to Catering; the same breakdown from `sales_ops` leaves them in In-Store/Digital. **Neither is wrong. They are different definitions.** Don't "fix" one to match the other — state which you used.

3. **`claude.order_lines` is now a plain passthrough.** It used to rename the partition column and left-join `store_info`; the 2026-07-30 full-history rebuild moved both upstream, so the view is `select *` over `sales_ops.order_lines` with the 3-year history filter. SQL written against either side is now identical apart from that floor.

4. **The market dimension is `store_state` on every table** — `sales_ops.order_customer`, `sales_ops.order_lines`, `claude.order_customer`, `claude.order_lines` and `store_info` all agree (settled 2026-07-30). Full state name (`Utah`, not `UT`). No join needed for a market breakdown on either side.

   > **⚠️ `order_customer.state` is GONE.** It was renamed to `store_state` on 2026-07-30 for consistency. Any saved query using `oc.state` now fails with `Name state not found inside oc`. The column had been documented under the old name, so this will hit saved work.
   >
   > **Deployment trap worth knowing** (hit 2026-07-30): `claude.order_customer` is defined as `oc.* except(...)`, and BigQuery **expands and freezes `*` at view-creation time**. After the base-table rename the view kept advertising `state` in `INFORMATION_SCHEMA.COLUMNS` while `select oc.state` errored and `select oc.store_state` worked — i.e. the schema metadata and the actual behaviour disagreed. **A `create or replace view` with identical text is required to refresh it.** If you rename a column on a base table, redeploy every `select *` view over it, then check `INFORMATION_SCHEMA` rather than assuming.

   There is also a **`claude.store_info`** view for the attributes that aren't denormalised (city, zip, address, open date, comp status, lat/long, timezone); it carries a `market` column aliasing `store_state`, and drops three non-store rows. See [`data_dictionaries/claude.store_info.md`](../../data_dictionaries/claude.store_info.md).

   > **⚠️ The market column is NULL for stores 1111 and 999** on both views — `store_info` has no row for either. A market breakdown **without `store_id <> 1111` grows a phantom tenth market**: 1,154 orders and **$117,196** over 2026-05-03 → 2026-06-27, appearing as an unnamed NULL group that reads like a data defect rather than the test store. Keep the filter and `coalesce` the label; never ship an unnamed group.

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

## Payment method / tender — `claude.order_payment_tender` (new 2026-08-05)

Payment questions ("how do people pay?", "cash vs card", "apple pay share") finally have a
home: **`claude.order_payment_tender`**, one row per `brink_order_id` on the same
population as `claude.order_customer`. The answer column is **`payment_tender`**
(lowercase; pulse digital-wallet names preferred over Brink tender names; `'discount'` and
`'no_payment'` fallbacks; split tenders comma-joined largest-first). It is a view over the
raw payment tables — **which remain off-limits directly**.

```sql
select
  opt.payment_tender
, count(*) as order_qty
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.claude.order_customer oc
	left join `marketing-data-442316`.claude.order_payment_tender opt
	on opt.brink_order_id = oc.brink_order_id
where 1=1
and oc.business_date between @start and @end
and opt.business_date between @start and @end
and oc.store_id <> 1111
group by 1
order by 2 desc
```

Before using it, scan the gotchas in
[`data_dictionaries/claude.order_payment_tender.md`](../../data_dictionaries/claude.order_payment_tender.md)
— the four that produce wrong answers fastest:

1. **The latest loaded `business_date` shows `'stripe'` as a placeholder** for online card
   orders until `pulse.stripe_order_payments` catches up (10.2% of the freshest day,
   verified 2026-08-05; zero on all earlier days). Exclude or annotate the latest day in
   any tender-mix report.
2. **A tender breakdown is not a channel breakdown** — `doordash` here is how an order
   *paid*, not the `Third_Party` channel; that axis is `revenue_category`.
3. **`total_payment_amount` is gross tendered (includes tips), not sales** — quote
   `net_sales` from `order_customer` for sales, always.
4. **Split tenders make `payment_tender` a non-enum** — `'cash, visa'` ≠ `'visa, cash'`;
   bucket comma values as `'split'` for clean breakdowns (~0.3% of orders).

## Repeat-rate and time-to-second-order cohorts (rules added 2026-08-13)

These are the most-requested customer questions in the query log and the easiest to get
quietly wrong. Three rules, all observed being broken in a live analyst template on
2026-08-13.

### 1. A fixed-window repeat rate is only quotable for cohorts that have finished the window

**Right-censoring is the single largest error source in this metric class.** A 90-day repeat
rate for a cohort whose first order was three weeks ago is not a low repeat rate — it is an
unfinished measurement. Pooling matured and unmatured cohorts into one number understates it
badly, and the result looks completely plausible.

Measured 2026-08-13 on `claude.order_customer` (person only, stores 1111/999 excluded),
90-day second-order rate by first-order cohort month:

| Cohort month | Days elapsed for the newest member | Cohort n | 90-day repeat | 30-day repeat |
|---|---|---|---|---|
| 2026-04 | 105 | 28,826 | **33.6%** | 23.1% |
| 2026-05 | 75 | 27,422 | 33.2% | 23.1% |
| 2026-06 | 44 | 25,887 | 28.2% | 22.0% |
| 2026-07 | 13 | 32,806 | 16.2% | 15.7% |
| 2026-08 | 0 | 15,007 | **7.7%** | 7.7% |

**The tell that a window is unfinished is the 90-day and 30-day columns converging** (7.7 = 7.7):
when a longer window stops exceeding a shorter one, the window hasn't elapsed and neither
number is real.

> **⚠️ But do NOT read this table as "the decline is just elapsed time" — that was the first
> conclusion drawn here on 2026-08-13 and it was wrong.** Holding exposure constant at 7 days
> (first orders on or before 2026-08-06) and splitting on whether the first order was a guest
> order, the identified-customer rate **rises**: 2026-04 **11.0%** (n=28,822) → 07 **12.4%**
> (n=14,921) → 08 **14.0%** (n=3,208). Guest first orders repeat at roughly a third of that —
> **4.0%** in July (n=17,885) and **4.5%** in August (n=3,234).
>
> The headline decline is therefore a **composition change, not a behaviour change and not only
> censoring**: guest first orders are **54.5%** of the July cohort and **50.2%** of August's,
> and they barely repeat. See the structural cause in the next box. Censoring is real and still
> disqualifies immature cohorts — it just isn't what drives this particular table.
>
> Generalisable lesson: **when a rate falls, test composition before attributing it to the
> measurement.** Two plausible mechanisms were available here (unfinished window, changed mix)
> and the obvious one was not the operative one. An equal-exposure split settles it cheaply.

> **🚨 Guest checkout manufactures first-time customers — this distorts every cohort and
> new-customer count** (measured 2026-08-13). **17,887 of July's 19,273 guest orders (92.8%)
> carry `customer_order_count = 1`.** A guest order generally creates a fresh `mapped_cust_id`,
> so nearly every one presents as a brand-new customer, and a customer id that exists for a
> single order is *structurally incapable* of recording a second one. Consequences:
>
> - **"New customers" is inflated.** The July first-order cohort grew **27%** (25,887 → 32,806)
>   while total July orders **fell** (713,137 → 683,228) — more new customers on fewer orders is
>   the signature of identity fragmentation, not acquisition.
> - **Repeat and retention rates are mechanically depressed** from 2026-07-01 onward, by an
>   amount that tracks guest-checkout share rather than anything customers did.
> - **Never present a first-time-vs-repeat or cohort trend spanning 2026-07-01 without splitting
>   on `is_guest_order`** (or excluding guest first orders and saying so). A blended series across
>   that date is not comparable to itself.
>
> Root cause is the CRM identity-hygiene problem already scoped in the backlog: guest checkout
> took duplicate-id creation from ~28 to ~280 per business day (21.9% of new ids). Until
> `customer_id_map` / `canonical_cust_id` lands, `mapped_cust_id` is not a stable person key for
> post-2026-07 cohorts.

Rules:

- **Only include cohorts where `date_diff(current_date, cohort_end, day) >= window_days`.** For a
  90-day metric as of 2026-08-13, the newest quotable cohort is first orders on or before
  **2026-05-15**. Truncate the cohort list — don't caveat it and ship it anyway.
- **Never let a cohort window end in the future.** Observed 2026-08-13: an analyst template
  hard-coded `between date('2026-06-15') and date('2026-09-13')` — a month past today — so the
  cohort was inherently a third unmeasurable, and the single pooled rate it returned blended
  28% cohorts with 8% cohorts.
- If someone wants recent-cohort signal, give them a **shorter window that has elapsed** (7- or
  14-day repeat) rather than a censored 90-day figure. Say which window you used.

### 2. Key cohorts on `mapped_cust_id`, and don't rebuild "first order" by hand

`customer_order_count = 1` on `claude.order_customer` already marks a customer's first order,
and `days_since_prev_order` on the `= 2` row already gives days-to-second — both folded in
from `order_sequence`, both person-filterable via `customer_type`. Use them.

The anti-pattern (live 2026-08-13, ~8 queries): a `min(order_datetime) group by email` CTE over
`sales_ops.order_customer` **with no `business_date` filter at all** — an unbounded scan of a
**13.2 GiB / 50.7M-row** table (logical size, measured 2026-08-13; it is rebuilt hourly, so
re-measure before quoting), repeated per query, to re-derive a column that already exists. Deriving
"first ever order" *feels* like it needs full history, which is exactly why this template never
got a partition filter. It doesn't: `customer_attribute.first_order_datetime` is precomputed per
customer with no partition column to filter, and the sequencing columns are on the order grain.

> ⚠️ The folded sequencing columns (`customer_order_count`, `days_since_prev_order`) live on
> **`claude.order_customer`**, not on `sales_ops.order_customer` — selecting them there fails with
> `Name customer_order_count not found inside oc`. On the `sales_ops` side they're in
> `sales_ops.order_sequence`.

Also: cohorts keyed on `lower(coalesce(mapped_email, email))` instead of `mapped_cust_id` are a
recurring defect (2026-08-11, -12, -13). Email is not the canonical identity key —
`mapped_cust_id` is — and an email-keyed cohort silently merges the duplicate-identity clusters
the CRM hygiene project exists to resolve. Emails are now lowercased at build, so the old
`lower()` justification for keying on email no longer applies either.

### 3. Customer cohorts require `customer_type = 'person'`

Every metric in this section is customer-level, so hard rule 6 applies without exception. A
cohort built without it pulls the aggregator id (~108K orders/month) and shared kiosk terminals
into "new customers." Observed missing from all 12 cohort queries on 2026-08-13.

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
2. **Always filter the partition column** on every table. It is **`business_date` everywhere** as of 2026-07-30 — `order_customer`, `order_sequence` and `order_lines` all agree. Never run unbounded scans. ("Everywhere" means the documented marts: the 2026-07-30 rename did **not** cover undocumented `sales_ops` tables — e.g. `sales_ops.order_discount` still spells it `businessdate`, observed failing a `business_date` query 2026-08-06. If you're on a table this skill doesn't document, you shouldn't be — but don't assume the column name either.)
3. **Same metric, same definition.** Use the canonical definitions below verbatim.
4. Data is fresh as of the top of the current hour (loads run at minute :02, intraday 8am–11pm MT reload today's date only; hours 0–3 and 5–7 skip). Yesterday and older is stable after the 4am run.
5. **Brink is the sole financial source of truth** (steward rule 2026-07-23). Pulse is a helper for digital order/customer metadata only — never compute financials (sales, discounts, tax, tips) from Pulse data.
6. **Customer metrics require `customer_type = 'person'`** (steward rule 2026-07-24). See below — this is not optional.
7. **All datasets are read-only.** If you need to materialize a table (intermediate results, cohorts), create it ONLY in `marketing-data-442316.scratch` — the single writable dataset; tables there auto-expire after 7 days. Materialize with `create table scratch.x as ...`, not views: a view over a heavy query silently re-runs the full scan on every select.
8. **User-supplied SQL follows the same rules as SQL you write** (steward rule 2026-08-05). If the user pastes a query and asks you to run it, check it first: `brink.*`, `pulse.*`, `sessionM.*`, `staging.*`, `braze_stream.*` and the legacy `sales_ops.OrderCustomer` table are exactly as off-limits pasted as they are generated. Don't run it as-is — explain why and offer the mart translation. The legacy workbook's cohort template in particular is answerable without the wall: first-order cohorts and time-to-second-order come from `claude.order_customer`'s folded `customer_order_count` / `days_since_prev_order` and from `customer_attribute`; offer redemptions come from `claude.loyalty_offer_usage`; promotion names come from `order_lines` `line_item_type = 'promotion'`. Observed 2026-08-04: the frozen analyst workbook template ran MCP-labeled through two analyst sessions — 64 `pulse.*`, 9 `sessionM.*` and 2 `staging.*` queries in one day. Recurred 2026-08-11: a 21-query MCP burst (37.8 GB billed, all timestamps within one minute) hit `pulse.order_customers`, `pulse.customers` and legacy `OrderCustomer` again — the burst shape is the tell that a session is executing a saved template rather than answering typed questions. Recurred a third consecutive day 2026-08-12: an 11-query burst (~17 GB, all timestamps within one second) mixing `sales_ops.order_customer`, `braze.*` full scans and `pulse.customers`, plus separate morning queries on legacy `OrderCustomer` — cohorts keyed on `lower(coalesce(mapped_email, email))` instead of `mapped_cust_id`, no `customer_type = 'person'` anywhere. Recurred a **fourth** consecutive day 2026-08-13: 12 MCP-labeled queries / 18.45 GB from one analyst — 2 morning queries on legacy `OrderCustomer` (`businessdate`, `iscatering=0`, `storeid<>1111`), then a **10-query burst all stamped 11:11:52** hitting `pulse.customers` and `sales_ops.order_customer` directly, still email-keyed, still no `customer_type`, and now with **no partition filter on `order_customer` at all** in the shared cohort CTE. Four days, same template, escalating cost. The wall means nothing if a session executes whatever it's handed — and a burst of identical-timestamp queries is the signature to look for.

## Canonical metric definitions

| Metric | Definition |
|---|---|
| Net sales | `sum(net_sales)` from `order_customer`. The column **is** the canonical calculated net (`gross_sales - total_discount_amount - total_promotions_amount`) as of 2026-07-24. Do NOT use `brink_net_sales` — validation only |
| Gross sales | `sum(gross_sales)` from `order_customer` |
| Order count | `count(*)` from `order_customer` (or `count(distinct brink_order_id)` — see the grain defect note) |
| Average check | `sum(net_sales) / count(*)` from `order_customer` |
| Identified customers | `count(distinct mapped_cust_id)` where `mapped_cust_id is not null` **and `customer_type = 'person'`** |
| Guest orders | `is_guest_order = true` (BOOLEAN since 2026-07-27, was 0/1). **Digital-only and effectively zero before 2026-07-01** — `false` is the default, not "logged in". Always state the denominator; see the gotcha |
| Catering | `is_catering = true` for the business line; `revenue_category = 'Catering'` for channel reporting (see gotchas — they differ slightly) |
| Channel | `revenue_category` (In-Store, Digital, Third_Party, Catering, Fundraiser) |
| Delivery (first-party) | `destination = 'CZ Delivery'` (steward rule 2026-08-04). Marketplace orders (`revenue_category = 'Third_Party'`) are NOT "delivery" unless explicitly requested — see protocol item 6 |
| Digital source | `order_source` (NULL = in-store POS) |
| First-time order | `order_sequence.customer_order_count = 1` **with `customer_type = 'person'`** — only back to 2023-03-06 (see gotchas) |
| Repeat order | `order_sequence.customer_order_count > 1` **with `customer_type = 'person'`** |
| Lifetime orders per customer | **`customer_attribute.lifetime_order_count`** — one row per person customer, already person-only and store-1111-excluded. **`order_sequence.lifetime_customer_order_count` was DROPPED 2026-07-29** — any query using it now errors |
| Items sold | `order_lines` where `line_item_type = 'item'`, measure `sum(qty)` or `count(*)`. **This is the default measure for item questions** — see the units-vs-dollars rule below |
| Item sales | `sum(item_gross_sales)` from `order_lines`. **Opt-in, not the default** — combo pricing distorts it (see below) |
| Item net sales | `sum(item_net_sales)` from `order_lines` — live, fully populated, safe to report **when asked**. Runs 2.3–3.8% under gross depending on sale shape, and does **not** reconcile to order-level `net_sales`; say so in the same breath. See the gotcha below |
| Menu mix name | `item_name` (size-normalized) + `item_size`; menu category via `rev_center_name` (`item_type` is only the closed 7-value rollup Entree / Kids Meals / Beverage / Discount / Promotion / Surcharge / Other as of 2026-08-12 — category values like `Desserts` return zero rows there) |

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

> **⚠️ Anti-pattern — "loyalty orders" is NOT `mapped_cust_id is not null`** (observed in analyst MCP SQL 2026-08-11, labeled `loyalty_orders`). An *identified* order is not a *loyalty* order: `mapped_cust_id` is populated on kiosk, internal and aggregator orders too (38% of identified orders — the aggregator id alone is ~108K orders/month), so this definition counts DoorDash feed orders as "loyalty." Call `mapped_cust_id is not null` what it is — **identified orders** — and note that the KB has no canonical "loyalty order" metric on `order_customer` yet: loyalty *membership* lives in `claude.loyalty_user` / `account_type`, and in-store scan reporting currently lives only in the steward's QuickSight tables (`shared_datasets.qs_in_store_app_scans_by_store`, undocumented — Asana 1216920434852093). If a user asks for loyalty penetration, surface that gap instead of quietly substituting identified-order share.

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

### Discount AND promotion lines masquerade as items — exclude both from item reports (steward rule 2026-07-30, extended 2026-07-31)

A discount applied to an item produces a line carrying **the item's own name** in `item_name`, with `line_item_type = 'discount'`. Over 2026-05-03 → 2026-06-27 the four-item test set had 319 such lines: $0 gross but **319 units**. *(Historical behavior — the discount half of the name collision was fixed upstream 2026-08-12; see the box below. The unit-count inflation still applies to both line types.)*

Two consequences. They inflate any unit count not filtered to `line_item_type in ('item','modifier')`. And, more insidiously, they surfaced as a **separate candidate row in the name-discovery query** (protocol item 5) — so a user resolving "Hot Honey Cottage Cheese Bowl" saw two entries for one product with no way to tell which is real.

> **✅ Partly fixed upstream 2026-07-30.** The build script now stamps discount lines consistently: `rev_center_name`, `item_type`, `parent_rev_center_name` and `parent_item_grp_name` are **all `'Discount'`**. Verified live — all 113,136 discount lines in that window carry the identical set. Previously `item_type` held the *item's name*, which is why it couldn't be filtered on. It can now. `item_name` still carries the item's name by design, so the discovery-query collision remains and the filters below are still required.

> **🆕 2026-07-31 — promotion lines joined the problem.** The build now resolves promotion names from `brink.brinkPromotions`, so a promotion line carries `item_name = 'Free Try 2 Combo'` / `'Free Mini Strawberry Cup'` / `'Grand Opening 100%'` where it used to carry NULL. It also carries `qty = 1` and `item_gross_sales = 0`, and it **passes the standalone-sale test** — `parent_rev_center_name` and `rev_center_name` are both `'Promotion'`, so a sale-shape breakdown files promotions under "sold alone" exactly as discount lines already did. Volume over 2026-05-03 → 2026-06-27: 1,111 lines / 1,111 phantom units.
>
> A **second pass the same day** added `rev_center_name = 'Promotion'`, so all three markers now agree and any of them excludes promotions. Earlier on 2026-07-31 `rev_center_name` was NULL on these rows and only `item_type` / `line_item_type` worked — if you are reading a result set or a saved query from that window, that's why.

> **✅ 2026-08-12 — the discount half of the name collision is fixed upstream (full history restated).** Discount lines now carry the discount **program** name in `item_name` (`SessionM Loyalty`, `Online Discount`, …), resolved from `brink.brinkDiscounts` per (id, store); the redeemed item's name lives only in `description`. The name-discovery query no longer surfaces phantom *discount* rows for a product. Verified live 2026-08-12: 0 blank `item_name`; ~3–7% of a day's discount lines fall back to the order-level name and then the generic `'Discount'` (missing/blank master rows). **Promotion lines still collide** — everything in the 2026-07-31 box above still applies to them — and both line types still inflate unfiltered unit counts, so the three-marker exclusion below is still required verbatim. Side effect worth knowing: `description` on team-member discount lines can carry an **employee's personal name** — don't surface it in shared reports without checking.

Filter them in **both** the discovery query and the metric query:

```sql
and ifnull(ol.item_type, '') not in ('Discount','Promotion')
and ifnull(ol.rev_center_name, '') not in ('Discount','Promotion')
and ifnull(ol.line_item_type, '') not in ('discount','promotion')
```

Since the 2026-07-30/31 fixes, `item_type not in ('Discount','Promotion')` is a reliable test on its own — but keep all three conditions: they're free, and they still hold for any pre-fix data you compare against.

> **⚠️ Wrap every string exclusion in `ifnull` — the bare form silently drops rows** (steward rule 2026-07-30). `col <> 'Discount'` evaluates to NULL, not TRUE, on a NULL `col`, and BigQuery's `WHERE` treats NULL as false. Those rows vanish with no warning. Re-measured 2026-07-31 over 2026-05-03 → 2026-06-27 (stores 1111 and 999 excluded, 10,018,577 lines): **`item_type` 0 nulls, `parent_rev_center_name` 0, `item_name` 0, `rev_center_name` 2** (both surcharge lines — stamped `'Surcharge'` by the second pass, so **0** as of 2026-08-12). The earlier counts (1,111 / 1,113 / 497) were *all* unnamed promotion lines; the 2026-07-31 build named them and then stamped their revenue center, which removed the cause on every column. **Keep the `ifnull` habit anyway** — it costs nothing, and the next upstream gap will arrive unannounced. Note also how fast these numbers moved: the same column went 1,113 nulls → 1,113 → 2 inside one day, which is why a skill should date every measured claim rather than state it as a property of the table. The same trap sits inside combo-shape logic: `parent_rev_center_name = rev_center_name` is NULL-unsafe, so use `ifnull(ol.parent_rev_center_name, '') = ifnull(ol.rev_center_name, '')` when testing for a standalone line.

### Promotion reporting is now answerable (new 2026-07-31)

"What did we give away on promotion X?" used to be unanswerable from the marts — 71.4% of promotion lines (171,522 of 240,191 in full history) had a NULL name because `brinkOrderPromotion.Name` is mostly empty. The build now joins the `brinkPromotions` name master on **(promotion id, store)**; names are store-specific, so an id-only join would mislabel. Promotion value = `sum(ol.amount)` (negative), **not** `item_gross_sales` (always 0). Full history back to 2018-08-28; 4 lines in all history have no master row and read `'Promotion'`.

```sql
select
  ol.description as promotion_name
, count(*) as lines
, round(sum(ol.amount), 2) as promotion_amount
from `marketing-data-442316`.claude.order_lines ol
where 1=1
and ol.business_date between @start_date and @end_date
and ol.line_item_type = 'promotion'
and ol.store_id not in (1111, 999)
group by 1
order by promotion_amount
```

### Discount-program reporting is now answerable (new 2026-08-12)

Same shape as promotion reporting, but group by **`item_name`** — on discount lines it now carries the program name from the `brink.brinkDiscounts` master. Do **not** group by `description` for program-level questions: it holds the free-text POS name (often the redeemed item, sometimes an employee's personal name — don't surface it unchecked).

```sql
select
  ol.item_name as discount_program
, count(*) as lines
, round(sum(ol.amount), 2) as discount_amount
from `marketing-data-442316`.claude.order_lines ol
where 1=1
and ol.business_date between @start_date and @end_date
and ol.line_item_type = 'discount'
and ol.store_id not in (1111, 999)
group by 1
order by discount_amount
```

Full history restated, so this works back to 2018. ~3–7% of a day's lines land in the generic `'Discount'` bucket (missing or blank master rows) — say so when a user needs exact program totals.

> **🆕 Superseded for most questions by `claude.discount_detail` (2026-08-15).** The recipe
> above still works and is the cheapest way to get a raw program total, but it can't tell you
> *how* a discount was redeemed — points vs reward vs offer, which offer, in-store vs
> integrated. Use `claude.discount_detail` for anything past a flat program total. See the
> section below.

## Discount and loyalty-giveaway questions — `claude.discount_detail` (new 2026-08-15)

"What did we give away, and through what?" now has a home. One row per **discount
component**, with loyalty and offer attribution joined on. Full docs:
[`data_dictionaries/claude.discount_detail.md`](../../data_dictionaries/claude.discount_detail.md).
It is the sanctioned wrapper around `pulse.order_discounts`, `sessionM.transaction_discounts`
and `sessionM.user_offers` — **never query those directly.**

### The grain is components, not lines — get this right first

Brink emits **exactly one** `item_id = 643536109` ("Online Discount") line per order. Where
Pulse holds several discount components under it, the table **splits that one Brink amount
across them** proportionally, so a single Brink line can produce several rows each with its
own `discount_type`. Row count runs **~1.5% above the source line count** (3,440,131 vs
3,388,269 full history, 2026-08-14). That surplus is the design.

- **`discount_amount` is the only summable money column.** It reconciles to `order_lines`
  exactly — **−$25,967,881.35 on both sides**, full history, identical filters.
- **`count(*)` counts components**, not discounts and not orders. For discounts use
  `count(distinct concat(brink_order_id, '-', item_id))`; for orders,
  `count(distinct brink_order_id)`.
- **Joining to `order_customer` requires aggregating this table first**, or the component
  split multiplies the sales side. See the discount-rate recipe in the dictionary.

```sql
select
  dd.discount_type
, count(distinct dd.brink_order_id) as orders
, round(sum(dd.discount_amount), 2) as discount_amount
from `marketing-data-442316`.claude.discount_detail dd
where 1=1
and dd.business_date between @start_date and @end_date
group by
  dd.discount_type
order by
  discount_amount
```

### `discount_origin` is not a channel

Values: `In-Store`, `Online`, `Third Party`, `Outdoor Kiosk`. **The column deliberately mixes
two axes** — `Outdoor Kiosk` and `Third Party` key on the *order*, `Online` and `In-Store` key
on the *discount mechanism*. That's why Kiosk carries 9 distinct discount types off 799 lines
(30 days to 2026-08-14) while Online carries 4. `Online` includes phone-entered catering that
flowed through the integrated bucket. **For channel questions the axis is `revenue_category`,
always.**

### `discount_type` is an open domain

Curated labels for the programs that matter, then `else item_name`. **There is no `'Other'`
bucket** — an unmapped Brink program surfaces under its own name on day one. 28 distinct
values across full history, **zero NULLs** in 3.44M rows. Most of the long tail is the
pre-2023 Punchh/OLO era; two label seams there (`NewTeamMemb Family Meal` vs
`New Team Member Family Meal`, and `Punchh Loyalty` vs `Punch Loyalty`) need collapsing by
hand before presenting a full-history breakdown.

### 🚨 `Error` is a health signal — and today always fails it

`Error` = an integrated line with neither a Pulse component type nor a `Third_Party` category.
**On any closed business day it runs at 0–1 lines.** Two ways it fires:

1. **Today, always.** Pulse hasn't loaded the current business date, so **~76% of today's
   integrated lines read `Error`** (531 of 694, measured 2026-08-14, against 0 on every closed
   day in the prior six weeks). It self-heals at the next 4am pass. **Never report today's
   discount mix intraday** — answer through yesterday and say why, same as the customer-grain
   rule for today.
2. **A closed day above ~1 line means the build's 60-day source lookback got too short.** That
   is a real defect — raise it, don't explain it away.

## ⚠️ In an incremental build, never window a DIMENSION by the fact window (general rule, 2026-08-15)

This one generalises to **every** scheduled script in `sql/`, and it produced the nastiest bug
found in the `discount_detail` review — worth stating as a rule rather than a war story.

An incremental script reloads a window of the **fact** (here `business_date >= start_date`,
matching the `delete`). The temptation is to put the same `start_date` on every source CTE for
pruning. **Don't** — the lookup tables are keyed on *different clocks*:

| Source | Its date column means | Not the same as |
|---|---|---|
| `sessionM.user_offers.create_date` | when the offer was **issued** | when it was redeemed |
| `pulse.order_discounts.created_at` | when the order was **placed** | when it was fulfilled (`business_date`) |
| `sessionM.transaction_headers.create_date` | the sessionM record date | either of the above |

Two measured consequences from applying `start_date` directly:

- **Offer attribution went non-deterministic by day of week.** Monday's 5-week reload resolved
  offers issued 8–35 days back; Tuesday's 8-day reload wiped them again. **275 rows differed
  over an 8-day window** — same row, different `offer_name` depending on which run last touched
  the partition. That breaks the same-question-same-answer guarantee this KB exists for.
- **Catering was silently dropped.** 31 orders lost their Pulse match, **27 of them catering**,
  with up to **33 days** between order placement and fulfillment — and those rows reclassified
  to `Error` rather than erroring out.

Two valid fixes, both verified set-identical to a full-history build:

1. **Filter the lookups by the order KEYS in the window**, not by their own timestamps
   (`od.order_id in (select pulse_order_id from window_orders)`). Exact, no lead-time
   assumption, ~5× the scan.
2. **Widen the reload windows so the lookback covers the tail** — what `discount_detail`
   ships with (120d daily / 380d Monday / 730d monthly, each with a further `- 60` on the
   sources). Cheaper, but it is a *bet* on lead times and needs an alarm. Here that alarm is
   the `Error` bucket.

Related traps in the same family:

- **Wrap the `delete` + `insert` in `begin transaction; … commit transaction;`.** BigQuery
  scripts are **not** atomic. A failed insert after a committed delete leaves a hole the width
  of the reload window — returning **zeros, not an error** — and intraday runs that only cover
  today won't heal it until the next 4am pass.
- **A wide reload window is not a full rebuild.** Whatever sits before the widest window is
  frozen forever. On `discount_detail` that is **65.1% of rows (2,239,212 / −$15.6M)**. Since
  `order_lines` was restated across full history **three times in the month to 2026-08-14**,
  re-running the full-history build of any derived table is a **required step in the
  `order_lines` rebuild checklist**, not a nice-to-have.
- **`current_date` is UTC.** Intraday runs firing 8pm–11pm Denver are 2am–5am the *next* UTC
  day, so a bare `current_date` silently means "tomorrow" for a third of the schedule. Pin
  `current_date('America/Denver')` in every scheduled script and every assertion. This cost
  real time during the `discount_detail` review: three test builds either side of the rollover
  picked different windows and the diff read as a logic regression when it was a clock
  difference.

### Store 999 joins 1111 in the exclusion list (steward rule 2026-07-30)

`store_id = 999` has **no `store_info` row**, so `store_name` and `store_state` are both NULL and it forms a second unnamed group in any store or market breakdown. It is tiny — 4 lines over 2026-05-03 → 2026-06-27 against store 1111's 24,128 — which is exactly why it survives review: it's too small to notice and too nameless to explain. Verified 2026-07-30 that 1111 and 999 are the **only** two store ids with a NULL name or state, and that `store_name` is otherwise unique across all 89 real stores (no dedup needed, no `store_id` prefix required for a readable label).

Use `and ol.store_id not in (1111, 999)` on `order_lines`, and the same on `order_customer`.

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

### 6. "Delivery" means CZ Delivery — never sweep in the marketplaces (steward rule 2026-08-04)

When an employee says "delivery" they mean the company's own delivery channel:

```sql
and oc.destination = 'CZ Delivery'
```

(`revenue_category = 'Digital'`.) They do **not** mean DoorDash / UberEats / GrubHub / Postmates marketplace orders (`revenue_category = 'Third_Party'`) — even though a third-party company physically carries CZ Delivery orders too. That's precisely how this burned a real answer on 2026-08-03: the delivery provider's name in the conversation pulled the marketplaces into the filter (`lower(destination) like '%delivery%' or like '%doordash%'`).

Measured 2026-05-01 → 2026-07-31, stores 1111 and 999 excluded:

| Scope | Orders | Net sales |
|---|---|---|
| `destination = 'CZ Delivery'` | 37,396 | $1.49M |
| Marketplaces (DoorDash, UberEats, GrubHub, Postmates) | 322,728 | $9.00M |
| Catering delivery destinations (`Catering Online Delivery`, `EZ Cater Delivery`, `Catering Delivery`) | 14,689 | $5.13M |

The naive LIKE read is roughly **9x** the intended number. `like '%delivery%'` also catches the catering delivery destinations — that scope is item 3's question (catering), not this one. If the user plausibly means third-party or "all delivered orders," ask, with these sizes in the option labels; when unstated and unambiguous, default to `'CZ Delivery'` and say so in the assumptions line.

Remaining defaults unless the user says otherwise: include employee-discount orders, all channels. State all assumptions in the answer when they matter.

### 🟡 Observed but NOT yet canonical: the internal-traffic exclusion (logged 2026-07-31)

The steward's own manual customer-behaviour SQL consistently strips three populations that this
skill's documented default **keeps**:

```sql
and coalesce(oc.source, '') <> 'Outdoor Kiosk'
and coalesce(oc.mapped_email_domain, 'b') not in ('cafezupas.com', 'tkxel.com')
```

i.e. shared kiosk terminals, employees (`cafezupas.com`) and the outsourced dev team
(`tkxel.com`). Note the null-safe `coalesce` on both — the bare `<>` / `not in` forms would drop
every NULL-domain row, which is most in-store orders.

**Do not apply this silently.** It is recorded here because it was observed repeatedly in steward
work, not because it has been ratified, and it materially changes customer counts and frequency.
Two conventions genuinely conflict: the kiosk exclusion overlaps `customer_type = 'kiosk'` (already
the canonical control), and the domain exclusion contradicts "include employee-discount orders."
If a question is about *customer behaviour* rather than *sales*, raise it as a scope choice with
the user and say which you used. Steward decision pending — Asana 1217062310224330.

**New evidence 2026-08-04 — the default drive-thru account** (observed in steward CLV-model SQL):
a third population joins the candidate exclusion set. Stores ring drive-thru orders on a shared
account with a `cafezupas.com` email, so the steward's model **nulls the identity** rather than
dropping the order:

```sql
case
  when (lower(oc.email) like '%@cafezupas.com'
        or lower(oc.mapped_email) like '%@cafezupas.com'
        or lower(oc.mapped_email_domain) = 'cafezupas.com')
   and oc.destination in ('Drive Thru', 'DT Order')
  then null else oc.mapped_cust_id
end as mapped_cust_id   -- drop the default drive-thru id, keep the order
```

Note the shape: it's an **identity fix, not an order exclusion** — sales totals keep the order;
customer counts and frequency stop attributing hundreds of orders to one phantom "customer."
Same pending decision, same Asana task.

> The legacy column name is `mapped_domain` on `sales_ops.OrderCustomer`; on the current
> `order_customer` / `claude.order_customer` it is **`mapped_email_domain`**.

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
| **Combo slot (zero-priced)** | `line_item_type = 'modifier'` **and `parent_rev_center_name = 'Try 2 Combo'`** | No — ~$0.01/line; the entrée recorded as a modifier selection |

#### Item questions default to UNITS — dollars are opt-in and warned (steward rule 2026-07-30)

The three sale shapes carry **three different prices for the same sandwich**, so a per-item
dollar total is not the figure it looks like. Ultimate Grilled Cheese, 2026-05-03 →
2026-06-27, non-catering, store 1111 excluded:

| Sale shape | Units | Gross | **Per unit** |
|---|---|---|---|
| Sold alone | 24,125 | $215,890 | **$8.95** ← menu price |
| In a combo, paid | 47,461 | $315,280 | **$6.64** ← allocated, 26% under menu |
| In a combo, free | 37,623 | $386 | **$0.01** |
| **Blended** | **109,209** | **$531,556** | **$4.87** |

**A blended average price lands 46% below the menu price** — and it moves with combo mix,
not with any pricing decision. Two items on the same menu price will show different average
prices purely because one gets bundled more often. This is the most quotable wrong number
the mart can produce.

- **Report units unless dollars were explicitly asked for.**
- **When you do report dollars**, say in the same sentence that combo components are booked
  at an allocated price and that this is *gross* — it will not tie to net sales.
- **A revenue number someone needs to reconcile is not an item question.** Use order-level
  `net_sales` from `order_customer` and say why you switched.

`artifacts/item-sales-builder.html` enforces this same default, so chat answers and the
report builder agree.

#### Equivalent formulation without `line_item_type` (verified 2026-07-30)

`line_item_type` is a POS-internal concept — **"item" vs "modifier" means nothing to a
business user**, and exposing it in a user-facing tool invites the wrong question. The same
four shapes are fully separable from `composite_item_id` and `parent_rev_center_name`
alone, which name things people recognise:

| Shape | Filter | Plain English |
|---|---|---|
| Sold alone | `composite_item_id is null and parent_rev_center_name = rev_center_name` | Bought on its own |
| In a combo, paid | `composite_item_id is not null` | The priced half of a Try 2 Combo |
| In a combo, free | `composite_item_id is null and parent_rev_center_name = 'Try 2 Combo'` | The zero-priced slot |
| In a catering box | `composite_item_id is null and ifnull(parent_rev_center_name, '') not in ('Try 2 Combo','Discount','Promotion') and ifnull(parent_rev_center_name, '') <> ifnull(rev_center_name, '')` | Box Lunches / Party Trays |

The tell for a standalone line is that its **`parent_rev_center_name` equals its own
`rev_center_name`** — an unbundled item is its own parent. Verified to produce identical
numbers to the `line_item_type` version on the four-item test set over 2026-05-03 →
2026-06-27: 211,033 sold alone / 90,226 in-combo paid / 71,330 in-combo free / 19,638
catering box, and $1,260,795 Utah gross either way. Use whichever is clearer for the
audience; **prefer this one in anything a non-analyst will read.**

- **`line_item_type = 'item'` is NOT the same as "standalone."** For Ultimate Grilled Cheese over 2026-05-03 → 2026-06-27: 71,586 `item` lines, but only **24,125** were standalone — the other **47,461** were priced combo components. Treating all `item` lines as standalone overstates standalone units ~3x and understates combo units.
- **The two combo shapes are mutually exclusive per `combo_order_line_item_id`** (verified: 47,461 groups have exactly one priced component line and zero modifier lines; 37,623 have exactly one modifier line and zero component lines). So **combo units = component lines + modifier lines, with no double-counting.** **Corrected 2026-07-30: the two shapes are a CHANNEL split, not a per-slot quirk.** Sandwich lines, 2026-06-30 → 2026-07-29, store 1111 excluded: in-store POS produced 209,982 priced components and only **29** zero-priced slots; digital produced 143,097 zero-priced slots and only **172** priced components. It is ~99.9% clean in both directions. So `composite_item_id is not null` is very nearly a proxy for `pulse_order_id is null`, and any analysis that filters to one combo shape has silently filtered to one channel. The earlier "appears across all 88 stores, so it isn't a split" reasoning was wrong — both channels operate in all 88 stores, which is exactly why the store test couldn't see it. **Test the candidate dimension, not a dimension that happens to be uniform.**
- **Revenue lives in the first two shapes, not just the first.** The priced combo components carried $315,280 of gross for UGC in that window vs $215,890 standalone — so "essentially all revenue is in standalone lines" is false. For revenue-per-unit, divide by standalone + component lines; exclude the zero-priced modifier lines.
- Box Lunches (catering) also surface entrées as zero-priced `modifier` lines with `parent_rev_center_name = 'Box Lunches'` — another reason to settle the catering question up front.
- ⚠️ **The "in a catering box" test catches orphaned modifiers** (found 2026-07-31). Modifiers attached to *priced combo components* (mostly POS Kids Combo selections — `Kids Tomato Basil Soup`, `Sprite`, …) get `parent_rev_center_name` = their **own description** because the mart's parent join misses combo components — 50,734 lines / 171 stray values over 2026-05-01 → 2026-07-30. Those lines satisfy `composite_item_id is null and parent <> rev_center and parent not in (...)` and would be misfiled as catering-box. Before running a shape breakdown, restrict to lines whose `parent_rev_center_name` is in the known rev-center list (see the `order_lines` dictionary gotcha), or add `and ifnull(ol.rev_center_name, '') <> 'Modifiers'` when the item can appear as a kids-combo/drink selection.

### Modifier / customization analysis — digital orders ONLY (verified 2026-07-30)

**`order_lines` carries essentially no modifier detail for in-store POS orders.** Standalone sandwiches
2026-06-30 → 2026-07-29, store 1111 excluded: **25** explicit ingredient changes across **65,276** POS lines
(0.0%) against **23,453** across **63,027** digital lines (37.2%). Priced combo components — which are the POS
combo shape — have **zero** attached modifiers across all 210,154 lines. This is a capture gap, not behavior:
a guest at the counter can obviously say "no tomato."

**Consequences, all mandatory:**

1. **Never report a company-wide modification rate.** Any rate is a *digital* rate. Filter
   `ol.pulse_order_id is not null` explicitly and say so — leaving POS in the denominator halves the number
   with no warning. Whether Brink records in-store modifiers at all is an open upstream question
   (Asana `KB finding: no in-store modifier capture`).
2. **`item_modifier = 'With'` is a build selection, not a modification.** The seven values are `With`, `No`,
   `Add`, `Substitute`, `Extra`, `None`, `For`. **A customization is `No` / `Add` / `Substitute` / `Extra`.**
   `With` covers the bread choice (`Ciabatta` 53,052, `Ancient Grain` 10,121) and the combo entrée slot, and it
   fires on **99.9%** of digital sandwiches because it's a required step. Counting any modifier line as
   "modified" returns ~99.9% — a technically-correct, completely useless number.
3. **Also require `rev_center_name = 'Modifiers'` on the change.** A `No` line can point at a dessert or a
   side (`No Chocolate Dipped Strawberry`, 2,896 lines) — that's a combo-slot decline, not an ingredient edit.

**Join key:** modifier lines attach to the parent item line on **(`brink_order_id`, `order_item_id`)** — the
modifier's `order_item_id` holds the *parent's* order-item id, and its own identity is `item_id_seq_num`.
Do **not** join on `combo_order_line_item_id`; it groups the whole combo.

> **⚠️ Inside a Try 2 Combo, modifiers cannot be attributed to a specific entrée.** All modifiers for every
> slot hang flat off the *combo parent's* `order_item_id`, siblings of the entrée slot lines themselves. Over
> 2026-06-30 → 2026-07-29, non-catering, **143,123 of 143,124** sandwich-bearing combos also held a
> soup/salad/bowl — so "No Roma Tomato" belongs to either entrée with no way to tell. The tell is in the data:
> the top changes on sandwich-bearing combos include `Add Salad Tortilla Strips` (8,157), `Add Radiatore Noodle`
> (7,802) and `Add Wild Rice Blend` (4,174), which are soup and salad ingredients.
>
> **So report the standalone rate as the answer and the combo rate as an upper bound**, never a blended number
> without both stated. Sandwiches, last 30 days, digital, non-catering: **37.2% standalone (exact, 1.61 changes
> each) vs 49.3% in-combo (ceiling, 2.04 each)**; blended 45.6% of 206,122.

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

- **Business questions run on the `claude` views for everyone except the steward — even for accounts whose IAM can read `sales_ops`.** A successful select from `sales_ops` is permission, not a routing signal (rule changed 2026-08-04). `Access Denied` on `sales_ops` is intended, not a broken setup. See the dataset-routing section near the top.
- **`claude` history starts 2023-01-01 and truncates silently.** The order views filter `business_date >= date_trunc(date_sub(current_date, interval 3 year), year)`. An older range returns **zero rows, not an error** — which reads as "no sales." Check the window before reporting an empty result.
- **`revenue_category` means something different in `claude` than in `sales_ops`.** The `claude` view forces it to `'Catering'` whenever `is_catering = true`, making the two equivalent; in `sales_ops`, `is_catering` is a superset (48 extra orders in June 2026). Channel breakdowns from the two datasets will legitimately disagree — state which you queried instead of reconciling them.
- **In `claude.order_customer`, `0` in a folded count column means "no upstream row," not zero orders.** `customer_order_count = 0` ⟺ unidentified (46.4% of June 2026 orders); `lifetime_order_count = 0` is broader at 51.5% — it also catches all kiosk, most internal, and most store-1111 orders, so 36,261 orders have a real sequence number but zero lifetime. Never `avg()` a lifetime column unfiltered; never present `lifetime_order_count = 0` as a cohort. The FLOAT/DATE lifetime columns are *not* coalesced and stay NULL, so the same absent customer reads `0` in one column and `NULL` in the next. Details in `data_dictionaries/claude.order_customer.md`.
- **There is no `claude.order_sequence` or `claude.customer_attribute`** — both are folded into `claude.order_customer`. Don't tell a user the data is unavailable; it's on the order view.
- **The partition column is `business_date` on every table** as of 2026-07-30. `order_lines` was rebuilt across full history that day and its `BusinessDate` column is **gone** — the long-standing two-spellings trap is closed. ⚠️ **Any saved query, template or workbook still writing `ol.BusinessDate` now fails outright** with `Unrecognized name: BusinessDate`. That is the good failure mode (loud, not silent), but it will hit the shared analyst workbook — read the error literally and swap in `business_date`.
- **`order_lines` has no `order_id`** — this now leads the gotcha list because it is the single most-repeated error in the query log: `Name order_id not found inside ol`, hit three more times on 2026-07-27/28 and **again on 2026-07-28 at 09:12** by the same analyst. The order key is `brink_order_id` on every one of these tables. The 2026-07-28 instance selected `ol.order_id` in a CTE and then joined `oc.brink_order_id = ol.order_id` — i.e. the correct column name was already in the query, on the other side of the join. Read your own join predicate before selecting.
- **Customer metrics need `customer_type = 'person'`**; sales metrics must NOT filter it. See the rule above.
- **`order_customer` emails are now lowercased at build** (fix deployed 2026-07-29 with the full-history rebuild; verified 2026-08-13: 0 non-lowercase `mapped_email` / `email` values in 365 days). `lower()` on them is a harmless no-op — keep it defensively, but the old "~17,900 overstated distinct emails" caveat no longer applies to current data. The SessionM fallback email also strips the leading `cater_` prefix, so catering logins resolve to the individual's address in `mapped_email` — when comparing to `claude.loyalty_user`, compare against `email_normalized`, not `email` (which keeps the prefix). Raw `pulse.*` / `braze.*` emails outside the marts still need `lower()`.
- **`order_customer` gained two columns, synced 2026-08-13**: `destination_id` (INT64, raw Brink destination id alongside `destination`) and `has_order_items` (BOOL, added 2026-08-04 — FALSE means no qualifying item rows survived the build's item filters, so `item_gross_sales` and friends are NULL on ~2.4% of rows; an audit flag, not a reporting filter). `phone` is now STRING. Both new columns flow through to `claude.order_customer`.
- **`claude.order_customer` excludes store 1111 at the view level** (deployed filter `and oc.store_id <> 1111`, documented 2026-08-13). Standard users cannot see the test store at all; `sales_ops` tables still contain it, so the exclusion remains load-bearing there. Writing `store_id <> 1111` against the `claude` view stays correct — just expect `claude`-vs-`sales_ops` totals to differ by the test store even when neither query filters it.
- **Per-customer questions should use `sales_ops.customer_attribute`, not a hand-rolled `group by mapped_cust_id`** (new 2026-07-29). Lifetime orders, spend, AOV, recency, tenure, store affinity and trailing 30/90/365-day activity are all precomputed there — that's the whole point, so two sessions can't produce two different LTV numbers. It is already person-only (adding `customer_type = 'person'` errors), it has **no partition column**, and you must check `attribute_asof_date = yesterday` before trusting the window columns. See its section above.
- **`order_lines.item_net_sales` is usable, with a named limit** (steward ruling 2026-07-30, superseding the earlier "not computable" wording). The column is live on **both** `sales_ops.order_lines` and `claude.order_lines`, fully populated, **zero nulls**. Report it when asked; do **not** treat it as reconcilable to order-level net. Measured on Ultimate Grilled Cheese, 2026-05-03 → 2026-06-27, non-catering, stores 1111/999 excluded:

  | Sale shape | Units | Gross | Net | Gross→net |
  |---|---|---|---|---|
  | Sold alone | 24,125 | $215,890 | $210,928 | **2.30%** |
  | In combo, paid | 47,461 | $315,280 | $304,716 | **3.35%** |
  | In combo, free slot | 37,623 | $386 | $371 | **3.83%** |

  The spread is **not constant across sale shapes**, so it is not a flat rate and the difference between gross and net cannot be described as "the discount" without evidence. Order-level discounts and promotions are still *not* allocated per item, so **`order_customer.net_sales` remains the only net figure to quote or tie out** — say that whenever you hand over `item_net_sales`. Still open: what the 2.3–3.8% actually represents, and why it is wider on combo components than on standalone lines (Asana: `KB finding: item_net_sales gross-to-net spread varies by sale shape`).
- **Net sales is the `net_sales` column** — read it directly (calculated at build since 2026-07-24). `brink_net_sales` is Brink-given and validation-only; it runs ~0.0025% above calculated net ($479 on $18.9M in June 2026). There is no per-item or per-modifier net in the mart any more.
- **`is_catering = false` does not exclude catering-only items** (verified 2026-07-28). `Ultimate Grilled Cheese Box` — the catering box SKU — is flagged `is_catering = false` on `order_lines`. The flag describes the *order's* catering destination, not the *item's* nature, so catering-specific SKUs leak into non-catering item mix. Check the resolved item-name list for `Box` / `Tray` / `Party` variants explicitly.
- **`is_catering` is a superset of `revenue_category = 'Catering'`** — every catering-destination order is TRUE, plus a handful (48 in June 2026) that pulse flagged as catering on In-Store/Digital destinations. Before 2026-07-24 the flag missed all POS-only catering (641 orders / $70.7K net in June), so pre-rebuild catering numbers understate it. **`order_lines` only caught up on 2026-07-31** (+644 June orders / +$71,586 gross); the definition is now identical on both marts and verified to agree on all 703,524 June orders. If you're comparing against a catering number produced between 07-24 and 07-31, ask which table it came from before calling either one wrong.
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
- **`is_guest_order` no longer means what this file used to say — the fix is DEPLOYED and the old "91% of all-time orders are guest" figure is dead** (re-measured 2026-08-13). That 91% was the pre-fix column, which was just an alias for `pulse_order_id is null` and carried no loyalty information at all. The deployed logic is now an explicit digital allowlist:
  ```sql
  case when ocs.is_loyalty_user = false
        and lower(po.source) in ('mobile_web_source','web_source','ios','android','mobile_source')
       then true else false end as is_guest_order
  ```
  Measured July 2026 (683,228 orders, stores 1111/999 excluded): **19,273 guest orders = 2.8% of all orders**, zero NULLs, and **zero POS orders flagged**.
  > **⚠️ `is_guest_order = false` is NOT "logged-in order" — it is the default value.** The deployed `else false` puts three unlike populations in one bucket: 406,796 in-store POS orders (guest-ness is *undefined* there, not false), 103,337 `Checkmate` aggregator orders, and genuinely-authenticated digital orders. Reading `false` as "identified" overstates that population by roughly 10x. **Pick the denominator explicitly and state it** — July 2026: 2.8% of all orders, **14.7%** of the four digital `order_source` values that can produce a guest (131,060 = Mobile Web + Web + Android + iOS), **39.6%** of web orders (19,272 / 48,725). The last is the one operators usually mean.
  >
  > **The build script and the deployed code disagree, and the data follows the code.** The script's own comment (lines 391-392) and the design in the backlog both say POS should be **NULL** (`case when ocs.order_id is null then null else not ocs.is_loyalty_user end`) because an in-store order has no guest/member distinction to make. The committed expression has no NULL branch. So "zero NULLs" is evidence of an unimplemented spec, not of a clean column — steward decision open (Asana 1217004980903117).
  >
  > Guest checkout is **web-only in practice**: `Mobile Web` 15,804 / 31,827 (49.7%), `Web` 3,468 / 16,898 (20.5%), `Android` **1** of 13,758, `iOS` **0** of 68,577. The apps are in the allowlist but keep users signed in, so they never produce guests. `coalesce(is_guest_order, false)` (seen in analyst SQL 2026-08-13) is now a no-op, but it encodes the same false-means-not-guest assumption — drop it rather than carry it.
  >
  > **⚠️ There IS a pre-launch guest population, and day-sampling will not find it.** ~**314,900** orders are flagged guest before 2026-07-01, essentially all in **Mar–Oct 2023** (peak 2026-08 ⇒ 2023-08 at 78,468; 2023-05 32,007, -06 51,631, -07 63,237, -09 57,951). The column then goes dark from Nov 2023 (23 orders) and stays in single or double digits per month through Jun 2026 (27). So the honest statement is **"no meaningful history between Nov 2023 and Jun 2026,"** not "none before the launch" — and the 2023 population needs an explanation before any pre/post comparison leans on this column. *(Method note: this was first reported as "effectively zero before 2026-07-01" from seven sampled single days, all of which fell in 2024–2026. A monthly `having guest_true > 0` aggregate over full history found the 2023 block immediately. **Sampling days cannot support a claim about a column's whole history** — aggregate the history.)*
- `mapped_cust_id` coverage is ~53% over the last year, and only ~62% of *that* is a real person.
- **Store 1111 is a test/training store — ALWAYS exclude it** (`store_id <> 1111`) in all sales, order, and item metrics on all tables. No exceptions (steward rule 2026-07-23). Note `order_sequence` sequence numbers are built without that exclusion.
- Store footprint: ~90 stores in UT, AZ, MN, NV, WI, ID, IL, OH, TX. Store attributes come from `sales_ops.store_info`.
- **Business week is Monday–Saturday** — all stores are closed Sunday. "Last week" means the most recent Mon–Sat; weekly averages divide by 6 days, not 7. Don't use Sun-anchored `date_trunc(..., week)` for CZ weeks (observed in analyst SQL 2026-07-22; steward-confirmed pending). Use `date_trunc(d, week(monday))` to bucket weeks.
- **"Week ending" means the Saturday, and is `date_trunc(business_date, week(sunday)) + 6`** (steward rule 2026-07-30). Users ask for week-ending dates far more often than week-starting ones, so label weekly output with the Saturday. Note the deliberate mismatch with the bucketing rule above: the label expression anchors on **Sunday**, not Monday, and that is not a typo. A Sunday-anchored week puts the ~4 stray Sunday lines that exist chain-wide into the *following* Mon–Sat week, so `week_ending` is always **on or after** every `business_date` in its bucket. `date_trunc(d, week(monday)) + 5` looks equivalent and is not: it hands a Sunday line a `week_ending` six days *earlier* than the line's own date, creating a phantom extra bucket. For all real Mon–Sat trading the two are identical, which is exactly why the difference survives review.
- **Snap the range to whole weeks before reporting weekly** (steward rule 2026-07-30). A range whose ends fall mid-week produces a short first and last bucket that reads as a dip nobody caused — the most screenshot-ready wrong conclusion this mart can produce. Either widen to the enclosing Sun→Sat boundaries and state the dates actually used, or label the partial buckets with their day count. Never ship an unflagged part-week next to full weeks. Verified: 2026-05-03 → 2026-06-27 is already exactly 8 whole weeks, 6 trading days each.
- **Year-over-year offset is 364 days, not 1 year** — `date_sub(d, interval 364 day)` (52 × 7) keeps the day-of-week aligned, which matters because the week is Mon–Sat and Sundays are zero. `date_sub(d, interval 1 year)` shifts the weekday and drags a Sunday into the comparison window. Convention observed in analyst SQL 2026-07-24.
- Timezone: business runs on `America/Denver` for schedule logic; each store's local time is in `order_datetime`, UTC in `order_customer.order_timestamp_utc`.
- There is **no `order_id` column** on any of these tables — the order key is `brink_order_id` (multiple users have hit this error).
- A legacy table `sales_ops.OrderCustomer` also exists (different schema: `netsales`, `iscatering`, `storeid`, `lifetime_order_cnt`, `first_order_datetime`, `order_count`, `mapped_domain`, `source`, …). **Do not use it** — it predates this mart and gives different answers. `sales_ops.order_customer` (lowercase) is the only canonical order table.
  - **It is now also going stale**: on 2026-07-27 its `max(business_date)` was **2026-07-25** while `order_customer` had loaded through 2026-07-27. Answers from it are silently 1–2 days short of current. Three separate users queried it during 2026-07-24 → 2026-07-26.
  - **🛑 If you are working from a saved query or a shared template, assume it targets this legacy table and rewrite it before running.** Query-log review counted **188 non-steward runs against `OrderCustomer` in the five business days 2026-07-24 → 2026-07-29**, and every one of the 115 raw-`pulse.*` wall breaches in that window came through it. The pattern is a *shared workbook* — byte-identical query text ran under two different users' accounts hours apart on 2026-07-28, eight of them inside a single minute (batch execution). Legacy schema is the tell: `businessdate`, `storeid`, `iscatering = 0`, `source`, `lifetime_order_cnt`, `first_order_datetime`. Translate to `business_date`, `store_id`, `is_catering = false`, `order_source`, and `order_sequence.lifetime_customer_order_count` — and if the template reached into `pulse.*` for identity, stop and say the mart can't answer it (Asana 1216992461499656).
  - `iscatering` on the legacy table is **INT64** (`iscatering = 0`); `is_catering` on the canonical mart is **BOOL** (`is_catering = false`). Writing `is_catering = 0` fails with `No matching signature for operator = for argument types: BOOL, INT64` (observed 2026-07-24) — a reliable sign a query was written against the legacy schema.
- **`sales_ops.store_info` column names are not the obvious ones** — it's `store_state`, not `state`; `store_city`, `store_zip`, `store_address`, `store_short_name`. Full column list: `store_id`, `store_name`, `store_address`, `store_city`, `store_state`, `store_zip`, `store_phone`, `store_short_name`, `store_tz`, `store_open_date`, `is_comp_store`, `latitude`, `longitude`, `weather_cluster_id`, `timezone_name`. Join `store_info.store_id = order_customer.store_id`. Full dictionary: [`data_dictionaries/sales_ops.store_info.md`](../../data_dictionaries/sales_ops.store_info.md). (Guessing `state` failed an analyst session 2026-07-24.)
- **"Market" means `store_state`** (steward decision 2026-07-30). There is **no** `market` / `region` / `dma` / `metro` column anywhere in `sales_ops` — verified against `INFORMATION_SCHEMA.COLUMNS`. When a user asks for anything "by market," join `store_info` and group by `si.store_state`, and **say in the answer that market = state**. Ten values, one of which is **blank** (one store has no `store_state`) — it becomes a nameless row in any breakdown, so exclude or label it. Caveat worth stating: Utah is 35 of ~90 stores across 28 cities, so one "Utah" row hides most of the geographic spread. `store_city` is finer but `West Valley` and `West Valley City` are separate values for the same metro. A real metro/DMA rollup is an open KB gap — don't invent one per-session.
- **⚠️ `sales_ops.order_discount` and `sales_ops.discount_detail` are different tables — don't confuse them.** `discount_detail` (new 2026-08-15) is the documented mart; `claude.discount_detail` is what users query. `order_discount` is an older raw Brink passthrough (`order_id`, `discount_id`, `name`, `amount`, `loyalty_reward_id`, `approver_employee_id`, `source`, …), **not documented**, join keys unverified. If a question needs `order_discount`, treat answers as provisional until its dictionary lands. **Its partition column is the legacy spelling `businessdate`, not `business_date`** — the 2026-07-24/30 renames did not reach it, so a query written to the current convention fails with `Unrecognized name: business_date; Did you mean businessdate?` (hit by an analyst MCP session 2026-08-06). Its `approver_employee_id` is the manager-discount audit trail, which `discount_detail` does **not** carry — an open enrichment idea, not a gap anyone has asked for.
- **Employee/test exclusion:** internal accounts are identifiable via `customer_type = 'internal'` (`@cafezupas.com`, `@tkxel.com`, `@tkxel.io`) — 119 ids / 736 orders in June 2026. The new `mapped_email_domain` column closes the old `mapped_domain` mart gap on this table. Unidentified internal orders still can't be flagged.
- The old `cowork_interim` and `nces_staging` scratch datasets were dropped 2026-07-22. Any saved query referencing them must be rebuilt against the marts (materialize intermediates in `scratch` if needed).

- **Payment method / tender questions run on `claude.order_payment_tender`** (view, new
  2026-08-05) — one row per order, join on `brink_order_id`, answer column
  `payment_tender`. Never reach into `pulse.order_payments` / `brink.brinkOrderPayment`
  directly (they hold cancelled/failed/refunded/deleted rows the view filters). Freshest
  loaded day shows `'stripe'` placeholders; amounts are gross tendered, not sales; split
  tenders are comma-joined. Full gotchas: `data_dictionaries/claude.order_payment_tender.md`.

- **Discount / loyalty-giveaway questions run on `claude.discount_detail`** (new 2026-08-15).
  **One row per discount COMPONENT, not per line and not per order** — a single Brink line can
  split into several rows. `discount_amount` is the **only** summable money column (it
  reconciles to `order_lines` exactly); `count(*)` counts components; joining to
  `order_customer` requires aggregating this table to order grain first or the split
  multiplies the sales side. `discount_origin` is **not** a channel — `revenue_category` is.
  `discount_type` is an open domain with no `'Other'` bucket. **`Error` is a health signal:
  0–1 lines on a closed day, but ~76% of *today's* integrated lines until the 4am pass — never
  report today's discount mix intraday.** Full gotchas:
  `data_dictionaries/claude.discount_detail.md`.

- **In an incremental build, never window a dimension by the fact window** (rule 2026-08-15).
  `user_offers.create_date` is *issuance*, `pulse.order_discounts.created_at` is order
  *placement*, `business_date` is *fulfillment* — different clocks. Reusing `start_date` on a
  lookup CTE made `offer_name` non-deterministic by day of week (275 rows over 8 days) and
  silently dropped catering booked further out than the window. Filter lookups by the order
  keys in the window, or widen the reload and add an alarm. Wrap `delete`+`insert` in an
  explicit transaction; BigQuery scripts are not atomic. Pin `current_date('America/Denver')`
  — bare `current_date` is UTC and evening intraday runs land on the next UTC day. Full
  writeup in the section above.

## When done

If you learned something new about these tables during the session (new gotcha, new canonical definition, data quality issue), do **not** edit this skill or any local copy — only the data steward commits to the repo, and session copies are discarded. Instead, create an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`) titled `KB finding: <short title>`, describing what you observed (include the query that surfaced it) and the proposed change. The steward reviews and merges vetted findings; the next session's fresh clone benefits automatically.
