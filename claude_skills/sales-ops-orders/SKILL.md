---
name: sales-ops-orders
description: How to query Cafe Zupas order data in BigQuery — sales_ops.order_customer (order-level sales, channels, customers) and sales_ops.order_lines (items, modifiers, combos). Use for ANY question about sales, orders, customers, loyalty, menu mix, items, channels, or store performance. Contains canonical definitions, join patterns, and gotchas so every session returns the same answer.
---

# Querying Cafe Zupas Order Data

> **Freshness check:** this file must come from a clone of `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**. If you're reading it from an installed skill package, a fork, or any saved copy, stop and re-clone first — it may be stale.

Project: `marketing-data-442316`. The two approved tables for order/sales analysis:

- **`sales_ops.order_customer`** — one row per order. Sales, channel, customer identity. Default table for sales/order/customer questions.
- **`sales_ops.order_lines`** — one row per line element. Menu mix, items, modifiers, combos.

Full column docs: `data_dictionaries/sales_ops.order_customer.md` and `data_dictionaries/sales_ops.order_lines.md`. Read them before writing non-trivial queries.

## Hard rules (consistency guarantees)

1. **Never query upstream/raw datasets** (`brink.*`, `pulse.*`, `sessionM.*`) to answer business questions. They contain voided rows, duplicates, and unfiltered records that these marts already handle. If the marts can't answer the question, say so — don't improvise from raw tables.
2. **Always filter `BusinessDate`** on both tables (partition column). Never run unbounded scans.
3. **Same metric, same definition.** Use the canonical definitions below verbatim.
4. Data is fresh as of the top of the current hour (loads run at minute :02, intraday 8am–11pm MT reload today's date only). Yesterday and older is stable after the 4am run.
5. **Brink is the sole financial source of truth** (steward rule 2026-07-23). Pulse is a helper for digital order/customer metadata only — never compute financials (sales, discounts, tax, tips) from Pulse data.
6. **All datasets are read-only.** If you need to materialize a table (intermediate results, cohorts), create it ONLY in `marketing-data-442316.scratch` — the single writable dataset; tables there auto-expire after 7 days. Materialize with `create table scratch.x as ...`, not views: a view over a heavy query silently re-runs the full scan on every select.

## Canonical metric definitions

| Metric | Definition |
|---|---|
| Net sales | **Calculated**: `sum(gross_sales - total_discount_amount - total_promotions_amount)` from `order_customer`. Do NOT use the `net_sales` column — it's Brink-given and retained for validation only (steward rule 2026-07-23) |
| Gross sales | `sum(gross_sales)` from `order_customer` |
| Order count | `count(*)` from `order_customer` (or `count(distinct brink_order_id)`, identical) |
| Average check | `sum(gross_sales - total_discount_amount - total_promotions_amount) / count(*)` |
| Identified customers | `count(distinct mapped_cust_id)` where `mapped_cust_id is not null` |
| Guest orders | `is_guest_order = 1` |
| Channel | `revenue_category` (In-Store, Digital, Third_Party, Catering, Fundraiser) |
| Digital source | `order_source` (NULL = in-store POS) |
| Items sold | `order_lines` where `line_item_type = 'item'`, measure `sum(qty)` or `count(*)` |
| Item sales | `sum(item_gross_sales)` from `order_lines`. The gross-minus-discount net rule applies at line level too, but discounts/promotions are separate order-level lines (no per-item allocation), so per-item net isn't computable from the mart — use gross for item mix; `item_net_sales` is validation-only (steward rule 2026-07-23) |
| Menu mix name | `item_name` (size-normalized) + `item_size`; category via `item_type` or `rev_center_name` |

**Required clarifications (steward rule 2026-07-23):** if the user hasn't already stated them, ASK before querying — do not assume defaults:

1. **Date range** — which dates the question covers.
2. **Catering** — included or excluded (`revenue_category = 'Catering'`).

Not up for discussion: **store 1111 is ALWAYS excluded** (test/training store — add `store_id <> 1111` on whichever table you're querying; never include it, don't ask). Remaining defaults unless the user says otherwise: include employee-discount orders, all channels. State all assumptions in the answer when they matter.

## Join pattern

```sql
select ...
from `marketing-data-442316`.sales_ops.order_lines l
join `marketing-data-442316`.sales_ops.order_customer c
  on c.brink_order_id = l.brink_order_id
where l.BusinessDate between @start and @end
  and c.BusinessDate between @start and @end   -- partition-prune BOTH tables
```

## Recipes

**Daily net sales by channel (last 30 days):**
```sql
select BusinessDate, revenue_category,
  round(sum(gross_sales - total_discount_amount - total_promotions_amount), 2) net_sales,
  count(*) orders
from `marketing-data-442316`.sales_ops.order_customer
where BusinessDate >= date_sub(current_date('America/Denver'), interval 30 day)
  and store_id <> 1111
