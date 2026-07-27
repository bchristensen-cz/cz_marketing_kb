# Data Dictionary: `marketing-data-442316.sales_ops.order_sequence`

**One row per identified-customer order.** Customer order sequencing and recency. Split out of `sales_ops.order_customer` on 2026-07-24 so the window functions are computed over **full history on every run** instead of being scoped to the reload window.

Use this table for anything involving *where an order sits in a customer's history*: first-time vs repeat, order frequency, recency gaps, lifetime order counts, cohorts.

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per `brink_order_id`, restricted to orders with an identified **person** customer |
| Row count | ~10.5M rows, earliest `business_date` **2023-03-06** (see Gotchas) |
| Partitioned by | `business_date` (DAY) — **always filter on it** |
| Clustered by | `brink_order_id` |
| Refresh | `create or replace` in full on **every run** of the `order_customer` scheduled query — same schedule, same skipped hours (0–3, 5–7 MT). Cost measured 2026-07-24: ~420 MB scanned, ~97 slot-seconds per run. |
| Source build script | `sql/sales_ops.order_customer.sql` (second statement) |
| Upstream | `sales_ops.order_customer` only |

## Columns

| Column | Type | Description |
|---|---|---|
| `brink_order_id` | INTEGER | Join key to `order_customer` and `order_lines`. |
| `business_date` | DATE | Copied from `order_customer` (partition column). |
| `mapped_cust_id` | INTEGER | Canonical customer key. Never NULL in this table. |
| `customer_order_count` | INTEGER | Sequential order number for this customer, 1 = first order. Ordered by `order_datetime`, tie-broken by `brink_order_id`. **Renamed from `order_count`.** |
| `days_since_prev_order` | INTEGER | Days between this order's `business_date` and the customer's previous order. NULL on the first order. |
| `lifetime_customer_order_count` | INTEGER | Total orders for this customer across all history in the table. Same value repeated on every one of their rows. |

## Scope

Restricted at build to `mapped_cust_id is not null and customer_type = 'person'`. Kiosk terminals, internal accounts, and the orphan third-party aggregator id are excluded — they are not people, and including them produced absurd sequences (aggregator id `19192` had a lifetime count of **2,481,596**).

Consequence: **this table does not cover every order.** Roughly 47% of orders have no identified customer, and a further ~38% of identified orders are non-person. Never compute sales or order totals here — join back to `order_customer` for those, or use it as the source and this table as the enrichment.

## Join pattern

```sql
select
oc.business_date
, count(*) as orders
, countif(os.customer_order_count = 1) as first_time_orders
from `marketing-data-442316`.sales_ops.order_customer oc
	left join `marketing-data-442316`.sales_ops.order_sequence os
	on os.brink_order_id = oc.brink_order_id
	and os.business_date = oc.business_date
where 1=1
and oc.business_date between @start and @end
and os.business_date between @start and @end   -- partition-prune BOTH tables
and oc.store_id <> 1111
group by 1
order by 1
```

Join on **both** `brink_order_id` and `business_date` so the optimizer can prune the sequence table's partitions too.

## Gotchas

- **History starts 2023-03-06**, not 2018-08-07 like `order_customer`. That is the earliest order with an identified customer, so pre-2023 orders have no sequence row at all. A `customer_order_count = 1` therefore means "first order since March 2023", not necessarily first-ever. Don't present it as a true first-order flag for long-horizon cohort work without saying so.
- **A missing row is not an error** — it means the order had no identified person customer. Use `left join` and treat NULL as unidentified; an inner join silently drops ~2/3 of orders.
- **Store 1111 is not excluded here.** The sequence is built across all stores, so a customer with test-store orders has those counted in their sequence. Filter `store_id <> 1111` on `order_customer` for reporting; be aware the sequence numbers themselves may include them.
- Sequence ordering uses `order_datetime` (store-local). For catering and advance orders that closed on a later day, `order_datetime` falls back to `promise_time` — so sequence order can differ slightly from `business_date` order.
- Rebuilt in full every run, so values are stable and consistent across the whole table at any point in time — but they **can change between runs** if a backfill inserts an order into the middle of a customer's history. Don't cache sequence numbers in downstream saved results.
- `lifetime_customer_order_count` counts only orders present in this table (person-identified, 2023-03-06 forward).
- As of 2026-07-24 the live table was still built from the pre-`customer_type` definition (all identified ids, 10,474,378 rows including one duplicate from the `order_customer` pulse fan-out defect). It picks up the `customer_type = 'person'` restriction on the next scheduled run.
