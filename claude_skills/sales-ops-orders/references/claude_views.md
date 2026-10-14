# The `claude` views vs `sales_ops`

> Part of the `sales-ops-orders` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** you need to know what the `claude.*` views add, filter or change versus `sales_ops`; a `claude` and a `sales_ops` number disagree; you use the folded lifetime/sequence columns on `claude.order_customer`.
> Content moved verbatim from `SKILL.md` on 2026-10-14 (router split); the rules and dates inside are unchanged.

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

   There is also a **`claude.store_info`** view for the attributes that aren't denormalised (city, zip, address, open date, comp status, lat/long, timezone); it carries a `market` column aliasing `store_state`, and drops three non-store rows. See [`data_dictionaries/claude.store_info.md`](../../../data_dictionaries/claude.store_info.md).

   > **⚠️ The market column is NULL for stores 1111 and 999** — `store_info` has no row for either. On **`sales_ops`**, a market breakdown **without `store_id not in (1111, 999)` grows a phantom tenth market**: 1,154 orders and **$117,196** over 2026-05-03 → 2026-06-27, appearing as an unnamed NULL group that reads like a data defect rather than the test store. Keep the filter and `coalesce` the label; never ship an unnamed group.
   >
   > **Correction 2026-08-19 — this box previously said "on both views," which was wrong.** `claude.order_customer` and `claude.order_lines` **already exclude both stores in the view definition** (`store_id not in (1111, 999)`, read from `INFORMATION_SCHEMA.VIEWS.view_definition`), so the phantom market cannot appear on the `claude` layer and the predicate there is redundant, not load-bearing. See the per-view table in [the store-exclusion section](clarifications.md#store-11111999-which-layer-already-excludes-them-measured-2026-08-19) — since 2026-08-20 all four `claude` order views carry the exclusion, so on the `claude` layer **don't write it** (steward rule 2026-09-03); it stays mandatory on every `sales_ops` table.

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

Full column docs: [`data_dictionaries/claude.order_customer.md`](../../../data_dictionaries/claude.order_customer.md).

Everything else in this skill — canonical metric definitions, the `customer_type` rule, the pre-query clarification protocol, store 1111, the combo taxonomy — **applies unchanged to the `claude` views.** They pass those columns through untouched.
