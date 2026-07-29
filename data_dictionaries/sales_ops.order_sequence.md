# Data Dictionary: `marketing-data-442316.sales_ops.order_sequence`

**One row per order that has a `mapped_cust_id`.** Customer order sequencing and recency. Split out of `sales_ops.order_customer` on 2026-07-24 so the window functions are computed over **full history on every run** instead of being scoped to the reload window.

Use this table for anything involving *where an order sits in a customer's history*: first-time vs repeat, order frequency, recency gaps, lifetime order counts, cohorts.

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per `brink_order_id`, for every order with a non-null `mapped_cust_id` (all customer types) |
| Row count | ~10.5M rows, earliest `business_date` **2023-03-06** (see Gotchas) |
| Partitioned by | `business_date` (DAY) — **always filter on it** |
| Clustered by | `brink_order_id`, `mapped_cust_id` |
| Refresh | `create or replace` in full on **every run** of the `order_customer` scheduled query — same schedule, same skipped hours (0–3, 5–7 MT). Cost measured 2026-07-24: ~420 MB scanned, ~97 slot-seconds per run. |
| Source build script | `sql/sales_ops.order_customer.sql` (second statement) |
| Upstream | `sales_ops.order_customer` only |

## Columns

| Column | Type | Description |
|---|---|---|
| `brink_order_id` | INTEGER | Join key to `order_customer` and `order_lines`. |
| `business_date` | DATE | Copied from `order_customer` (partition column). |
| `mapped_cust_id` | INTEGER | Canonical customer key. Never NULL in this table. |
| `customer_type` | STRING | Copied from `order_customer` — `person`, `kiosk`, `internal`, `aggregator`. **Added 2026-07-27** so callers can filter here instead of joining back. Order-level, so it can vary across one customer's rows. |
| `customer_order_count` | INTEGER | Sequential order number for this customer, 1 = first order. Ordered by `order_datetime`, tie-broken by `brink_order_id`. Computed across **all** the customer's orders, not just person ones. **Renamed from `order_count`.** |
| `days_since_prev_order` | INTEGER | Days between this order's `business_date` and the customer's previous order (any type). NULL on the first order. |

### 🛑 `lifetime_customer_order_count` was DROPPED 2026-07-29 — breaking change

The column **no longer exists**. Any query referencing it now fails with
`Unrecognized name: lifetime_customer_order_count`. Live schema is exactly six columns:
`brink_order_id`, `business_date`, `mapped_cust_id`, `customer_type`, `customer_order_count`,
`days_since_prev_order`.

**Replacement: `sales_ops.customer_attribute.lifetime_order_count`** — one row per customer, so
no window-function caveats and no need to filter `customer_type`. Dropped deliberately so there
is one unambiguous source for lifetime orders.

**The two are NOT the same number — don't swap one for the other blindly:**

| | `order_sequence` (dropped) | `customer_attribute.lifetime_order_count` |
|---|---|---|
| Customer types | **All** | **`person` only** |
| Store 1111 | Included | **Excluded** |
| Freshness | Current (rebuilt every run) | **As of yesterday** (`attribute_asof_date`) |
| History floor | 2023-03-06 | 2023-03-06 (same in practice) |
| Mixed-id distortion | Yes — million-scale on person rows | No — computed on person orders only |

Measured agreement 2026-07-29: **1,374,231 of 1,376,394 shared customers match (99.84%)**.
2,163 differ (0.16%), mostly the one-day freshness gap plus store 1111 and mixed-type ids.
**1,434 non-person ids have no lifetime count anywhere now** — if you genuinely need an
aggregator's or kiosk's order count, aggregate `order_customer` directly.

The `customer_attribute` figure is the more correct one. That's the point of the change.

## Scope

**Every order with a `mapped_cust_id`.** The only build filter is `mapped_cust_id is not null` — there is no `customer_type` restriction. `customer_type` is carried as a column so the caller filters.

