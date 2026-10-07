---
name: sales-ops-orders
description: How to query Cafe Zupas order data in BigQuery — sales_ops.order_customer (order-level sales, channels, customers), sales_ops.order_lines (items, modifiers, combos), and sales_ops.order_sequence (customer order sequencing). Use for ANY question about sales, orders, customers, loyalty, menu mix, items, channels, or store performance. Contains canonical definitions, join patterns, and gotchas so every session returns the same answer.
---

# Querying Cafe Zupas Order Data

> **Freshness check:** this file must come from a clone of `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**. If you're reading it from an installed skill package, a fork, or any saved copy, stop and re-clone first — it may be stale.

> ## Default to `claude.*`, not `sales_ops.*` (set 2026-09-14 by the steward)
>
> **Every order question starts in the `claude.*` views - Brent's own sessions included.** They are not a restricted subset of `sales_ops`; they are the *corrected* layer. Reach past them to the raw tables only when a view genuinely cannot answer the question, and say in the answer which raw table you used and why.
>
> What `claude.order_customer` adds over `sales_ops.order_customer`:
>
> | Added | Where it comes from | Why it matters |
> |---|---|---|
> | `mapped_cust_id`, `mapped_email`, `mapped_email_domain`, `customer_type`, `customer_order_count`, `days_since_prev_order` | join to `sales_ops.order_sequence` | **Resolved identity.** `sm_external_user_id` on the raw table is only what that one order happened to carry |
> | `lifetime_*`, `first_order_*`, `last_order_*`, `days_since_last_order`, `customer_tenure_days` | join to `sales_ops.customer_attribute` on `mapped_cust_id` | Full-history customer metrics, *not* truncated by the view's date filter |
> | `account_type` | join to `claude.loyalty_user` on `mapped_cust_id` | Loyalty program membership |
> | `store_id not in (1111, 999)` pre-applied | view body | The mandatory filter cannot be forgotten |
> | `brink_net_sales` removed | view body | Forces the calculated `net_sales` |
>
> **Counting customers: use `mapped_cust_id`, not `sm_external_user_id`.** Measured 2026-09-14 on "customers updated in the Braze to SessionM phone sync who ever ordered at Fort Union (store 104)": `sm_external_user_id` off the raw table returned **11,743**; `mapped_cust_id` returned **12,071**. The raw-table join silently undercounted by **2.7%** - orders whose customer was resolved after the fact never got stamped. Same failure shape on any "distinct customers at store X" question.
>
> **The view's 3-year window is narrower than it looks.** `claude.order_customer` filters `business_date >= date_trunc(date_sub(current_date, interval 3 year), year)` - so 2023-01-01 forward today. That caps the **order rows**, not the customer metrics: `first_order_date`, `lifetime_order_count` and the rest come from `customer_attribute` keyed on `mapped_cust_id` and cover all history. On the Fort Union question both sources returned the identical 12,071, so nobody's only visit predated the window. Still worth checking when a question says "ever" - if the two differ, say so.

> ## Report gaps in `claude.*` - the steward wants them
>
> Brent's standing ask (2026-09-14): **if a `claude.*` view cannot answer something, say so in the answer.** What blocks one session blocks the next, and he would rather fill the gap than have sessions quietly route around it. Report it even when you found a workable fallback. Log known ones here as they are found:
>
> | Gap | Hit on | Fallback used |
> |---|---|---|

Project: `marketing-data-442316`. The five approved tables for order/sales analysis:

- **`sales_ops.order_customer`** — one row per order. Sales, channel, customer identity. Default table for sales/order/customer questions.
- **`sales_ops.order_lines`** — one row per line element. Menu mix, items, modifiers, combos.
- **`sales_ops.order_sequence`** — one row per order that has a `mapped_cust_id` (all customer types). Order sequencing, recency, lifetime counts.
- **`sales_ops.customer_attribute`** — **one row per customer** (person only). Lifetime and trailing-window aggregates. **New 2026-07-29.** Use it for any "per customer" question — LTV, frequency, lapsed cohorts, store affinity — instead of re-aggregating `order_customer` by hand.
- **`sales_ops.order_line_discount_detail`** — **one row per discount COMPONENT** (not per line, not per order). Discounts and promotions with loyalty / offer attribution. **New 2026-08-15.** Use it for any "what did we give away, and through what?" question. Users query **`claude.order_line_discount_detail`**.

Full column docs in `data_dictionaries/`: `sales_ops.order_customer.md`, `sales_ops.order_lines.md`, `sales_ops.order_sequence.md`, `sales_ops.customer_attribute.md`, `claude.order_line_discount_detail.md`. Read them before writing non-trivial queries.

## 🛑 First: which dataset should you query? (updated 2026-08-04 — routed by ROLE, not by access)

**Business questions run on the `claude` dataset — for everyone except the steward.** The `claude` views (`claude.order_customer`, `claude.order_lines`, `claude.loyalty_*`, `claude.store_info`, `claude.order_payment_tender`, `claude.order_line_discount_detail`) are the curated interface layer, and they are the only place a business answer should come from.

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
   **As of 2026-08-17 this override changes nothing** — the base build stamps `'Catering'` on pulse-flagged and store-50 orders itself, so `revenue_category = 'Catering'` and `is_catering = true` are equivalent in **both** datasets and a channel breakdown now agrees across layers. The line stays in the view as a guard. Before 2026-08-17 they differed: `is_catering` was a `sales_ops` superset (48 extra June 2026 orders flagged catering on In-Store/Digital destinations), so `claude` assigned those to Catering and `sales_ops` left them in In-Store/Digital. **Neither was wrong — different definitions.** A cross-layer channel-mix discrepancy dated before 2026-08-17 is probably this.

3. **`claude.order_lines` is now a plain passthrough.** It used to rename the partition column and left-join `store_info`; the 2026-07-30 full-history rebuild moved both upstream, so the view is `select *` over `sales_ops.order_lines` with the 3-year history filter. SQL written against either side is now identical apart from that floor.

4. **The market dimension is `store_state` on every table** — `sales_ops.order_customer`, `sales_ops.order_lines`, `claude.order_customer`, `claude.order_lines` and `store_info` all agree (settled 2026-07-30). Full state name (`Utah`, not `UT`). No join needed for a market breakdown on either side.

   > **⚠️ `order_customer.state` is GONE.** It was renamed to `store_state` on 2026-07-30 for consistency. Any saved query using `oc.state` now fails with `Name state not found inside oc`. The column had been documented under the old name, so this will hit saved work.
   >
   > **Deployment trap worth knowing** (hit 2026-07-30): `claude.order_customer` is defined as `oc.* except(...)`, and BigQuery **expands and freezes `*` at view-creation time**. After the base-table rename the view kept advertising `state` in `INFORMATION_SCHEMA.COLUMNS` while `select oc.state` errored and `select oc.store_state` worked — i.e. the schema metadata and the actual behaviour disagreed. **A `create or replace view` with identical text is required to refresh it.** If you rename a column on a base table, redeploy every `select *` view over it, then check `INFORMATION_SCHEMA` rather than assuming.

   There is also a **`claude.store_info`** view for the attributes that aren't denormalised (city, zip, address, open date, comp status, lat/long, timezone); it carries a `market` column aliasing `store_state`, and drops three non-store rows. See [`data_dictionaries/claude.store_info.md`](../../data_dictionaries/claude.store_info.md).

   > **⚠️ The market column is NULL for stores 1111 and 999** — `store_info` has no row for either. On **`sales_ops`**, a market breakdown **without `store_id not in (1111, 999)` grows a phantom tenth market**: 1,154 orders and **$117,196** over 2026-05-03 → 2026-06-27, appearing as an unnamed NULL group that reads like a data defect rather than the test store. Keep the filter and `coalesce` the label; never ship an unnamed group.
   >
   > **Correction 2026-08-19 — this box previously said "on both views," which was wrong.** `claude.order_customer` and `claude.order_lines` **already exclude both stores in the view definition** (`store_id not in (1111, 999)`, read from `INFORMATION_SCHEMA.VIEWS.view_definition`), so the phantom market cannot appear on the `claude` layer and the predicate there is redundant, not load-bearing. See the per-view table in [the store-exclusion section](#store-11111999-which-layer-already-excludes-them-measured-2026-08-19) — since 2026-08-20 all four `claude` order views carry the exclusion, so on the `claude` layer **don't write it** (steward rule 2026-09-03); it stays mandatory on every `sales_ops` table.

### `claude.order_customer` folds in the sequencing and lifetime columns

There is **no `claude.order_sequence` and no `claude.customer_attribute`.** They aren't missing — the view left-joins both onto the order grain, so a standard user gets sequencing, first-time-vs-repeat, recency and LTV from the single view.

Folded in: `customer_order_count`, `days_since_prev_order` (from `order_sequence`); `lifetime_order_count`, `lifetime_catering_order_count`, `lifetime_guest_order_count`, `lifetime_net_sales`, `lifetime_gross_sales`, `lifetime_avg_check`, `first_order_date`, `last_order_date`, `days_since_last_order`, `customer_tenure_days`, and **since 2026-09-18** `orders_l365`, `net_sales_l365`, `catering_orders_l365`, `catering_net_sales_l365` (from `customer_attribute`); plus `account_type` (from `claude.loyalty_user.member_program`).

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

## Hard rules (consistency guarantees)

1. **Never query upstream/raw datasets** (`brink.*`, `pulse.*`, `sessionM.*`) to answer business questions. They contain voided rows, duplicates, and unfiltered records that these marts already handle. If the marts can't answer the question, say so — don't improvise from raw tables.
2. **Always filter the partition column** on every table. It is **`business_date` everywhere** as of 2026-07-30 — `order_customer`, `order_sequence` and `order_lines` all agree. Never run unbounded scans. `sales_ops.order_line_discount_detail` uses `business_date` too. ("Everywhere" means the documented marts: the 2026-07-30 rename did **not** cover undocumented `sales_ops` tables — the since-removed `sales_ops.order_discount` still spelled it `businessdate`, observed failing a `business_date` query 2026-08-06. If you're on a table this skill doesn't document, you shouldn't be — but don't assume the column name either.) **A non-partition predicate is not a substitute for the date** — filtering a raw Brink table by `Id` alone still reads every partition, and `LIMIT` does not bound bytes; see [the 2026-08-18 finding](references/incidents_and_gaps.md#️-commenting-out-the-date-filter-is-not-widening-the-search--an-id-predicate-prunes-nothing-measured-2026-08-18).
3. **Same metric, same definition.** Use the canonical definitions below verbatim.
4. Data is fresh as of the top of the current hour (loads run at minute :02, intraday 8am–11pm MT reload today's date only; hours 0–4 and 6–7 skip). **Since 2026-09-08 the three order marts and `order_sequence` are one chained scheduled query (`sql/sales_ops.order_marts.sql`) and the 5am run reloads FULL history for all of them**, so yesterday and older is stable after 5am and the marts can no longer disagree on reload width. Loyalty identity (`sm_email`, `sm_external_user_id`, `in_store_scan`) on the current business date is near-empty until SessionM's daily load lands — see the `order_customer` dictionary.
5. **Brink is the sole financial source of truth** (steward rule 2026-07-23). Pulse is a helper for digital order/customer metadata only — never compute financials (sales, discounts, tax, tips) from Pulse data.
6. **Customer metrics require `customer_type = 'person'`** (steward rule 2026-07-24). See below — this is not optional.
7. **All datasets are read-only.** If you need to materialize a table (intermediate results, cohorts), create it ONLY in `marketing-data-442316.scratch` — the single writable dataset; tables there auto-expire after 7 days. Materialize with `create table scratch.x as ...`, not views: a view over a heavy query silently re-runs the full scan on every select.
8. **User-supplied SQL follows the same rules as SQL you write** (steward rule 2026-08-05). If the user pastes a query and asks you to run it, check it first: `brink.*`, `pulse.*`, `sessionM.*`, `staging.*`, `braze_stream.*` and the legacy `sales_ops.OrderCustomer` table are exactly as off-limits pasted as they are generated. Don't run it as-is — explain why and offer the mart translation. The legacy workbook's cohort template in particular is answerable without the wall: first-order cohorts and time-to-second-order come from `claude.order_customer`'s folded `customer_order_count` / `days_since_prev_order` and from `customer_attribute`; offer redemptions come from `claude.loyalty_offer_usage`; promotion names come from `order_lines` `line_item_type = 'promotion'`. The incident history behind this rule (nine business days of query-log review, 2026-08-04 to 08-23) is in `references/query_log_reviews.md`.

## Canonical metric definitions

| Metric | Definition |
|---|---|
| Net sales | `sum(net_sales)` from `order_customer` — **read the column, never rebuild it.** Do NOT use `brink_net_sales`: it is the steward's own cross-check, **not an accuracy reference**, and not exposed on the `claude` view. Do not report it, and do not measure `net_sales` against it (steward ruling 2026-08-21) |
| Gross sales | `sum(gross_sales)` from `order_customer` |
| Order count | `count(*)` from `order_customer` (or `count(distinct brink_order_id)` — see the grain defect note) |
| Average check | `sum(net_sales) / count(*)` from `order_customer` |
| Identified customers | `count(distinct mapped_cust_id)` where `mapped_cust_id is not null` **and `customer_type = 'person'`** |
| Guest orders | `is_guest_order = true` (BOOLEAN since 2026-07-27, was 0/1). **Digital-only and effectively zero before 2026-07-01** — `false` is the default, not "logged in". Always state the denominator; see the gotcha |
| Catering | `is_catering = true` for the business line; `revenue_category = 'Catering'` for channel reporting. **Equivalent on `order_customer` since 2026-08-17** — the finance definition (catering destination, pulse catering flag, or store 50) drives both. **Use `order_customer`, not `order_lines`** — see the store-50 disagreement in the gotchas |
| Comp store | **`store_info.is_comp_store = 1`** (77 stores). **INT64, never `= true`.** Say "comp stores only (`is_comp_store = 1`), 77 stores" in the answer. For a *historical* comp base use **`store_comp_date <= <window start>`**. **Never** `store_open_date <= <cutoff>`, never "traded in both windows" — six different proxies have been observed and one of them put $2.6M of non-comp sales inside a comp number. Rule: a store comps on the first Jan 1 after 18 months of trading |
| Channel | `revenue_category` (In-Store, Digital, Third_Party, Catering, Fundraiser) |
| Delivery (first-party) | `destination = 'CZ Delivery'` (steward rule 2026-08-04). Marketplace orders (`revenue_category = 'Third_Party'`) are NOT "delivery" unless explicitly requested — see protocol item 6 |
| Digital source | `order_source` (NULL = in-store POS) |
| App user | **Canonical customer definition (steward decision 2026-09-17, revised 2026-09-22 and 09-23).** A `person` customer with a **non-catering app purchase in the trailing 12 months** (`is_catering = false` and `order_source in ('iOS', 'Android')` **or** `in_store_scan = 1`; an in-store scan counts as an app purchase by steward assumption; catering orders never count). **A native-app session alone does not qualify since 2026-09-22** (it did 09-18 to 09-21). Materialised as `is_app_user`; how they buy is `app_purchase_mode` (`app_orders_and_scans` / `app_orders_only` / `scans_only`). Full rules, gotchas and the canonical query: see *"App user" is a canonical customer definition* below |
| Guest customer | **`customer_attribute.guest_status`** (steward decision 2026-09-22): `guest` never authenticated, `converted_guest` guest first then authenticated, `account` authenticated first. Authentication wins; a later forgotten login does not demote an account. Exposed on `claude.order_customer`. `is_guest_order` stays the ORDER flag; never call an order-level share a "guest customer" count. Lifetime status: 2023 had its own guest-checkout era (173k orders), so filter `first_order_date >= '2026-07-01'` for the relaunch cohort |
| First-time order | `order_sequence.customer_order_count = 1` **with `customer_type = 'person'`** — only back to 2023-03-06 (see gotchas) |
| Repeat order | `order_sequence.customer_order_count > 1` **with `customer_type = 'person'`** |
| Lifetime orders per customer | **`customer_attribute.lifetime_order_count`** — one row per person customer, already person-only and store-1111-excluded. **`order_sequence.lifetime_customer_order_count` was DROPPED 2026-07-29** — any query using it now errors |
| Items sold | `order_lines` where `line_item_type = 'item'`, measure `sum(qty)` or `count(*)`. **This is the default measure for item questions** — see the units-vs-dollars rule below |
| Item sales | `sum(item_gross_sales)` from `order_lines`. **Opt-in, not the default** — combo pricing distorts it (see below) |
| Item net sales | `sum(item_net_sales)` from `order_lines` — live, fully populated, safe to report **when asked**. Runs 2.3–3.8% under gross depending on sale shape, and does **not** reconcile to order-level `net_sales`; say so in the same breath. See the gotcha below |
| Menu mix name | `item_name` (size-normalized) + `item_size`; menu category via `rev_center_name` (`item_type` is only the closed 7-value rollup Entree / Kids Meals / Beverage / Discount / Promotion / Surcharge / Other as of 2026-08-12 — category values like `Desserts` return zero rows there) |

> **🚩 CORRECTION 2026-08-20 — the net-sales decomposition, in three parts. Read all three; the middle one is my own error.**
>
> **(a) The formula this skill published was unusable.** It read
> `net_sales = gross_sales - total_discount_amount - total_promotions_amount`. **`total_promotions_amount` does not exist** on the table — the discount columns are `discount_amount`, `promotions_amount`, `total_discount_amount` — so anyone copying it got `Unrecognized name`. And promotions are already inside `total_discount_amount`, so the formula double-counted them as well.
>
> **(b) 🔻 RETRACTED — my "9.2% don't reconcile" finding was mostly my own sign error.** **The discount columns are stored NEGATIVE.** `discount_amount` and `promotions_amount` come from `sum(amount) * -1` in the build, so net is `gross_sales` **+** `total_discount_amount`, not minus. Subtracting a negative added the discount back, and the 130,171 "matches" I reported were simply the orders with no discount at all. The lesson, and it is the same one this KB keeps relearning: **check the sign of a column before reporting a reconciliation gap** — a plausible-looking mismatch percentage was an artifact of my arithmetic, not of the data.
>
> **(c) ✅ FIXED 2026-08-21 — `net_sales` now deducts promotions.** The build had computed
> `bo.GrossSales + coalesce(d.total_discount_amount,0)` — the *discount* CTE only — while its own
> comment defined net sales as *"gross sales - discounts - promotions"*. `promotions_amount` was
> computed, exposed, rolled into `total_discount_amount`, and never subtracted, so net sales was
> overstated by exactly the promotions total on every promotion order (1,287 orders / $15,805.69 in
> the week measured). The steward added the term and full-refreshed all history:
>
> ```sql
> , bo.GrossSales + coalesce(d.total_discount_amount,0) + coalesce(bp.total_promotions_amount,0) as net_sales
> ```
>
> **The basis for calling it fixed is definitional, not a tie-out**: the steward's stated definition
> of net sales is gross less discounts less promotions, and the expression now matches it. That is
> the whole claim, and it is enough.
>
> **🔻 RETRACTED 2026-08-21 — do NOT validate `net_sales` against `brink_net_sales`.** An earlier
> version of this section published a year-by-year "tie-out" against that column and concluded net
> sales was "reconciled to Brink from 2022 forward" with ~$1.15M unexplained before that.
> **Steward ruling: `brink_net_sales` exists for his own purposes and is not an accuracy
> reference.** Every conclusion that rested on it is withdrawn — the per-year mismatch table, the
> 2022 reconciliation boundary, and the pre-2022 "$1.15M discrepancy," which was never a finding
> about our data at all. Do not reintroduce it, and do not quote net sales as "reconciled" on that
> basis.
>
### ✅ The sanctioned validation for net sales: `order_lines` rolled up against `order_customer` (steward 2026-08-21)

**This is the check to run, and it is the only one in the KB with the steward's blessing.** It reconciles the
line grain against the order header through different filters and joins, and it "exposes much more
detail" than a header-level comparison — when it disagrees you can see *which lines*. (The steward
also holds an external validation outside BigQuery; that is the genuinely independent source, and it
is not available to a session.)

```sql
with oc as (
  select
    oc.brink_order_id
  , oc.item_gross_sales + oc.mods_gross_sales as oc_detail_gross
  , oc.discount_amount
  , oc.promotions_amount
  from `marketing-data-442316`.sales_ops.order_customer oc
  where 1=1
  and oc.business_date between @start_date and @end_date
  and oc.store_id not in (1111, 999)
)
, ol as (
  select
    ol.brink_order_id
  , sum(if(ol.line_item_type in ('item','modifier','fee'), ol.item_gross_sales, 0)) as line_gross
  , sum(if(ol.line_item_type = 'discount' , ol.amount, 0)) as line_discounts
  , sum(if(ol.line_item_type = 'promotion', ol.amount, 0)) as line_promotions
  from `marketing-data-442316`.sales_ops.order_lines ol
  where 1=1
  and ol.business_date between @start_date and @end_date
  and ol.store_id not in (1111, 999)
  group by 1
)
select
  count(*) as orders_in_both
