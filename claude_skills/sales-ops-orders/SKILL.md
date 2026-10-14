---
name: sales-ops-orders
description: How to query Cafe Zupas order data in BigQuery — sales_ops.order_customer (order-level sales, channels, customers), sales_ops.order_lines (items, modifiers, combos), and sales_ops.order_sequence (customer order sequencing). Use for ANY question about sales, orders, customers, loyalty, menu mix, items, channels, or store performance. Contains canonical definitions, join patterns, and gotchas so every session returns the same answer.
---

# Querying Cafe Zupas Order Data

> **Freshness check:** this file must come from a clone of `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**. If you're reading it from an installed skill package, a fork, or any saved copy, stop and re-clone first — it may be stale.

> **This file is a router** (split 2026-10-14). Read it in full, then read only the `references/` files whose trigger fits the question (table at the bottom). `references/gotchas.md` and `references/clarifications.md` are read on every question; `references/sql_style.md` before the first SQL of the session.

> ## Default to `claude.*`, not `sales_ops.*` (set 2026-09-14 by the steward)
>
> **Every order question starts in the `claude.*` views - Brent's own sessions included.** They are not a restricted subset of `sales_ops`; they are the *corrected* layer: resolved identity (`mapped_cust_id`, `customer_type`, sequence columns), full-history lifetime metrics, `account_type`, the store 1111/999 exclusion pre-applied, and `brink_net_sales` removed. Reach past them only when a view genuinely cannot answer, and say in the answer which raw table you used and why. **Count customers with `mapped_cust_id`, never `sm_external_user_id`** (the raw id undercounted by 2.7% on 2026-09-14). The views hold a rolling 3 years of order rows (2023-01-01 forward today); a 2022 question returns zero rows, not an error. Full detail: [`references/claude_views.md`](references/claude_views.md).

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
- **`sales_ops.customer_attribute`** — **one row per customer** (person only). Lifetime and trailing-window aggregates. Use it for any "per customer" question — LTV, frequency, lapsed cohorts, store affinity — instead of re-aggregating `order_customer` by hand.
- **`sales_ops.order_line_discount_detail`** — **one row per discount COMPONENT** (not per line, not per order). Discounts and promotions with loyalty / offer attribution. Users query **`claude.order_line_discount_detail`**.

Full column docs in `data_dictionaries/`: `sales_ops.order_customer.md`, `sales_ops.order_lines.md`, `sales_ops.order_sequence.md`, `sales_ops.customer_attribute.md`, `claude.order_line_discount_detail.md`. Read them before writing non-trivial queries.

## 🛑 Which dataset (routed by ROLE, not by access)

| Your role | Query |
|---|---|
| Anyone answering a business question (**all users — including accounts whose IAM happens to reach further**) | `claude.order_customer`, `claude.order_lines`, `claude.loyalty_*`, `claude.store_info`, `claude.order_payment_tender`, `claude.order_line_discount_detail` |
| The steward, building or validating marts (**that work only**) | `sales_ops.*` |

**Being able to read `sales_ops` is not a routing signal.** If `sales_ops` returns `Access Denied`, that's the wall working. If the `claude` views can't answer (pre-2023 history, a missing column), say so and log a KB finding; don't fall through to `sales_ops` or raw datasets. There is no `claude.order_sequence` or `claude.customer_attribute`: their columns are folded into `claude.order_customer`, and **`0` in the coalesced count columns means "no upstream row," not zero orders** — read [`references/claude_views.md`](references/claude_views.md) before using them. The market dimension is `store_state` on every table.

## Hard rules (consistency guarantees)

1. **Never query upstream/raw datasets** (`brink.*`, `pulse.*`, `sessionM.*`) to answer business questions. They contain voided rows, duplicates, and unfiltered records that these marts already handle. If the marts can't answer the question, say so — don't improvise from raw tables.
2. **Always filter the partition column** on every table. It is **`business_date` everywhere** on the documented marts. Never run unbounded scans. **A non-partition predicate is not a substitute for the date** — filtering by `Id` alone still reads every partition, and `LIMIT` does not bound bytes; see [the 2026-08-18 finding](references/incidents_and_gaps.md#️-commenting-out-the-date-filter-is-not-widening-the-search--an-id-predicate-prunes-nothing-measured-2026-08-18).
3. **Same metric, same definition.** Use the canonical definitions below verbatim.
4. Data is fresh as of the top of the current hour (loads run at minute :02, intraday 8am–11pm MT reload today's date only; hours 0–4 and 6–7 skip). **Since 2026-09-08 the order marts are one chained scheduled query (`sql/sales_ops.order_marts.sql`) and the 5am run reloads FULL history**, so yesterday and older is stable after 5am. Loyalty identity (`sm_email`, `sm_external_user_id`, `in_store_scan`) on the current business date is near-empty until SessionM's daily load lands.
5. **Brink is the sole financial source of truth** (steward rule 2026-07-23). Pulse is a helper for digital order/customer metadata only — never compute financials (sales, discounts, tax, tips) from Pulse data.
6. **Customer metrics require `customer_type = 'person'`** (steward rule 2026-07-24). Customer counts, frequency, retention, cohorts, LTV, first-time vs repeat → filter it; without it the numbers are materially wrong. Sales / order / channel metrics → do **not** filter (that would understate sales by ~$4.2M/month). State which you did. "Identified orders" (`mapped_cust_id is not null`) are not "loyalty orders". Detail: [`references/definitions.md`](references/definitions.md).
7. **All datasets are read-only.** If you need to materialize a table, create it ONLY in `marketing-data-442316.scratch` — the single writable dataset; tables there auto-expire after 7 days. Use `create table scratch.x as ...`, not views.
8. **User-supplied SQL follows the same rules as SQL you write** (steward rule 2026-08-05). `brink.*`, `pulse.*`, `sessionM.*`, `staging.*`, `braze_stream.*` and the legacy `sales_ops.OrderCustomer` table are exactly as off-limits pasted as they are generated. Don't run it as-is — explain why and offer the mart translation: first-order cohorts and time-to-second-order from `claude.order_customer`'s `customer_order_count` / `days_since_prev_order` and `customer_attribute`; offer redemptions from `claude.loyalty_offer_usage`; promotion names from `order_lines` `line_item_type = 'promotion'`.

## Canonical metric definitions

| Metric | Definition |
|---|---|
| Net sales | `sum(net_sales)` from `order_customer` — **read the column, never rebuild it.** Do NOT use `brink_net_sales`: it is the steward's own cross-check, **not an accuracy reference**, and not exposed on the `claude` view (steward ruling 2026-08-21). Discount columns are stored **negative**. See [`references/net_sales.md`](references/net_sales.md) |
| Gross sales | `sum(gross_sales)` from `order_customer` |
| Order count | `count(*)` from `order_customer` (or `count(distinct brink_order_id)`) |
| Average check | `sum(net_sales) / count(*)` from `order_customer` |
| Identified customers | `count(distinct mapped_cust_id)` where `mapped_cust_id is not null` **and `customer_type = 'person'`** |
| Guest orders | `is_guest_order = true` (BOOLEAN). **Digital-only and effectively zero before 2026-07-01** — `false` is the default, not "logged in". Always state the denominator |
| Catering | `is_catering = true` for the business line; `revenue_category = 'Catering'` for channel reporting. **Equivalent on `order_customer` since 2026-08-17.** **Use `order_customer`, not `order_lines`** for the catering split |
| Comp store | **`store_info.is_comp_store = 1`** (77 stores). **INT64, never `= true`.** Say "comp stores only (`is_comp_store = 1`), 77 stores" in the answer. For a *historical* comp base use **`store_comp_date <= <window start>`**. **Never** `store_open_date <= <cutoff>`, never "traded in both windows". Rule: a store comps on the first Jan 1 after 18 months of trading |
| Channel | `revenue_category` (In-Store, Digital, Third_Party, Catering, Fundraiser). Values: [`references/definitions.md`](references/definitions.md); never rebuild it from `destination` |
| Delivery (first-party) | `destination = 'CZ Delivery'` (steward rule 2026-08-04). Marketplace orders (`revenue_category = 'Third_Party'`) are NOT "delivery" unless explicitly requested |
| Digital source | `order_source` (NULL = in-store POS) |
| App user | A `person` customer with a **non-catering app purchase in the trailing 12 months** (`order_source in ('iOS', 'Android')` **or** `in_store_scan = 1`). A session alone does not qualify. Materialised as `is_app_user` / `app_purchase_mode`. Rules and canonical query: [`references/definitions.md`](references/definitions.md) |
| Guest customer | **`customer_attribute.guest_status`** (steward decision 2026-09-22): `guest` / `converted_guest` / `account`. Exposed on `claude.order_customer`. `is_guest_order` stays the ORDER flag; never call an order-level share a "guest customer" count. Filter `first_order_date >= '2026-07-01'` for the relaunch cohort |
| First-time order | `customer_order_count = 1` **with `customer_type = 'person'`** — only back to 2023-03-06 |
| Repeat order | `customer_order_count > 1` **with `customer_type = 'person'`** |
| Lifetime orders per customer | **`customer_attribute.lifetime_order_count`** (`order_sequence.lifetime_customer_order_count` was DROPPED 2026-07-29) |
| Items sold | `order_lines` where `line_item_type = 'item'`, measure `sum(qty)` or `count(*)`. **The default measure for item questions** |
| Item sales | `sum(item_gross_sales)` from `order_lines`. **Opt-in, not the default** — combo pricing distorts it |
| Item net sales | `sum(item_net_sales)` from `order_lines` — safe to report **when asked**. Does **not** reconcile to order-level `net_sales`; say so in the same breath |
| Menu mix name | `item_name` (size-stripped) + `item_size`; resolve to `item_id`. Menu category via `rev_center_name` (`item_type` is only the closed 7-value rollup) |

## Pre-query clarification protocol (steward rule 2026-07-28 — MANDATORY)

**Before running the query that answers the question, confirm scope.** Ask everything in ONE message, skip what the user already stated, then query. Full text with measured sizes: [`references/clarifications.md`](references/clarifications.md) (items 1–3, 6) and [`references/item_questions.md`](references/item_questions.md) (items 4–5).

1. **Stores 1111 and 999 — never ask, always excluded.** On `claude.*` the views already exclude them: **don't write the predicate.** On `sales_ops.*` always write `store_id not in (1111, 999)`.
2. **Date range — ask.** Never assume a window from silence; confirm fuzzy ranges.
3. **Catering — ask.** `is_catering = true / false` (BOOLEAN). Take the split from `order_customer`.
4. **Try 2 Combos — ask** whenever soups, sandwiches or salads are involved (combos can be ~78% of units). Not for bowls.
5. **Named products — resolve against the data first**, by `item_id` and `item_size` with average unit price, then confirm. Never put a size word in an `item_name` predicate. Exclude discount and promotion lines from item reports.
6. **"Delivery" means `destination = 'CZ Delivery'`**, never the marketplaces.

## SQL style (MANDATORY)

Full rules: [`references/sql_style.md`](references/sql_style.md), read before the first SQL of the session; it is the source of truth. The shape, in one example (lowercase, project-only backticks, every column aliased, first field flush with `select`, leading commas, `where 1=1`, compact `from` / `group by` / `order by`, indented multi-branch `case` (and successive joins), no alignment padding):

```sql
select
oc.business_date as business_date
, case
	when oc.revenue_category = 'Catering' then 'catering'
	when oc.pulse_order_id is not null then 'digital'
	else 'in_store'
