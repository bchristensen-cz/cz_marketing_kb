---
name: sales-ops-orders
description: How to query Cafe Zupas order data in BigQuery — sales_ops.order_customer (order-level sales, channels, customers) and sales_ops.order_lines (items, modifiers, combos). Use for ANY question about sales, orders, customers, loyalty, menu mix, items, channels, or store performance. Contains canonical definitions, join patterns, and gotchas so every session returns the same answer.
---

# Querying Cafe Zupas Order Data

Project: `marketing-data-442316`. The two approved tables for order/sales analysis:

- **`sales_ops.order_customer`** — one row per order. Sales, channel, customer identity. Default table for sales/order/customer questions.
- **`sales_ops.order_lines`** — one row per line element. Menu mix, items, modifiers, combos.

Full column docs: `data_dictionaries/sales_ops.order_customer.md` and `data_dictionaries/sales_ops.order_lines.md`. Read them before writing non-trivial queries.

## Hard rules (consistency guarantees)

1. **Never query upstream/raw datasets** (`brink.*`, `pulse.*`, `sessionM.*`) to answer business questions. They contain voided rows, duplicates, and unfiltered records that these marts already handle. If the marts can't answer the question, say so — don't improvise from raw tables.
2. **Always filter `BusinessDate`** on both tables (partition column). Never run unbounded scans.
3. **Same metric, same definition.** Use the canonical definitions below verbatim.
4. Data is fresh as of the top of the current hour (loads run at minute :02, intraday 8am–11pm MT reload today's date only). Yesterday and older is stable after the 4am run.

## Canonical metric definitions

| Metric | Definition |
|---|---|
| Net sales | `sum(net_sales)` from `order_customer` |
| Gross sales | `sum(gross_sales)` from `order_customer` |
| Order count | `count(*)` from `order_customer` (or `count(distinct brink_order_id)`, identical) |
| Average check | `sum(net_sales) / count(*)` |
| Identified customers | `count(distinct mapped_cust_id)` where `mapped_cust_id is not null` |
| Guest orders | `is_guest_order = 1` |
| Channel | `revenue_category` (In-Store, Digital, Third_Party, Catering, Fundraiser) |
| Digital source | `order_source` (NULL = in-store POS) |
| Items sold | `order_lines` where `line_item_type = 'item'`, measure `sum(qty)` or `count(*)` |
| Item sales | `sum(item_gross_sales)` / `sum(item_net_sales)` from `order_lines` |
| Menu mix name | `item_name` (size-normalized) + `item_size`; category via `item_type` or `rev_center_name` |

Defaults unless the user says otherwise: include catering, include employee-discount orders, all channels, all stores. State these assumptions in the answer when they matter.

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
select BusinessDate, revenue_category, round(sum(net_sales), 2) net_sales, count(*) orders
from `marketing-data-442316`.sales_ops.order_customer
where BusinessDate >= date_sub(current_date('America/Denver'), interval 30 day)
group by 1, 2
order by 1, 2
```

**Top items by quantity (entrées, last 90 days):**
```sql
select item_name, item_size, sum(qty) qty, round(sum(item_net_sales), 0) net_sales
from `marketing-data-442316`.sales_ops.order_lines
where BusinessDate >= date_sub(current_date('America/Denver'), interval 90 day)
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
  and parent_rev_center_name = 'Try 2 Combo'
group by 1
order by 2 desc
```

**Customer frequency (compute windows fresh — don't trust stored `order_count` across reload boundaries):**
```sql
select mapped_cust_id, count(*) orders, min(BusinessDate) first_order, max(BusinessDate) last_order
from `marketing-data-442316`.sales_ops.order_customer
where BusinessDate >= '2025-01-01'
  and mapped_cust_id is not null
group by 1
```

## Gotchas checklist (scan before answering)

- `order_lines.amount` is NOT sales — it mixes tips, fees, and negative discounts. Use `item_gross_sales` / `item_net_sales`.
- Item counts need `line_item_type = 'item'`, else modifiers ~double the count.
- `qty` is derived from price and approximate; fine for mix, not for inventory-grade counts.
- Line-level sums won't exactly reconcile to `order_customer` order-level sales (order-level discounts, rounding). Order-level is the truth for sales.
- `rev_center_name = 'Foutain Beverages'` is misspelled in source — match it as-is.
- `is_guest_order` is loyalty-based (91% of all-time orders are guest); `mapped_cust_id` coverage is ~53% over the last year.
- `order_count` / `days_since_prev_order` are computed within reload windows — recompute for lifetime analyses.
- Store footprint: ~90 stores in UT, AZ, MN, NV, WI, ID, IL, OH, TX. Store attributes come from `sales_ops.store_info`.
- Timezone: business runs on `America/Denver` for schedule logic; each store's local time is in `order_datetime`, UTC in `order_customer.order_timestamp_utc`.
- There is **no `order_id` column** on either table — the order key is `brink_order_id` (multiple users have hit this error).
- A legacy table `sales_ops.OrderCustomer` also exists (different schema: `netsales`, `iscatering`, `storeid`, `lifetime_order_cnt`, …). **Do not use it** — it predates this mart and gives different answers. `sales_ops.order_customer` (lowercase) is the only canonical order table.
- `sales_ops.order_discount` exists (order-level discount lines: `order_id`, `discount_id`, `name`, `amount`, `loyalty_reward_id`, …) but is **not yet documented** — join keys unverified. If a question needs it, treat answers as provisional until its dictionary lands.

## When done

If you learned something new about these tables during the session (new gotcha, new canonical definition, data quality issue), update this skill and the data dictionaries in `cz_marketing_kb` so the next session benefits.