, countif(abs(oc.oc_detail_gross   - ol.line_gross)      < 0.005) as gross_match
, countif(abs(oc.discount_amount   - ol.line_discounts)  < 0.005) as discounts_match
, countif(abs(oc.promotions_amount - ol.line_promotions) < 0.005) as promotions_match
from oc
    join ol
    on ol.brink_order_id = oc.brink_order_id
```

**Result 2026-08-01 → 08-16, 350,761 orders present in both: gross 350,761/350,761 ($0.00), discounts
350,761/350,761 ($0.00), promotions 350,760/350,761 ($3.19 on one order).** That is the cross-path
confirmation of the promotions fix.

Three things that will trip you up running it:

1. **`line_item_type = 'fee'` MUST be in the gross sum.** `order_customer.item_gross_sales` excludes
   only *tip* items, so it includes fees, while `order_lines` breaks fees out as their own line type.
   Omitting `'fee'` manufactures a discrepancy — it produced a **$132,949.74 / 8,147-order** phantom
   gap on the first attempt here, which is exactly `sum(total_fees_amount)` for the window.
2. **~1.4% of `order_customer` orders are absent from `order_lines` by design** — 4,939 of 355,700 in
   that window, dropped by the `valid_order_lines` gate (no line with positive gross or net). Use an
   inner join and report the excluded count; a left join leaves NULLs that quietly skip `sum()` and
   fail `countif()`, making the reconciliation look worse than it is.
3. **The discount and promotion legs share a source** — both marts read `brink.brinkOrderDiscount`
   and `brinkOrderPromotion` — so those legs test the *path*, not the figure. The **gross** leg is
   the strong one: Brink's header `GrossSales` against independently summed line detail. For
   reference, header vs `order_customer`'s own detail columns summed to **−$6.48** across the same
   window.
>
> **🧰 Method note — this write-up was wrong twice, in opposite directions, and both are instructive.**
>
> **First error, circular evidence.** I "proved" the promotions gap with tests comparing `net_sales`
> to `gross_sales + discount_amount` and to `gross_sales + total_discount_amount`. Both are
> **algebraically implied by the build script** — `net_sales` *is* `gross + discount_amount`, so the
> 143,407/143,407 result was a tautology, and the second necessarily fails exactly where
> `promotions_amount <> 0`. It confirmed the table matches its own SQL and nothing more, while being
> presented as evidence about correctness. **If a reconciliation test's inputs all come from the same
> build expression, it cannot fail for an interesting reason.**
>
> **Second error, and it is the subtler one: I picked a reference column without confirming it WAS a
> reference.** Corrected, I reached for `brink_net_sales` — which this skill and the build script
> both label "for validation only" — and treated that phrase as authority. The steward's meaning was
> narrower: it is *his* cross-check, not a source of truth, and explicitly **not** to be used for
> accuracy. On that false footing I published a per-year tie-out, a "reconciled from 2022 forward"
> rule, and a ~$1.15M pre-2022 discrepancy — a confident, precise, plausible finding about nothing.
>
> The generalisable lesson is sharper than "use an independent source": **an independent source has
> to be independent *and* sanctioned as authoritative, and only the steward can confer that.** A
> column sitting in the same table, populated by the same upstream vendor, described by an ambiguous
> comment, is not automatically ground truth. Ask whose definition a column encodes before you
> measure anything against it — and note the failure mode, which is that the wrong reference
> produces answers that look *more* rigorous, not less.
>
> **Practical rule: `net_sales` is a column, not a formula — select it.** If you must decompose, use `gross_sales + discount_amount` (plus, because the column is negative) and state that promotions are not netted out.

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

### "App user" is a canonical customer definition (steward decision 2026-09-17, revised 2026-09-22)

An **app user** is a `person` customer with an **app purchase in the trailing 12 months**: at
least one **non-catering** `claude.order_customer` row (`is_catering = false`) with
`order_source in ('iOS', 'Android')` **or** `in_store_scan = 1`. The steward's stated assumption
is that an in-store loyalty scan is made with the app, so **a scan counts as an app purchase** for
this definition. State that assumption whenever the scan share matters to the answer.

> **Revision 2026-09-23 (steward): catering orders never make an app user.** The app supports
> catering ordering (about 8,000 iOS/Android catering orders a year), so 1,433 catering-only
> accounts (970 on consumer email domains, $3.0M of catering) were qualifying as app users through
> `order_source = 'iOS'` and sitting inside `app_orders_only`. The definition is about the in-store
> customer relationship, so `is_catering` orders are excluded from both halves of the test.

> **Revision 2026-09-22 (steward): opening the app is not using the app.** From 2026-09-18 to
> 09-21 the definition had a second test, a native-app `braze.app_sessionstart` in the trailing
> 90 days, and a customer who only browsed qualified as `session_only`. That test is retired.
> Sessions are still measured (`is_app_session_user`, `app_session_days_l90`) and still split
> app users into `purchase_and_session` vs `purchase_only`, but a session never makes someone an
> app user. Anything quoted between 09-18 and 09-21 (for example 468,851 app users on 09-17)
> included 23k to 51k session-only people and is not comparable to figures under this text.

The window anchors to `current_date('America/Denver')` unless the question names an as-of date,
in which case substitute that date and say so.

**Three app-purchase modes** (steward decision 2026-09-22, materialised as `app_purchase_mode`):
`app_orders_and_scans` (both in the 12 months), `app_orders_only`, `scans_only`. Mutually
exclusive. Report them alongside the headline when value is the question: on the window ending
2026-09-14 (`claude/app-segments-value-2026-09-22.md`, Analysis project) the both group was
107,377 customers at 9.54 orders and $219.56 a year ex catering, 23% of app users and 44% of
app-user restaurant sales; `app_orders_only` (139,891) and `scans_only` (170,412) were near
twins at 3.97 vs 4.03 orders and $96.69 vs $92.31 a year, and 81% of scans-only customers have
never placed an app order in their lifetime.

**Rules and gotchas**

- **It is a customer-level metric**, so `customer_type = 'person'` applies to the order side
  (kiosk, internal and aggregator ids never qualify). Report `count(distinct mapped_cust_id)`.
- **What is deliberately NOT in the definition:** native-app sessions (since 2026-09-22), in-app
  message or content card impressions and clicks, push opens, and any share-of-orders threshold.
  Keep those as engagement metrics measured *within* the app-user population. A "50%+ of orders
  via the app" cut is **not canonical**; if someone asks for it, present it as a labelled fork
  ("app-primary") and never substitute it for the definition above.
- **This is not "loyalty member", "digital customer" or "app orders".** Loyalty membership
  lives in `claude.loyalty_user`; "digital" is `revenue_category = 'Digital'`; and a
  channel question about **app orders** is `order_source in ('iOS', 'Android')` on orders,
  with no scan component and catering included unless the question excludes it. The
  scan-as-purchase assumption and the catering exclusion are for the customer definition only.
- **"App openers" / "installed but not buying"** is a real question but a different population:
  `is_app_session_user and not is_app_user` on `customer_attribute` (27,512 on the 2026-09-21
  build) plus session users with no identified order at all (~23k, only reachable through the
  Braze CTE below). On the window ending 2026-09-14, 49,236 such people existed, 6,228 (13%) had
  ordered on the web, $0.4M. Label it as its own thing, never as a kind of app user.
- **`platform` is the whole game on the Braze side** whenever sessions are measured.
  `app_sessionstart` is not app-only: the web SDK and landing pages log to the same table.
  Trailing 90 days measured 2026-09-17, `cafe_zupas` workspace: **web 1,132,440 users**,
  ios 257,285, android 63,241, landing_page 3,454. Braze platform values are **lowercase**
  (`'ios'`, `'android'`); the order-mart values are **mixed case** (`'iOS'`, `'Android'`). Join
  on `safe_cast(s.external_user_id as int64) = oc.mapped_cust_id`, never on email.
- **Materialised on `sales_ops.customer_attribute` since 2026-09-18, revised 2026-09-22:**
  `is_app_user`, `app_user_type` (`purchase_and_session` / `purchase_only` / NULL),
  `app_purchase_mode` (`app_orders_and_scans` / `app_orders_only` / `scans_only` / NULL),
  `is_app_purchaser` (now identical to `is_app_user`), `is_app_session_user`, `app_orders_l12m`,
  `in_store_scans_l12m`, `app_session_days_l90`, the three `last_*_date` columns and two lifetime
  counts, rebuilt daily at 05:20 MT with windows anchored on `attribute_asof_date`. Use the table
  for segmentation of known customers; use the query below when the as-of date is not yesterday.
  **`is_app_user`, `app_user_type` and `app_purchase_mode` are also on `claude.order_customer`**,
  so standard users can split orders by app-user status directly: all three are **NULL on
  unidentified and non-person orders**, so filter `oc.is_app_user is true` and pair any "not an
  app user" read with `oc.customer_type = 'person'`.
- **The scan-as-app assumption, measured 2026-09-17:** 8.1% of customers who scanned in-store
  in the trailing 90 days had no native-app session in the window, versus 1.3% of customers
  who placed an app order (the Braze identification baseline). About 7,000 scanners are
  therefore counted as app users without the app being visible in Braze. Intentional; state it
  when the scan share drives the answer.
- **Pulse feed gaps blank the app-order half.** `order_source` comes from `pulse.orders`; when
  that feed stalls (2026-09-15 to 09-21) app orders read as unidentified in-store orders and only
  scans survive, so app-user counts and `app_purchase_mode` drift toward `scans_only` until the
  marts heal. Check `countif(pulse_order_id is not null)` by day before quoting a recent window.

**Canonical query** (one row per app user; the session CTE is descriptive and does not add rows):

```sql
with app_purchasers as (
select
oc.mapped_cust_id as mapped_cust_id
, countif(oc.order_source in ('iOS', 'Android')) as app_orders
, countif(oc.in_store_scan = 1) as in_store_scans
, max(oc.business_date) as last_app_purchase_date
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 12 month)
and oc.mapped_cust_id is not null
and oc.customer_type = 'person'
and oc.is_catering = false
and (oc.order_source in ('iOS', 'Android') or oc.in_store_scan = 1)
group by oc.mapped_cust_id
)
, app_sessions as (
select
safe_cast(s.external_user_id as int64) as mapped_cust_id
, count(distinct s.event_date) as session_days
, max(s.event_date) as last_session_date
from `marketing-data-442316`.braze.app_sessionstart s
where 1=1
and s.event_date >= date_sub(current_date('America/Denver'), interval 90 day)
and s.workspace = 'cafe_zupas'
and s.platform in ('ios', 'android')
and safe_cast(s.external_user_id as int64) is not null
group by 1
)
select
ap.mapped_cust_id as mapped_cust_id
, ap.app_orders as app_orders
, ap.in_store_scans as in_store_scans
, case
	when ap.app_orders > 0 and ap.in_store_scans > 0 then 'app_orders_and_scans'
	when ap.app_orders > 0 then 'app_orders_only'
	else 'scans_only'
	end as app_purchase_mode