> ### ⚠️ The build script's comment contradicts the build script's code
>
> As of the 2026-07-29 deployed version, the header comment above `order_sequence` in
> `sql/sales_ops.order_customer.sql` reads *"Restricted to `customer_type = 'person'`: kiosk
> terminals, internal accounts and the third-party aggregator id are not people and would
> poison sequence/lifetime counts."*
>
> **That comment is stale and describes behaviour that was deliberately reverted on
> 2026-07-27.** The SQL beneath it filters only `mapped_cust_id is not null`. **This table is
> NOT person-only.** Verified 2026-07-29:
>
> | `customer_type` | Rows | Ids | Max `customer_order_count` |
> |---|---|---|---|
> | `person` | 7,203,474 | 1,376,995 | **2,495,891** |
> | `aggregator` | 2,517,397 | 10 | 2,494,804 |
> | `kiosk` | 785,655 | 49 | 48,014 |
> | `internal` | 23,690 | 911 | 569,938 |
>
> Note the 2,494,884 on **`person`** rows — that's the mixed-id problem below. Trusting the
> comment means skipping the mandatory `customer_type = 'person'` filter *and* believing the
> lifetime counts are per-person. Both are wrong. Fix the comment (Asana task logged).

Steward decision 2026-07-27, replacing an earlier person-only build: don't bake compensation for upstream bad data into the mart. The previous person filter plus a customer-level guard existed to work around pulse's missing customer record for id `19192`; that belongs in the dev fix, not in the sequencing table.

### The unfiltered scope is intentional — it is a data-source canary (reaffirmed 2026-07-29)

The non-person ids in this table are a **symptom of `pulse.customers` not being maintained
correctly upstream**; the ETL team is still working on it. The steward is deliberately leaving
the table unfiltered so that breakage stays **visible as an ongoing check on source accuracy.**

**Do not "fix" this by adding a `customer_type` filter to the build.** Filtering here would hide
the upstream defect and destroy the signal that tells us when it's resolved. The non-person id
counts shrinking on their own *is* the measurement — expect the ~10 aggregator ids and their
2.5M-row footprint to fall away once the ETL fix lands.

Current canary reading (2026-07-29, `business_date >= 2023-01-01`):

| `customer_type` | Rows | Ids |
|---|---|---|
| `person` | 7,203,474 | 1,376,995 |
| `aggregator` | 2,517,397 | 10 |
| `kiosk` | 785,655 | 49 |
| `internal` | 23,690 | 911 |

This is why the caller-side `customer_type = 'person'` filter is mandatory and permanent, not a
temporary workaround.

> ### ⚠️ Read this before using the lifetime columns
>
> The window functions run over **all** of a customer's orders regardless of type. For non-person ids the numbers are enormous and meaningless — `19192` carries a `lifetime_customer_order_count` around **2.48 million**.
>
> Filtering `customer_type = 'person'` afterwards **selects rows but does not renumber them.** A mixed id (one that has both person and aggregator orders) still shows million-scale `customer_order_count` and `lifetime_customer_order_count` values on its person rows. In June 2026 that affects 30 ids.
>
> So: filter `customer_type = 'person'` for customer metrics — that rule is unchanged and still required — but treat sequence and lifetime values on mixed ids as unreliable. If you need true per-person sequencing for a mixed id, recompute the window over its person orders only.

Consequence: **this table does not cover every order.** Roughly 47% of orders have no identified customer and so have no row here. Never compute sales or order totals from this table — drive from `order_customer` and use this one as the enrichment.

## Join pattern

```sql
select
oc.business_date
, count(*) as orders
, countif(os.customer_type = 'person' and os.customer_order_count = 1) as first_time_orders
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
- **A missing row is not an error** — it means the order had no `mapped_cust_id`. Use `left join` and treat NULL as unidentified; an inner join silently drops ~47% of orders.
- **Store 1111 is not excluded here.** The sequence is built across all stores, so a customer with test-store orders has those counted in their sequence. Filter `store_id <> 1111` on `order_customer` for reporting; be aware the sequence numbers themselves may include them.
- Sequence ordering uses `order_datetime` (store-local). For catering and advance orders that closed on a later day, `order_datetime` falls back to `promise_time` — so sequence order can differ slightly from `business_date` order.
- Rebuilt in full every run, so values are stable and consistent across the whole table at any point in time — but they **can change between runs** if a backfill inserts an order into the middle of a customer's history. Don't cache sequence numbers in downstream saved results.
- **`lifetime_customer_order_count` no longer exists** (dropped 2026-07-29). Use `sales_ops.customer_attribute.lifetime_order_count` — see the breaking-change note above for how the two differ.
- **No pre-filtering as of 2026-07-27.** Earlier versions of this table were restricted to `customer_type = 'person'` plus a customer-level guard. Both were removed deliberately. Any saved query that assumed the table was already person-only now needs an explicit `customer_type = 'person'`.
- The `order_customer` pulse fan-out defect put one duplicate `brink_order_id` in this table. Fixed in the build script 2026-07-27; clears on the next full rebuild.