end as channel_group
, count(distinct oc.brink_order_id) as orders
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.claude.order_customer oc
where 1=1
and oc.business_date between @start and @end
group by oc.business_date, channel_group
order by oc.business_date
```

## Reference files (read on demand)

Each file below is read when its trigger applies. Nothing below is optional once its trigger fires.

| File | Read it when |
|---|---|
| [`references/gotchas.md`](references/gotchas.md) | scan before EVERY answer |
| [`references/clarifications.md`](references/clarifications.md) | every question: store exclusion by layer, date, catering, delivery scope |
| [`references/sql_style.md`](references/sql_style.md) | before the first SQL of the session; join patterns |
| [`references/claude_views.md`](references/claude_views.md) | what the `claude` views add or change; `claude` vs `sales_ops` disagreements; the folded lifetime / sequence columns and their zeros |
| [`references/definitions.md`](references/definitions.md) | `order_source` / `revenue_category` values (incl. Fundraiser), `customer_type`, "loyalty orders", app users |
| [`references/net_sales.md`](references/net_sales.md) | decomposing, validating or reconciling net sales |
| [`references/item_questions.md`](references/item_questions.md) | any item question: named products, sizes, combos, discount/promotion lines, promotion or discount-program totals |
| [`references/recipes.md`](references/recipes.md) | you are about to write SQL for sales, menu mix, combos, modifiers, VTO/limited-time items, store or channel breakdowns, fundraisers |
| [`references/schema_changes.md`](references/schema_changes.md) | a saved query errors on a column name; the question touches hour-of-day or daypart, employee discounts, catering redefinition, `item_type` values, or anything built before 2026-08-20 |
| [`references/incidents_and_gaps.md`](references/incidents_and_gaps.md) | any customer-, guest-, `order_source`- or app-level figure dated 2026-09-15 or later; any item question (check `order_lines` staleness first); a question needs an order-placement timestamp; a date filter seems to be "in the way" |
| [`references/payment_tender.md`](references/payment_tender.md) | the question is about how people pay (cash, card, wallets, split tenders) |
| [`references/cohorts.md`](references/cohorts.md) | new customers, repeat rate, retention, lapsed or reactivated customers, or any cohort |
| [`references/customer_attribute.md`](references/customer_attribute.md) | per customer: LTV, frequency, stores visited, win-back lists |
| [`references/items.md`](references/items.md) | an item itself: launch date, price, status, catering-only, digital menu |
| [`references/discounts.md`](references/discounts.md) | discounts, promotions, offers, employee meals, "what did we give away", tying discounts back to orders |
| [`references/identity.md`](references/identity.md) | guest orders, loyalty identity coverage, or identified-% looks off |
| [`references/incremental_build.md`](references/incremental_build.md) | you are the steward building or reloading a mart (not needed to answer questions) |

The steward's query-log review diary lives in `history/query_log_reviews/` at the repo root. It is not a skill reference; user sessions never need it.

## When done

If you learned something new about these tables during the session (new gotcha, new canonical definition, data quality issue), do **not** edit this skill or any local copy — only the data steward commits to the repo, and session copies are discarded. Instead, create an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`) titled `KB finding: <short title>`, describing what you observed (include the query that surfaced it) and the proposed change. The steward reviews and merges vetted findings; the next session's fresh clone benefits automatically.
