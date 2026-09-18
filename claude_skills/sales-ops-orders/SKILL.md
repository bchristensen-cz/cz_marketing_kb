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
> | No view over `sessionM.user_phone_numbers` or `sessionM.external_user_mappings` | Braze to SessionM phone sync, 2026-09 | raw `sessionM.*` |
> | No view over the `braze` dataset (profiles, engagement events) | same | raw `braze.*` |
> | **`sessionM.user_phone_numbers` is incomplete** - 185 users verified via the SessionM API to hold a live phone have *zero* rows in the table, not even soft-deleted ones (0.025% of 750K writes). Anything computed off it inherits the hole | reconciliation of SM Sync job 90977, 2026-09-12 | API GET per user |

> **⚠️ Breaking changes 2026-07-24** — `order_customer` was rebuilt across all history. `businessdate` is now **`business_date`**; `net_sales` is now the **calculated** net (read it directly); `item_net_sales` / `item_netsales_with_mods` / `mods_net_sales` are **gone**; `is_catering` was redefined; a **`customer_type`** column was added and is now **required for customer metrics**; `order_count` / `days_since_prev_order` moved to the new **`sales_ops.order_sequence`** table. Any saved query written before this date needs updating.

> **⚠️ Breaking change 2026-08-20 — `order_datetime` is now `order_datetime_local` EVERYWHERE.** The rename went to the base tables the same day, followed by a full-history refresh of both marts: `sales_ops.order_customer`, `sales_ops.order_lines`, `claude.order_customer` and `claude.order_lines` all say `order_datetime_local`. Selecting `order_datetime` fails on every one of them. Value and type unchanged (DATETIME, store-local).
>
> Two knock-ons worth knowing. **(1)** `claude.order_customer` and `claude.order_lines` were *broken* for a window between the base rename and their redeploy — a `select *`-style view naming the old column in `except(...)` fails to parse entirely (`Column order_datetime in SELECT * EXCEPT list does not exist; failed to parse view`), so the whole view was unqueryable rather than merely missing a column. Redeploying every view over a renamed column is not optional cleanup. **(2)** `sales_ops.customer_attribute` and `customer_id_map` read the column and needed their own edits — `customer_attribute` aliases it back (`oc.order_datetime_local as order_datetime`) so its public `first_order_datetime` / `last_order_datetime` columns are unchanged.
>
> **Why:** on 2026-08-19, **73 of one analyst's 160 queries** contained `timestamp(order_datetime)` and **zero** used `order_timestamp_utc`. That bare cast assumes the value is UTC. It isn't — it is store-local, across **four** live UTC offsets (Ohio 4 h, IL/MN/TX/WI 5 h, ID/UT 6 h, AZ/NV 7 h), so every affected order read 4–7 hours early with no constant offset available to correct it downstream. The name `order_datetime` gave no hint of that; `timestamp(order_datetime_local)` reads obviously wrong at the call site, and the rename fails loudly on saved queries rather than silently returning a plausible number.
>
> **Rule: two time columns, two jobs, never convert between them yourself.**
>
> | Question | Column |
> |---|---|
> | Daypart, hour-of-day, "what time do people order", anything shown to a human | **`order_datetime_local`** (DATETIME) |
> | Any comparison against Braze or another UTC source | **`order_timestamp_utc`** (TIMESTAMP) |
>
> Neither column is redundant and neither is being dropped — dropping the local one would push a timezone conversion into daypart analysis (the most common time question), and dropping the UTC one recreates this exact bug. If you find yourself wrapping either in `timestamp()` or `datetime()`, you have picked the wrong column.
>
> **🚨 Hour-of-day is NOT comparable across years yet — 2024 rows of `order_datetime_local` carry a 12-hour clock with no AM/PM (steward working note, 2026-09-02; extent unmeasured in the KB).** The steward's own Labor Day hour-by-hour comparison (2025 vs 2024 Mondays) had to patch the 2024 arm: `case when extract(year from business_date) = 2024 and extract(hour from order_datetime_local) between 1 and 9 then extract(hour from order_datetime_local) + 12 else extract(hour from order_datetime_local) end`. Stores open ~10:00, so in the affected rows hours 1–9 can only be 13:00–21:00 read off a 12-hour clock. Consequences until the build normalises it: **(a)** any daypart / hour-of-day / "lunch vs dinner" split that includes 2024 puts every afternoon and evening order into a 1–9 a.m. bucket that does not exist, silently; **(b)** a YoY daypart comparison against 2024 is wrong on both the current-year and prior-year side unless the CASE above is applied; **(c)** `order_timestamp_utc` is derived from this column, so it inherits the defect for the same rows — Braze↔order attribution against 2024 orders is shifted 12 hours. The steward measured the affected month range on 2026-09-02 (`countif(extract(hour) between 13 and 23)` vs `countif(extract(hour) between 1 and 9)` by month, 2023-01 → 2026-08, days 10 and 20 of each month); the result is not yet in the KB — treat **"2024" as the working boundary, not a verified one**, and re-run that probe before quoting a range. Logged as a build defect (Asana 1218146293827269). Related: the daypart gap (Asana 1218013729974930) now has a **third** competing bucketing in live SQL — the steward's own `10–12 lunch / 13–16 afternoon / 17+ evening`, alongside the analyst's `10–13` and `11–14` lunches — so until it is ratified, state the hour boundaries in every daypart answer.