, se.mapped_cust_id is not null as is_app_session_user
, case when se.mapped_cust_id is not null then 'purchase_and_session' else 'purchase_only' end as app_user_type
, coalesce(se.session_days, 0) as session_days
, ap.last_app_purchase_date as last_app_purchase_date
, se.last_session_date as last_session_date
from app_purchasers ap
	left join app_sessions se
	on se.mapped_cust_id = ap.mapped_cust_id
```

Headline: `count(*)` over that result is the app-user count. The join is a `left join` on purpose
(it was a `full outer join` under the 2026-09-18 text); the partition filters are constant
expressions on purpose (a value pulled from a CTE would not prune either table).

## Pre-query clarification protocol (steward rule 2026-07-28 — MANDATORY)

**Before running the query that answers the question, confirm scope.** Every one of these has burned a real answer. Ask them together in ONE message (don't interrogate the user one item at a time), then query. If the user has already stated an item, don't re-ask it.

### 1. Store 1111 — never ask, always excluded

Test/training store 1111, plus 999 which has no `store_info` row and so forms a second unnamed group. Not a question, not a default the user can override, and don't raise it as an assumption. **Which layer you're on decides who writes the filter** (steward rule 2026-09-03):

- **`claude.*` views — do NOT add `store_id not in (1111, 999)`.** All four order views (`order_customer`, `order_lines`, `order_line_discount_detail`, `order_payment_tender`) already apply it in their `view_definition`, so the predicate is redundant noise in user-facing SQL. Just note "stores 1111/999 excluded by the view" in the assumptions line.
- **`sales_ops.*` tables (steward only) — always write `store_id not in (1111, 999)`.** Nothing upstream applies it.

#### Store 1111/999: which layer already excludes them (measured 2026-08-19)

Read from `INFORMATION_SCHEMA.VIEWS.view_definition`, not from documentation:

| Object | Excludes |
|---|---|
| `claude.order_customer` | `store_id not in (1111, 999)` ✅ |
| `claude.order_lines` | `store_id not in (1111,999)` ✅ |
| `claude.order_payment_tender` | `store_id not in (1111, 999)` ✅ (fixed 2026-08-20; was `<> 1111` only) |
| `claude.order_line_discount_detail` | `store_id not in (1111,999)` ✅ (fixed 2026-08-20; previously relied on its base build) |
| `claude.store_info` | `store_id not in (0, 901, 9001)` — a different list for a different purpose (non-store dimension rows) |
| every `sales_ops.*` table | **nothing** — the filter is entirely yours |

**✅ As of 2026-08-20 the four order views are uniform** — all exclude both stores, verified against `INFORMATION_SCHEMA.VIEWS.view_definition`. The earlier asymmetry (payment_tender excluded only 1111; discount_detail carried no predicate of its own) is closed, and the `$13.49` tie-out floor it created is gone.

**Don't write the predicate on `claude` objects** (steward rule 2026-09-03, superseding the earlier "write it anyway" guidance). The views own the exclusion; repeating it in every query taught users it was theirs to remember and cluttered the SQL the steward reads. It remains *required* on every `sales_ops` table. If a number depends on the exclusion, re-verify with `select table_name, view_definition from `marketing-data-442316`.claude.INFORMATION_SCHEMA.VIEWS` rather than trusting this table — it was asymmetric for five days in August without anything failing.

> **Store 1111 is not dormant, so this still matters.** On `sales_ops.order_customer`, 2026-07-01 → 2026-08-19: **626 orders / $17,325.14 net / 223 of them `customer_type = 'person'`**. Store 999 had **zero** orders in the same window — it is `order_lines`-only and tiny, which is exactly why it went unnoticed until 2026-07-30.
>
> Two corollaries worth keeping. **(1)** `customer_type = 'person'` does *not* substitute for the store filter — 223 of those 626 orders are person orders, so a `sales_ops` cohort filtered only on customer type still pulls the test store in. **(2)** A measurement of store 1111 taken *through* `claude.order_customer` is vacuously zero, because the view filters it out. If you are asked "is the test store still active?", that question can only be answered on `sales_ops` — a zero from the `claude` layer proves nothing about the store and everything about the view. Guard against reading a view's own filter as a fact about the world.

### 2. Date range — ask

Which dates the question covers. Never assume "last 30 days" or "this month" from silence. Also confirm the interpretation when a range is fuzzy ("May" = `2026-05-01` to `2026-05-31`; "last week" = the most recent **Mon–Sat**, see the business-week gotcha).

### 3. Catering — ask

Included or excluded, defined as **`is_catering = true` / `= false`** (BOOLEAN — `is_catering = 0` fails). Since 2026-08-17 it is finance's definition — catering destination **or** pulse catering flag **or store 50 (Middleton Mobile)** — and it selects the same orders as `revenue_category = 'Catering'`. Catering skews item questions hard: catering trays/box lunches carry the same `item_name` as the retail item at very different volumes and prices, so an unstated choice here silently changes the answer.

**⚠️ Take the catering split from `order_customer`.** `order_lines` has not been given the store-50 rule yet, so an item-level catering breakdown shows store 50 as zero catering (793 orders in the 30 days to 2026-08-16). See the gotcha.

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

> **🆕 Superseded for most questions by `claude.order_line_discount_detail` (2026-08-15).** The recipe
> above still works and is the cheapest way to get a raw program total, but it can't tell you
> *how* a discount was redeemed — points vs reward vs offer, which offer, in-store vs
> integrated. Use `claude.order_line_discount_detail` for anything past a flat program total. See the
> section below.

### Store 999 joins 1111 in the exclusion list (steward rule 2026-07-30)

`store_id = 999` has **no `store_info` row**, so `store_name` and `store_state` are both NULL and it forms a second unnamed group in any store or market breakdown. It is tiny — 4 lines over 2026-05-03 → 2026-06-27 against store 1111's 24,128 — which is exactly why it survives review: it's too small to notice and too nameless to explain. Verified 2026-07-30 that 1111 and 999 are the **only** two store ids with a NULL name or state, and that `store_name` is otherwise unique across all 89 real stores (no dedup needed, no `store_id` prefix required for a readable label).

Use `and ol.store_id not in (1111, 999)` on `order_lines`, and the same on `order_customer`.

### 5. Named products — resolve the name against the data FIRST, then confirm

When the user asks about a specific product by name, **do not guess the string and go straight to the metric query.** `item_name` values don't match how people speak, one spoken name can span several rows (sizes, catering variants, LTO renames, seasonal spellings), and a wrong guess returns a clean-looking wrong number — or zero rows presented as "no sales."

Run a cheap discovery query first, show the user the list, and get confirmation:

```sql
select
ol.item_name
, ol.item_size
, ol.item_id
, ol.rev_center_name
, ol.item_type
, count(*) as lines
, sum(ol.qty) as units
, round(sum(ol.item_gross_sales), 0) as gross_sales
, round(sum(ol.item_gross_sales) / nullif(sum(ol.qty), 0), 2) as avg_unit_price
from `marketing-data-442316`.sales_ops.order_lines ol
where 1=1
and ol.business_date between @start and @end
and ol.store_id not in (1111, 999)
and lower(ol.item_name) like '%grilled cheese%'   -- broadest distinctive fragment, lowercased
group by 1, 2, 3, 4, 5
order by lines desc
```

- Match on the **shortest distinctive fragment**, lowercased on both sides. `like '%ultimate grilled cheese%'` misses `Ultimate Grilled Cheese Box`; `like '%grilled cheese%'` finds the family.
- `item_name` is a **cluster field** — these filters are cheap. Still filter `business_date`.
- **Group by `item_id` and `item_size`, and show the average unit price.** One `item_name` routinely covers several products; the price column is what makes a wrong pick visible to the user. See the size rule immediately below.
- Show the candidates with their volumes, sizes, prices and revenue centers so the user can see what they're choosing between, then ask which to include. Zero rows = say so and widen the fragment; never report `$0`.
- Only after the list is confirmed, run the metric query against the agreed **`item_id in (...)`** set (fall back to `item_name` + `item_size` only if the ids weren't resolved).

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

> **Catering ITEM ≠ catering ORDER — and there is no canonical item-side flag (first live demand 2026-09-02).** "How many trays did we sell the week before Labor Day, outside catering?" was answered three ways in one session: `rev_center_name = 'Party Trays & Food'`, `item_size in ('Party','Tray')`, and `lower(item_name) like '%tray%'`, then joined to `order_customer` with `revenue_category <> 'Catering'` to keep only regular-channel orders. Each arm returns a different population. Until an `is_catering_item` column exists (Asana 1218146236424381), use the rev-center list — `Party Trays & Food`, `Box Lunches`, `Cater Desserts`, `Cater Beverages` — as the item-side definition, exclude Discount/Promotion lines as usual, and say in the answer which side (order or item) the word "catering" applied to.

#### Size is a separate column — and `item_name` is not a product (steward rule 2026-08-27)

**The build strips the size prefix out of `item_name` and parks it in `item_size`.** In
`sql/sales_ops.order_lines.sql` the published `item_name` is the size-stripped
`item_grp_name` (line 395), and the prefix regex is
`^(REG|Mini|LG|PRTY|HALF|Kids|LARGE|Medium|Tray|QUART) `. So the name a user speaks and the
string in the column are **not the same string**:

| Predicate | Result |
|---|---|
| `ol.item_name = 'Mini Chocolate Strawberry Cup'` | **zero rows** — reads as "no sales" |
| `lower(ol.item_name) like '%chocolate strawberry%'` | the family, sizes visible |
| `ol.item_name = 'Chocolate Strawberry Cup' and ol.item_size = 'Mini'` | ✅ the product |

**Never put a size word inside an `item_name` predicate.** Match the name without it, then
filter `item_size`. A user asking about the "mini chocolate strawberry cup" is naming two
columns, not one — and the failure mode is a silent zero, which the user reads as the item
not existing.

**Worked example — Mini Chocolate Strawberry Cup** (re-measured 2026-09-11, trailing 30 days
**2026-08-12 → 2026-09-10**, sellable lines, stores 1111/999 excluded):

| `item_id` | `item_name` | `item_size` | Units | Item gross | Avg unit price |
|---|---|---|---|---|---|
| 643640578 | `Chocolate Strawberry Cup` | `Mini` | 15,717 | $141,453 | **$9.00** |
| 643640567 | `Chocolate Strawberry Cup` | `Regular` | 5,241 | $73,374 | **$14.00** |
| | | *name only* | *20,958* | *$214,827* | *$10.25* |

Answering on the name alone overstates the Mini by **33.3% in units / 51.9% in gross**, and
reports a blended **$10.25** price for a product sold at $9.00 and $14.00 and never at
$10.25. Both ids have sold since **February 2025** — not an LTO artifact, and nothing about
the name hints that it splits.

> **Both prices and the split are stable.** First measured 2026-08-27 (30 days to 08-26):
> 15,550 / 5,051 units, same $9.00 and $14.00, blended $10.23. Two weeks later the unit mix
> and the blend have barely moved. This is a permanent property of the catalogue, not a
> window artifact — don't re-derive it per question.
>
> **643640567 is `Regular`, and has been since the 2026-08-27 rebuild.** Anything still
> describing the full-size cup as NULL-sized predates that rebuild and is wrong in the
> opposite direction now: `item_size = 'Regular'` finds it, and `item_size is null` finds
> nothing at all (see the dead-filter warning below).

> ✅ **`item_size` has no NULLs and `Regular` means an actual regular size (rebuilt
> 2026-08-27 12:35 MT).** The column is a closed 9-value domain resolved in four steps:
>
> ```sql
> case
> 	when l.line_item_type not in ('item', 'modifier') then 'Not Applicable'
> 	when l.item_size is not null                      then l.item_size
> 	when f.family_has_sizes                           then 'Regular'
> 	else 'Not Sized'
> end as item_size
> ```
>
> where `family_has_sizes` comes from the **item master** (`brink_items`), not from the fact
> rows — so the value does not depend on how wide that run's reload was. Distribution
> re-measured 2026-09-11 over **2026-09-04 → 2026-09-10** (stores 1111/999 excluded); the
> 2026-08-20 → 08-26 shares from the original measurement are shown beside it:
>
> | `item_size` | Lines | Share | (08-20→26) | Names | Means |
> |---|---|---|---|---|---|
> | `Not Sized` | 757,187 | 60.8% | 62.5% | 245 | a real product with no size concept (chips, bottled drink, cookie) |
> | `Half` | 166,038 | 13.3% | 13.0% | 27 | |
> | **`Regular`** | **147,932** | **11.9%** | 11.7% | 41 | base size of a family that *has* other sizes, or a genuine `REG` prefix |
> | `Kids` | 71,751 | 5.8% | 5.1% | 28 | |
> | `Large` | 55,046 | 4.4% | 4.4% | 40 | |
> | `Not Applicable` | 38,888 | 3.1% | 2.6% | 26 | not a product line — tip, fee, discount, promotion, gift card, surcharge |
> | `Mini` | 7,013 | 0.6% | 0.5% | **2** | still only `Chocolate Strawberry Cup` and `Dubai Cup` |
> | `Party` | 751 | 0.1% | — | 7 | |
> | `Tray` | 15 | 0.0% | — | 4 | |
>
> Every share is within ~1 point of the original, so treat these as the settled shape rather
> than a moving number. **A size breakout is safe to present unlabelled** — `Regular` is ~12%,
> not 76%, and the two non-size states are named rather than hidden inside it. Filter
> `line_item_type in ('item','modifier')` for any size analysis and `Not Applicable` disappears.

> ⚠️ **Three semantics shipped for this column on 2026-08-27, hours apart.** NULL-for-unparsed
> (until ~10:53 MT), then `coalesce(..., 'Regular')` which made `Regular` **76.3%** of lines
> (10:53 → 12:35), then the CASE above. A query written against any earlier version still runs
> and returns a different number, silently. In particular **`item_size is null` is dead** — it
> returns zero rows rather than the unsized items, so it reads as "no such thing" instead of
> erroring. If you are handed a saved query or an older report that touches `item_size`,
> re-read it before trusting the number.
>
> **Why `family_has_sizes` reads the item master and not the facts** (measured before the fix):
> deriving it from `order_lines_detail` bounds it by the run's reload window, so the same item
> got different labels depending on which run wrote the partition — full-history CTAS most
> generous, 8-day narrower, intraday narrowest. On a one-day window **11 of 316 names / 2,645
> of 212,311 lines (1.25%)** flipped `Regular` → `Not Sized`: `Brisket Grilled Cheese` plus
> most fountain and bottled beverages, i.e. families whose sized variant simply does not sell
> every day. The item-master version misses **none** of the families the 30-day facts find and
> adds **11** more (a Half on the menu is a size whether or not one sold). **The general rule:
> never derive a dimension's meaning from the fact window — a dimension must not change
> because a reload was narrower.**
>
> **The reusable lesson (third instance in this KB): an upstream fix creates a downstream
> trap** — and the second fix can create its own. Filling a formerly-NULL column changed what
> every existing filter included; naming the unparsed case `Regular` then overloaded a label 22
> item names already meant something specific by. Both were improvements. Both moved millions
> of rows into a bucket something else was already reading.

**Size is necessary but not sufficient — `item_id` is the product key.** Re-measured
2026-09-11 over **2026-08-12 → 2026-09-10**, 374 `item_name` values on sellable lines
(discount/promotion markers excluded); the 2026-08-27 figures are in brackets:

| | Names | Share of names | Share of units |
|---|---|---|---|
| Span more than one `item_id` | **142** [140] | 38.0% [37.5%] | **50.6%** [50.1%] |
| …of which split by `item_size` | 49 [49] | 13.1% | 21.3% [21.0%] |
| …of which split by something **other** than size | **93** [91] | 24.9% | — |

Half the volume in the mart sits under a name that is not unique to one product, and size
explains only a third of those splits — and both figures have held steady across two
independent windows two weeks apart. Resolve to `item_id`; treat size as the most common
reason a name needs resolving, not the only one.

Two more instances of the same collision, so it is a pattern and not one dessert
(same window, re-verified 2026-09-11):

- **`Dubai Cup`** — identical shape: id 643640588 `Mini` **$12.00** (14,948 units), id
  643640587 `Regular` **$18.00** (4,638). `Mini` still exists on exactly these two names.
- **`Kids Combo`** — the same collision with no size story: id 643647054 is the `Kids`
  **$0.00** bundle slot (46,653 units), id 642361971 is the `Regular` **$7.26** paid combo
  (39,844). One name, two things, and a units count on the name double-counts every kids
  meal — here that is 86,497 where the real paid figure is 39,844.

**A size word can still survive inside `item_name`** — 14 names in the window carry one,
because the strip runs once and is case-sensitive: `PRTY TRAY Avocado Caesar Salad` loses
`PRTY` (→ `item_size = 'Party'`) and keeps `TRAY`; `Kids Combo` is special-cased to no
parsed size; and lines that miss the item master fall back to `description`, which was never
stripped (`Mini Chocolate Chips` — a Mini whose `item_size` is decided by its family, not by
the word in its name). So matching the bare name is right — but
**the absence of a size word in a name is not evidence the item has no sizes.** Check
`item_size` every time.

**`item_name` is not trimmed — two live SKUs carry a trailing space** (measured 2026-09-05,
stores 1111/999 excluded): `'Apple Juice '` (id 643636585, 839 lines that day) and
`'Strawberry Daiquiri Mocktail '` (ids 643644616 / 643644617, 73 lines). `item_name = 'Apple
Juice'` returns **zero rows** and reads as "we don't sell it" — the same failure mode as the
size strip. Resolve names with `lower(item_name) like '%…%'` or `trim(item_name)`, and once
resolved **filter on `item_id`**, never on the bare name. The analyst who found it wrapped every
`item_name` in `trim()` for a whole session (2026-09-08); the build should strip it once instead
(logged as a build fix). Same table, same lesson as `Foutain Beverages`: the `rev_center_name`
typo is a real value and must be matched as spelled.

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