group by 1, 2
order by 1, 2
```

**Top items by quantity (entrées, last 90 days):**
```sql
select item_name, item_size, sum(qty) qty, round(sum(item_gross_sales), 0) gross_sales
from `marketing-data-442316`.sales_ops.order_lines
where BusinessDate >= date_sub(current_date('America/Denver'), interval 90 day)
  and store_id <> 1111
  and line_item_type = 'item'
  and item_type = 'Entree'
group by 1, 2
order by 3 desc
limit 25
```

**Try 2 Combo count and composition:**
```sql
select parent_item_grp_name, count(distinct combo_order_line_item_id) combos
from `marketing-data-442316`.sales_ops.order_lines
where BusinessDate >= date_sub(current_date('America/Denver'), interval 30 day)
  and store_id <> 1111
  and parent_rev_center_name = 'Try 2 Combo'
group by 1
order by 2 desc
```

**Customer frequency (compute windows fresh — don't trust stored `order_count` across reload boundaries):**
```sql
select mapped_cust_id, count(*) orders, min(BusinessDate) first_order, max(BusinessDate) last_order
from `marketing-data-442316`.sales_ops.order_customer
where BusinessDate >= '2025-01-01'
  and store_id <> 1111
  and mapped_cust_id is not null
group by 1
```

## Gotchas checklist (scan before answering)

- `order_lines.amount` is NOT sales — it mixes tips, fees, and negative discounts. Use `item_gross_sales`.
- **Net sales is always calculated** (`gross_sales - total_discount_amount - total_promotions_amount`), never read from the `net_sales` / `item_net_sales` columns — those are Brink-given and kept for validation only (steward rule 2026-07-23). The upcoming `claude` dataset views will expose only the calculated net.
- Item counts need `line_item_type = 'item'`, else modifiers ~double the count.
- `qty` is derived from price and approximate; fine for mix, not for inventory-grade counts.
- Line-level sums won't exactly reconcile to `order_customer` order-level sales (order-level discounts, rounding). Order-level calculated net from `order_customer` is the truth for sales. Quantified 2026-07-23: ~1.3% of orders have no `order_lines` rows (all $0-net fully-voided orders — benign), and line-reconstructed net runs ~0.7% high on the rest (modifier gross noise) — never report sales totals from `order_lines`.
- `rev_center_name = 'Foutain Beverages'` is misspelled in source — match it as-is.
- `is_guest_order` is loyalty-based (91% of all-time orders are guest); `mapped_cust_id` coverage is ~53% over the last year.
- `order_count` / `days_since_prev_order` are computed within reload windows — recompute for lifetime analyses.
- **Store 1111 is a test/training store — ALWAYS exclude it** (`store_id <> 1111`) in all sales, order, and item metrics on both tables. No exceptions (steward rule 2026-07-23).
- Store footprint: ~90 stores in UT, AZ, MN, NV, WI, ID, IL, OH, TX. Store attributes come from `sales_ops.store_info`.
- **Business week is Monday–Saturday** — all stores are closed Sunday. "Last week" means the most recent Mon–Sat; weekly averages divide by 6 days, not 7. Don't use Sun-anchored `date_trunc(..., week)` for CZ weeks (observed in analyst SQL 2026-07-22; steward-confirmed pending).
- Timezone: business runs on `America/Denver` for schedule logic; each store's local time is in `order_datetime`, UTC in `order_customer.order_timestamp_utc`.
- There is **no `order_id` column** on either table — the order key is `brink_order_id` (multiple users have hit this error).
- A legacy table `sales_ops.OrderCustomer` also exists (different schema: `netsales`, `iscatering`, `storeid`, `lifetime_order_cnt`, …). **Do not use it** — it predates this mart and gives different answers. `sales_ops.order_customer` (lowercase) is the only canonical order table.
- `sales_ops.order_discount` exists (order-level discount lines: `order_id`, `discount_id`, `name`, `amount`, `loyalty_reward_id`, …) but is **not yet documented** — join keys unverified. If a question needs it, treat answers as provisional until its dictionary lands.
- **Employee/test exclusion (steward business rule):** internal orders are identified by mapped email domain in (`cafezupas.com`, `tkxel.com`). The `mapped_domain` column only exists on the legacy table today, so this filter can't yet be applied on `order_customer` — a mart gap is logged. State whether employee orders are included when it matters.
- **Lifetime customer fields** (`lifetime_order_cnt`, `first_order_datetime`, `days_since_last_order`) exist only on the legacy table; `order_customer.order_count` is reload-window-scoped. For lifetime/first-order questions, compute fresh from `order_customer` history (see customer-frequency recipe) until the lifetime columns land in the mart.
- The old `cowork_interim` and `nces_staging` scratch datasets were dropped 2026-07-22. Any saved query referencing them must be rebuilt against the marts (materialize intermediates in `scratch` if needed).

## When done

If you learned something new about these tables during the session (new gotcha, new canonical definition, data quality issue), do **not** edit this skill or any local copy — only the data steward commits to the repo, and session copies are discarded. Instead, create an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`) titled `KB finding: <short title>`, describing what you observed (include the query that surfaced it) and the proposed change. The steward reviews and merges vetted findings; the next session's fresh clone benefits automatically.