> **⚠️ Breaking change 2026-08-17 — `order_customer.is_employee_discount` is GONE.** The column was dropped from the table; naming it now errors rather than returning a stale value. Employee / team-member meal questions run on **`claude.order_line_discount_detail.is_employee_meal_discount`** (line-level, never NULL, covers all four eras of the benefit). Aggregate with `max()` / `logical_or()` for an order-level flag.
>
> **⚠️ Catering was redefined the same day (finance's definition).** `is_catering` and `revenue_category` on `order_customer` now both count **store 50 (Middleton Mobile)** as catering, and the two columns select identical orders. **`order_lines` has not caught up** — see the store-50 gotcha before answering any item-level catering question.

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

> **🛠️ Steward checklist — any full-history rebuild of `order_lines` must be followed by a full-history rebuild of `sales_ops.order_line_discount_detail`** (added 2026-08-15). `order_line_discount_detail` is derived from `order_lines`, and its widest scheduled reload is 730 days — **65.1% of its rows (2,239,212 / −$15.6M) sit before that floor and are never refreshed by any scheduled run.** `order_lines` was restated across full history three times in the month to 2026-08-14 (07-30, 07-31, 08-12); each one silently changes the parent beneath that frozen block. The full-history build is the commented header in [`sql/sales_ops.order_line_discount_detail.sql`](../../sql/sales_ops.order_line_discount_detail.sql).

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
>
> **⚠️ And do not go to `pulse.*` for the guest's email — that is a wall breach, not a workaround**
> (observed again 2026-08-28, 10:04–10:18 MT: an analyst MCP session joined `pulse.order_customers` /
> `pulse.customers` in five queries to recover guest-typed emails, because guest web orders carry
> **NULL `email` and NULL `mapped_email`** on the order marts — no mart column holds the
> guest-supplied address yet, Asana 1217645882648277). **Recurred at scale 2026-08-31**: ~25 MCP
> queries in one analyst session ran a guest first-order cohort keyed on `lower(pulse.order_customers.email)`
> and joined it forward to Braze push/SMS engagement for guest-conversion lift — and the workaround
> doesn't even scale (two of the runs were killed at the 3-minute MCP timeout). The steward has an
> email-based guest identity mapping built and validated (full history, powers the Guest Checkout
> Relaunch dashboard); it is **pending deployment to the `claude` dataset** (Asana 1218000084425507).
> Until it deploys, guest-identity questions (which email placed this guest order, guest→account
> conversion by email, guest repeat behaviour across identities) are **unanswerable from the
> marts — say so and log the question as a KB finding rather than crossing the wall.**
>
> **⚠️ A third `pulse.customers` purpose appeared 2026-09-11 07:09 MT, and this one the marts
> already answer.** Two MCP queries (current year + a `date_sub(current_date(), interval 364 day)`
> YoY arm) read `pulse.customers.created_at` to build "contacts created in week W who have never
> ordered". **`claude.loyalty_user.registered_date` is the signup date** and joins to
> `order_customer.mapped_cust_id` via `sm_external_user_id` — the whole cohort runs inside
> `claude.*` for ~0.1 GiB. Recipe, measured numbers and the two caveats (it is a *loyalty* signup,
> not a Pulse contact; the newest weeks are right-censored) are in **`sessionm-loyalty`, "Signup
> cohorts"**. Reach for that before you reach for `pulse.*`.

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

> **🚨 A year-over-year repeat rate must censor BOTH years identically (observed 2026-08-25).**
> The live analyst template grew a YoY arm and got this exactly backwards. The LY cohort anchors
> on `date_sub(current_date(), interval 364 day)` and its 91-day forward window has **fully
> elapsed**; the CY cohort's forward window runs to `date_add(current_date(), interval 91 day)`
> — **91 days into the future**. So a matured LY number is being compared against a
> right-censored CY number.
>
> CY reads low *by construction*, the gap is entirely an artefact, and the output is worse than
> a plain wrong number: it arrives pre-loaded with a story ("repeat rate is down versus last
> year") that a reader has no way to distinguish from a real decline.
>
> **Rule: apply the same elapsed-days test to every year in the comparison, and truncate both to
> the shorter one.** For a 90-day metric, if CY's newest quotable cohort is 2026-05-15, then LY's
> cohort must be cut at the matching relative position too — not left to run to its natural,
> fully-matured end. Then say in the answer which cohort end-dates each year used.
>
> Same tell as the single-year case: **if the longer window stops exceeding the shorter one in
> either year, that year is unfinished.** Check it per year, not once for the query.
>
> (Padding a forward-looking CTE's window past today is harmless on its own — there are no rows
> there. It becomes a defect the moment the two sides of a comparison are padded differently.)

### 2. 🚨 HARD RULE: never scan history to find a customer's first order (steward rule 2026-09-09)

**"First order ever", "new customer", "days to second order", "lapsed / reactivated" are
already columns.** There is no question in this family that needs a `min(...) group by
customer` over the table, and every such scan is billed in full because the only partition
filter it can carry is "everything".

| Question | Use this — one bounded pass | Never this |
|---|---|---|
| New customers in a window | `customer_order_count = 1` with `business_date between @s and @e` | `min(business_date) group by mapped_cust_id` over history |
| Their first-order date / store / channel | the `= 1` row itself (it *is* the first order) — or `first_order_date` | `array_agg(... order by business_date limit 1)` over history |
| Second order within N days | `customer_order_count = 2 and days_since_prev_order <= N` and `date_sub(business_date, interval days_since_prev_order day) between @s and @e` (recovers the cohort date from the second order — no self-join) | `eord`/`sec` self-join, 470-day cohort scanned from 2023 |
| Lifetime orders / tenure | `lifetime_order_count`, `first_order_date`, `customer_tenure_days` (as-of yesterday) | `count(*) over (partition by …)` over history |
| Lapsed / reactivated | `days_since_prev_order >= 180` on the reactivating order | `lag()` over full history |

**Why a history scan cannot even beat the columns:** `order_sequence` and
`customer_attribute.first_order_date` both start on **2023-03-06** (measured 2026-09-09 —
`min(business_date)` / `min(first_order_date)`; the identity mapping has no earlier floor). A
hand-rolled `min()` over `order_customer` from any date **is the same population**, just paid for
again. The analyst tracker that scans `between date('2023-03-06') and current_date()` is not
"going deeper than the mart" — it is re-deriving the mart's own floor.

**Cost, measured on the query log (2026-08-31 → 09-08):** the `with eord as (…)` tracker ran
**70× on 2026-09-08 at ~2 GiB per execution ≈ 140 GiB**, and **188 of the analyst's 2,350
queries since 08-10 reached back 3+ years (323 GiB)** — all but ~15 of them were first-order
floors, not questions about old years. The bounded shapes above read the cohort window only
(tens of MiB).

> **The rule landed 2026-09-09 and the tracker still ran on 2026-09-11** (07:09:35 MT, one
> execution, `with eord as (…)` scanning `between date('2023-03-06') and current_date()`). Once,
> not seventy times, so the rule is working — but it is not self-enforcing, and the shape survives
> in whatever template the analyst is pasting from. Rewriting that template at source is the open
> fix (Asana 1217645792289097); until it lands, expect this shape to reappear and replace it with
> the bounded form rather than just noting it.
>
> **Related, same tracker, measured 2026-09-11/13: the metric drifts between runs.** The
> "new customers and banked second orders since 2026-06-15" question ran nine times over the two
> days with **four different definitions** — `countif(customer_order_count = 1)` in some runs and
> `count(distinct oc.mapped_cust_id)` in others; `days_since_prev_order <= 90` sometimes inside the
> `or` branch and sometimes only in the outer predicate (which changes which first orders enter the
> cohort at all); and "banked through yesterday" written three ways (`business_date <
> current_date`, `<= date_sub(current_date, 1)`, `< date_sub(current_date, 1)` — the last is two
> days ago, not one). Same question, different answers, no way for the reader to tell which run
> they got. **Name the definition once and quote the boundary in the answer**: cohort = first
> orders in [start, end], banked = `customer_order_count = 2 and days_since_prev_order <= N` with
> the cohort date recovered by `date_sub(business_date, interval days_since_prev_order day)`, and
> "through yesterday" = `business_date <= date_sub(current_date('America/Denver'), interval 1 day)`.
> A canonical first-order-cohort mart is the durable fix (Asana 1217493799685485).
>
> One harmless artefact in the same template, so nobody re-derives it: the filter
> `lower(coalesce(oc.mapped_email, oc.email)) <> 'nan'` matches **nothing**. Measured 2026-09-14
> over 2026-06-15 → 09-13, stores 1111/999 excluded, 2,095,686 orders: **zero** `'nan'` values in
> `email`, `mapped_email`, or the coalesce. It is a pandas-export leftover, not a real sentinel.

`customer_order_count = 1` on `claude.order_customer` already marks a customer's first order,
and `days_since_prev_order` on the `= 2` row already gives days-to-second — both folded in
from `order_sequence`, both person-filterable via `customer_type`. Use them.

```sql
-- New customers by week, and % with a 2nd order within 30 days — ONE pass, cohort window only
select
date_trunc(oc.business_date, week(monday)) as cohort_week
, countif(oc.customer_order_count = 1) as new_customers
, countif(oc.customer_order_count = 2 and oc.days_since_prev_order <= 30) as second_within_30
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date between @cohort_start and date_add(@cohort_end, interval 30 day)
and (oc.customer_order_count = 1
	or (oc.customer_order_count = 2
		and date_sub(oc.business_date, interval oc.days_since_prev_order day) between @cohort_start and @cohort_end))
and oc.customer_type = 'person'
and oc.is_catering = false
group by 1
order by 1
```

Caveats that travel with the columns: `customer_order_count` counts **all** of a customer's
orders (catering, store 1111) before the view filters them, so a visible sequence can skip
numbers; `lifetime_*` / `first_order_date` are as-of yesterday; and only cohorts whose window
has closed are quotable (§1). If a question truly needs pre-2023-03-06 history, say that the
identity mapping does not exist there and log it as a gap — do not scan.

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

**And there is a second, sharper reason (steward 2026-08-24): `oc.email` is the ORDER email, not
the customer's email.** A guest may give us any address at checkout so we can send updates about
*that order*; the canonical customer email is `pulse.customers.email`, which reaches the mart only
as the first fallback of `mapped_email`. So `email` is *always* user-typed, and `mapped_email` is
canonical only when the customer row has one — on **19,168 of 136,653 July 2026 `person` orders
(14.0%)** it does not, and `mapped_email` is a typed order/booking address instead. Of the 17,842
customers behind that 14%, **7,315 have an order email equal to some `pulse.customers.email`** and
**143** of those addresses are owned by more than one id. An email-keyed cohort does not merely
merge known duplicates — it can merge strangers on an address the account never claimed. Use
`mapped_cust_id`. Full measurement in `data_dictionaries/sales_ops.order_customer.md` →
"Order email vs canonical email".

### 3. Customer cohorts require `customer_type = 'person'`

Every metric in this section is customer-level, so hard rule 6 applies without exception. A
cohort built without it pulls the aggregator id (~108K orders/month) and shared kiosk terminals
into "new customers." Observed missing from all 12 cohort queries on 2026-08-13.

### 4. 🚨 `net_sales between 3 and 200` is NOT a canonical filter — it is an undeclared population change (observed 2026-08-27)

**32 of one analyst's 156 MCP queries on 2026-08-27** carried
`and o.net_sales between 3 and 200` on the order CTE feeding campaign-lift and repeat-rate
measurements. It appears nowhere in this KB, has never been ratified by the steward, and is
never mentioned in the answers it produces. Measured on `claude.order_customer`,
2026-08-01 → 08-26, person / non-catering / stores 1111+999 excluded (199,451 orders):

| | Orders | Share |
|---|---|---|
| `net_sales < 3` | 7,420 | 3.72% |
| `net_sales > 200` | 236 | 0.12% |
| **Excluded in total** | **7,656** | **3.84% of orders, 1.32% of net sales** |

Two separate problems, and the small headline percentage is what hides them:

1. **It is not an outlier filter, it is a segment filter.** The `< 3` tail is 97% of what it
   removes, and a sub-$3 order is overwhelmingly a **fully-discounted or fully-redeemed
   order** — exactly the loyalty and offer behaviour a campaign test is trying to detect.
   Dropping it removes the treated group's most likely response before the lift is computed.
   The `> 200` tail is 236 orders and does essentially nothing; the bound is doing no real
   outlier work in either direction.
2. **It is applied asymmetrically by accident.** In the observed template the bound sits on
   the orders CTE only, so it silently reshapes both the numerator and the denominator of a
   rate, while the Braze-side arm definition is untouched. If one arm redeems more, that arm
   loses more orders.

**Rules:** don't add a value bound to an order population unless the question asked for one.
If a genuine outlier concern exists, say so, bound only the tail you can justify, and **state
the bound and its row count in the answer**. A filter that changes the population and is not
named in the output is indistinguishable from a wrong number to whoever reads it. If someone's
saved template carries this bound, that is a rewrite, not a caveat (same disposition as the
`lower(email)` bridge above).

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

## `sales_ops.items` — the item-grain table (new 2026-09-14)

**Reach for this before writing your own `group by item_id` over `order_lines`.** If a question
is about an *item* rather than about sales — what is it, what size, what does it cost, when did
it launch, is it still selling, is it catering-only, is it on the app — the aggregate already
exists and every session gets the same answer from it. One row per Brink `item_id`, 3,242 rows,
rebuilt daily at 07:30 MT. Built on `sales_ops.item_daily` (item × day, partitioned on
`business_date`), which is also the right table for an item trend line.

| Need | Column |
|---|---|
| Resolve a name to the real SKU | `item_id`, `item_name`, `item_size`, `avg_unit_price_90d` |
| Is it still on the menu | `item_status` (`selling` / `dormant` / `discontinued` / `never_sold`), `stores_selling_28d` |
| When did it launch | `launch_date` (chain rollout) vs `first_sold_date` (first sale anywhere) |
| Price | `current_price`, `price_min`, `price_max` |
| Catering-only SKU | `is_catering_item` (60 ids), `catering_unit_share` |
| Sold as a modifier, not an item | `sold_as` |
| Digital menu | `pulse_item_id`, `is_on_digital_menu`, `pulse_category_name` |

`items.item_name` and `items.item_size` are **identical to the `order_lines` values** for the
same id — verified on 548 of 548 ids sold in the trailing 45 days, zero mismatches — so the
join is safe and no re-derivation is needed.

Three things to know before using it:

1. **`item_name` is still not a product key.** That rule does not change because a dimension
   exists. Resolve to `item_id` first; `items` just makes resolving cheap, and
   `avg_unit_price_90d` next to each candidate is what makes a wrong pick visible.
2. **96 item_ids carry different products at different stores** (`640934279` is
   `Combo Turkey Cranbry Sand` at 37 stores and `Combo Turkey Avocado Club` at 29). The table
   publishes the most-stores name and flags the rest with
   `is_name_ambiguous_across_stores`. A store-specific question cannot be answered from this
   table.
3. **Join it only to sellable lines.** On `discount` / `promotion` / `surcharge` lines
   `order_lines.item_id` is a DiscountId / PromotionId / SurchargeId, not an item id.

`launch_date` is **derived**: the first business date the item sold in at least 25% of the
stores it ever reached. Brink itself carries no item dates — `CreatedTime`, `StartDate`,
`EndDate` and `LastEditedTime` are blank or NULL on all 214,182 master rows. 1,565 of 2,234
sold items have `launch_date` later than `first_sold_date`, so quoting the wrong one turns a
three-store test into a chain launch.

`has_ever_sold` is the filter that matters, not `is_active_anywhere`: 1,008 ids have never
sold and 962 of those are still Active in Brink, most of them POS config artifacts
(`*** For 31 ***` guest-count markers, `** DEST TRAY **`).

Full column list: [`data_dictionaries/sales_ops.items.md`](../../data_dictionaries/sales_ops.items.md)
and [`data_dictionaries/sales_ops.item_daily.md`](../../data_dictionaries/sales_ops.item_daily.md).

⚠️ There is **no `claude` view over either table yet** — standard users cannot reach them.
Name it as a mart gap if a user needs it.

## Hard rules (consistency guarantees)

1. **Never query upstream/raw datasets** (`brink.*`, `pulse.*`, `sessionM.*`) to answer business questions. They contain voided rows, duplicates, and unfiltered records that these marts already handle. If the marts can't answer the question, say so — don't improvise from raw tables.
2. **Always filter the partition column** on every table. It is **`business_date` everywhere** as of 2026-07-30 — `order_customer`, `order_sequence` and `order_lines` all agree. Never run unbounded scans. `sales_ops.order_line_discount_detail` uses `business_date` too. ("Everywhere" means the documented marts: the 2026-07-30 rename did **not** cover undocumented `sales_ops` tables — the since-removed `sales_ops.order_discount` still spelled it `businessdate`, observed failing a `business_date` query 2026-08-06. If you're on a table this skill doesn't document, you shouldn't be — but don't assume the column name either.) **A non-partition predicate is not a substitute for the date** — filtering a raw Brink table by `Id` alone still reads every partition, and `LIMIT` does not bound bytes; see [the 2026-08-18 finding](#️-commenting-out-the-date-filter-is-not-widening-the-search--an-id-predicate-prunes-nothing-measured-2026-08-18).
3. **Same metric, same definition.** Use the canonical definitions below verbatim.
4. Data is fresh as of the top of the current hour (loads run at minute :02, intraday 8am–11pm MT reload today's date only; hours 0–4 and 6–7 skip). **Since 2026-09-08 the three order marts and `order_sequence` are one chained scheduled query (`sql/sales_ops.order_marts.sql`) and the 5am run reloads FULL history for all of them**, so yesterday and older is stable after 5am and the marts can no longer disagree on reload width. Loyalty identity (`sm_email`, `sm_external_user_id`, `in_store_scan`) on the current business date is near-empty until SessionM's daily load lands — see the `order_customer` dictionary.
5. **Brink is the sole financial source of truth** (steward rule 2026-07-23). Pulse is a helper for digital order/customer metadata only — never compute financials (sales, discounts, tax, tips) from Pulse data.
6. **Customer metrics require `customer_type = 'person'`** (steward rule 2026-07-24). See below — this is not optional.
7. **All datasets are read-only.** If you need to materialize a table (intermediate results, cohorts), create it ONLY in `marketing-data-442316.scratch` — the single writable dataset; tables there auto-expire after 7 days. Materialize with `create table scratch.x as ...`, not views: a view over a heavy query silently re-runs the full scan on every select.
8. **User-supplied SQL follows the same rules as SQL you write** (steward rule 2026-08-05). If the user pastes a query and asks you to run it, check it first: `brink.*`, `pulse.*`, `sessionM.*`, `staging.*`, `braze_stream.*` and the legacy `sales_ops.OrderCustomer` table are exactly as off-limits pasted as they are generated. Don't run it as-is — explain why and offer the mart translation. The legacy workbook's cohort template in particular is answerable without the wall: first-order cohorts and time-to-second-order come from `claude.order_customer`'s folded `customer_order_count` / `days_since_prev_order` and from `customer_attribute`; offer redemptions come from `claude.loyalty_offer_usage`; promotion names come from `order_lines` `line_item_type = 'promotion'`. Observed 2026-08-04: the frozen analyst workbook template ran MCP-labeled through two analyst sessions — 64 `pulse.*`, 9 `sessionM.*` and 2 `staging.*` queries in one day. Recurred 2026-08-11: a 21-query MCP burst (37.8 GB billed, all timestamps within one minute) hit `pulse.order_customers`, `pulse.customers` and legacy `OrderCustomer` again — the burst shape is the tell that a session is executing a saved template rather than answering typed questions. Recurred a third consecutive day 2026-08-12: an 11-query burst (~17 GB, all timestamps within one second) mixing `sales_ops.order_customer`, `braze.*` full scans and `pulse.customers`, plus separate morning queries on legacy `OrderCustomer` — cohorts keyed on `lower(coalesce(mapped_email, email))` instead of `mapped_cust_id`, no `customer_type = 'person'` anywhere. Recurred a **fourth** consecutive day 2026-08-13: 12 MCP-labeled queries / 18.45 GB from one analyst — 2 morning queries on legacy `OrderCustomer` (`businessdate`, `iscatering=0`, `storeid<>1111`), then a **10-query burst all stamped 11:11:52** hitting `pulse.customers` and `sales_ops.order_customer` directly, still email-keyed, still no `customer_type`, and now with **no partition filter on `order_customer` at all** in the shared cohort CTE. Four days, same template, escalating cost. The wall means nothing if a session executes whatever it's handed — and a burst of identical-timestamp queries is the signature to look for. Recurred a **fifth** business day 2026-08-14, and the shape has changed in a way worth reading carefully: **no `pulse.*` breach at all this time**, and the same analysts' cohort work ran cleanly on `claude.order_customer` with `customer_type = 'person'` and proper partition filters. What survived is the legacy table itself — 3 queries across 2 users, including a `max(businessdate)` freshness check, plus one 90-day `OrderCustomer` cohort joined to `sales_ops.order_lines` **with no partition filter on `order_lines`** (12.76 GiB for a top-15 item list). Read that as progress with a specific residue: the wall guidance landed, the *table substitution* did not, because the legacy name is still valid SQL that returns plausible numbers. Loud failure retired the `BusinessDate` spelling in one day; `OrderCustomer` has survived five because nothing about it errors.

**Sixth business day, 2026-08-17 — and the cost stopped being incidental: 82 MCP queries / 267.18 GiB billed from one analyst in a day** (up from 18.45 GiB on 08-13, a 14x escalation). Three things in that day are worth carrying forward as rules, because each is a *new shape* rather than a repeat:

1. **The unbounded scan moved somewhere a partition filter cannot reach it.** The 12:07 burst (11 distinct templates, 34 executions, all timestamps within one second) opens with
   ```sql
   -- ANTI-PATTERN, do not copy
   from `marketing-data-442316`.sales_ops.order_customer
   where is_catering = false and store_id <> 1111 and coalesce(mapped_email, email) is not null
   ```
   — **no `business_date` predicate at all.** The date bound lives downstream as `having date(min(odt)) between …` on a `group by` email. That is not a filter BigQuery can push into partition pruning: `min()` over a group is only knowable after reading every partition, so the full table is scanned by construction, once per query. Earlier reviews recorded "no partition filter" as an omission; here it is **structural** — the template cannot be fixed by adding a `where` clause, only by re-keying onto the precomputed columns. Watch for the signature: **a date range expressed in a `HAVING` over an aggregate of the date column means an unbounded scan, however tidy the SQL looks.** The fix is `claude.order_customer.customer_order_count = 1` (first order, already computed, partition-filterable) or `customer_attribute.first_order_datetime` (precomputed, dimension-sized).
2. **A defect the KB documented on 2026-08-13 was still hard-coded verbatim four days later.** One template again bounds its cohort `having date(min(odt)) between date('2026-06-15') and date('2026-09-13')` — an end date **four weeks in the future**. Guidance reached the analyst's *new* work (see the good news below) but not the saved template, because nothing about a future date errors. **Assume any finding about a saved template persists until the template itself is rewritten**; re-documenting it a second time changes nothing.
3. **Legacy `OrderCustomer` is now the single most expensive object in the log.** Two Braze-attribution queries billed **45.38 and 45.34 GiB each** — self-joining `OrderCustomer` to itself on email (a `cohort` CTE for `min(first_order_datetime)` and a `fwd` CTE for forward orders, both scanning 9 months) to re-derive forward-order counts that `customer_order_count` / `days_since_prev_order` already carry. The columns that make it attractive (`lifetime_order_cnt`, `first_order_datetime`) are precisely the ones the marts fold in for free.

> **✅ Genuine progress the same day, and it locates the real obstacle.** At 15:10–15:12 the same analyst ran a cohort analysis that is textbook-correct: `claude.order_customer`, `customer_type = 'person'`, `is_catering = false`, `store_id not in (1111, 999)`, `customer_order_count = 1`, a real partition filter, cohorts keyed on `mapped_cust_id`, **and** a maturity bound (`wk <= date_sub(current_date, interval 37 day)`) implementing the 2026-08-13 right-censoring rule. Cost: **0.55–1.31 GiB** per query versus 45 GiB for the legacy equivalent — the compliant path is ~40x cheaper, which is the argument to lead with.
>
> It failed on its first attempt with `No matching signature for operator <= for argument types: TIMESTAMP, DATETIME` — a **type mismatch between `order_datetime` (DATETIME) and a Braze TIMESTAMP**, not a wall or a definition problem. That is the friction that sends analysts back to a legacy table they know compiles. The pairing rule is now documented in the `braze-campaigns` skill: compare on **`order_timestamp_utc`**, never `order_datetime`, when the other side is Braze. **Read this as the operative lesson of the day: the compliant path lost adoption on ergonomics, not on trust or on cost.** When a correct query errors and a wrong one doesn't, document the correct query's sharp edges with the same urgency as the wall itself.

**Seventh business day, 2026-08-18 — 460.37 GiB from one analyst, and the day's clearest lesson is that documentation cannot fix a saved file.** Measured on `JOBS_BY_PROJECT` for the Denver day, one MCP-labeled analyst account, 144 jobs:

| What | Count of 144 | GiB |
|---|---|---|
| Reference legacy `sales_ops.OrderCustomer` | 41 | **293.84** (63.8% of the day) |
| Reference `pulse.*` in the query text | 34 | 106.32 |
| Still carry the hard-coded future end date `2026-09-13` | 17 | 28.28 |
| Contain `customer_type = 'person'` | **4** | — |
| Reference any `claude.*` object | **4** | — |

Read the last two rows together: **~97% of one analyst's day ran outside the sanctioned interface layer.** Day totals are escalating, not settling — 18.45 GiB (08-13) → 267.18 (08-17) → 460.37 (08-18). The two most expensive templates billed 91.37 and 91.31 GiB across two runs each, i.e. the same ~45.6 GiB email-self-join Braze attribution queries recorded on 08-17, run twice.

Three things worth carrying forward:

1. **The `2026-09-13` future cohort end date has now been documented three times and edited zero times** (08-13, 08-17, 08-18). Stop re-documenting it. The defect survives because *nothing about it errors*: it compiles, returns a plausible pooled rate, and lives in a saved template nobody reopens. **Guidance reaches new work and cannot reach a saved file** — the same analyst authored a textbook-correct cohort query on 08-17 while this template kept running unchanged beside it. If a rule must hold inside a template, ship it as something that returns zero rows rather than a wrong number: `and cohort_end <= date_sub(current_date, interval @window_days day)`.
2. **A wall breach can have a legitimate cause, and the cause is the thing to fix.** Five templates reach into `pulse.order_customers` under a predicate of `oc.email is null and oc.mapped_email is null` on `source in ('mobile_web_source','web_source')` — they are recovering **the email a guest typed at checkout**, which no mart column carries. That's a mart gap wearing a breach's clothes (Asana 1217645882648277, flagged as inferred from SQL and not yet measured). Closing it removes the motive for about a third of the pulse queries; repeating the rule would not.
3. **The clean day did not stick.** 08-14 had zero `pulse.*` queries and was recorded as progress. 08-18 has 34, at higher volume than the 08-04 record. One compliant day is noise, not a trend — don't close a systemic finding on it.

**Eighth business day, 2026-08-19 — the migration finally happened, and it carried a silent error across with it.** Same analyst account, 160 MCP jobs / **431.49 GiB** (08-18: 144 / 460.37). The first genuine movement in eight reviews:

| Signal | 2026-08-18 | 2026-08-19 |
|---|---|---|
| Queries referencing `claude.*` | 4 | **44** |
| Queries with `customer_type = 'person'` | 4 | **54** |
| Queries referencing legacy `sales_ops.OrderCustomer` | 41 / 293.84 GiB | 39 / **184.72 GiB** |
| Cohorts keyed on `mapped_cust_id` | ~0 | 13 (vs 102 still email-keyed) |
| `having date(min(odt)) between …` unbounded shape | most | 67 |
| Hard-coded future end date `2026-09-13` | 17 | 8 |

Three lessons, and the middle one is the reason to read this section rather than skim the table.

1. **A partial migration is progress and must be recorded as such.** Guidance did move a template that three previous write-ups could not. What moved it was not repetition — it was the cost argument plus a working correct example, and the residue is concentrated in the *saved* file rather than in the analyst's judgement (Asana 1217645792289097).

2. **🚨 The migration introduced a new, silent, worse defect than the one it fixed: 73 of the 160 queries carry `timestamp(order_datetime)`, and `order_timestamp_utc` appears in zero of them.** The 2026-08-17 `TIMESTAMP vs DATETIME` type error was resolved by wrapping the local datetime in a bare `timestamp()` — which assumes UTC — instead of switching to the UTC column. `order_datetime` is **store-local**, and the chain spans **four** live UTC offsets (Ohio 4 h, IL/MN/TX/WI 5 h, ID/UT 6 h, AZ/NV 7 h — measured 2026-08-01 → 08-16, 355,700 orders), so every affected order reads 4–7 hours earlier than it happened, with **no constant offset available to correct it downstream**. Full measurement and the retraction of the old `timestamp(x, 'America/Denver')` advice are in [`braze-campaigns`](../braze-campaigns/SKILL.md). **The general lesson: when you push a user off a wrong table, check what they did to the code to make it compile against the right one.** Fixing the routing does not fix the semantics, and the second error is quieter than the first — a wrong table returns numbers someone might sanity-check, a wrong timezone returns numbers nobody can.

3. **One reported "regression" was not one — verify a dropped filter before writing it up.** 42 of the 44 migrated `claude.order_customer` queries dropped their `store_id <> 1111` predicate, which looks exactly like a compliance regression. It isn't: the view already excludes 1111 and 999. Checking `view_definition` took one query and prevented a false finding — and turned up the real one, that the exclusion is *inconsistent across the five `claude` views*. See [the per-view table](#store-11111999-which-layer-already-excludes-them-measured-2026-08-19).

> **✅ The positive control, same day.** A second MCP account (`dgetz@`) ran 26 jobs / 13.5 GiB with **zero** raw-dataset queries and zero legacy-table queries, diagnosing a guest-checkout-recovery canvas: `claude.order_customer` with `customer_type = 'person'`, `is_catering = false`, a real partition filter, the folded `customer_order_count` / `days_since_prev_order` columns, **`order_timestamp_utc`** for the Braze comparison, `date_trunc(business_date, week(monday))` for the Mon–Sat business week, and intermediate cohorts materialized in `scratch` per hard rule 7 rather than re-scanned per query. Cheapest single query in the day's log was 0.01 GiB. Two analysts, same board, same day, a **32x** cost difference — worth quoting when the compliant path needs an advocate.

**Ninth business day, 2026-08-21 — both loud failures fired on the same day, and they closed the two findings that eight write-ups could not.** `sales_ops.OrderCustomer` was dropped and `order_datetime` was renamed. Measured on `JOBS_BY_PROJECT` for 2026-08-21 → 08-23 (Denver), all jobs, error rows included:

| Account | Jobs | Errors | of which `OrderCustomer` not found | of which `order_datetime` unrecognized | GiB |
|---|---|---|---|---|---|
| `jelgie@` (MCP) | 247 | 71 | 18 | **41** | 304.10 |
| `dgetz@` (MCP) | 25 | **10** | 10 | 0 | 38.48 |
| `mraza@` (console) | 12 | 0 | 0 | 0 | 2.68 |
| `social-capis-job@` (service acct) | 6 | **2** | 2 | 0 | 0.08 |

Five lessons, and the last two are the ones that generalise beyond this project.

1. **The `2026-09-13` cohort template is dead, and nobody fixed it — the rename killed it.** Documented three times (08-13, 08-17, 08-18) and edited zero times. On 08-21 it ran **four more times** (bursts at 10:22:57, 13:54:59, 13:55:06, 13:59:15, ~10 variants each) and every execution failed on `Unrecognized name: order_datetime`. **41 hard failures, 0 bytes billed, 0 wrong answers published.** Compare the same template's prior week: 460 GiB of plausible, censored, email-keyed, timezone-shifted output. This is the 08-18 prescription working verbatim — *ship the rule as something that errors, not as documentation* — and it is now proven twice, after `BusinessDate` in one day and `order_datetime` in one day. **Stop writing findings about saved templates. Break the column they depend on.**

2. **The same analyst's *new* work migrated cleanly.** The 16:25–16:27 Braze attribution set (9 queries, 47.26 / 47.22 GiB on the two heaviest) now runs on `claude.order_customer` and joins Braze on **`order_timestamp_utc`** — the 08-19 silent-timezone defect does not appear anywhere in the day. Residue: still keyed on `lower(coalesce(mapped_email, email))` rather than `mapped_cust_id`, and still the `cohort`/`fwd` self-join shape at ~47 GiB apiece. Routing fixed, semantics fixed, **grain still wrong** — see the order-email rule above.

3. **🚨 The timezone defect was also live in a production outbound feed, and no audit had looked there.** The `social-capis-job@` service account ships purchase conversions to social platforms. Its last run on the legacy table (2026-08-21 09:02) read:

   ```sql
   -- ANTI-PATTERN, retired 2026-08-22
   oc.netsales      AS transaction_value,
   oc.order_datetime AS event_time          -- store-local, sent as if UTC
   FROM `marketing-data-442316.sales_ops.OrderCustomer` oc
   WHERE oc.BusinessDate = @target_date AND oc.iscatering = 0 AND oc.storeid <> 1111
   ```

   Every conversion event this feed has ever sent carried an `event_time` **4–7 hours early**, across four offsets, to an external attribution platform — the exact defect the 08-19 review measured on analyst queries, in the one place where nobody can sanity-check the number and the consequence is misattributed ad spend. It was found only because the table it read got dropped: 2 failed runs on 08-22 (09:01, 09:03), rewritten and verified the same evening (22:19, 22:22), clean scheduled run 08-23 09:01. The fixed version reads `sales_ops.order_customer`, `net_sales`, **`order_timestamp_utc`**, `is_catering = FALSE`, `store_id <> 1111`, plus a `CAST(i.Phone AS STRING)`.

   **Rule: a column-semantics audit must cover machine readers, not just human ones.** Scheduled queries, service accounts and application SQL are the highest-consequence consumers of a mis-named column and the only ones that never complain. Sweep `JOBS_BY_PROJECT` by `user_email like '%gserviceaccount%'` for the old name before declaring a rename complete.

4. **✅ The wall breach went with the templates — because it was riding inside them.** This is the strongest version of the day's lesson and the one to quote. Raw-dataset references in the query text, both MCP analysts, 2026-08-21 → 08-23:

   | Outcome | Jobs | GiB | Objects |
   |---|---|---|---|
   | **Executed** | **3** | **11.73** | `sessionm.users` (1), `pulse.customers` (2) |
   | Failed | 17 | 0 | `pulse.order_customers` (12), `sessionm.users` (3), `pulse.customers` (1), `staging.leads_meta` (1) |

   Every one of the 17 failures died on `OrderCustomer` not found or `order_datetime` unrecognized — the `pulse.*` reads were **clauses inside the same saved cohort and attribution templates**, not separate deliberate acts. Killing the two objects those templates depended on killed the breach they carried, for free. Compare late July: 115 `pulse.*` MCP queries across 5 days from these same two accounts (Asana 1216992461499656). **Three executed raw jobs in three days is the lowest figure in the log's history.**

   Two cautions against over-reading it. **(a)** The motive hasn't changed — 12 of the 17 failures wanted `pulse.order_customers`, still recovering the guest-supplied email that no mart column carries (Asana 1217645882648277). The moment either template is repaired, the breach returns unless that column ships first. **(b)** One compliant window is not a trend; the 08-14 clean day was recorded as progress and 08-18 came in with 34 `pulse.*` queries. Don't close the systemic finding on this.

5. **And the machine-reader sweep is exactly what this review's own inclusion rules forbid.** The rules say *exclude all `*.gserviceaccount.com`* — sensible for judging user behaviour, and precisely why a production dependency on a table the steward was about to drop stayed invisible until it broke. The pre-drop warning (Asana 1217722726180551, filed 08-21 15:56) had to be assembled by hand. **Harness fix: keep service accounts out of the behaviour report, but always include them in a dependency sweep before any drop or rename.** Two harness defects now share this shape — the `statement_type = 'SELECT'` filter (Asana 1217494247853173) hides DDL/DML *and* hides every failed job, because a query that cannot resolve its table never gets a `statement_type`. Both filters were narrowing for tidiness and both hid failures.

### 🚨 `sales_ops.order_lines` is STALE from 2026-08-16 — check before answering any item question (found 2026-08-25)

**`max(business_date) = 2026-08-15`. Zero rows for 2026-08-16 → 2026-08-25 (10 business days).** Verified against the full 381,383,908-row table: 0 rows in the window, 0 NULL `business_date`, 0 future dates. `claude.order_lines` is a view over it and is equally empty. Meanwhile **`order_customer` is current through 2026-08-25** and `order_line_discount_detail` through 08-24.

**The build never failed.** 24 runs/day, every day, **zero errors**, ~1.5M rows inserted at the 4am reload plus 0.3–2.1M across the intraday runs — every one landing on a partition ≤ 2026-08-15. Cost of the no-op: on 08-24 the sixteen intraday runs each scanned **14.16 GiB to insert 0 rows** (~227 GiB that day; the 08-08 → 08-25 daily range is 226–442 GiB).

**✅ Root cause, found 2026-08-25 — and it is not Brink.** `brink.brinkOrder` and `brink.brinkOrderItem` hold complete data for every affected date (126,330–147,723 item rows per business date, items on 99.3% of orders), with `brinkOrder` partitions written at **~00:57 MT** — three hours before the 4am run — and `brinkOrderItem` written continuously. Sunday partitions are near-empty or absent because the stores are closed, so **the 2026-08-09 "hole" first reported this morning is a closed day, not a defect** (retracted).

The collision is with **`sales_ops.order_customer`**. This build takes its order header from the mart, not from Brink — `sql/sales_ops.order_lines.sql` line 44 selects `from sales_ops.order_customer where business_date >= start_date`, and line 113 **INNER** joins it. Both marts are separate scheduled queries firing at minute **:02 with identical window logic**, and `order_customer`'s `delete` + `insert` is **not wrapped in a transaction**. A BigQuery reader gets a snapshot as of query start, so `order_lines` snapshots `order_customer` with the DELETE applied and the INSERT uncommitted; the CTE returns the hole and the INNER JOIN converts it to zero rows.

**Measured across 23 consecutive runs (08-24 → 08-25): `order_lines` began reading 5.5–14.8 s before `order_customer` committed — it lost the race 23 times out of 23.** The 08-25 04:02 run: `order_customer` INSERT ran 04:02:05.491 → **14.713**; `order_lines` INSERT started 04:02:06.**326**, 8.2 s before the restore committed.

**It is a ratchet, which is why deep history survives.** Damage is confined to the *intersection of the two delete windows*: the 4am run deletes 8 days (35 on Mondays), reads the hole, reinserts nearly nothing, and the recent tail is wiped nightly. Late intraday runs sometimes win enough of the snapshot to land a day (08-24 at 15:02 / 21:02 / 22:02 / 23:02 inserted 106,734 / 198,104 / 206,521 / 208,387 rows) — and the next 4am run deletes it again.

**Three general rules, and the middle one is the one worth carrying to other projects.**

1. **An untransacted `delete`+`insert` is a public API.** `order_customer`'s rebuild was safe as long as nothing read it mid-flight. The moment a second mart sourced its header from it, the missing `begin transaction` became a data-loss bug in a *different* table. Wrap every mart rebuild, whether or not you know of a reader today.
2. **🚨 An INNER JOIN turns a transient source hole into permanent silent deletion.** The reader deletes its own window first, then inserts what the join returns — so an empty snapshot doesn't yield a stale row, it yields *no* row, and the previous good data is already gone. With a LEFT join this would have produced visibly NULL headers; with an INNER join it produced nothing at all and no error. **When a build's delete window overlaps its source's delete window, the join type decides whether a race is a blip or a data loss.**
3. **Two builds on the same cron minute with the same window logic are one build that hasn't been written yet.** Re-timing to :12 only shortens the odds; the fix is sequencing (Asana 1217564375242412, whose stated prerequisite was exactly this hazard — now measured).

> **✅ Update 2026-08-26 — rule 1 was fixed in production 38 minutes after it was written here, and nobody told the repo.** Both marts are now transacted. First scheduled run carrying `begin transaction` / `commit transaction`: `order_customer` **2026-08-25 13:02 MT** (query text 18,428 -> 18,479 chars), `order_lines` **2026-08-25 13:07** (13,263 -> 13,302); `order_line_discount_detail` already had one. Verified across 25 / 25 / 48 consecutive runs through 2026-08-26 13:02 on `JOBS_BY_PROJECT`. The builds were also re-staggered to **:02 / :07 / :12**, so the "same cron minute" half of rule 3 no longer describes reality either. `sql/sales_ops.order_customer.sql` in this repo still carries neither change.
>
> **The meta-lesson is about where truth lives.** Three write-ups in this file described the live build from the repo copy, and the repo was two edits behind the console for a full day. **The deployed text is in `JOBS_BY_PROJECT.query`; read it before describing what a build does, and re-read it before writing that a defect is still open.** This is the same failure mode as the 2026-08-17 view-definition drift, in the opposite direction: there the repo was safer than deployed, here it was staler.

> **🚨 New rule 2026-08-26 — widening a reload window only repairs drift in the columns the build actually reads.** The 4am reload is being changed from 8 days to all history because Pulse rewrites `pulse.order_customers` when accounts are merged. Measured the same day: the drift a full refresh would actually repair is **~17 orders in 50,985,194** (6 days' accumulation), while the merge population the change was made for — **6,061 orders / 1,884 customers / $163,845.84**, back to 2023-03-22 — is attributed to `pulse.customers` rows carrying `deleted_at`, which **the build does not filter on any of the three pulse tables**. Re-reading the same deleted rows over eight years produces the same answer. **Before widening a window, measure the drift and confirm the build reads the signal that moves it.** Full detail, cost and the three downstream consequences: [`sales_ops.order_customer.md`](../../data_dictionaries/sales_ops.order_customer.md).
>
> **✅ Superseded 2026-09-08.** The chaining item shipped: one scheduled query, one `start_date`, 5am = full history for `order_customer`, `order_lines` and `order_line_discount_detail` alike. The paragraph below described 2026-08-26 → 2026-09-08 and is kept for history. **Also 2026-09-08: `mapped_cust_id`, `mapped_email`, `mapped_email_domain`, `customer_type` moved from `sales_ops.order_customer` to `sales_ops.order_sequence` and `mapped_cust_id` was redefined through `sales_ops.cust_map`** — the `claude.order_customer` view still exposes all four, but any `sales_ops.order_customer` query that names them now errors, and customer counts straddling 2026-09-08 are not strictly comparable. Dictionaries: `sales_ops.order_sequence.md` (definition), `sales_ops.order_customer.md` (the rebuild banner), `sales_ops.cust_map.md`.
>
> Practical consequence for answering questions (2026-08-26 → 2026-09-08): **the four order marts no longer share a reload width** (`order_customer` all history / `order_line_discount_detail` 120 days / `order_lines` 8 days at 4am, measured live 2026-08-26). Any figure that mixes `order_customer` with `order_lines` on partitions older than 8 days can now disagree permanently rather than converging on the next Monday reload. If a number spans both marts and reaches back past ~a week, say which mart it came from.

**Until it is fixed:** cap `order_lines` queries at `business_date <= '2026-08-15'` and state the cap in the answer. **Never describe the gap as a sales decline** — item volume falling to zero against healthy `order_customer` volume is the defect, not a business event. If a question needs the last 10 days at item grain, say the marts cannot answer it. The `item-sales-builder` artifact inherits this directly.

**Two general rules this earns:**

1. **An empty partition satisfies a `between` predicate.** A missing date range is the one data-quality failure that produces neither an error nor a suspicious number — it produces a *smaller* number, which reads as a real decline. **A freshness check is part of answering, not part of maintenance:** `select max(business_date)` on every fact table an answer touches, and compare them to each other. The comparison is what caught this — `order_lines` alone looks fine.
2. **Add the assert to the build, not the warning to the doc.** Same lesson as the `order_datetime` rename below: a build that cannot fail is a build nobody checks. `assert max(business_date) >= run_date - 1` after the insert would have made this loud on 2026-08-16 instead of silent for ten days (Asana 1216955196273978, filed 2026-07-28, still open).

**Tenth business day, 2026-08-24 — the loud failure finished the job. The single heaviest account in the log went from ~650 GiB/day of plausible wrong answers to 11.51 GiB of canonical right ones, and paid for it with 406 hard failures in one day.** All jobs, error rows included, `JOBS_BY_PROJECT`, Denver dates:

| Date | Jobs | Errors | `order_datetime` unrecognized | `OrderCustomer` not found | GiB |
|---|---|---|---|---|---|
| 08-17 | 82 | 1 | 0 | 0 | 267.18 |
| 08-18 | 145 | 1 | 0 | 0 | **610.32** |
| 08-19 | 30 | 1 | 0 | 0 | 23.46 |
| 08-20 | 167 | 1 | 0 | 0 | **655.85** |
| 08-21 | 25 | 10 | 0 | 10 | 38.48 |
| **08-24** | **423** | **407** | **363** | **43** | **11.51** |
| 08-25 (part) | 3 | 0 | 0 | 0 | 2.57 |

Five things, and the first is the one to quote when the loud-failure strategy needs defending.

1. **✅ The rewrite happened, and it adopted every prescription in this skill at once.** The 16 jobs that succeeded on 08-24 are not a partial migration — they are the canonical pattern verbatim:

   ```sql
   with cohort as (
   	select
   	oc.mapped_cust_id as cid                        -- id grain, not lower(email)
   	, min(oc.order_timestamp_utc) as first_ts_utc   -- UTC column, not timestamp(local)
   	, date_trunc(min(oc.business_date), week(monday)) as cohort_week
   	from `marketing-data-442316`.claude.order_customer oc
   	where 1=1
   	and oc.business_date between date_sub(current_date(), interval 100 day) and current_date()
   	and oc.customer_order_count = 1                 -- precomputed sequence, partition-filterable
   	and oc.customer_type = 'person'
   	and oc.is_catering = false
   	and oc.store_id not in (1111, 999)
   	group by 1
   )
   ```

   Compare what this replaced: `lower(coalesce(mapped_email, email))` keyed, `having date(min(odt))` as the date bound (structurally unbounded — see the `2026-09-13` template notes above), `timestamp(order_datetime)` for the Braze join, `store_id <> 1111`, `sales_ops.order_customer` direct. Braze is now joined on `safe_cast(u.external_id as int64) = mapped_cust_id`. **Cost per query fell from 45–47 GiB to 0.55–1.76 GiB, and the pattern held into 08-25.** Eight write-ups changed nothing; renaming one column changed all of it in a single day. Third consecutive proof — after `BusinessDate` and `OrderCustomer` — that **the deliverable of a finding about a saved template is a break, not a paragraph.**

   > **🚨 The break has been patched around, not learned from (2026-09-01).** The `2026-09-13` cohort template is running again under `jelgie@`, repaired *just enough* to compile: `order_datetime` → `order_timestamp_utc`, `store_id <> 1111` → `not in (1111, 999)`, `customer_type = 'person'` and a `<> 'nan'` guard added. Everything the rename was meant to force did **not** change: still keyed on `lower(coalesce(mapped_email, email))`, still `sales_ops.order_customer` direct, still rebuilding "first order" with `min()` over `business_date between '2023-03-06' and current_date()` (a 3.5-year scan for a 100-day cohort), and still carrying the two `pulse.customers` "contacts created but never ordered" fragments — so **the wall breach came back with it, exactly as the 08-21 caution (a) predicted.** Shape on 09-01: three loads (09:10, 09:17, 09:53–54 MT) of ~17 queries each, all timestamps within a minute, **~105 GiB for the day**, `pulse.customers` executed 5× (4 under `jelgie@`, 1 under `dgetz@`). Meanwhile `dgetz@` still holds the **unrepaired** copy: 31 `Unrecognized name: order_datetime` failures in a 6-second burst at 08:55 — three loads of the same ~10 variants — while the *same user's live session* three minutes later ran the correct shape (`claude.order_customer`, `customer_order_count in (1, 2)`, `customer_type = 'person'`, `not in (1111, 999)`, second order banked through yesterday). Two copies of one template, two users, one of them producing an email-keyed "90-day repeat" number and the other a `mapped_cust_id`-keyed one — **the same question is now producing two different answers on the same morning**, which is the exact failure this KB exists to prevent. The 08-21 lesson needs its second half: a break only works if the *replacement* is easier to reach than the patch. The replacement here is the `customer_order_count` recipe two paragraphs up; it has been in the KB since 08-13 and still is not what the saved copy runs. Fix at source (Asana 1217645792289097) or expose the account-creation dimension the `pulse.customers` fragment is after (Asana 1217792657112397) — a fourth write-up will not do it.
   >
   > **Day 2 (2026-09-02): same template, same minute-burst shape, now the most expensive day in the log.** Two loads at 09:48:17–09:49:22 MT under `jelgie@`, ~55 queries in 65 seconds, **295.8 GiB for the day**. Raw refs by query text: `pulse.order_customers` (the guest-email arm, `created_at >= '2026-06-25'`) in **10** executed queries, `pulse.customers` ("contacts created but never ordered") in **2**. Cost is no longer the cohort arm: **four queries at ~50 GiB each (200.7 GiB, 68% of the day) are the welcome-series lift checks** — `braze.canvas_entry` scanned `event_date between '2026-02-01' and current_date()` for a four-canvas name list, then joined through `braze.users` to a `lower(coalesce(mapped_email, email))` cohort rebuilt from `claude.order_customer` since 2025-11-01 — and each of the two ran **twice within seven seconds** (09:48:19 and 09:48:25/26), i.e. the same template fired two loads. Everything the KB says about this is already written: materialise the canvas leg roster to `scratch` once (braze-campaigns skill), key cohorts on `mapped_cust_id` with `customer_order_count = 1` (section 2 above), and the guest email belongs in a mart column, not in `pulse.order_customers` (Asana 1217645882648277). Fix-at-source task: Asana 1217645792289097.

   > **Day 3 (2026-09-03): quiet on the wall, loud on the legacy names.** Zero raw-dataset reads by anyone — the first clean day since the guest-email breach began 08-28 — and `dgetz@`'s 04:06 welcome-series lift runs the canonical shape verbatim (`claude.order_customer`, `customer_order_count in (1, 2)`, `customer_type = 'person'`, `is_catering = false`, `not in (1111, 999)`), so the "two copies, two answers" split of 09-01 is closed on that side. What did fail: **4 of the analyst's 7 errors were retired column names** — `oc.BusinessDate` / `oc.storeid` / `oc.netsales` / `oc.iscatering = 0` at 13:32 (the dead scorecard template pasted whole, 24-month comp-store net by day), then Claude-authored queries at 14:08, 15:19 and 15:30 that had been writing `business_date` correctly all morning **reverted to `BusinessDate` mid-session** and had to be re-run. The KB has said `business_date` everywhere since 07-30; the one place still spelling it the old way is the shared project's instruction box ("*Always filter on partition columns (BusinessDate)*") — fix that text, not this file (Asana 1218113375076710, now 6 live failures across 09-01 and 09-03). Six smaller things from the same day, none new in kind: **(a)** a hand-typed **77-id comp-store `in (...)` list** on `sales_ops.order_customer` (10:48, a 14-day post-09-01 daily store series, Sundays dropped) — `store_info.is_comp_store = 1` is the definition and the literal list drifts the month a store comps in (Asana 1217879256348882); **(b)** the 90/30-day repeat rates were rebuilt from `min(business_date)` over `claude.order_customer` with **no partition filter at all** (`where mapped_cust_id is not null`, 0.89 GiB) when `customer_order_count` / `days_since_prev_order` answer it in one bounded pass (Asana 1217493799685485); **(c)** `Offline Cafe Zupas Rewards` was bucketed as a reward redemption in a points analysis (15:19) — it is the **$0.00 marker line** (see the earned-discount section) and inflates redemption *order counts* without moving dollars; **(d)** a rev-center sales mix used `count(*) as units` (it is `sum(qty)`) and `store_id <> 1111` without 999; **(e)** the daily flash's daypart CASE is still `10–13 / 14–16 / 17–21` — third day running, still unratified (Asana 1218013729974930); **(f)** one **25.31 GiB** query (55% of the day's 57 GiB) was `lower(item_name) like '%strawberr%'` over `business_date between '2019-01-01' and current_date()` to find first/last sale dates — run discovery on the 30-day window first, then widen *only* the resolved `item_id`s, and only if `min(business_date)` lands on the window edge.
   >
   > **New demand shape, first live occurrence: new-store ramp (14:08–14:33, 19 queries, 4.9 GiB).** Eight stores opened since 2024-08 (`182, 183, 184, 185, 189, 190, 193, 194`; store 50 excluded by hand), indexed by `div(date_diff(business_date, store_open_date, day), 7)` as weeks-since-open, then sales per operating day (`sum(net_sales) / count(distinct business_date)` — right, because calendar weeks contain closed Sundays), a wk0–3 vs wk20–22 phase compare, identified customers acquired per store and their in-window repeat, hour-of-day, `order_source` mix (`coalesce(order_source, '(in-store POS)')`), `item_type` mix on `item_net_sales`, and a Braze `home_city` join. All of it ran on `sales_ops.order_customer` + `store_info`, not the `claude` views. Two gotchas for whoever codifies it: `store_open_date` is **NULL on 9 `store_info` rows, four of them live stores** (dictionary), so `where store_open_date >= '2024-08-01'` silently drops any new store that has not yet had a >150-order day; and `store_open_date` is *first day with >150 orders*, not the ops opening date — a soft-open week lands at negative `day_idx`. Logged as demand evidence on Asana 1217279348220260.
   >
   > **Steward patterns mined the same day.** (1) **Order-event upload to Braze** (07:00, unlabeled): `select distinct cast(oc.mapped_cust_id as string) as external_id, format_timestamp('%Y-%m-%dT%H:%M:%E3SZ', oc.order_timestamp_utc) as event_time` from `claude.order_lines` joined to `claude.order_customer` on `brink_order_id`, 45-day window, `is_catering = false`, `oc.mapped_cust_id is not null and oc.order_timestamp_utc is not null` — the `distinct` collapses several qualifying lines on one order to one event, and the `Z` literal is honest only because the source is the true-UTC column (written up in `braze-campaigns` → *Writing attributes OUT*, item 5). (2) **The `social-capis-daily` eligibility predicate** (15:31): `mapped_email is not null and pulse_order_id is null and is_catering = false and store_id <> 1111` on `sales_ops.order_customer` — i.e. *identified in-store orders only*, digital orders are excluded because the platforms already receive them from the web/app pixels. Quote this if anyone asks "how many conversions did we send to Meta/TikTok yesterday". (3) A probe for **items per order** (09:29, MCP): `menu_items = sum(qty) where line_item_type = 'item' and composite_item_id is null` (standalone lines only) versus `products = item lines outside the Combos rev center + Try 2 Combo modifier lines` (each combo half counted). Two different denominators for "basket size"; **neither is ratified** — if a user asks, present both and say which one they want.
   >
   > **Days 4–6 (Fri 09-04 → Sun 09-06): second clean weekend on the wall; the recurrences are all definitional.** Zero raw-dataset reads by any non-steward — `jelgie@` 35 MCP queries (Sat 16:43–17:17, 10.2 GiB), `dgetz@` 5 (Fri 04:18 scheduled + Sun 16:20/17:21), all on `sales_ops` / `claude` / `braze` / `google_ads` / GA4. `dgetz@`'s Sunday queries are the canonical 90-day "banked second order" shape **and drop `store_id not in (1111, 999)` on `claude.order_customer`**, which is the 09-03 steward rule adopted within three days — the view already excludes both. One caution on that template: `countif(not c.is_guest)` as "identified new customers" leans on `is_guest_order`, which is **NULL on POS orders** (or `true` under the pre-fix alias, see the dictionary), so POS-first loyalty scanners drop out of "identified" either way — split identified vs guest on the identity mapping, not on that flag, until the rebuild lands. What recurred, all in the analyst's Saturday Friday-recap session (Friday-before-Labor-Day flash — total / comp / digital / third-party / catering, store outliers vs the median of the prior four Fridays, state rollup, GA4 sessions, Google Ads spend, Braze launches in the last 14 days): **(a)** `businessdate` and `BusinessDate` failed again at 16:43 and 16:53 — **8 live failures** since 09-01, same fix (the project instruction box, Asana 1218113375076710); **(b)** **two comp definitions five minutes apart** — `store_info.is_comp_store = 1` in five queries, then `having count(distinct period) = 2` ("stores trading in both Fridays") in the FY26/FY25 compare, unlabelled. The dictionary rule stands: `is_comp_store = 1` is comp; both-windows is a different question and must be named that way (Asana 1217879256348882, third variant); **(c)** the size blend, verbatim: `item_name in ('Chocolate Strawberry Cup', 'S\'mores Strawberry Cup', 'Dot Strawberry Cup')` with `sum(item_net_sales)/sum(qty) as avg_net` — the Mini ($9) and full ($14) Chocolate Strawberry Cup are two `item_id`s under one name, so that average is a price the product is never sold at (section 5 above). The discovery step that preceded it grouped `'%strawberr%'` by `item_name, item_type, rev_center_name` **without `item_size` or `item_id`**, so the fork was never visible — group discovery by `item_id, item_name, item_size` with the unit price, always; **(d)** two LY anchors in one session — 2025-09-05 (364-day, same weekday) and 2025-08-29 (Friday before Labor Day 2025), once both in the same query. Either is defensible; a recap that carries both without labels is two answers. Say which one and why (see the 09-01 note on floating holidays); **(e)** `date(time)` on `braze.app_sessionstart` failed — `time` is INT64 epoch, `timestamp_seconds(time)` is the rule — and the same query selected `indiv_sessionm_user_id`, which is a **Braze custom-attribute *table***, not a column on the session table; **(f)** the whole session ran on `sales_ops.*` directly, zero `claude.*` reads (Asana 1217879450574426). One thing that may be a gap rather than a miss: to find the **$2 online promo** that ran 09-04 the analyst first searched `offer_name` / `discount_name` / `item_name like '%strawberr%'` on `order_line_discount_detail`, found nothing, and fell back to `discount_name = 'Online Discount' and discount_amount between -2.01 and -1.99` — identifying a promotion by its dollar value. If the Pulse-side `discount_type` / `offer_name` really do not name that promo, campaign-level promo reporting is not answerable from the mart (Asana 1218240026546013 — verify before building). **Steward side, nothing new to mine:** the unlabeled account is now almost entirely automation — the QuickSight refresh (13 `shared_datasets.*` views + `sales_ops.cs_comp_points`, 07:50–08:01 daily, Asana 1216920434852093 still open) and the 05:30 `marketing_ops.weather_triggers` health checks (`store_id <> 1111` only, safe because `store_info` has no 999 row); the one manual query (09-04 09:38) is the Braze order-event upload recipe already written up above.
   >
   > **Day 7 (Mon 09-07, Labor Day): quiet — 5 non-steward queries, zero wall reads, zero failures; the day's lesson comes from the steward's own session.** `dgetz@` 06:42 (4 MCP, scheduled): the banked-second-order tracker collapsed to **one bounded pass** — `customer_order_count = 2 and days_since_prev_order <= 90 and date_sub(business_date, interval days_since_prev_order day) >= cohort_start` recovers the first-order date from the second order without a self-join; that is the shape section "Repeat-rate" §2 asks for, adopt it. Two small drifts inside the same template versus its 09-04 version: the Braze arm dropped `workspace = 'cafe_zupas'` (canonical default in `braze-campaigns`; the catering workspace leaks in without it) and `current_date()` lost its `'America/Denver'` (UTC after 6pm MT — see Gotchas). `jelgie@` 09:32: one `max(business_date)` freshness check across both marts before anything else — exactly right. **Steward session (12:04–16:16, 22 MCP queries, all `claude.*` + `sessionM.*`), two things to keep:** **(1) Intraday same-time pacing** — cumulative `countif(time(oc.order_datetime_local) < time 'HH:MM')` columns across the target day, the same weekday for the prior four weeks, and the holiday-aligned LY day (2025-09-01) *plus* a plain LY Monday (2025-08-25), with `max(oc.order_datetime_local) as last_order` in the select so the reader sees the data cutoff. Now a recipe below ("Intraday pacing"). **(2) The `$2 off` promo was identified by dollar value a second time, by the steward, after the name lookups came back empty**: `offer_name` / `discount_name like '%kid%'` and three explicit `upper(root_offer_id) in (…)` probes on `claude.order_line_discount_detail`, then a fallback to per-order `discount_origin = 'Online' and round(sum(discount_amount), 2) = -2.0` and `round(oc.total_discount_amount, 2) = -2.0`. The offer *does* have a name upstream — `sessionM.offers.name = '$2 Off Strawberry Cup'` was queried directly at 12:46 — so the question in Asana 1218240026546013 sharpens to: **does the Pulse `Online Discount` component carry a `root_offer_id` that resolves to that offer (`upper()` both sides), or not?** If yes, the recipe is name → `root_offer_id` via `claude.loyalty_offer_usage` → discount lines; if no, promo identity is a mart gap. Either way the `= -2.0` test is a placeholder, and any other $2 discount that day (employee, guest relations, a second promo) is swept in. One gotcha surfaced by comparing the two sessions: **`'Kids Meals'` is a value in two different columns with two different populations** — `rev_center_name = 'Kids Meals'` is the menu category (analyst, 09-05), `item_type = 'Kids Meals'` is the closed-domain rollup that holds **only the Kids Combo** (other kids items roll to `Entree`; steward, 09-07). Use `rev_center_name` for "kids menu" questions and say so; `item_type` is the narrower promo-eligible set. Steward unlabeled queries: QuickSight + weather automation only, nothing to mine.
   >
   > **Day 8 (Tue 09-08): the busiest day since 08-25 — 393 non-steward queries / 616 GiB, a NEW MCP account, two wall breaches, and a 70-execution tracker that was reading columns dropped that afternoon.** Volumes: `jelgie@` 237 MCP / 357.3 GiB, `wbeaman@` **55 MCP / 71.5 GiB (first day on the connector)**, `dgetz@` 33 MCP / 60.0 GiB, `mraza@` 28 console / 127.3 GiB + 3 MCP / 0.1 GiB; zero `error_result` for anyone (SELECT-only harness caveat applies). **(a) Wall, new account:** `wbeaman@` read `brink.*` four times through the connector — `brinkOrder` min/max `BusinessDate` (14:31), `brinkCreditCardTransactionInfo` `CardToken` coverage (14:37), `brinkOrder` × `brinkOrderItem` void/deleted/cleared check on four LTO `ItemId`s (14:58, 5.2 GiB), raw `brinkOrder.NetSales` comp-store tie-out vs the mart (15:38) — all *verification* motives, not answers, and each one is already a documented mart guarantee (voids handled, `brink_net_sales` kept as the validation field). The rest of the session ran on `sales_ops.*` direct, **zero `claude.*` reads**, plus two tables the KB does not document (`sales_ops.menu_item_meta_data` with a `vto = 1` flag; `customer_hash.brink_order_customer_hash`, see (e)). **(b) Wall, console:** `mraza@` 28 unlabeled queries — `select *` on `brink.brinkOrder` by `id` **nine times at 11.31 GiB each (~102 GiB, no `BusinessDate` predicate, Asana 1217554047292419)**, `pulse.customers` / **`pulse_new.customers`** by `id`, and two orphan checks (`pulse.order_customers.customer_id` with no `customers` row; `pulse_new.orders` carrying a `brink_order_id` with no `order_customers` row before 09-07). This is Pulse-side integrity work on a **new `pulse_new` dataset** that a dev service account now MERGEs nightly from `staging_new.*` — if Pulse is re-platforming, every `pulse.*` source in the order-mart build needs a migration plan (new Asana task). His 3 MCP queries were textbook: `claude.order_customer`, Labor Day by `revenue_category` / `order_source`. **(c) 🚨 The shared tracker read `mapped_email` + `customer_type` off `sales_ops.order_customer` 70 times before the 16:16 drop** — `jelgie@` 42 executions (09:25–11:21) and `dgetz@` 28 (all 33 of his queries fired 13:49:xx, one dashboard refresh, 60 GiB), the `with eord as (…)` second-order-curve shape at ~2 GiB apiece scanning **from 2023-03-06** for a 470-day cohort window, plus 9 runs of the `pulse.customers` "contacts created but never ordered" arm (the known breach, 1216992461499656). Those columns now live on `order_sequence` only (verified on `INFORMATION_SCHEMA.COLUMNS` this morning: `order_customer` keeps `is_guest_order`, `acct_email`, `sm_external_user_id`; `order_sequence` has `mapped_cust_id`, `mapped_email`, `mapped_email_domain`, `customer_type`), so the next refresh fails. `jelgie@`'s 16:24 query already joins `order_sequence s` for `s.mapped_cust_id` — she adapted within eight minutes; the *saved* tracker has not. When it is repointed, the fix is not a join — it is the Day-7 one-pass shape (`customer_order_count` / `days_since_prev_order` on `claude.order_customer`), which also retires the 2023-03-06 scan (Asana 1217493799685485). **(d) Same failure, machine side, this morning:** `social-capis-job@` failed **6× at 09:04–09:06 (2026-09-09)** on `Name mapped_cust_id not found inside oc` — it reads `oc.mapped_cust_id` and `oc.mapped_email` off `sales_ops.order_customer` joined to `sales_ops.cust_info`, and it was **not** in the six-build list. `braze-cloud-data-ingestion@` failed 2× at 09:00 on the same name (two `order_stores` pulls; its CTAS set ran clean). Every named build did pass: `customer_attribute` **05:20** (moved off 05:00 — good), `bgnbd` 06:00, `cs_comp_points` 07:15, `weather_flag` 08:00, `google_offline_conversions` 09:16. The 5am full-history chain measured **384 s / 91.7 GiB** (order_customer insert 65 s / 22.2 GiB; `order_sequence` CTAS 77 s); intraday runs 77–91 s / 29–40 GiB. **(e) What `wbeaman@` was building is a real demand pattern with no recipe: an LTO / campaign scorecard.** Summer 2026 items by `item_id` (Burger Bowl 643647082, Hot Honey Brisket 643647081, S'mores Strawberry Cup 643647079, Dot Strawberry Cup 643647121, nine Mocktail ids) launched 06-03 / 06-05 / 06-15: launch detection as the first date with ≥50 stores selling, units per store-day, entrée-mix %, pre/during share shift **with the LY pre/during shift as a control** (`d_ty - d_ly`), comp-store net and traffic during-vs-pre and TY-vs-LY, and a customer-level test/control lift keyed on **`'L' || mapped_cust_id` for members and `'C' || HashKey` from `customer_hash.brink_order_customer_hash` for card-paying anonymous guests** — the first analyst use of the card-hash identity, on a table the steward rebuilds daily at 06:55 and the KB has never described. Three things he got right that the KB should say out loud: `line_item_type in ('item','modifier')` for LTO units (he re-derived the combo taxonomy himself — "digital Try 2 Combo (modifier row) / in-store Try 2 Combo (item row) / standalone"); `TRIM(item_name)` everywhere — because **`item_name` carries trailing whitespace on real SKUs** (`'Apple Juice '` 643636585, `'Strawberry Daiquiri Mocktail '` 643644616/617 — 912 lines on 2026-09-05 alone; an `=` test on the bare name returns zero rows, see §5); and holiday days excluded from the comp windows (Jul 3–5, Labor Day). Two things that recurred: **comp store** as `store_open_date <= X and traded in both windows` (labelled A/B against `is_comp_store = 1` at 15:37 — good practice, still a second definition, Asana 1217879256348882), and **"entrée" as `rev_center_name in ('Sandwiches','Soups','Salads','Bowls')`** when `item_type = 'Entree'` is the closed-domain rollup — on 2026-09-05 the two disagree by 47,548 item-rows vs 70,579 lines, so "entrée mix %" has two denominators in the wild. **(f) `jelgie@`'s week-ending-09-05 recap carried THREE LY anchors** — `LY6` (364-day, 2025-09-01→06, *contains Labor Day 2025*), `LY13` (2025-09-08→13, shifted past it) and `LY_preLD` (2025-08-25→30, the week before LY's Labor Day, which her own comment marks "the CORRECT holiday-relative partner") — plus an **81-store "traded non-catering in the LY-aligned week" base** alongside `is_comp_store`. The KB rule (Gotchas: "364 days preserves the weekday but NOT floating holidays") already says to give the 364-day number and the holiday-aligned one as a labelled pair; the relative-position anchor she landed on *is* the holiday-aligned choice for a week adjacent to the holiday, and should be named that way rather than as a third method. Her Braze work (Points_Top_Off canvas, weather automation, **RCS channel** — `rcs_send` / `rcs_read` / `rcs_click` / `rcs_rejection` with `is_sms_fallback`, and unattributed RCS sends where both `campaign_name` and `canvas_name` are null) is the `braze-campaigns` skill's territory; nothing there contradicts it. Steward unlabeled queries: QuickSight + weather automation + one `order_sequence` peek after the redeploy; nothing to mine.
   >
   > **Day 9 (Wed 09-09): 284 non-steward queries / 668 GiB — the second-heaviest day on record, three wall readers, zero failures, and two analysts independently re-deriving item launch windows that `sales_ops.vto_items` half-answers.** Volumes: `wbeaman@` **103 MCP / 401.4 GiB** (day two on the connector, now the heaviest account), `jelgie@` 152 MCP / 254.0 GiB, `dgetz@` 26 MCP / 12.5 GiB, `mraza@` 3 console / 0.1 GiB. **(a) Wall, MCP:** `wbeaman@` read `brink.brinkOrder` × `brinkOrderItem` × `brinkOrderItemModifier` **4 times / ~43 GiB** (11:43–12:40) — the same void/deleted/cleared unit tie-out as 09-08, now extended to every LTO cohort back to Feb 2025 (`IsRefund = FALSE`, `NOT IsVoided AND NOT IsDeleted AND NOT IsCleared`, catering removed via an anti-join to `order_customer.is_catering`); `jelgie@` read `pulse.order_customers` **8×** (15:36–15:38, 14.5 GiB) inside the app-download experiment lift queries — `lower(email), order_id where created_at >= '2026-06-25'` joined on `oc.pulse_order_id` to recover the **guest-typed email** for orders whose `coalesce(mapped_email, email)` came back null (Asana 1217645882648277 is exactly this) — and `pulse.customers` 2× (the "contacts created but never ordered" arm, 1216992461499656). **(b) Wall, console:** `mraza@` 3 queries on `pulse.temp_brink_weekly_gross_sales` / `pulse.temp_pulse_cater_sales` / `pulse.locations` generating **MySQL `INSERT` statements for `web_systems.catering_same_day_sales_pct`** — Pulse-side engineering, not a business question, but weekly gross and catering same-day sales are being computed from `pulse.temp_*` scratch tables that no mart defines (1217645882937957). **(c) 🚨 `customer_hash.brink_order_customer_hash` was read 51× / 157 GiB, and one shape 23× at ~4.5 GiB each (11:58, 102.8 GiB) with NO date predicate** — `select OrderID, BusinessDate, any_value(HashKey) from customer_hash.brink_order_customer_hash group by 1,2` as the `hk` CTE, full table every run, inside the `'L' || mapped_cust_id` / `'C' || HashKey` customer key. The KB still has no dictionary for this table (1218319855021359) — whether it is partitioned on `BusinessDate` is the first thing that dictionary must say, because the analyst could not know to filter it. **(d) The LTO scorecard is now two analysts, not one.** `wbeaman@` derived launch windows as *first/last date an item sold in ≥60% of active stores* (`d.stores >= 0.6 * a.active_stores as chainwide`, two runs at **20 GiB each** over 2019→today), then hand-typed the resulting `s`/`e` dates into ~15 downstream `camp` CTEs; `jelgie@` (10:04) derived `min(business_date) as first_seen` over 180 days for a "new items" list. Neither touched `sales_ops.vto_items`, which carries `launch_date` by `item_id` — but **not an end date**, and the scorecard needs both edges of the window (pre / during / LY-pre / LY-during). That is the concrete gap under 1218319740414409: add `end_date` (last chainwide date) to `vto_items`, and the 40 GiB re-derivation disappears. **(e) Recurrences, day after the rule shipped:** three week definitions in one day — `dgetz@` `date_trunc(business_date, week(sunday)) + 6 as week_ending` (Sun–Sat), `wbeaman@` `DATE_TRUNC(business_date, WEEK(THURSDAY))` (LTO launch-anchored), the steward rule is `last_day(d, week(monday))` = `claude.date_dim.week_ending` (Sunday) — a launch-anchored week is a legitimate different question, label it as one; comp store: `store_open_date <= date_sub(launch, interval 365 day)` (wbeaman) and `having count(distinct business_date) = 6` (dgetz, 11:12) alongside `is_comp_store` (1217879256348882, variants four and five); holiday exclusions hand-listed twice (`'07-03','07-04','07-05','12-24','12-25','12-26','01-01'` + Thanksgiving dates) when `claude.date_dim.holiday` is the ratified list — `dgetz@` used it correctly the same morning; `jelgie@` derived store open date as `min(business_date) group by store_id` (11:37) when `store_info.store_open_date` is a column; `store_id <> 1111` without 999 (jelgie 16:21, twice). **(f) 21 more runs of the 2023-03-06 `eord` scan (50.5 GiB, 10:53–11:0x)** — the analyst tracker again, hours after commit 8e5fe3f made "never scan history for first order" a hard rule. Its email-keyed first order is now the same thing as `customer_order_count = 1` (since 09-08 `mapped_cust_id` IS the email-ruled person), so the rewrite is a filter swap, not a redesign (1217493799685485). **(g) New gotcha, measured: a partition filter written as `business_date in (select business_date from d)` does NOT prune** — `jelgie@` 14:52 billed **19.1 GiB for ten business dates** across `order_customer`, `order_lines` and `order_line_discount_detail` because each `where business_date in (select …)` is a semi-join, not a constant predicate. `in unnest([date '…', …])` or an explicit `between` prunes. Added to the Gotchas checklist. **(h) `dgetz@` was clean and useful:** `claude.*` only, `date_dim.holiday` for the Labor Day alignment, `is_comp_store` via `claude.store_info`, and a Kids Meal offer tie-out across `loyalty_offer_usage` → `order_line_discount_detail` → `order_customer.total_discount_amount` by day and by `root_offer_id` (`upper()` both sides — the rule held). **(i) Machine side:** `social-capis-job@` (2 jobs, 09:01) and `braze-cloud-data-ingestion@` (552 jobs from 05:40) both ran **clean on 09-10** — the 09-09 09:00 `mapped_cust_id` failures were fixed within the day (1218319740465859 closed). Steward unlabeled (35): QuickSight + weather automation, `dashboard.refresh_log` checks, six `cust_map` v2 iterations (already in `sql/analysis/`), and single-email identity traces; nothing new to mine.
   >
   > **Days 11–14 (Fri 09-11 → Mon 09-14): three near-silent days and one heavy one — 97 non-steward queries / 197 GiB, zero failures, one wall reader, and the comp-store fork finally has a root cause.** Volumes: `wbeaman@` **60 MCP / 142.3 GiB (09-14)**, `dgetz@` 27 MCP / 52.6 GiB (09-11) + 10 / 2.2 GiB (09-13), `jelgie@` and `mraza@` **absent from the whole window**. Steward: 09-14 was his biggest day (687 unlabeled / 46.8 GiB + 76 MCP / 131.4 GiB), almost all of it cz-dashboard tab development. 09-11 raw reads were **all out of scope** — `hassaan.akmal@tkxel.io` QuickSight refreshes and `*-compute@developer.gserviceaccount.com`, both excluded by the inclusion rules; no in-scope user touched raw that day. **(a) 🚨 Wall, third occurrence, same account, same motive:** `wbeaman@` read `brink.*` four times on 09-14 (12:58–12:59) — `brink.INFORMATION_SCHEMA.COLUMNS` for the three order tables, then `brinkOrder × brinkOrderItem × brinkOrderItemModifier` at **7.4 GiB** counting four LTO `ItemId`s with `IsVoided/IsDeleted/IsCleared = FALSE`, and twice a raw `brinkOrder.NetSales` comp tie-out against the mart (10:51 and 12:59). This is the 09-08 and 09-09 pattern verbatim, now on its third run: the motive is always *verification*, never an answer the mart refused. Both guarantees are already documented (voids are handled in the build; `brink_net_sales` is kept on `order_customer` **as the tie-out field** precisely so nobody has to open `brinkOrder`). The gap is not knowledge, it is reach — three sessions in seven days have gone to raw rather than to the documented validation column, which says the rollout of pull-based distribution to this account is now the blocker (Asana 1216812558621961), not another paragraph here. **(b) ✅ The comp-store fork has a root cause, and it is a column nobody could see.** The session produced **variant six** — `store_open_date <= DATE '2025-06-14' and store_id <> 50`, plus a second cutoff `<= '2025-06-03'` in other queries of the same analysis — returning **81 stores against the canonical 77**. The four extras are 182 Prasada / 183 Burnsville / 184 Surprise / 185 Brookfield: **$2,610,636 TY / $2,639,328 LY**, collectively **down ~1.1%**, so they drag the comp number rather than washing out. Measuring *why* turned up `sales_ops.store_info.store_comp_date`, undocumented until now: it is exactly `is_comp_store` as a date (77 past-dated, 21 future-dated, **zero disagreements**), and **every value is a January 1st** — comp entry is a finance-calendar decision, not tenure. A store opened 2024-08-08 comps on **2027-01-01**. *No* open-date offset can reproduce the comp base, which is why six analysts have now invented six different ones and why writing a longer offset never fixes it. Written up in both `store_info` dictionaries with the per-store table; the column is **not exposed on `claude.store_info`** and is **hand-maintained with no feed, no build step and no guard** (verified against `staging.store_info` and `sql/sales_ops.store_info.sql`), so point-in-time comp remains a steward request, not a self-serve filter (Asana 1217879256348882). **(c) `customer_hash.brink_order_customer_hash`: ~30 executions, ~100 GiB, recipe not adopted.** The `hk` CTE is still `select OrderID, BusinessDate, any_value(HashKey) … group by 1,2` over the full table, ~3.3 GiB a run, inside ~20 iterations of one 4,100-character query between 10:42 and 11:19 and again 12:51–13:50. Day 10 established the table is unpartitioned and unclustered and that the fix is materialise-to-`scratch`-once; the dictionary is still unwritten, so there was nothing for him to read (1218319855021359). Iterating a 4,100-char query 20 times against an unprunable table is the most expensive shape in the window and the cheapest one to prevent. **(d) Metric logic:** `sum(item_net_sales) as order_net` aggregated to order grain in the 10:47 comp query — §5 is explicit that per-item net **does not reconcile** to `order_customer.net_sales`, which is the only quotable net; he used `order_customer.net_sales` correctly in the 12:49 and 12:53 versions, so the two shapes disagree inside one session. Also `store_id <> 50` as the only store exclusion in every query — **1111 and 999 absent from the entire session again**, the Day-10 finding unchanged (1217879450574426). **(e) `dgetz@` was clean and hit a real edge.** All `claude.order_customer` + `braze.*`, no raw, canonical `customer_order_count` / `days_since_prev_order` shape, and the Day-7 one-pass first-order recovery (`date_sub(business_date, interval days_since_prev_order day)`) used correctly. What he ran into is the **today-partition identity gate**: `count(distinct mapped_cust_id) … where business_date between … and current_date('America/Denver')` undercounts the last day badly, because today's partition carries orders long before it carries identity (2026-09-14: 28,039 orders, **95 non-null `mapped_cust_id`**). He felt it and hand-patched around it **three different ways in one session** — `business_date < current_date` at 00:01, then `<= date_sub(current_date, interval 1 day)` as a separate `banked_thru_yesterday` column at 06:12, then an explicit literal end date. Three workarounds for one unstated rule is a definition gap, not a user error: **any identity-keyed count must end at yesterday, and say so.** New Asana task. **(f) Steward side, nothing new to mine.** The unlabeled account is automation plus dashboard work: the QuickSight refresh (13 `shared_datasets.*` views + `sales_ops.cs_comp_points`, 07:50–08:01 daily — note for future reviews, **these run under `bchristensen@` and are not manual queries**, Asana 1216920434852093), the 05:30 `marketing_ops.weather_triggers` health checks, and **540 executions of two cz-dashboard tab payload queries (`discount_day` and `item_day`, 270 each, 21.1 GiB apiece — 42 GiB, 90% of his unlabeled spend for the day)** during tab development. His MCP work was the SessionM phone-sync validation (all in `scratch`) and the `brink.brinkItems` master profiling that shipped the same day as the items mart (commit 8ab32dd) — already in memory and the dictionaries, nothing to add.
   >
   > **Day 10 (Thu 09-10): lighter — 168 non-steward queries / 261 GiB, zero failures, no business-data wall breach — but the single most consequential finding of the week is a competing definition of *a person*.** Volumes: `jelgie@` 134 MCP / 169.9 GiB, `wbeaman@` 27 MCP / 90.4 GiB, `dgetz@` 6 MCP / 0.9 GiB, `mraza@` 1 console / 0.01 GiB. **(a) 🚨 A second person-resolution algorithm is live in analyst SQL, one day after the steward ratified the first.** On 09-08/09 `wbeaman@` used the card hash as a *composite key* — `'L' || mapped_cust_id` for members, `'C' || HashKey` for anonymous guests, two populations held apart. On 09-10 he built a **bridge that overrides identity**: `edges` = (hkey, lid) co-occurrence counts, then `hmap` = `having count(*) = 1 or (count(*) = 2 and max(n)/sum(n) >= 0.8)` — a card hash is assigned to a loyalty person if it maps to one id, or to two with one dominant at ≥80% — and finally `coalesce(o.lid, m.lid) as gid`. He then measured `pct_guests_gaining_visits` and `pct_one_timers_who_were_repeaters` on that key, i.e. **restated visit frequency and repeat rate**, the two metrics this KB exists to hold stable. The 80% threshold, the two-id cap, and letting a hash outrank a NULL `mapped_cust_id` are all unratified judgement calls living in one session's SQL. The *motive* is sound — anonymous POS guests genuinely have no identity, and this is aimed at the guest-checkout distortion (1217494358740060) — so the ask is not to stop it but for the steward to either fold a card-hash tier **into `cust_map`** so there is one person rule, or name hash-stitched identity as a separate measure that is never quoted as a customer count (Asana 1218397760310471). **(b) The mechanical half of the same story, measured: `customer_hash.brink_order_customer_hash` is unpartitioned AND unclustered**, so the `where BusinessDate >= '2024-01-01'` he wrote on some runs (and omitted on others) prunes nothing either way — that is why 09-09 cost 157 GiB across 51 reads. First question on 1218319855021359 now closed; the dictionary must say the filter is cosmetic and the recipe is materialise-to-`scratch`-once. **(c) The routing rule, now with a price tag.** `wbeaman@` ran **27 of 27** queries on `sales_ops.*` with zero `claude.*` reads, and **zero** of them mention store 1111 or 999 — the locked exclusion is absent from his entire session, including the identity stitch and the LTO pre/post windows. `jelgie@` mentions 1111 in 31 of 134 and 999 in 7. The views already carry the rule; this is the concrete case that bypassing them is not a naming preference but a loss of four locked rules per query (1217879450574426). **(d) `edi`, three verified column facts** from `jelgie@`'s new-store opening media analysis (Ammon 2026-01-14, Rexburg 2026-08-05, Oconomowoc 2026-05-01, McKinney, week-4 account targets hand-typed into a `struct`), in which she hand-wrote the five-platform spend union **four times**: `spend` is stored as a **STRING** (every arm is `cast(spend as float64)`); the grain column is **not uniform** — `ad_group_name` on facebook/google/tiktok/snapchat, **`ad_set` on spotify**; and there is **no store key on spend rows**, so she matched spend to stores by regex on the ad-group name (`'mckinney'`, and a creative-type regex `r'[0-9]+\s*-?\s*[0-9]*\s*mi|day of|days? before|now open'`). That is the case for a `claude.ad_spend_daily` union — one typed `spend`, one `ad_group`, one `datasource` (1216803727477024). **(e) New GA4 gotcha:** she compared `analytics_384132317.events_intraday_20260909` (labelled `'yesterday'`) against `events_20260902` (labelled `'lw'`) in one union and computed sessions and purchase rate per device — an **incomplete intraday day against a complete day**, which reads as a real WoW drop. Three GA4 properties exist (`372459534`, `384132317`, `416476510`) and one was used; which is canonical for web purchase rate is unnamed. **(f) Wall: clean on business data.** The only raw reads were metadata — `jelgie@` hit `pulse.__TABLES__` twice (the first failed: `__TABLES__` exposes `table_id`, not `table_name`) and `mraza@` dumped `pulse.locations` from the console. No raw business measure was computed by anyone. **(g) That `pulse.locations` dump turned out to answer a long-open blocker:** the table carries **`brink_id` and `sessionm_store_id` on the same row** — 104 rows / 99 live, both populated on **92**, the same population size as `sessionM.retailer_stores`. `store_info` has no such column (verified). Denormalising `sessionm_store_id` onto `sales_ops.store_info` is one join and unblocks store-level loyalty reporting for standard users without exposing `pulse.*` (1216991989432028). **Steward patterns mined (28 unlabeled, the most useful day in a while):** **(1)** an `order_line_discount_detail` **grain probe** — `group by brink_order_id having count(*) > 1`, then the same with `root_offer_id` — confirming the mart is many rows per order *and* per (order, offer); aggregate to order grain before joining to `order_customer` or net sales fans out (the 09-07 `$2 Off Kids Meal` 4× fan-out, 1218328444979829, is this shape). **(2)** `brink.gblStore` → `store_info` column mapping written out explicitly, including **`IsCompStore as is_comp_store`** — worth pinning in the dictionary given comp-store is now the most-forked definition in the log (five variants, 1217879256348882): the flag has a single upstream source and it is Brink's. **(3)** date arithmetic worked out in three successive probes — `date_add(current_date(), interval 18 month)` vs `interval 548 day` vs `date_add(last_day(date_add(current_date(), interval 18 month), year), interval 1 day)` — an 18-month horizon snapped to the start of the following year. Shape matches the loyalty points-expiry rule; **intent not stated, so nothing codified** (don't infer a rule from its arithmetic). **(4)** The day's cheapest lesson, from the steward's own console: `select * … where 1=1` billed **14.57 GiB** and the follow-up `limit 10` still billed **5.29 GiB** — `LIMIT` is not a cost control. Now in the Gotchas checklist (1218397668807774).
   >
   > **Days 15–16 (Tue 09-15 → Wed 09-16): two brand-new MCP accounts that are both textbook, one account that is 202 GiB of re-derived definitions, and a price analysis built on a column that is itself derived from price.** Volumes: 09-15 was `jlarsen@` **4 MCP / 1.0 GiB and nobody else**; 09-16 was `wbeaman@` **80 MCP / 202.6 GiB** + `csokia@` **3 MCP / 0.5 GiB**. Zero `error_result` for any non-steward across both days. Steward 09-16: 262 unlabeled / 30.3 GiB (**204 of them one cz-dashboard payload query at 29.1 GiB** — tab development again, not manual analysis) + 85 MCP / 23.1 GiB with two trivial syntax errors. **(a) ✅ Both new accounts are clean, and they are clean in the way the distribution model predicts.** `jlarsen@` (13:48–13:55) opened with `max(business_date)` as a freshness check *before* asking anything — the right first move — then answered catering by fiscal period off `claude.order_customer` joined to `claude.date_dim` on `cal_date = business_date` using `fsc_year` / `fsc_period` / `fsc_week`, 0.89 GiB for 32 months. `csokia@` (16:40–16:45) ran loyalty orders / net / avg check per `mapped_cust_id` off `claude.order_customer` × `claude.loyalty_user`, keyed on **`lu.full_email`, not `lu.email`** — the 2026-09-01 rename honoured by a first-time user on their first session, which is the clearest evidence yet that the skill text is doing its job. Between them: zero raw reads, zero hand-rolled definitions, zero `sales_ops.*`. **(b) `wbeaman@`, session four, unchanged on routing:** 80 of 80 queries on `sales_ops.*`, **zero `claude.*`**, and stores 1111 / 999 absent from the entire day (1217879450574426). **(c) 🚨 NEW, and the most consequential finding of the window: a price-change and elasticity analysis computed realized unit price as `item_gross_sales / qty` — and `qty` is derived from `price`.** 11 queries / 13.6 GiB: weekly modal `round(price, 2)` per `item_id`, `sum(item_gross_sales)/sum(qty) as gross_per_unit`, `round(item_gross_sales/qty, 2) as upr`, and `avg(item_net_sales/nullif(qty,0))`, all comparing a pre window (2026-01-26→02-21) against a post window (02-23→03-21) with 02-22 excluded, to size a February menu-price change. The dictionary is explicit (`sales_ops.order_lines.md`, `qty`): **`qty` is not a source column — it is `round(item_gross_sales / price)`, floored at 1.** So `item_gross_sales / qty` reconstructs `price` by construction and the residual it measures is the rounding-and-floor error, not a discount, not a realized-price gap, and not elasticity. The shape is near-tautological wherever `price > 0`, and *worst* exactly where the analysis is most interesting — price-overridden and $0 lines, where `qty` is already wrong. It also silently drops nothing and errors on nothing, so it will keep producing a plausible number. Unit economics need a source quantity; the mart does not have one. **New Asana task**, and the gotcha is now on the `qty` row of the dictionary. **(d) The card-hash person key ran 18 more times / 48.3 GiB, now industrialised per-LTO** (1218397760310471). One execution per LTO window — `item_id in (643640567, 643640578)`, then `(643640588, 643640587)`, then `(643640573)`, then `(643640547, 643640548, 643640579, 643640549)`, and so on — each rebuilding the `hk` CTE (`select OrderID, BusinessDate, any_value(HashKey) … group by 1, 2`) over the full **unpartitioned, unclustered** `customer_hash.brink_order_customer_hash`, ~2.8 GiB a run, and each with **no date predicate on `base` at all**, so `first_d` is a full-history `min` recomputed 18 times. The `hmap` threshold is still the unratified `count(*) = 1 or (count(*) = 2 and max(n)/sum(n) >= 0.8)`. Two things this adds to the Day-10 write-up: the classification it feeds is `new` / `react` (any order before, none in the prior **98 days**) / `existing`, which is a **third lapsed definition** in live SQL alongside the guest-checkout 180-day rule and `days_since_prev_order`; and the cost is no longer a one-off session, it is per-campaign and will scale with the LTO calendar. The dictionary remains unwritten, so there is still nothing for him to read (1218319855021359). **(e) Comp store, variant seven, and it is the anti-pattern this file names in plain words.** `opens as (select store_id, min(business_date) first_day from sales_ops.order_lines group by store_id), comp as (select store_id from opens where first_day <= '2025-02-23' and store_id <> 50)`, plus a sibling built the same way off `order_customer` — 2 runs, 7.35 GiB, two full-history scans of a fact table to rebuild a column that already exists. The 09-09 rule says *never `min(business_date) group by store_id` off the fact table*; the 09-14 measurement says **no open-date offset can reproduce the comp base at all**, because `store_comp_date` is always a January 1st and comp entry is a finance-calendar decision. Seven variants now (1217879256348882). **(f) Channel rebuilt from `destination` + `order_source` six times / 9.3 GiB, in four mutually inconsistent shapes inside one day**: `'3P' = destination in ('DoorDash','UberEats','GrubHub','Postmates') or order_source = 'Checkmate'` (which double-counts — Checkmate *is* that destination list); `'POS register' / 'Outdoor kiosk' / 'Third party' / 'App' / 'Web' / 'Other'`; `is_reg = order_source is null`; and `mode = if(order_source is null, 'POS register', 'Digital')`. The canonical rollup is `revenue_category`, and the "Canonical `order_source` and `revenue_category` values" section above already says **do not rebuild the channel rollup yourself**. Four answers to "how did this sell by channel" from one analyst in one day is the exact failure this KB exists to prevent. **New Asana task.** **(g) Wall: two raw `brink` reads — fourth session in nine days, same verification motive, but one of them is a real gap.** `brink.brinkOrder` YoY net at 17:57 (0.18 GiB) fired **immediately after** the same YoY off `sales_ops.order_customer` — `order_customer.brink_net_sales` is the tie-out column kept on the mart for precisely this and was not used (1218510909825773, now 4×). The second is different in kind: `brink.SGBBreadOrderInvoicesDetails` at 18:04 — supplier bread invoices (`InvoiceDate`, `InvoiceNumber`, `StoreNumber`, `ItemDescription`, `Amount`), a **supply / COGS domain that no mart covers and the KB has never mentioned**. He found it by sweeping `INFORMATION_SCHEMA.TABLES` across 15 datasets at 18:03–18:04, which is what a user does when the documented surface does not answer the question. That is a gap, not a habit. **New Asana task.** **(h) One thing he got right that the KB should steal: the add-on attach-rate shape.** For cottage cheese and for ham, the same add-on is **two `item_id`s with two line shapes** — digital orders record it as `line_item_type = 'modifier'` with `item_modifier = 'Add'` (e.g. 643644590), in-store POS records it as `line_item_type = 'item'` (643644591) — and `'Extra'` / `'No'` are separate `item_modifier` values on the same id. Counting `item_id = X` alone returns one channel's half of the attach rate. Same family as the Try 2 Combo modifier/item split in §5; written up there now. **(i) Catering-item exclusion hand-rolled again** as `rev_center_name not in ('Party Trays & Food','Cater Desserts','Box Lunches')` sitting alongside `not is_catering` — the SKU-level flag gap (1218146236424381), now with a literal list to test against when it is built. **(j)** Every catering filter in the session was `order_lines.is_catering`, which is the **wrong side of the still-open store-50 disagreement** (#3) — `order_customer.is_catering` is the one the finance definition reached. **Steward patterns mined — two keepers, both out of the cz-dashboard payload queries, and one of them closes an open task.** **(1) The as-of guard**, which is exactly what 1218510909985648 asks for: `cast(least(date_sub(current_date('America/Denver'), interval 1 day), (select max(sd.business_date) from …)) as date)` — *yesterday, or the mart's last loaded date, whichever is earlier* — applied once at the top and reused by every cohort and identity-keyed count in the tab. It handles both failure modes in one expression: today's partition carrying orders but no `mapped_cust_id`, and a stalled mart (an empty partition satisfies `between`). Adopt this verbatim rather than the three hand-patches `dgetz@` tried on 09-14. **(2) The store-open fallback**: `coalesce(sdm.store_open_date, sdm.first_sold_date)` — the documented answer to the 9 `store_info` rows with NULL `store_open_date`, four of them live stores. **(3)** And one negative: a `select * from pulse.customers limit 100` on the steward's own console (09-15) billed **1.93 GiB** — the 09-10 lesson that `LIMIT` is not a cost control, reproduced by the person who wrote it down (1218397668807774).


2. **🚨 Harness defect, now measured rather than inferred: 43 of the day's 407 failures carry `statement_type = NULL`, and every one is `Not found: Table sales_ops.OrderCustomer`.** A query that cannot resolve its table never gets classified, so this review's `statement_type = 'SELECT'` filter drops it. The 08-21 write-up guessed at this shape; here is the number. **Every `OrderCustomer`-not-found count previously published in this skill is an undercount, including the ninth-business-day table above.** The two dead objects were still killing 406 jobs a day *four days* after the drop and rename, which is the opposite of the "it went quiet, we're done" reading the SELECT-only view produces. Harness fix: drop the `statement_type` filter, or add `or statement_type is null` (Asana 1217494247853173).

3. **✅ The wall breach stayed dead, and for the documented reason.** 34 of dgetz@'s 08-24 jobs reference `pulse.*` in their text; **33 of them are the dead template and never executed.** One ran (0.47 GiB): a "contacts created but never ordered, by week" count off `pulse.customers`. jelgie@ ran the same shape twice (0.51 / 0.47 GiB, current-year and LY-shifted). Three accounts' worth of motive, one surviving query shape, **byte-similar text under two user accounts 27 minutes apart** — the shared-workbook signature again. This fragment survived the rename only because it never referenced `order_datetime`. It will not go away until `pulse.customers` account-creation is exposed in `claude` (Asana 1217792657112397, 1216826772600045).

4. **🚨 A weekly executive scorecard is counting reward members off raw `sessionM.users` with the catering definition this KB explicitly retracted.** One MCP query, 10.71 GiB, produced ~24 board-level metrics. Its loyalty CTEs read:

   ```sql
   -- ANTI-PATTERN, observed 2026-08-24
   join `marketing-data-442316.sessionM.users` u
     on u.create_date <= w.we
    and u.email not like 'cater_%'      -- prefix-as-definition
   ```

   Two faults stacked. **(a)** It is a raw-dataset read; `claude.loyalty_user` exists for exactly this and carries `created_date`, `is_catering_member`, `was_ever_catering_member`, and the 420-external-id dedupe. **(b)** `email not like 'cater_%'` is the definition the [`sessionm-loyalty`](../sessionm-loyalty/SKILL.md) skill retracted: the prefix measures *ever provisioned*, not *current member*, agrees with the tier system only 99.93%, and **all 181 tier exits keep the prefix** — so it overstates catering by 232 and cannot answer any point-in-time question. A cumulative `create_date <= week_ending` count is precisely a point-in-time question. Use `is_catering_member = false` on `claude.loyalty_user`. Also note the same query is the denominator of a published `retention_rate` (`L6M distinct customers / cumulative reward members`), so the error propagates into a rate, where it is harder to spot than in a count.

5. **🕳️ The scorecard's metric definitions exist nowhere in this KB — that is the day's largest gap.** `rev_capture`, `activation_rate` (≥3 orders in a trailing 90 days), `retention_rate`, `l13w_active`, comp-store net sales, new-store sales (`store_open_date >= week_ending - 112 days`), the Digital / app / desktop / mobile-web splits, and trailing-52-week vs past-week VTO revenue are all hand-derived in one 10.71 GiB query and defined in zero dictionaries. A KB whose stated purpose is *the same question always produces the same answer* cannot leave its most senior recurring report undefined. Three concrete defects visible in that one query, pending the steward pinning the definitions:

   - `store_id <> 1111` appears **six** times — the locked exclusion is `not in (1111, 999)`, and the negated form is also NULL-unsafe.
   - The internal-traffic exclusion is `coalesce(mapped_email_domain,'') not in ('cafezupas.com','tkxel.com')` — still unratified (Asana 1217062310224330) and still copy-pasted per-CTE rather than defined once.
   - `join sales_ops.order_lines ol on ol.brink_order_id = oc.brink_order_id` with **no `business_date` equality** — both tables are partitioned on it, so the join prunes nothing and scans `order_lines` whole. Add `and ol.business_date = oc.business_date`. This is the same omission the steward found between the repo and deployed copies of `claude.order_customer` on 2026-08-17.

> **✅ RESOLVED 2026-09-11 — `edi` (paid media) is now documented and behind views.** It was the KB's largest hole: a live steward-maintained pipeline refreshed daily at **04:01 MT** from windsor.ai (`staging.edi_*` → `edi.*`), carrying 13 tables and $1.34M of spend since 2024, with zero references in any skill, dictionary or SQL file. Now covered by **`claude_skills/paid-media/SKILL.md`** and three dictionaries (`claude.ad_spend_daily`, `claude.ad_reach_weekly`, `edi.paid_media_sources`), with two views deployed: **`claude.ad_spend_daily`** (55,113 rows, all five platforms, ties out exactly to source) and **`claude.ad_reach_weekly`**. Spend / ROAS / channel-performance questions are answerable. Asana 1216803727477024.
>
> **Two corrections to earlier notes in this file.** (1) `spend` is **`BIGNUMERIC`**, not STRING — re-verified 2026-09-11 against `INFORMATION_SCHEMA.COLUMNS` in both `edi.*` and `staging.edi_*`; `cast(spend as float64)` is harmless but unnecessary. (2) The "common column vocabulary across platforms" listed above **is not shared** — impressions are `total_impressions` on snapchat, conversions are `actions_purchase` on facebook and `transactions` on snapchat, and tiktok/spotify's `total_complete_payment_rate` holds **dollars, not a rate**. That divergence is why the union is now a view. Full mapping table in `data_dictionaries/edi.paid_media_sources.md`.
>
> **The undocumented paid-media surface is wider than `edi` (measured 2026-08-31):** one analyst MCP session also queried the native Google Ads transfer dataset (`google_ads.ads_Campaign_*`, `ads_CampaignCriterion_*`, `ads_GeoStats_*`, `ads_CampaignStats_*` — catering-campaign geo-target questions) and the GA4 export (`analytics_384132317.events_*` — device/session counts), ~30 paid-media queries in the day with six schema-guessing failures along the way (`edi.facebook_daily` has `date`, not `date_start`; `EXTRACT(DAYOFWEEK FROM date)`, not `EXTRACT(DAYOFWEEK, date)`). All three datasets answer real recurring questions and none has a dictionary, canonical metric definitions, or a skill.
>
> **Still widening (2026-09-01):** the same analyst added `shared_datasets.google_offline_conversions` (upload rows by `conversion_name`, missing email/phone match keys), `etl_metadata.watermark` / `connection_info` / `table_config` (pipeline freshness), and two more GA4 properties (`analytics_372459534`, `analytics_416476510`, incl. `events_intraday_*`). One more verified column name: **`edi.google_ads_daily` spends in `spend`, not `cost`** — `Unrecognized name: cost` failed twice in two separate sessions the same day before the cross-platform spend union compiled. The per-platform daily tables all share `spend`; there is no `cost` column anywhere in `edi`.
>
> **✅ Reusable steward pattern mined from that pipeline — restate by observed key set, not by date window.** The order marts delete a *window* (`where business_date >= start_date`). The EDI loads instead delete exactly what the source is about to replace:
>
> ```sql
> delete `marketing-data-442316`.edi.google_ads_daily g
> where g.date in (
>   select date from `marketing-data-442316`.staging.edi_googleads_daily
>   union distinct
>   select date from `marketing-data-442316`.staging.edi_googleads_daily_pmax
> )
> ```
>
> Two properties a window cannot match. It **cannot leave a hole** (only keys that are being reinserted are removed), and it **handles non-contiguous restatements** — the 08-24 run's Google Ads key set skipped 07-26, 08-02, 08-09 and 08-16, which any `>= start_date` window would have deleted and not replaced. Use this idiom whenever the upstream is a full-refresh staging table rather than an append-only log. The weekly-reach loads add a companion trick — `qualify min(reach_week) over (partition by 1) <> reach_week` drops the oldest, still-partial reach week from the restatement set.

### 🕳️ MART GAP: there is no order-*placement* timestamp anywhere in the marts (measured 2026-08-24)

**Catering lead time — "was this ordered the same day it was served, or booked in advance?" — cannot be answered from the `claude` or `sales_ops` marts.** This is a real gap, not a routing problem, and it is worth stating precisely because the obvious column looks like it should work and doesn't.

`order_datetime_local` is a **fulfillment**-side timestamp, not a placement time. Measured on `claude.order_customer`, 2026-07-27 → 08-20, stores 1111/999 excluded:

| Population | Orders | `date(order_datetime_local) = business_date` | max lead days |
|---|---|---|---|
| Non-catering | 596,215 | 596,211 (99.999%) | 5 |
| **Catering** | 7,407 | **7,378 (99.6%)** | **0** |

A catering order booked three weeks out still carries an `order_datetime_local` on its *service* date. So `date_diff(business_date, date(order_datetime_local))` is structurally ~0 and any "advance vs same-day" split built on it returns "100% same-day" — a confident, plausible, entirely wrong answer.

The only source of placement time is **`pulse.orders.place_time`**, which is behind the wall. That makes this the third instance of the same shape (after the guest-supplied email, Asana 1217645882648277): **a wall breach whose cause is a missing mart column, where repeating the rule accomplishes nothing and exposing the column removes the motive.** Observed driving it, 2026-08-21/23, `mraza@` direct console, 12 queries: a weekly `catering_same_day_sales_pct` by store built on `pulse.orders` joined to `pulse.locations`, with `DATE(o.place_time) = o.business_date` as the same-day test — then, on 08-23, wrapped in a `FORMAT(...)` generator emitting `INSERT INTO web_systems.catering_same_day_sales_pct ...` statements for a downstream MySQL application.

Two things to say about it, in this order:

1. **The question is legitimate and the marts cannot answer it.** Log it as a gap; don't send the author back to a mart that will silently tell them everything is same-day.
2. **The financials in that pipeline are not canonical, and that part is fixable today.** It measures catering sales as `sum(o.sub_total)` from `pulse.orders` — **Pulse financials, which hard rule 5 forbids outright** ("Brink is the sole financial source of truth; Pulse is a helper for digital order/customer metadata only"). It also uses Pulse's own `o.is_catering` rather than the finance definition on `order_customer`, and carries no `store_id not in (1111, 999)`. A production MySQL table is being populated from it. **Even before the placement-time column exists, the denominator and the sales measure must come from `claude.order_customer` (`net_sales` / `gross_sales`, `is_catering`);** only the same-day *flag* genuinely requires Pulse. Splitting the query that way shrinks the breach to one column and makes the number quotable.

### ⚠️ Legacy schemas survive outside the walls — `stella_cafezupas.OrderCustomer_test` (found 2026-08-24)

Dropping `sales_ops.OrderCustomer` did **not** retire the legacy vocabulary. A full copy of its schema lives in an undocumented dataset that no skill, dictionary or wall mentions:

`marketing-data-442316.stella_cafezupas.OrderCustomer_test` — the only table in its dataset, created 2026-04-01, **not partitioned and not clustered**, carrying the entire retired column set: `BusinessDate`, `order_datetime`, `storeid`, `state`, `netsales`, `iscatering INT64`, `lifetime_order_cnt`, `order_count`.

Three things make it worth knowing about:

1. **It is frozen at a single business date.** 29,552 rows, `min(BusinessDate) = max(BusinessDate) = 2026-03-26`, `max(update_datetime)` 2026-04-01. Yet `stella-bigquery@` has read it **15 times since 2026-08-17**, most recently 2026-08-24 06:10 MT, with `WHERE brink_order_id > ?` — an incremental-sync loop that can never advance because the source never changes. Whatever "Stella" is, it believes it is syncing orders and has received nothing since March. Cost is trivial (~0.10 GiB/run); the silence is the problem.
2. **Both time columns are typed `TIMESTAMP`.** On the mart, local is `DATETIME` and UTC is `TIMESTAMP`, so a type error catches the confusion (that is what happened on 08-17). Here `order_datetime` and `order_timestamp_utc` are *both* `TIMESTAMP` — the store-local wall clock has been cast into a UTC-bearing type and persisted. Nothing errors, and the only signal left is the column name.
3. **It independently confirms the 4–7 hour claim.** `timestamp_diff(order_timestamp_utc, order_datetime, hour)` ranges **min 4, max 7** over its 29,530 dual-populated rows — a separate table, built by a separate process, reproducing the four live offsets the KB measured on the mart. A number that survives an independent build is worth more than one measured twice the same way.

**Rule: `select *`-shaped copies of a mart into a vendor-facing dataset are a second, unwalled interface.** They inherit the schema at copy time and then diverge silently. When you rename or drop a column, grep `INFORMATION_SCHEMA.COLUMNS` across **every** dataset in the project, not just `sales_ops` and `claude` (Asana task filed 2026-08-24).

### ⚠️ Commenting out the date filter is not "widening the search" — an id predicate prunes nothing (measured 2026-08-18)

The most expensive authoring mistake in the log to date, and it isn't about this project's marts — it will bite anyone doing single-order lookups on a raw Brink table. Observed from a new direct-console account: **20 full-table scans / 224.08 GiB in one day, 99.9% of that account's entire spend.** The shape, verbatim:

```sql
-- ANTI-PATTERN, do not copy
select *
from `marketing-data-442316`.brink.brinkOrder bo
where 1=1
--and bo.businessdate = '2026-8-17'
and bo.id = 105394802264065
LIMIT 200500
```

The `bo.id` predicate is live and so is the `LIMIT`. It still reads the entire table, because **`brink.brinkOrder` is partitioned on `BusinessDate` and not clustered on `Id`** — an id filter is evaluated after the scan, and `LIMIT` doesn't bound bytes either. Measured on that table the same day:

| Predicate | Billed |
|---|---|
| `where businessDate = '2026-8-17'` | **0.01 GiB** |
| `where bo.id = <literal>` (no date) | **11.20 GiB** |

~1,120x, for a query that looks *more* selective. The author commented the date out to search across days, which is a reasonable intent with an unreasonable price. **A single-order lookup must carry a date**; if the date genuinely isn't known, expect and budget a full scan, or ask for the table to be clustered on `Id` (Asana 1217554047292419).

**The detection signal is a cost that doesn't move when the filter moves.** All 20 of these billed 11.2 GiB whether the id predicate was live or commented, and across twelve different order ids. Identical `total_bytes_billed` across different literals proves the literal is pruning nothing.

> **🧰 Harness note for whoever runs the query-log review — do not analyse query text with whitespace collapsed.** This finding was first written up as "the `--` comment swallowed the `bo.id` predicate and the `LIMIT` too," which is **false and was retracted the next morning**. The cause was the review's own SQL: `substr(regexp_replace(query, r'\s+', ' '), 1, 700)` flattens the six-line query onto one line, after which a leading `--` genuinely *appears* to comment out everything following it. Line structure is load-bearing whenever a `--` is present. Inspect with `split(query, '\n')` before drawing any conclusion about what a comment covers — and note that the wrong version was self-consistent with the byte counts, so plausibility was no protection.

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
| App user | **Canonical customer definition (steward decision 2026-09-17).** A `person` customer with an **app purchase in the trailing 12 months** (`order_source in ('iOS', 'Android')` **or** `in_store_scan = 1`; an in-store scan counts as an app purchase by steward assumption) **or** a **native-app session in the trailing 90 days** (`braze.app_sessionstart`, `platform in ('ios', 'android')`, `workspace = 'cafe_zupas'`). Full rules, gotchas and the canonical query: see *"App user" is a canonical customer definition* below |
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

### "App user" is a canonical customer definition (steward decision 2026-09-17)

An **app user** is a `person` customer who satisfies **either** test:

1. **App purchase in the trailing 12 months.** At least one `claude.order_customer` row with
   `order_source in ('iOS', 'Android')` **or** `in_store_scan = 1`. The steward's stated
   assumption is that an in-store loyalty scan is made with the app, so **a scan counts as an
   app purchase** for this definition. State that assumption whenever the scan share matters
   to the answer.
2. **Native-app session in the trailing 90 days.** At least one `braze.app_sessionstart` event
   with `workspace = 'cafe_zupas'` and `platform in ('ios', 'android')`, joined on
   `safe_cast(external_user_id as int64) = oc.mapped_cust_id`.

Both windows anchor to `current_date('America/Denver')` unless the question names an as-of
date, in which case substitute that date in **both** window expressions and say so.

**Rules and gotchas**

- **`platform` is the whole game on the Braze side.** `app_sessionstart` is not app-only: the
  web SDK and landing pages log to the same table. Trailing 90 days measured 2026-09-17,
  `cafe_zupas` workspace: **web 1,132,440 users**, ios 257,285, android 63,241,
  landing_page 3,454. Without `platform in ('ios', 'android')` the "app user" count roughly
  quadruples. Braze platform values are **lowercase** (`'ios'`, `'android'`); the order-mart
  values are **mixed case** (`'iOS'`, `'Android'`). Both spellings above are the live ones.
- **Join on the customer id, never on email.** `safe_cast(s.external_user_id as int64) =
  oc.mapped_cust_id`, per the braze-campaigns skill. Rows whose `external_user_id` does not
  cast are anonymous or non-customer profiles and drop out of the definition by design.
- **It is a customer-level metric**, so `customer_type = 'person'` applies to the order side
  (kiosk, internal and aggregator ids never qualify). Report `count(distinct mapped_cust_id)`.
- **What is deliberately NOT in the definition:** in-app message or content card
  impressions and clicks, push opens, and any share-of-orders threshold. Impressions are a
  by-product of a session and add nothing over `app_sessionstart`; push opens happen outside
  the app and the session they trigger is already counted. Keep those as engagement metrics
  measured *within* the app-user population. A "50%+ of orders via the app" cut is **not
  canonical**; if someone asks for it, present it as a labelled fork ("app-primary") and never
  substitute it for the definition above.
- **This is not "loyalty member", "digital customer" or "app orders".** Loyalty membership
  lives in `claude.loyalty_user`; "digital" is `revenue_category = 'Digital'`; and a
  channel question about **app orders** is `order_source in ('iOS', 'Android')` on orders,
  with no scan component and no session component. The scan-as-purchase assumption is for the
  customer definition only.
- **Four sub-populations are worth reporting alongside the headline** because the two tests
  measure different things: app purchasers (test 1), session users (test 2), session-only
  (installed and active, no attributable purchase in 12 months) and purchase-only (bought or
  scanned in the last 12 months, no native session in 90 days, i.e. lapsing or uninstalled).
- **Measured 2026-09-17** (windows ending that day): **468,851 app users**; 417,711 app
  purchasers (246,649 with an app order, 278,382 with a scan; the two overlap); 310,623
  session users; 51,140 session-only; 158,228 purchase-only. Quote these only as the
  as-of-date sizes they are.
- **Freshness:** `app_sessionstart` backfills for ~2 days (see the braze-campaigns skill), so
  a same-day count is a few sessions light at the edge of the 90-day window. Immaterial for
  the headline; label it if the question is about the most recent days.
- **Materialised on `sales_ops.customer_attribute` since 2026-09-18:** `is_app_user`,
  `app_user_type` (`purchase_and_session` / `purchase_only` / `session_only` / NULL),
  `is_app_purchaser`, `is_app_session_user`, `app_orders_l12m`, `in_store_scans_l12m`,
  `app_session_days_l90`, the three `last_*_date` columns and two lifetime counts, rebuilt daily
  at 05:20 MT with windows anchored on `attribute_asof_date`. Use the table for segmentation of
  known customers; use the query above when the as-of date is not yesterday or when the
  never-ordered session users matter (the table cannot hold them: 23,092 on 2026-09-16, see the
  dictionary). **`is_app_user` and `app_user_type` are also on `claude.order_customer`** (view
  redeployed 2026-09-17 23:20 MT), so standard users can split orders by app-user status directly:
  both are **NULL on unidentified and non-person orders**, so filter `oc.is_app_user is true` and
  pair any "not an app user" read with `oc.customer_type = 'person'`.
- **The scan-as-app assumption, measured 2026-09-17:** 8.1% of customers who scanned in-store
  in the trailing 90 days had no native-app session in the window, versus 1.3% of customers
  who placed an app order (the Braze identification baseline). About 7,000 scanners are
  therefore counted as app users without the app being visible in Braze. Intentional; state it
  when the scan share drives the answer.

**Canonical query** (one row per app user, with the flags needed for the sub-populations):

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
coalesce(ap.mapped_cust_id, se.mapped_cust_id) as mapped_cust_id
, ap.mapped_cust_id is not null as is_app_purchaser
, se.mapped_cust_id is not null as is_app_session_user
, coalesce(ap.app_orders, 0) as app_orders
, coalesce(ap.in_store_scans, 0) as in_store_scans
, coalesce(se.session_days, 0) as session_days
, ap.last_app_purchase_date as last_app_purchase_date
, se.last_session_date as last_session_date
from app_purchasers ap
	full outer join app_sessions se
	on se.mapped_cust_id = ap.mapped_cust_id
```

Headline: `count(*)` over that result is the app-user count. Verified 2026-09-17 against
`claude.order_customer` and `braze.app_sessionstart`; the partition filters are constant
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

## Discount and loyalty-giveaway questions — `claude.order_line_discount_detail` (new 2026-08-15)

"What did we give away, and through what?" now has a home. One row per **discount
component**, with loyalty and offer attribution joined on. Full docs:
[`data_dictionaries/claude.order_line_discount_detail.md`](../../data_dictionaries/claude.order_line_discount_detail.md).
It is the sanctioned wrapper around `pulse.order_discounts`, `sessionM.transaction_discounts`
and `sessionM.user_offers` — **never query those directly.**

### The grain is components, not lines — get this right first

Brink emits **exactly one** `item_id = 643536109` ("Online Discount") line per order. Where
Pulse holds several discount components under it, the table **splits that one Brink amount
across them** proportionally, so a single Brink line can produce several rows each with its
own `discount_type`. Row count runs **~1.5% above the source line count** (3,440,131 vs
3,388,269 full history, 2026-08-14). That surplus is the design.

- **`discount_amount` is the only summable money column.** It reconciles to `order_lines`
  exactly — **−$25,977,208.08 on both sides**, full history, identical filters (deployed table, 2026-08-15).
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
from `marketing-data-442316`.claude.order_line_discount_detail dd
where 1=1
and dd.business_date between @start_date and @end_date
group by
dd.discount_type
order by
discount_amount
```

### Employee / team-member meal questions — use `is_employee_meal_discount` (new 2026-08-17)

**Do not filter on `discount_type` or on a name pattern.** The employee benefit has run under
four different Brink programs and two sessionM offer paths since 2018, and no single name or id
covers them. `is_employee_meal_discount` is the canonical flag and is never NULL.

```sql
select
dd.business_date
, count(distinct dd.brink_order_id) as employee_meal_orders
, round(sum(dd.discount_amount), 2) as employee_meal_discount
from `marketing-data-442316`.claude.order_line_discount_detail dd
where 1=1
and dd.business_date between @start_date and @end_date
and dd.is_employee_meal_discount = true
group by
dd.business_date
order by
dd.business_date
```

It replaces **`order_customer.is_employee_discount`**, which was **dropped from the table on
2026-08-17** — the column no longer exists and naming it errors. That one was built from name
patterns and its `%Meal%` arm flagged `Free Birthday Meal - Catering Offer` as an employee order
(55 orders in 90 days). Any saved query still using it is now broken, not merely stale; move it
here. For an order-level flag, aggregate this table with `max()` / `logical_or()` first.

⚠️ **Two live caveats.** (1) The flag was widened on 2026-08-17 to cover `Employee 25%`
(2018→2020) and the pre-cutover family-meal id; that widening reaches history **only after a
full-history rebuild**, because the widest scheduled reload is 730 days. Until that runs,
pre-2023 employee-meal spend reads ~$757K low. (2) `discount_type` still keeps `Employee 25%`
and `Employee Meal Discount` as **separate** programs on purpose — 25%-off and 100%-off are
different benefits. Use the flag to union them, not a merged `discount_type`.

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

### "Earned" discounts = the two loyalty redemption types (steward definition 2026-08-18)

**Earned = `discount_type in ('Reward Redemption', 'In-cart Points Redemption')`.** Full stop.
Confirmed by the steward 2026-08-18. Everything else was **given**: marketing offers outside the
loyalty wallet, in-store promotions, third-party discounts, service recovery, manager
discretion, employee benefit.

```sql
select
dd.business_date
, case
    when dd.discount_type in ('Reward Redemption', 'In-cart Points Redemption')
      then 'earned'
    else 'given'
  end as discount_basis
, count(*) as discount_lines
, count(distinct dd.brink_order_id) as orders
, round(sum(dd.discount_amount), 2) as discount_amount
from `marketing-data-442316`.claude.order_line_discount_detail dd
where 1=1
and dd.business_date between @start_date and @end_date
group by
dd.business_date
, discount_basis
order by
dd.business_date
, discount_basis
```

2026-05-01 → 2026-07-31: earned **103,540 lines / −$752,606.55**, out of 181,505 lines /
−$1,485,468.22 of all discounts — **50.7% of discount dollars**.

#### Why both Brink ids belong, including `643571116`

**`643571116` is a purpose-built loyalty-redemption id** — the in-store Cafe Zupas Rewards
button. It fires only when a member redeems something from their loyalty wallet. That is the
definition of the id, not an inference from its contents.

The data agrees. Every reward line resolves to a sessionM member wallet offer
(`root_offer_id`), on both ids and every origin:

| `discount_type` | `discount_origin` | `item_id` | Lines | With wallet offer | Coverage |
|---|---|---|---|---|---|
| Reward Redemption | In-Store | 643571116 | 42,173 | 41,767 | **99.0%** |
| Reward Redemption | Online | 643536109 | 26,675 | 26,452 | **99.2%** |
| Reward Redemption | Outdoor Kiosk | 643571116 | 605 | 597 | 98.7% |
| Reward Redemption | Outdoor Kiosk | 643536109 | 385 | 383 | 99.5% |
| In-cart Points Redemption | Online / Kiosk | 643536109 | 33,702 | n/a — `points > 0` on 100% | — |

`In-cart Points Redemption` carries the point spend directly: `points > 0` on **all 33,702
lines**, 43.0M points in the window, zero exceptions.

> **Do not "correct" this by excluding `offer_kind = 'promotional'` rows.** A wallet offer that
> was issued rather than points-priced is still a loyalty redemption by a member — the program
> earned it, and the steward's definition covers it. An earlier pass at this question excluded
> them and understated earned by −$36,798.41. That was wrong.

#### Optional breakdown *within* earned — points-priced vs issued-to-wallet

If someone asks specifically about **points cost, points liability, or what points bought**,
they want the points-priced subset, not all of earned. `claude.loyalty_offer_usage.offer_kind`
splits it: `points_purchase` = the guest paid points at a published price, `promotional` = the
offer was issued into the wallet and redeemed at no point cost. Verified clean over offers
redeemed in the window — `points_required > 0` on **59,190 of 59,190** `points_purchase` rows
(avg 1,110 points) and **0 of 22,074** `promotional` rows.

| Subset of earned (in-store `643571116`, 2026-05-01 → 07-31) | Lines | Amount |
|---|---|---|
| `points_purchase` — points paid at a published price | 32,299 | −$243,048.45 |
| `promotional` — offer issued to the wallet, redeemed free | 10,064 | −$36,798.41 |

The points menu with its prices: `Try 2 Combo` 1,950 pts, `Protein Bowl` 1,900,
`Large Salad` 1,750, `Sandwich` 1,350, `Half Salad` 1,350, `Half Soup` 1,100,
`Cheesecake` 1,000, `50% Off Try 2 Combo` 975, `Large Drink` 550, `Regular Drink` 450,
`Chips` 300, `French Baguette Bread` 200. The issued-to-wallet side:
`$1 Happy Hour Mocktail`, `Birthday Free Dessert`, `Free Reg Drink w/ Purch`,
`Sip Pass - Free Daily Drink`, `$5 off Your First Order`, `$5 off Oconomowoc`, `Free Delivery`.

**This is a breakdown, not a filter.** Both rows are earned. Present it only when the question
is about points economics, and label the two rows in the words above — not as
"earned vs not earned."

#### 🚨 `root_offer_id` case is inconsistent — `upper()` both sides or the join returns nothing

Independent of the definition, and still live. The column is
`coalesce(odr.root_offer_id, pd.sessionM_root_offer_id)`: the sessionM arm is **UPPERCASE**,
the Pulse arm is **lowercase**. `claude.loyalty_offer_usage.root_offer_id` is UPPERCASE.

Joining without `upper()` matches **0 of 12,040** `Offer` lines and drops online reward lines
too, and it fails **silently** — in the direction that makes wallet offers look unresolvable.
Same offer under two cases: `06ce255f-b15b-405e-8b0b-720059a51715` (Pulse,
`Sip Pass - Free Daily Drink`) vs `06CE255F-B15B-405E-8B0B-720059A51715` (sessionM).

Always `upper()` both sides. Build fix pending: `upper()` on `pd.sessionM_root_offer_id`, one
line below where `sessionM_user_offer_id` already is.

#### ⚠️ Employee meals sit inside earned — don't double-count them

**292 lines / −$4,255.83** in the window are `discount_type = 'Reward Redemption'` **and**
`is_employee_meal_discount = true` — the `Team Member Meal` offer, issued to team members'
loyalty wallets. Both flags are correct and both are canonical, so an earned-vs-employee
rollup that treats the two as exclusive double-counts them. State which one the question is
asking about; if it needs both, subtract the overlap explicitly.

#### Window rules

- **Reliable 2024-01-01 forward.** Unattributable `Error` as a share of loyalty-bucket dollars:
  **2023: 18.0%** (−$407,323.83) · 2024: 2.9% · 2025: 0.1% · 2026: 1.3%.
- **2023 spans the Punchh → sessionM cutover**, and the legacy earned programs carry different
  `discount_type` values the rule above does not name: `Punch Loyalty` 4,028 lines (→2023-05-30),
  `Catering Redemption` 3,627 (2023-05-31→12-01), `Punchh Loyalty` 534 (→2023-02-15),
  `Loyalty Reward-Free Drink` / `-Birthday Meal` / `-Free Dessert` 37 combined (→2023-02-10).
  These *were* earned in the old program's terms. Add them by name for any pre-2024 figure and
  label the result as two incompatible loyalty programs stitched together.
- **`Offline Cafe Zupas Rewards`** (`item_id 643571119`, 2,225 lines full history) is always
  **$0.00** — a marker line. Harmless in dollar totals, inflates line and order counts. It is
  not one of the two earned types, so the rule above already excludes it.
- **Never intraday** — see the `Error` health signal below.

#### ⚠️ Offer resolution shifts when a wide reload runs

Measured 2026-08-18: online reward `root_offer_id` coverage read **314 of 26,675 lines** early
in the session and **26,452 of 26,675** after `sales_ops.order_line_discount_detail` was
modified at 17:15 MT the same afternoon. Same table, same window, same query.

The likely mechanism is the build's `offer_detail` CTE filtering
`uo.create_date >= start_date - 60`: a narrow daily reload cannot see older offers, so
`root_offer_id` goes NULL on rows a wide reload would resolve. **That explanation is untested** —
do not repeat it as fact. What is certain: **wallet-offer attribution on this table is not
stable across reload widths**, so a coverage percentage is only true as of a stated timestamp,
and a low one means "check what last touched the partition" before it means "the data is
missing." Same family as the `is_employee_meal_discount` widening note.

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

## Discounts must tie to `order_customer` — and how to run that check (2026-08-15)

`sum(discount_amount)` on `claude.order_line_discount_detail` equals
`sum(total_discount_amount + total_promotions_amount)` on `claude.order_customer`, to the cent.
If a user reports these disagreeing, **check the comparison before you check the data** — three
things break it and all three look like a data defect:

1. **Compare at ORDER grain, not date grain.** At date grain a compensating pair on the same day
   cancels out and reads as a match. Join on `brink_order_id` **and** `business_date`.
2. **Exclude store 999 on the `order_customer` side.** `order_line_discount_detail` drops
   `store_id not in (1111, 999)` upstream; `claude.order_customer` drops only 1111. One order /
   **$13.49** over 90 days lives in that gap.
3. **Closed days only.** `order_customer` is a snapshot from its last load while raw Brink moves
   all day, so the current business date drifts ~47 orders / ~$438. Same rule as the discount-mix
   one above: answer through yesterday and say why.

```sql
with dd as (
select
dd.business_date
, dd.brink_order_id
, abs(round(sum(dd.discount_amount), 2)) as amount
from `marketing-data-442316`.claude.order_line_discount_detail dd
where 1=1
and dd.business_date between @start_date and @end_date
group by
dd.business_date
, dd.brink_order_id
)

, oc as (
select
oc.business_date
, oc.brink_order_id
, round(oc.total_discount_amount + oc.total_promotions_amount, 2) as order_discount
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date between @start_date and @end_date
and oc.store_id not in (1111, 999)
)

select
dd.business_date
, dd.brink_order_id
, dd.amount
, oc.order_discount
from dd
	full outer join oc
	on oc.business_date = dd.business_date
	and oc.brink_order_id = dd.brink_order_id
where 1=1
and ifnull(dd.amount, 0) <> ifnull(oc.order_discount, 0)
```

### Why they used to disagree — and why `order_customer`'s zeros were RIGHT

Worth carrying as a pattern, because the instinct it corrects is a common one.

`sales_ops.order_customer` joins its discount and promotion CTEs on **`boi.orderid`** — the output
of its own `brink_order_item` CTE — not on `bo.id`. That CTE filters
`IsCleared/IsVoided/IsDeleted = false` and then applies
`having sum(ItemGrossSales) > 0 or sum(ItemNetSales) > 0`. Any order it drops has
`boi.orderid = NULL`, so the discount joins collapse and the order reports **zero** discount even
though `brinkOrderDiscount` holds live rows with `isDeleted = false`. `order_lines` keyed on
`bo.id`, kept the money, and ran **$753.68 high over 90 days across 80 orders**. Every affected
order carries `has_order_items = false`.

It reads like a bug in `order_customer`, and the obvious fix — repoint the join at `bo.id` — is
**wrong**. Those orders are voided/comped shells: Brink zeroes the header (`GrossSales` /
`NetSales` / `Subtotal` / `Total` all 0) and voids the items but leaves the discount row standing.
78 of the 80 had every item row cleared/voided/deleted; the other 2 carried a single
`Online Details Memo` line at $0.00. Nothing was sold, so nothing was given away — joining on
`bo.id` would book $767 of giveaway against $0 of sales and drive `net_sales` negative.

**The rule: when two marts disagree, work out which one is describing reality before you make the
other one match it.** Here the fix went into `order_lines` (a `sellable_orders` guard suppressing
discount and promotion lines on those orders), not into the mart that looked broken.

`has_order_items = false` orders read `net_sales` = **$0.00, and that is correct**.
`gross_sales` is 0 on every one of them — 12,327 of 12,327 over 2026-07-20 → 08-22 — so
`0 - 0 - 0 = 0`. Nothing was sold and nothing was given away. Payments on those rows are real.
**Retracted 2026-08-24 (steward ruling):** an earlier revision called this net figure "wrong"
and the zeroed discounts a join-key bug. Orders without valid lines cannot carry discounts or
promotions, so they are excluded by design.

## ⚠️ In an incremental build, never window a DIMENSION by the fact window (general rule, 2026-08-15)

This one generalises to **every** scheduled script in `sql/`, and it produced the nastiest bug
found in the `order_line_discount_detail` review — worth stating as a rule rather than a war story.

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
2. **Widen the reload windows so the lookback covers the tail** — what `order_line_discount_detail`
   ships with (120d daily / 380d Monday / 730d monthly, each with a further `- 60` on the
   sources). Cheaper, but it is a *bet* on lead times and needs an alarm. Here that alarm is
   the `Error` bucket.

Related traps in the same family:

- **Wrap the `delete` + `insert` in `begin transaction; … commit transaction;`.** BigQuery
  scripts are **not** atomic. A failed insert after a committed delete leaves a hole the width
  of the reload window — returning **zeros, not an error** — and intraday runs that only cover
  today won't heal it until the next 4am pass.
- **A wide reload window is not a full rebuild.** Whatever sits before the widest window is
  frozen forever. On `order_line_discount_detail` that is **65.1% of rows (2,239,212 / −$15.6M)**. Since
  `order_lines` was restated across full history **three times in the month to 2026-08-14**,
  re-running the full-history build of any derived table is a **required step in the
  `order_lines` rebuild checklist**, not a nice-to-have.
- **`current_date` is UTC.** Intraday runs firing 8pm–11pm Denver are 2am–5am the *next* UTC
  day, so a bare `current_date` silently means "tomorrow" for a third of the schedule. Pin
  `current_date('America/Denver')` in every scheduled script and every assertion. This cost
  real time during the `order_line_discount_detail` review: three test builds either side of the rollover
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

## Recipes

**Intraday pacing — "how is today running versus comparable days at this hour?" (steward pattern, mined 2026-09-07):**

Compare cumulative order counts at fixed wall-clock cutoffs, not day totals — a partial day against full days is the classic false alarm. Use `order_datetime_local` (DATETIME, store-local), never `order_timestamp_utc`. Pick the comparison set explicitly and label it: the same weekday for the prior four weeks, plus the holiday-aligned LY day if today is a holiday (Labor Day 2026-09-07 ↔ 2025-09-01) and a plain LY weekday as the non-holiday baseline. Always carry `max(order_datetime_local)` so the reader sees where today's data stops — intraday reloads land hourly at :02, so "today" is stale by up to an hour. Restrict `revenue_category` / `is_catering` to the population being paced; catering orders carry their *service*-date timestamp and distort a same-hour read. Hour-of-day against **2024** is not comparable (12-hour clock defect, see top of file).
```sql
select
oc.business_date
, format_date('%a', oc.business_date) as dow
, count(*) as orders_day
, countif(time(oc.order_datetime_local) < time '11:00:00') as thru_11
, countif(time(oc.order_datetime_local) < time '12:00:00') as thru_12
, countif(time(oc.order_datetime_local) < time '13:00:00') as thru_13
, countif(time(oc.order_datetime_local) < time '14:00:00') as thru_14
, max(oc.order_datetime_local) as last_order
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date in ('2025-09-01', '2025-08-25', '2026-08-10', '2026-08-17', '2026-08-24', '2026-08-31', '2026-09-07')
and oc.is_catering = false
and oc.revenue_category = 'Digital'
group by 1, 2
order by 1
```

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

**Identified customer counts (person only):** *(rewritten 2026-09-08 — `mapped_cust_id` and `customer_type` now live on `order_sequence`; on `claude.order_customer` they are still exposed directly and the join is unnecessary)*
```sql
select
date_trunc(oc.business_date, month) as month
, count(distinct os.mapped_cust_id) as customers
, count(*) as orders
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.sales_ops.order_customer oc
	join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
	and os.business_date = oc.business_date
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 365 day)
and os.business_date >= date_sub(current_date('America/Denver'), interval 365 day)
and oc.store_id not in (1111, 999)
and os.customer_type = 'person'
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

#### 🚨 "Did this order contain a salad?" is NOT `line_item_type = 'item'` (observed 2026-08-27)

The taxonomy above is usually read as a *revenue* rule. It is also a **presence** rule, and
that is where campaign-lift analysis quietly breaks. Observed in a live Braze experiment
query on 2026-08-27:

```sql
-- WRONG for a "bought a salad" test
select distinct brink_order_id
from `marketing-data-442316`.sales_ops.order_lines
where business_date between '2026-08-24' and '2026-08-26'
  and line_item_type = 'item'
  and rev_center_name = 'Salads'
```

`line_item_type = 'item'` keeps standalone sales **and** priced combo components, but drops
the **zero-priced combo slot** — the entrée recorded as a `modifier` selection. That third
shape is not a rounding error: for the entrée classes it applies to, the split between priced
components and $0 modifier lines runs roughly **56/44 across all 88 stores and both combo
types** (documented in the taxonomy above; still an open question *why*). So a Try 2 Combo
containing a salad can register as "did not buy a salad", and it does so **only for combo
buyers** — a behavioural segment, not a random sample. In a lift test that is a biased
denominator, not noise.

**For "did the order contain X", ask about presence and ignore `line_item_type`:**

```sql
select distinct ol.brink_order_id
from `marketing-data-442316`.claude.order_lines ol
where 1=1
and ol.business_date between @start and @end
and ol.store_id not in (1111, 999)
and ifnull(ol.item_type, '') not in ('Discount', 'Promotion')
and ifnull(ol.rev_center_name, '') not in ('Discount', 'Promotion')
and ifnull(ol.line_item_type, '') not in ('discount', 'promotion')
and 'Salads' in (ifnull(ol.rev_center_name, ''), ifnull(ol.parent_rev_center_name, ''))
```

Testing `rev_center_name` **or** `parent_rev_center_name` catches all three shapes, because
the combo slot carries its category on the parent. Keep the discount/promotion exclusion —
promotion lines pass the standalone-sale test and named promotions collide with item names.

**Generalisable rule: a revenue filter and a presence filter are different questions.** Same
family as the filter-vs-breakout rule in `ask-a-data-question` — reusing one for the other is
how a control group ends up measured differently from a treated one.

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
- 🚨 **The same channel split applies to paid ADD-ONS, and there it costs you a whole `item_id`** (observed 2026-09-16). A protein or topping add-on is recorded as `line_item_type = 'modifier'` with `item_modifier = 'Add'` on digital orders, and as `line_item_type = 'item'` on in-store POS — **under two different `item_id`s**. Cottage cheese is 643644590 (digital modifier) and 643644591 (POS item); ham is 643538356 / 642369565. So an attach rate written as `item_id = 643644590 and item_modifier = 'Add'` silently measures digital only, and the POS half never appears as a zero — it appears as a smaller, entirely plausible number. Resolve add-ons the way §5 resolves sizes: **discover by name across `item_id`, `line_item_type`, `item_modifier` and `rev_center_name` first**, then filter on the resolved id set — `(item_id = 643644590 and item_modifier = 'Add') or (item_id = 643644591 and line_item_type = 'item')`. `'Extra'` and `'No'` are separate `item_modifier` values on the digital id and are **not** add-on purchases (`'No'` is a removal); count only `'Add'`. Related: `rev_center_name = 'Modifiers'` with `line_item_type = 'item'` is the POS add-on population as a whole.
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

### Identify VTO / limited-time items by first appearance (steward pattern, mined 2026-08-22)

There is no `is_limited_time` / `is_vto` flag on any item table, so a "which items are seasonal
rotations vs core menu?" question has to be answered from **when an item first appears in
`order_lines`**. The steward iterated this shape ~10 times on 2026-08-22 while building a
`sales_ops.vto_items` dimension.

> **✅ `sales_ops.vto_items` is now deployed — this section's earlier "not deployed, use the pattern
> inline" warning is retracted (verified against `INFORMATION_SCHEMA.TABLES`, 2026-08-25).** Prefer
> the table; keep the pattern below for understanding how membership is decided and for re-deriving
> it on a different cutoff.
>
> **The deployed schema is not the pattern's output shape.** It is a plain (unpartitioned,
> unclustered) 5-column dimension:
>
> | Column | Type |
> |---|---|
> | `launch_date` | DATE |
> | `item_id` | INT64 |
> | `item_name` | STRING |
> | `item_grp_name` | STRING |
> | `rev_center_name` | STRING |
>
> `launch_date` is the first-appearance date the pattern computes as `min_date`. The pattern's
> `max_date` and `is_current_vto` **are not in the table** — a "is this VTO currently running?" test
> has to be derived at query time (`launch_date > current_date('America/Denver') - 91`, or a
> `max(business_date)` back on `order_lines`), not selected. Join on `item_id`; it is the grain.
> **The missing end date is now a measured cost (2026-09-09):** two analysts re-derived launch
> *and* end windows from `order_lines` on the same day (≥60%-of-active-stores "chainwide" test,
> 2 × 20 GiB over 2019→today; 180-day `min(business_date)` list) because the scorecard needs both
> edges of the campaign window and neither knew this table existed. Adding `end_date` here retires
> that scan (Asana 1218319740414409).
>
> Observed in use 2026-08-24 (analyst weekly scorecard): `join sales_ops.vto_items v on v.item_id =
> ol.item_id` to sum `item_gross_sales` for trailing-52-week and past-week VTO revenue. That is the
> intended use. See the join-pruning caution in the tenth-business-day notes below — the same query
> joined `order_lines` to `order_customer` on `brink_order_id` alone, with no `business_date`
> equality, and billed 10.71 GiB.

```sql
with items as (
	select
	ol.business_date
	, ol.item_id
	, ol.item_name
	, count(distinct ol.brink_order_id) as order_cnt
	from `marketing-data-442316`.claude.order_lines ol
	where 1=1
	and ol.business_date >= '2024-11-01'
	and ol.is_catering = false
	and ol.item_type = 'Entree'
	group by 1,2,3
	having count(distinct ol.brink_order_id) > 25
)
, vto_items as (
	select
	i.item_id
	, i.item_name
	, min(i.business_date) as min_date
	, max(i.business_date) as max_date
	, case when min(i.business_date) > current_date('America/Denver') - 91 then 1 else 0 end as is_current_vto
	from items i
	group by 1,2
	having min(i.business_date) > '2025-01-15'
)
select * from vto_items order by min_date desc
```

Four things in it are deliberate and worth reusing:

1. **First appearance is the discriminator.** `having min(business_date) > <cutoff>` where the
   cutoff sits comfortably after the history floor: an item whose first-ever line is *after* the
   window opened is a new or rotating item, whereas a core-menu item appears on day one. The
   cutoff must be later than the scan start (`2024-11-01` scan, `2025-01-15` cutoff) or every item
   qualifies.
2. **Group by `business_date` first, then roll up.** The inner CTE keeps the partition column in the
   `group by` so pruning still applies, and the outer CTE collapses to `min`/`max`. It looks
   redundant and isn't — flattening it into one `group by item_id` costs the same read but loses
   the per-day counts that make step 3 work.
3. **`having count(distinct brink_order_id) > 25` is a per-day noise floor**, not a popularity
   filter. It removes test SKUs, one-off POS mistakes and single-store experiments that would
   otherwise each present as a "new item" with a first-appearance date.
4. **Key on `item_id`, carry `item_name`.** Names get re-used and re-cased across rotations; the id
   is what makes "first seen" meaningful.

Scope notes: `item_type = 'Entree'` reflects that VTOs are entrees — widen it deliberately, and
remember `item_type` is the closed 7-value domain (menu categories live in `rev_center_name`).
`is_catering = false` keeps catering-only SKUs out. And `select *` on `order_lines` for this is
expensive — the steward's own `select *` variant billed **27.12 GiB** against **3.43 GiB** for the
column-projected equivalent over the same window.

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
, countif(os.customer_type = 'person') as person_orders  -- 2026-09-08: customer_type moved to order_sequence
, round(100 * countif(oc.sm_external_user_id is not null) / count(*), 1) as pct_sm_linked
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
	and os.business_date = oc.business_date
where 1=1
and oc.business_date >= date_sub(current_date('America/Denver'), interval 14 day)
and oc.store_id not in (1111, 999)
group by 1
order by 1
```

Healthy is **~28–33%**. Under 15% on a **completed** day means that date is corrupted — **say so
in the answer and exclude or caveat those dates** rather than reporting the number as-is.

> ### 🔑 Exclude today — SessionM merges once per day at 04:07 MT; yesterday is complete from the 05:02 rebuild
>
> **Today's date will always read ~0–2% `pct_sm_linked` and that is normal.** SessionM ingestion
> is three scheduled steps — S3→GCS transfer 03:45, GCS→`staging.sm_*` loader 03:55,
> `staging`→`sessionM.*` merge **04:07** (all MT; re-sequenced 2026-09-08/09) — followed by
> `claude.loyalty_user` 04:30, the **full-history `order_customer` + `order_sequence` rebuild at
> 05:02**, and `customer_attribute` 05:20. Yesterday therefore has its ~30% loyalty identity from
> ~05:10 MT; the hourly intraday runs (08:02–23:02) reload **today only**.
>
> - **Never apply the 15% rule to the current business date** — guaranteed false positive.
>   Yesterday is fair game after ~05:15 MT.
> - **Never answer a customer-grain question about today.** Customer counts, `mapped_cust_id`,
>   first-time vs repeat, `in_store_scan`, and anything from `order_sequence` /
>   `customer_attribute` are ~98% under-identified for today. Answer through yesterday and say why.
> - **If yesterday reads under 15% after 05:15 MT**, the three SessionM steps have probably fallen
>   out of order (it happened 2026-09-05 → 09-08: merge before loader, `sessionM.*` one day stale,
>   yesterday at 0.0%). Check `LOAD` vs `MERGE` times for `bigquery-loader-sa` on
>   `JOBS_BY_PROJECT` before blaming the order_customer script — full write-up in
>   `data_dictionaries/sales_ops.order_customer.md` § "SessionM loads once per day".
> - **Sales, order counts and channel mix for today are fine** — those come from Brink, which
>   loads intraday every hour.

## Gotchas checklist (scan before answering)

- **🚨 Never scan history for "first order ever" / "new customer" / "second order within N days"** — `customer_order_count`, `days_since_prev_order`, `first_order_date`, `lifetime_order_count` on `claude.order_customer` already carry it, and the mart's own floor is **2023-03-06**, so a `min() group by customer` from 2023 (or 2018, or 2015) returns the same population for ~2 GiB a run. 140 GiB on 2026-09-08 alone. Recipe and table in "Repeat-rate" §2.
- **"Earned" discounts = `discount_type in ('Reward Redemption','In-cart Points Redemption')`** (steward definition 2026-08-18). Both Brink ids belong: **`643571116` is a purpose-built in-store loyalty-redemption id** (the Cafe Zupas Rewards button), and 99.0–99.5% of reward lines on every id/origin resolve to a sessionM member wallet offer. `In-cart Points Redemption` carries the spend directly (`points > 0` on 100% of 33,702 lines). Earned = 103,540 lines / **−$752,606.55** of −$1,485,468.22 all discounts (50.7%), 2026-05-01 → 07-31. **Do not exclude `offer_kind = 'promotional'` rows** — a wallet offer issued rather than points-priced is still a member redemption; excluding them understates earned by −$36,798.41. `offer_kind` is a **breakdown within earned** for points-economics questions only. Full section above.
- **⚠️ Employee meals sit inside earned — 292 lines / −$4,255.83** in the window are `Reward Redemption` **and** `is_employee_meal_discount = true` (the `Team Member Meal` wallet offer). Both flags are canonical and correct; an earned-vs-employee rollup treating them as exclusive double-counts. Subtract the overlap explicitly.
- **🚨 `order_line_discount_detail.root_offer_id` mixes UPPERCASE and lowercase — `upper()` both sides of any offer join.** The sessionM arm of the `coalesce` is uppercase, the Pulse arm is lowercase, and `claude.loyalty_offer_usage` is uppercase. Joining raw matches **0 of 12,040** `Offer` lines (measured 2026-08-18) and fails silently in the direction that makes wallet offers look unresolvable. Build fix pending: `upper()` on `pd.sessionM_root_offer_id`.
- **⚠️ Wallet-offer attribution is not stable across reload widths.** Online reward `root_offer_id` coverage read 314/26,675 lines early on 2026-08-18 and 26,452/26,675 after the table was rebuilt at 17:15 MT that afternoon — same query, same window. Likely the `offer_detail` CTE's `create_date >= start_date - 60` filter, but **untested — don't repeat it as fact**. Practical rule: a coverage figure is only true as of a stated timestamp, and a low one means "check what last touched the partition" before it means "the data is missing."

- **🔴 Steward-only, and expensive: the `brink` child tables have no partitioning or clustering at all** (verified from DDL 2026-08-17). `brinkOrder` is `PARTITION BY BusinessDate`, but **`brinkOrderItem`, `brinkOrderSurcharge` and `brinkOrderDiscount` are plain unpartitioned tables keyed only on `orderId`**. Consequences, all measured 2026-08-15:
  - Looking up **one order** — `select boi.* from brink.brinkOrderItem where boi.orderId = 31418142951520` — billed **29.75 GiB**. There is no cheap single-order lookup in these tables.
  - **Filtering the parent does not prune the child.** `join brink.brinkOrder bo on bo.id = s.orderid and bo.BusinessDate > current_date - 90` still billed **30.2 GiB**, versus 29.77 GiB with no date filter at all — the predicate prunes `brinkOrder` and leaves the child full-scanned, because BigQuery cannot push a partition filter across a join. Widening 90 → 900 days cost 34.15 GiB, i.e. the date range was never the driver.
  - Four validation attempts on one afternoon billed **~124 GiB**. If you need line-level Brink truth, do it **once** into `scratch` and query that, and prefer `select` of named columns over `select *`.
  - For everyone who is not the steward this is moot — line-level questions run on `sales_ops.order_lines` / `claude.order_lines`, which *are* partitioned on `business_date`. This entry exists so the cost is a known quantity before the scan, not after.
- **Business questions run on the `claude` views for everyone except the steward — even for accounts whose IAM can read `sales_ops`.** A successful select from `sales_ops` is permission, not a routing signal (rule changed 2026-08-04). `Access Denied` on `sales_ops` is intended, not a broken setup. See the dataset-routing section near the top.
- **`claude` history starts 2023-01-01 and truncates silently.** The order views filter `business_date >= date_trunc(date_sub(current_date, interval 3 year), year)`. An older range returns **zero rows, not an error** — which reads as "no sales." Check the window before reporting an empty result.
- **~~`revenue_category` means something different in `claude` than in `sales_ops`~~ — resolved 2026-08-17.** The `claude` view still forces `'Catering'` whenever `is_catering = true`, but the base build now does the same, so the two layers agree. Channel breakdowns produced **before** 2026-08-17 can still legitimately disagree across datasets (48 June 2026 orders) — state which you queried rather than reconciling them.
- **In `claude.order_customer`, `0` in a folded count column means "no upstream row," not zero orders.** `customer_order_count = 0` ⟺ unidentified (46.4% of June 2026 orders); `lifetime_order_count = 0` is broader at 51.5% — it also catches all kiosk, most internal, and most store-1111 orders, so 36,261 orders have a real sequence number but zero lifetime. Never `avg()` a lifetime column unfiltered; never present `lifetime_order_count = 0` as a cohort. The FLOAT/DATE lifetime columns are *not* coalesced and stay NULL, so the same absent customer reads `0` in one column and `NULL` in the next. Details in `data_dictionaries/claude.order_customer.md`.
- **There is no `claude.order_sequence` or `claude.customer_attribute`** — both are folded into `claude.order_customer`. Don't tell a user the data is unavailable; it's on the order view.
- **Demographics (`gender`, `birthday`, `age`) are on `claude.order_customer` since 2026-09-17 23:40 MT** (steward call; they had been `sales_ops`-only since 2026-09-15 because the view folds the attribute table in through a select list). Three rules when answering with them: (1) `gender` is lowercase two-valued (`female` / `male`, no `other` sentinel) and NULL for ~16% of customers, so quote shares on the **populated base**; (2) **`birthday` year `1950` is the app's placeholder for "year not provided"**: 54% of birthdays carry it, month and day are real, the year is not, so birthday-month work uses the whole column but anything needing the year excludes `extract(year from birthday) = 1950`; (3) **`age` is NULL on exactly those placeholder rows** and populated on the 127,906 real-year birthdays (9.6% of customers, 28% of identified person orders in a recent week), so **never compute an age from `birthday`**, read the column, and say the denominator when presenting an age split. All three are NULL on unidentified and non-person orders, like every other folded attribute.
- **A partition filter must be a constant, not a subquery — `business_date in (select business_date from d)` scans the whole table** (measured 2026-09-09: 19.1 GiB for ten business dates across `order_customer`, `order_lines` and `order_line_discount_detail`). BigQuery treats `in (select …)` as a semi-join it cannot prune on, even when the subquery is a literal `unnest([...])` CTE. Write the dates inline — `business_date in unnest([date '2026-08-07', date '2026-08-14', …])` — or bound with `between` and filter the specific days afterwards. The same rule is why `having date(min(odt)) between …` (Day 1 above) scans everything: the predicate is only knowable after the read.
- **`LIMIT` is not a cost control — a `select * … limit 10` peek at `order_customer` billed 5.29 GiB** (measured 2026-09-10, steward console; the same statement without the limit billed 14.57 GiB). BigQuery bills the columns read across the partitions scanned and applies `LIMIT` afterwards, so "just look at ten rows" costs GiB on any wide partitioned mart. To see the **shape** of a table use `INFORMATION_SCHEMA.COLUMNS` (free); to see **rows**, bound the partition first — `where business_date = current_date('America/Denver')` — and only then `limit`. Same family as the subquery-predicate entry above: predicates and clauses that look like they bound the scan and do not.
- **🚨 `customer_hash.brink_order_customer_hash` is unpartitioned and unclustered** (DDL, 2026-09-10), so a `where BusinessDate >= …` on it prunes **nothing** — every read is a full table scan, whatever the predicate says. Analysts have been paying ~4.5 GiB per evaluation for a `hk` CTE that gets re-evaluated per query (51 reads / 157 GiB on 2026-09-09 alone). Until the 06:55 rebuild is partitioned, materialise the hash→order map to `scratch` **once** per session. Note this table is also the basis of an unratified second person-definition — see the identity note in the review log.
- **Two things already in the KB that keep getting re-derived (2026-09-09):** store open date is `store_info.store_open_date` — never `min(business_date) group by store_id` off the fact table; holiday exclusions are `claude.date_dim.holiday` — never a hand-typed `('07-03','07-04','07-05','12-24', …)` list, which drifts between two analysts' queries on the same day and silently omits Thanksgiving in one of them.
- **The partition column is `business_date` on every table** as of 2026-07-30. `order_lines` was rebuilt across full history that day and its `BusinessDate` column is **gone** — the long-standing two-spellings trap is closed. ⚠️ **Any saved query, template or workbook still writing `ol.BusinessDate` now fails outright** with `Unrecognized name: BusinessDate`. That is the good failure mode (loud, not silent), but it will hit the shared analyst workbook — read the error literally and swap in `business_date`.
- **`order_lines` has no `order_id`** — this now leads the gotcha list because it is the single most-repeated error in the query log: `Name order_id not found inside ol`, hit three more times on 2026-07-27/28 and **again on 2026-07-28 at 09:12** by the same analyst. The order key is `brink_order_id` on every one of these tables. The 2026-07-28 instance selected `ol.order_id` in a CTE and then joined `oc.brink_order_id = ol.order_id` — i.e. the correct column name was already in the query, on the other side of the join. Read your own join predicate before selecting.
- **Customer metrics need `customer_type = 'person'`**; sales metrics must NOT filter it. See the rule above.
- **`order_customer` emails are now lowercased at build** (fix deployed 2026-07-29 with the full-history rebuild; verified 2026-08-13: 0 non-lowercase `mapped_email` / `email` values in 365 days). `lower()` on them is a harmless no-op — keep it defensively, but the old "~17,900 overstated distinct emails" caveat no longer applies to current data. The SessionM fallback email also strips the leading `cater_` prefix, so catering logins resolve to the individual's address in `mapped_email` — when comparing to `claude.loyalty_user`, compare against its `email` column — which since the 2026-09-01 rename IS the stripped address (formerly `email_normalized`); the prefixed original is now `full_email`. Raw `pulse.*` / `braze.*` emails outside the marts still need `lower()`.
- **`oc.email` is the ORDER email; `pulse.customers.email` is canonical** (steward 2026-08-24).
  Per-order, user-supplied, fine for "which address got this receipt" and for reading the
  aggregator brand (`email like '%doordash%'` → 75,010 July orders; `mapped_email like
  '%doordash%'` → **none**, because the canonical there is `checkmate_user@cafezupas.com`).
  Never an identity, join, dedup or cohort key. `mapped_email` inherits the canonical when one
  exists (86.0% of July `person` orders) and is user-typed on the rest.
- **`pulse.customers.primary_email` is not canonical** (steward ruling 2026-08-24) even though it
  is populated on *more* rows than `email` (1,962,081 vs 1,817,870) and fills 173,717 gaps. `email`
  is the field of record; do not substitute.
- **`order_customer` gained two columns, synced 2026-08-13**: `destination_id` (INT64, raw Brink destination id alongside `destination`) and `has_order_items` (BOOL, added 2026-08-04 — FALSE means no qualifying item rows survived the build's item filters, so `item_gross_sales` and friends are NULL on ~2.4% of rows; an audit flag, not a reporting filter). `phone` is now STRING. Both new columns flow through to `claude.order_customer`.
- **`claude.order_customer` excludes stores 1111 AND 999 at the view level** (deployed filter `and oc.store_id not in (1111, 999)` — **corrected 2026-08-17**; the 2026-08-13 entry and the repo script both said `<> 1111`, while the deployed view had always excluded both). Standard users cannot see either unnamed store; `sales_ops` tables still contain them, so the exclusion remains load-bearing there. Writing `store_id not in (1111, 999)` against the `claude` view stays correct — just expect `claude`-vs-`sales_ops` totals to differ by those stores even when neither query filters them.
- **Per-customer questions should use `sales_ops.customer_attribute`, not a hand-rolled `group by mapped_cust_id`** (new 2026-07-29). Lifetime orders, spend, AOV, recency, tenure, store affinity and trailing 30/90/365-day activity are all precomputed there — that's the whole point, so two sessions can't produce two different LTV numbers. It is already person-only (adding `customer_type = 'person'` errors), it has **no partition column**, and you must check `attribute_asof_date = yesterday` before trusting the window columns. See its section above.
- **`order_lines.item_net_sales` is usable, with a named limit** (steward ruling 2026-07-30, superseding the earlier "not computable" wording). The column is live on **both** `sales_ops.order_lines` and `claude.order_lines`, fully populated, **zero nulls**. Report it when asked; do **not** treat it as reconcilable to order-level net. Measured on Ultimate Grilled Cheese, 2026-05-03 → 2026-06-27, non-catering, stores 1111/999 excluded:

  | Sale shape | Units | Gross | Net | Gross→net |
  |---|---|---|---|---|
  | Sold alone | 24,125 | $215,890 | $210,928 | **2.30%** |
  | In combo, paid | 47,461 | $315,280 | $304,716 | **3.35%** |
  | In combo, free slot | 37,623 | $386 | $371 | **3.83%** |

  The spread is **not constant across sale shapes**, so it is not a flat rate and the difference between gross and net cannot be described as "the discount" without evidence. Order-level discounts and promotions are still *not* allocated per item, so **`order_customer.net_sales` remains the only net figure to quote or tie out** — say that whenever you hand over `item_net_sales`. Still open: what the 2.3–3.8% actually represents, and why it is wider on combo components than on standalone lines (Asana: `KB finding: item_net_sales gross-to-net spread varies by sale shape`).
- **Net sales is the `net_sales` column** — read it directly (calculated at build since 2026-07-24; promotions term added 2026-08-21). `brink_net_sales` is the Brink-given value kept as the **steward's own cross-check — not an accuracy reference, not for reporting, and not something to measure `net_sales` against** (ruling 2026-08-21; an earlier version of this bullet quoted a 0.0025% variance against it, which was never a meaningful comparison). There is no per-item or per-modifier net in the mart any more.
- **`is_catering = false` does not exclude catering-only items** (verified 2026-07-28). `Ultimate Grilled Cheese Box` — the catering box SKU — is flagged `is_catering = false` on `order_lines`. The flag describes the *order's* catering destination, not the *item's* nature, so catering-specific SKUs leak into non-catering item mix. Check the resolved item-name list for `Box` / `Tray` / `Party` variants explicitly.
- **🚨 `order_customer` and `order_lines` disagree on catering again, since 2026-08-17.** Finance's
  definition added **store 50 (Middleton Mobile)** to `order_customer.is_catering` and to
  `revenue_category`; `order_lines` still computes its own flag from raw Brink without it. Measured
  2026-08-17 over the trailing 30 closed days: **793 orders disagree, all store 50**, `order_customer`
  true / `order_lines` false. **Catering questions go to `order_customer` until the marts are merged.**
  Any catering item mix, unit count or item-level figure from `order_lines` — including the report
  builder artifact — shows store 50 as zero catering. `order_line_discount_detail` straddles both
  (its `is_catering` comes from `order_lines`, its `revenue_category` from `order_customer`), so a
  store-50 row there can read `revenue_category = 'Catering'` with `is_catering = false`; store 50 has
  no discount lines yet, so it hasn't surfaced.

  **Third instance of one defect class**: 2026-07-24, 2026-07-31, 2026-08-17. Cause is always that
  `is_catering` is derived twice, independently, from raw Brink. The fix in flight is to chain the
  order-mart scripts into one scheduled query and have `order_lines` read header attributes from
  `order_customer` (steward taking it 2026-08-17).
- **~~`is_catering` is a superset of `revenue_category = 'Catering'`~~ — not since 2026-08-17.** The
  base build now stamps `'Catering'` on pulse-flagged and store-50 orders too, so in `sales_ops` the
  two select **identical** sets, as they already did in `claude`. Historic note: before 2026-07-24 the
  flag missed all POS-only catering (641 orders / $70.7K net in June), so pre-rebuild catering numbers
  understate; `order_lines` only caught up 2026-07-31 (+644 June orders / +$71,586 gross). If you're
  comparing against a catering number produced between 07-24 and 07-31, ask which table it came from
  before calling either one wrong.
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
- Store footprint: **91 stores trading** (last 7 days, 2026-09-15) in UT, AZ, MN, NV, WI, ID, IL, OH, TX, out of 101 `store_info` rows and 77 comp. Store attributes come from `sales_ops.store_info`.
- **Trading week is Monday–Saturday; the reporting week is Monday–Sunday, labelled by its Sunday** (steward rule 2026-09-09, replaces the Saturday-label rule of 2026-07-30). All stores are closed Sunday, so "last week" still means the most recent Mon–Sat of trading and weekly *averages per trading day* divide by 6, not 7 — but the bucket and the label are the Mon–Sun week. Bucket with `date_trunc(d, week(monday))`; never a bare Sun-anchored `date_trunc(..., week)`.
- **"Week ending" means the Sunday, and is `last_day(business_date, week(monday))`** (steward rule 2026-09-09). This is identical to `claude.date_dim.week_ending`, so the business week and the fiscal week are now the **same** bucket and there is no longer a week fork. The ~4 stray Sunday lines chain-wide land in the week they belong to (the Mon–Sun that contains them), and every `business_date` in a bucket is on or before its `week_ending`. Retired expression: `date_trunc(business_date, week(sunday)) + 6` (the Saturday label) — if you meet it in older SQL or saved analyses, it bucketed identically for Mon–Sat dates and differed only on Sunday rows; relabel, don't re-derive.
- **Snap the range to whole weeks before reporting weekly** (steward rule 2026-07-30). A range whose ends fall mid-week produces a short first and last bucket that reads as a dip nobody caused — the most screenshot-ready wrong conclusion this mart can produce. Either widen to the enclosing Mon→Sun boundaries and state the dates actually used, or label the partial buckets with their day count. Never ship an unflagged part-week next to full weeks. Verified: 2026-05-04 → 2026-06-28 is exactly 8 whole weeks, 6 trading days each.
- **Year-over-year offset is 364 days, not 1 year** — `date_sub(d, interval 364 day)` (52 × 7) keeps the day-of-week aligned, which matters because trading is Mon–Sat and Sundays are zero. `date_sub(d, interval 1 year)` shifts the weekday and drags a Sunday into the comparison window. Convention observed in analyst SQL 2026-07-24.
  - **364 days preserves the weekday but NOT floating holidays** (observed 2026-09-01). The daily flash for Monday **2026-08-31** (an ordinary Monday — Labor Day 2026 is 09-07) compared against `- 364 day` = **2025-09-01, which WAS Labor Day**, so the "LY" column carried a holiday trading pattern and the YoY read as a swing nobody caused. The reverse hits a week later: Labor Day 2026 (09-07) lands on ordinary Monday 2025-09-08. Same for Memorial Day, MLK, Presidents Day, Thanksgiving/C5 and Easter-adjacent days. Before quoting a day-level or week-level YoY, join both sides to `claude.date_dim` and check `holiday` — if either side carries a label, say so in the answer and offer the holiday-to-holiday comparison as the second number. The `date-dimensions` skill's `week_beginning_ly` / `week_ending_ly` columns have the same property: they are the 364-day offset, not a holiday-aligned one.
- Timezone: business runs on `America/Denver` for schedule logic; each store's local time is in `order_datetime_local` (DATETIME — **renamed from `order_datetime` base-table-wide 2026-08-20/21**, the old name no longer exists on `sales_ops.order_customer`, `sales_ops.order_lines`, or either `claude` view), UTC in `order_customer.order_timestamp_utc`.
- There is **no `order_id` column** on any of these tables — the order key is `brink_order_id` (multiple users have hit this error).
- ### ⚰️ `sales_ops.OrderCustomer` was DROPPED 2026-08-21 09:52 MT. If a query names it, the answer is the migration table below — not a workaround.

  The legacy table (schema: `netsales`, `iscatering`, `storeid`, `lifetime_order_cnt`, `first_order_datetime`, `order_count`, `mapped_domain`, `order_trans_or_cust_id`, `state`, `source`, …) is gone. `sales_ops.order_customer` (lowercase) is the only order table. Any query against the old name now fails with `Not found: Table ... OrderCustomer` — which is the point: five documented days of "do not use it" changed nothing, and the drop retired it in one.

  **Translate, don't re-point-and-hope.** Verified against deployed `INFORMATION_SCHEMA.COLUMNS` 2026-08-21:

  | Legacy column | Canonical replacement |
  |---|---|
  | `businessdate` / `BusinessDate` | `business_date` |
  | `storeid` | `store_id` |
  | `state` | `store_state` |
  | `iscatering = 0` | `is_catering = false` (INT64 → BOOL) |
  | `order_datetime` | `order_datetime_local` |
  | `mapped_domain` | `mapped_email_domain` |
  | `order_count` | `customer_order_count` (`claude.order_customer` or `order_sequence`) |
  | `lifetime_order_cnt` | `lifetime_order_count` (`claude.order_customer` or `customer_attribute`) |
  | `first_order_datetime` / `last_order_datetime` | `customer_attribute.first_order_datetime` / `.last_order_datetime` |
  | `order_trans_or_cust_id` | **No equivalent — it exists nowhere on the canonical marts.** Use the `in_store_scan` column, which is the same idea the legacy builds computed inline as `case when pulse_order_id is null and mapped_cust_id is not null then 1 else 0 end` |
  | `netsales` | **A decision, not a rename** — see below |
  | `storeid <> 1111` | `store_id not in (1111, 999)` (999 was excluded nowhere in the legacy queries) |

  ⚠️ **`netsales` is the one non-mechanical mapping.** It is the Brink-**given** net sales, whose counterpart is `brink_net_sales` — a validation field the steward rule keeps out of published output. The canonical quotable net is the calculated `net_sales`. The two differ, so mapping `netsales → net_sales` **moves every historical number** on any report that used to read the legacy column (the YoY sales dashboard among them). State which one you used.

  💡 **What the drop cost, and the process lesson.** Zero views depended on it (checked `view_definition` across all 14 datasets that have views) — the 2026-07-30 "renaming a base table drops its view" failure did not repeat. But **15 daily scheduled builds read it in live SQL** and were found only after the drop: 8 `shared_datasets` QuickSight sources including `google_offline_conversions` (which uploads to Google Ads), `sales_ops.cs_comp_points` / `cust_info` / `rfm` / `store_info`, and three `braze.*` customer-attribute builds. The dependency sweep is cheap — one `regexp_contains` over `JOBS_BY_PROJECT` for non-`SELECT` statement types, plus `view_definition` per dataset — so **run it before the drop, not after** (Asana 1217722726180551).
  - **It is now also going stale**: on 2026-07-27 its `max(business_date)` was **2026-07-25** while `order_customer` had loaded through 2026-07-27. Answers from it are silently 1–2 days short of current. Three separate users queried it during 2026-07-24 → 2026-07-26.
  - **🛑 If you are working from a saved query or a shared template, assume it targets this legacy table and rewrite it before running.** Query-log review counted **188 non-steward runs against `OrderCustomer` in the five business days 2026-07-24 → 2026-07-29**, and every one of the 115 raw-`pulse.*` wall breaches in that window came through it. The pattern is a *shared workbook* — byte-identical query text ran under two different users' accounts hours apart on 2026-07-28, eight of them inside a single minute (batch execution). Legacy schema is the tell: `businessdate`, `storeid`, `iscatering = 0`, `source`, `lifetime_order_cnt`, `first_order_datetime`. Translate to `business_date`, `store_id`, `is_catering = false`, `order_source`, and `order_sequence.lifetime_customer_order_count` — and if the template reached into `pulse.*` for identity, stop and say the mart can't answer it (Asana 1216992461499656).
  - `iscatering` on the legacy table is **INT64** (`iscatering = 0`); `is_catering` on the canonical mart is **BOOL** (`is_catering = false`). Writing `is_catering = 0` fails with `No matching signature for operator = for argument types: BOOL, INT64` (observed 2026-07-24) — a reliable sign a query was written against the legacy schema.
  - **The disagreement is now measured, not asserted** (2026-08-17 review, business date 2026-08-07, stores 1111/999 excluded, one full day): the two tables agree on 29,513 orders, but the legacy table holds **12 orders the canonical mart does not**, and **2 orders are flagged catering on one side and not the other**. Across 2026-08-04 → 2026-08-10 the legacy table runs **1–10 orders/day higher** and its `netsales` sits **$0.50–$22.00/day above** the canonical calculated `net_sales`. The gap is small enough that nobody notices and large enough that two people answering "how many orders yesterday" from the two tables get different numbers — which is exactly the failure this project exists to prevent. Do not report the difference as a rounding artifact; report the canonical mart's number.
  - **`netsales` on the legacy table is the Brink-given net sales**, the column the steward rule keeps out of the `claude` layer entirely (it is retained on `sales_ops.order_customer` as `brink_net_sales`, a validation field only). Quotable net is `order_customer.net_sales` = `gross_sales − total_discount_amount − total_promotions_amount`. A legacy query returning "net sales" is answering a different question than the marts do, on top of querying a different row set.
  - **🧊 IT STOPPED LOADING — and nothing announced it (measured 2026-08-21).** The scheduled build (`SCRIPT` → `DELETE` → `INSERT` → `UPDATE` under `bigquery-loader-sa`) ran daily at ~08:50 MT on 2026-08-16/17/18/19 and then **never fired again** — no error row, no failed job, it simply stopped. `max(BusinessDate)` is **2026-08-18**; `last_modified` is **2026-08-19 08:50 MT**. Meanwhile `sales_ops.order_customer` is current to today. **104 non-steward queries ran against the frozen table after the last load** (2026-08-19: 39 by jelgie@; 2026-08-20: 39 by dgetz@ + 26 by jelgie@), every one of them with a window whose end date was inside the missing days. This is the worst possible failure mode and the reason the retirement can't wait: while it was loading it gave *slightly different* answers, which someone might catch; now it gives *confidently incomplete* ones, and the shortfall grows one day per day. **The schedule is already off, so renaming it costs nothing** — rename to `zz_retired_OrderCustomer_20260819` so the shared workbook errors instead of answering (Asana 1217553975515537; standing lesson: guidance never retires a deprecated table that still returns plausible numbers — a rename does).
  - **⚠️ Its `order_datetime` is a TIMESTAMP holding store-local wall-clock time, so a Braze comparison type-checks with no cast at all.** Measured on BusinessDate 2026-08-15, 26,412 orders, store 1111 excluded: `order_datetime = order_timestamp_utc` on **0** of them, `timestamp_diff(order_timestamp_utc, order_datetime, hour)` spans **4 to 7 hours** — the same four live UTC offsets as the canonical mart. This makes the legacy table the **only** place the timezone error is completely silent. The `braze-campaigns` rule ("never wrap `order_datetime` in `timestamp()`") is a *cast* rule, and on this table there is nothing to wrap: `braze_ts >= oc.order_datetime` compiles clean, TIMESTAMP against TIMESTAMP, and is wrong by 4–7 hours. The legacy table carries a correct `order_timestamp_utc` alongside it, unused in every query observed. **The tell has to be the table name, not the cast.** As of the 2026-08-20/21 rename the bare cast now *errors* on all four canonical objects — which leaves `OrderCustomer` as the last surviving host for the bug.
  - **Still live, still in use — 2026-08-14** (fifth business day of recurrence in this log): two analysts hit it the same morning. One ran a 90-day cohort CTE off `OrderCustomer` and joined it to `sales_ops.order_lines` **with no partition filter on `order_lines` at all** (12.76 GiB billed for a top-15 sandwich list); the other used it for a mart-freshness check and a store-opening loyalty benchmark. The freshness check is the tell that people believe it is the live table. It is live — that is the problem, not the excuse.
- **Cohort columns live on the `claude` view, not on the `sales_ops` base table.** `customer_order_count` and `days_since_prev_order` exist on **`claude.order_customer` only**; selecting either from `sales_ops.order_customer` fails with `Name customer_order_count not found inside oc` (hit by the steward's own session 2026-08-14, verified against `INFORMATION_SCHEMA.COLUMNS` 2026-08-17). `customer_type`, `is_guest_order` and `store_state` are on both. Standard users should be on `claude.*` anyway; the trap is for anyone translating a `sales_ops`-flavoured query and assuming the base table is a superset of the view. It is not — the view adds the folded order-sequence columns.
- **`sales_ops.store_info` column names are not the obvious ones** — it's `store_state`, not `state`; `store_city`, `store_zip`, `store_address`, `store_short_name`. Full column list (16, verified 2026-09-15): `store_id`, `store_name`, `store_address`, `store_city`, `store_state`, `store_zip`, `store_phone`, `store_short_name`, `store_tz`, `store_open_date`, `is_comp_store`, `store_comp_date`, `latitude`, `longitude`, `weather_cluster_id`, `timezone_name`. **`store_comp_date` is the point-in-time comp base** and is NOT on `claude.store_info`. Join `store_info.store_id = order_customer.store_id`. Full dictionary: [`data_dictionaries/sales_ops.store_info.md`](../../data_dictionaries/sales_ops.store_info.md). (Guessing `state` failed an analyst session 2026-07-24.)
- **"Market" means `store_state`** (steward decision 2026-07-30). There is **no** `market` / `region` / `dma` / `metro` column anywhere in `sales_ops` — verified against `INFORMATION_SCHEMA.COLUMNS`. When a user asks for anything "by market," join `store_info` and group by `si.store_state`, and **say in the answer that market = state**. Ten values, one of which is **blank** (one store has no `store_state`) — it becomes a nameless row in any breakdown, so exclude or label it. Caveat worth stating: Utah is 36 of 101 rows across 29 cities, so one "Utah" row hides most of the geographic spread. `store_city` is finer but `West Valley` and `West Valley City` are separate values for the same metro. A real metro/DMA rollup is an open KB gap — don't invent one per-session.
- **`sales_ops.order_discount` no longer exists** — verified absent from `INFORMATION_SCHEMA` on 2026-08-15; it was a BASE TABLE on 2026-08-06. It was an undocumented raw Brink passthrough (`order_id`, `discount_id`, `name`, `amount`, `loyalty_reward_id`, `approver_employee_id`, `source`, partitioned on the legacy `businessdate` spelling), and **`sales_ops.order_line_discount_detail` supersedes it**. A saved query against it now fails loudly with a not-found error — the good failure mode. **Don't confuse the names**: the discount mart is `order_line_discount_detail`, and users query `claude.order_line_discount_detail`. One thing the old table carried that the mart does **not** is `approver_employee_id`, the manager-discount audit trail — an open enrichment idea, not a gap anyone has asked for.
- **Employee/test exclusion:** internal accounts are identifiable via `customer_type = 'internal'` (`@cafezupas.com`, `@tkxel.com`, `@tkxel.io`) — 119 ids / 736 orders in June 2026. The new `mapped_email_domain` column closes the old `mapped_domain` mart gap on this table. Unidentified internal orders still can't be flagged.
- The old `cowork_interim` and `nces_staging` scratch datasets were dropped 2026-07-22. Any saved query referencing them must be rebuilt against the marts (materialize intermediates in `scratch` if needed).

- **Payment method / tender questions run on `claude.order_payment_tender`** (view, new
  2026-08-05) — one row per order, join on `brink_order_id`, answer column
  `payment_tender`. Never reach into `pulse.order_payments` / `brink.brinkOrderPayment`
  directly (they hold cancelled/failed/refunded/deleted rows the view filters). Freshest
  loaded day shows `'stripe'` placeholders; amounts are gross tendered, not sales; split
  tenders are comma-joined. Full gotchas: `data_dictionaries/claude.order_payment_tender.md`.

- **Discount / loyalty-giveaway questions run on `claude.order_line_discount_detail`** (new 2026-08-15).
  **One row per discount COMPONENT, not per line and not per order** — a single Brink line can
  split into several rows. `discount_amount` is the **only** summable money column (it
  reconciles to `order_lines` exactly); `count(*)` counts components; joining to
  `order_customer` requires aggregating this table to order grain first or the split
  multiplies the sales side. `discount_origin` is **not** a channel — `revenue_category` is.
  `discount_type` is an open domain with no `'Other'` bucket. **Employee / team-member meal
  questions use `is_employee_meal_discount` (new 2026-08-17), never a `discount_type` filter or
  a name pattern** — the benefit has run under four Brink programs since 2018; it replaces
  `order_customer.is_employee_discount`, **dropped from that table 2026-08-17**. **`Error` is a health signal:
  0–1 lines on a closed day, but ~76% of *today's* integrated lines until the 4am pass — never
  report today's discount mix intraday.** Full gotchas:
  `data_dictionaries/claude.order_line_discount_detail.md`.

- **In an incremental build, never window a dimension by the fact window** (rule 2026-08-15).
  `user_offers.create_date` is *issuance*, `pulse.order_discounts.created_at` is order
  *placement*, `business_date` is *fulfillment* — different clocks. Reusing `start_date` on a
  lookup CTE made `offer_name` non-deterministic by day of week (275 rows over 8 days) and
  silently dropped catering booked further out than the window. Filter lookups by the order
  keys in the window, or widen the reload and add an alarm. Wrap `delete`+`insert` in an
  explicit transaction; BigQuery scripts are not atomic. Pin `current_date('America/Denver')`
  — bare `current_date` is UTC and evening intraday runs land on the next UTC day. Full
  writeup in the section above.

- **Weather questions: the source is `marketing_ops.weather_triggers`. The four `brink.*`
  weather tables are dead or stale, and one of them is silently EMPTY** (measured 2026-08-27
  after an analyst hit them on 08-26).

  | Table | Rows | Coverage | Verdict |
  |---|---|---|---|
  | `brink.weather_data` | **0** | — | **Empty. Returns no rows, never an error.** |
  | `brink.WeatherData` | 4,201,493 | 2014-12-08 → **2026-04-25** | 4 months stale |
  | `brink.WeatherData_Staging`, `brink.WeatherDataForSchedulerProjectionsWrtMonday` | — | — | Scheduler internals, not analysis tables |
  | `marketing_ops.weather_triggers` | 45,408 | actuals 2025-05-29 → yesterday; forecasts to tomorrow, 90 store zips | **Use this** |

  Three traps, all fired in one session:

  1. **`brink.weather_data` is empty, so a weather-vs-sales query against it returns a clean,
     plausible, entirely empty result** — the same silent-zero class as
     [a stalled partition satisfying `BETWEEN`](#). The analyst read the blank output as
     "no weather effect," not "no table."
  2. **The two brink tables differ only by letter case in the table name AND in every column
     name** — `weather_data`(`business_date`, `store_id`, `temperature`, `precipmm`, `hour`)
     vs `WeatherData`(`BusinessDate`, `StoreId`, `Temperature`, `PrecipMM`, `Hour`). BigQuery
     table names are case-sensitive, so both resolve. A `union all` across them fails with
     `Unrecognized name: business_date; Did you mean BusinessDate?`, which reads like a typo
     rather than like two different tables.
  3. **Falling back from the empty table to the stale one is worse than either**, because
     `WeatherData` stops at 2026-04-25: a yesterday-vs-last-year comparison returns a
     **populated LY side and an empty CY side**, which presents as a dramatic weather change.

  `marketing_ops.weather_triggers` is keyed on **`store_zip`, not `store_id`** — join via
  `claude.store_info.store_zip`. It also carries a `record_type` of `'actual'` or
  `'forecast'`; filter it, or a "yesterday" query can pick up a forecast row.
  `sales_ops.store_info.weather_cluster` and `marketing_ops.zip_weather_cluster` group zips
  into weather regions. There is **no `claude` weather view yet** — flag it as a mart gap
  rather than routing a user to `marketing_ops` or `brink` (Asana 1217062464974534).

- **The `claude` views floor at 2023-01-01, so pre-2023 questions have no standard-user
  answer** (observed 2026-08-26: an analyst ran a 2019-01-07 → 2023-06-25 weekly net-sales
  series against `sales_ops.order_customer` directly, because that is the only place it
  exists). The floor is a rolling 3 years, so it moves every January. Multi-year trend,
  COVID-baseline and pre-opening questions all cross it. **The correct response is to say the
  range is outside the curated window and log it as a mart gap — not to fall through to
  `sales_ops`.** See Asana 1217932458641436.

## When done

If you learned something new about these tables during the session (new gotcha, new canonical definition, data quality issue), do **not** edit this skill or any local copy — only the data steward commits to the repo, and session copies are discarded. Instead, create an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`) titled `KB finding: <short title>`, describing what you observed (include the query that surfaced it) and the proposed change. The steward reviews and merges vetted findings; the next session's fresh clone benefits automatically.