## SQL style (steward rule 2026-07-23, extended 2026-07-29, 2026-08-20 and 2026-08-21 — MANDATORY)

All SQL — shown to users or executed — follows the steward's format so he can diagnose any query quickly. The rules below are the source of truth. **Do not copy layout from `sql/`** — those build scripts predate the 2026-08-20 first-field and alias-padding rules and are deliberately left unreformatted so the repo stays diffable against the deployed scheduled-query text; each one gets reformatted the next time it is actually deployed.

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
   - select list: one column per line, **leading commas with a single space after the comma** — `, oc.store_id as store_id`; column aliases use `as`
   - **the first field is flush with `select` — do not indent it** (steward rule 2026-08-20). A leading-comma list has no reason to be indented; indenting the first field alone just makes it fail to line up with everything under it
   - **`from`, `group by` and `order by` keep their values ON the keyword line** (steward rule 2026-08-21) — `from `marketing-data-442316`.sales_ops.order_customer oc`, `group by oc.business_date, oc.store_id, ol.item_name`, `order by oc.business_date`. Only the **select list** is stacked one-per-line; the tail clauses stay compact however many values they hold. ⚠️ This **reverses** the 2026-08-20 wording that said `group by` / `order by` follow the select-list layout with stacked leading-comma lines — that was an extrapolation from the select-list rule, never the steward's instruction
   - **exactly one space before `as` — never pad or column-align aliases** (steward rule 2026-08-20). `oc.net_sales as net_sales`, not `oc.net_sales                 as net_sales`. Alignment padding survives exactly one edit before it's wrong, and it turns a one-column change into a whole-block diff
   - **`case`: one `when` stays inline, two or more break and indent** (steward rule 2026-08-21). One branch: `, case when oc.is_catering then 'Catering' else 'Retail' end as channel`. Two or more: `case` alone on its own line flush left, each `when` and the `else` indented **one tab**, then `end as alias` flush left again — see the worked example below
   - **no alignment padding inside a `case` either** — single spaces throughout, never lined-up `then`s, `else`s or `end`s. Same reasoning as the alias rule: padding is wrong after the next edit and turns a one-branch change into a whole-block diff
   - CTEs: `with name as (` … `)`, chained as `, next_name as (`
   - **`where 1=1` is always the first condition**, then each real condition on its own `and ...` line — so conditions can be added, removed, or commented out without touching the rest
   - each join on its own line with `on ...` on the line directly beneath it, **lined up with the `join`**
   - **indent one additional level for each successive join**, so nesting depth is readable at a glance
   - **indentation appears in exactly two places** (steward rule 2026-08-21): successive joins with their `on` lines, and the `when` / `else` branches of a multi-branch `case`. Nothing else is ever indented — not the select list (inside a CTE or out), not the `and` lines under `where`, not the tail clauses. ⚠️ Replaces the earlier 2026-08-21 line claiming a join and its `on` are the *only* indented lines; that was wrong, and it was wrong because it was written from a corrected snippet rather than from a full query the steward had actually laid out

Wrong — indented first field, padded aliases, aligned `case`, stacked `group by`:

```sql
select
  oc.business_date                        as business_date
, case when oc.is_catering then 'Catering'
       else                     'Retail'
  end                                     as channel
, count(distinct oc.brink_order_id)       as orders
from `marketing-data-442316`.sales_ops.order_customer oc
group by
oc.business_date
, channel
```

Right:

```sql
select
oc.business_date as business_date
, case when oc.is_catering then 'Catering' else 'Retail' end as channel
, count(distinct oc.brink_order_id) as orders
from `marketing-data-442316`.sales_ops.order_customer oc
group by oc.business_date, channel
```

Full worked example — multi-branch `case`, nested joins, compact tail clauses:

```sql
select
oc.business_date as business_date
, oc.store_id as store_id
, case
	when oc.revenue_category = 'Catering' then 'catering'
	when oc.destination = 'Third Party' then 'third_party'
	when oc.pulse_order_id is not null then 'digital'
	else 'in_store'
end as channel_group
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
and oc.store_id not in (1111, 999)
group by oc.business_date, oc.store_id, channel_group
order by oc.business_date, oc.store_id
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

## Reference files (read on demand)

This skill is split so a session reads only what the question needs. **`SKILL.md` is always read in full.** Each file below is read when its trigger applies — and `gotchas.md` is read on every question. Nothing below is optional once its trigger fires.

| File | Read it when |
|---|---|
| [`references/schema_changes.md`](references/schema_changes.md) | a saved query errors on a column name; the question touches hour-of-day or daypart, employee discounts, catering redefinition, `item_type` values, or anything built before 2026-08-20 |
| [`references/payment_tender.md`](references/payment_tender.md) | the question is about how people pay (cash, card, wallets, split tenders) |
| [`references/cohorts.md`](references/cohorts.md) | the question is about new customers, repeat rate, retention, lapsed or reactivated customers, or any cohort |
| [`references/customer_attribute.md`](references/customer_attribute.md) | the question is per customer: LTV, frequency, stores visited, win-back lists |
| [`references/items.md`](references/items.md) | the question is about an item itself: launch date, price, status, catering-only, digital menu |
| [`references/query_log_reviews.md`](references/query_log_reviews.md) | you are the steward reviewing analyst query behaviour (includes the day-by-day review diary from 2026-08-25 onward), or a user pastes a saved template to run |
| [`references/incidents_and_gaps.md`](references/incidents_and_gaps.md) | any customer-, guest-, `order_source`- or app-level figure dated 2026-09-15 or later; any item question (check `order_lines` staleness first); a question needs an order-placement timestamp; a date filter seems to be "in the way" |
| [`references/discounts.md`](references/discounts.md) | the question involves discounts, promotions, offers, employee meals, "what did we give away", or tying discounts back to orders |
| [`references/incremental_build.md`](references/incremental_build.md) | you are the steward building or reloading a mart (not needed to answer questions) |
| [`references/recipes.md`](references/recipes.md) | you are about to write SQL for sales, menu mix, combos, modifiers, VTO/limited-time items, store or channel breakdowns |
| [`references/identity.md`](references/identity.md) | the question involves guest orders, loyalty identity coverage, or identified-% looks off |
| [`references/gotchas.md`](references/gotchas.md) | scan before EVERY answer — this is the checklist the single file used to end with |

## When done

If you learned something new about these tables during the session (new gotcha, new canonical definition, data quality issue), do **not** edit this skill or any local copy — only the data steward commits to the repo, and session copies are discarded. Instead, create an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`) titled `KB finding: <short title>`, describing what you observed (include the query that surfaced it) and the proposed change. The steward reviews and merges vetted findings; the next session's fresh clone benefits automatically.
