# Data Dictionary: `marketing-data-442316.sales_ops.customer_attribute`

> ## 🚧 DRAFT — NOT DEPLOYED (2026-07-28)
>
> The build script exists at `sql/sales_ops.customer_attribute.sql`; **no table and no
> scheduled query exist yet.** The SELECT body has been validated against live data (see
> Validation below) but nothing has been written. Do not answer business questions from
> this table until this banner is removed.

**One row per customer** (`mapped_cust_id`), **person only**. Lifetime and trailing-window
aggregates. This is a *dimension* — a customer's current state — not a fact table.

Two consumers:

1. Analyst segmentation in BigQuery (LTV, frequency, lapsed cohorts, store affinity).
2. A daily push of `custom_attributes` to Braze, keyed on `braze_external_id`.

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per `mapped_cust_id` where `customer_type = 'person'` |
| Row count | **1,374,213** (as of 2026-07-28) |
| Partitioned by | none — it's a ~1.4M-row dimension, partitioning buys nothing |
| Clustered by | `mapped_cust_id` |
| Refresh | Daily, full `create or replace`. Schedule TBD — must run **after** the 4am `order_customer` reload completes; 5am MT proposed |
| Cost | ~3.8 GB scanned / ~985 slot-seconds per run (measured 2026-07-28) ≈ $0.019/run |
| Source build script | `sql/sales_ops.customer_attribute.sql` |
| Upstream | `sales_ops.order_customer` **only** |

## Why full rebuild, not MERGE

A customer's record has to change when they order **and** when they cross a date boundary
without ordering. The second case is the whole point of the table — `orders_l30` falling to
zero is what makes someone a win-back target — and an incremental MERGE keyed on recent
orders never touches those customers. At $0.019 a run, recomputing all 1.37M customers daily
is cheaper than the logic required to get incremental right. **Do not convert this to a
MERGE.**

## Why person-only, when `order_sequence` deliberately isn't

`order_sequence` is per-order, so a caller can still filter it; pre-filtering there would
have hidden rows (steward decision 2026-07-27). Here **the row *is* the aggregate.** If
aggregator id `19192` were included it would produce one row with ~2.5M lifetime orders and
no downstream filter could unwind it. Filtering *after* aggregation doesn't renumber;
filtering *before* does. Same principle, opposite conclusion, because the grain differs.

## Why it's built from `order_customer`, not `order_sequence`

`order_sequence` is the intuitive base — it already holds `lifetime_customer_order_count` —
but it doesn't work here:

- It carries **no financials, no `store_id`, no `revenue_category`**. Every attribute except
  the order count would need `order_customer` anyway.
- Its `lifetime_customer_order_count` is computed across **all** customer types, so it's
  wrong for the ~30 mixed ids (`19192` sits at ~2.48M).
- `count(*)` over the person-filtered set is correct by construction and free.

The one thing `order_sequence` would have cost us — its history starts 2023-03-06 vs
`order_customer`'s 2018-08-07 — turns out to be moot: **zero person customers have a first
order before 2023-03-06** (verified 2026-07-28). Customer identity capture effectively
begins in March 2023, which is itself worth knowing when presenting `first_order_date`.

## Columns

### Identity
| Column | Type | Description |
|---|---|---|
| `mapped_cust_id` | INT64 | Canonical customer key. Primary key of this table. |
| `braze_external_id` | STRING | `cast(mapped_cust_id as string)` — the Braze `external_id`. 87% (1,194,620 of 1,374,213) match an existing `braze.users` row. |
| `mapped_email` | STRING | Most recent non-null email across the customer's orders. NULL for 844 customers (0.06%). |
| `mapped_email_domain` | STRING | Domain of the same order's email. |

### Lifetime volume
| Column | Type | Description |
|---|---|---|
| `lifetime_order_count` | INT64 | All person orders, store 1111 excluded, catering **included**. |
| `lifetime_catering_order_count` | INT64 | Subset where `is_catering = true`, so downstream can net catering out. |

### Lifetime value
| Column | Type | Description |
|---|---|---|
| `lifetime_net_sales` | FLOAT | Sum of canonical `net_sales`. |
| `lifetime_gross_sales` | FLOAT | Sum of `gross_sales`. |
| `lifetime_avg_check` | FLOAT | `lifetime_net_sales / lifetime_order_count`. |

### Dates
| Column | Type | Description |
|---|---|---|
| `first_order_datetime` | DATETIME | Earliest `order_datetime` (store-local). |
| `last_order_datetime` | DATETIME | Latest `order_datetime`. |
| `first_order_date` | DATE | Earliest `business_date`. |
| `last_order_date` | DATE | Latest `business_date`. |
| `days_since_last_order` | INT64 | `attribute_asof_date - last_order_date`. Recency driver. |
| `customer_tenure_days` | INT64 | `attribute_asof_date - first_order_date`. |

### First / last order context
| Column | Type | Description |
|---|---|---|
| `first_order_revenue_category` | STRING | Channel of the first order (`In-Store`, `Digital`, `Third_Party`, `Catering`, `Fundraiser`). |
| `first_order_source` | STRING | `order_source` of the first order (NULL = in-store POS). |
| `first_order_store_id` / `first_order_store_name` | INT64 / STRING | Where they were acquired. |
| `last_order_revenue_category` | STRING | Channel of the most recent order. |
| `last_order_source` | STRING | `order_source` of the most recent order. |
| `last_order_store_id` / `last_order_store_name` | INT64 / STRING | Most recent store visited. |

Ordering is by `order_datetime` with `brink_order_id` as tie-break — the same convention
`order_sequence` uses, so the two agree on which order is "first".

> **"Category" here means channel, not menu category.** `revenue_category` is on
> `order_customer` and costs nothing. A *menu*-category attribute (the
> `Bowls-Soups` / `Soups-Sandwiches` style already in Braze as `first_purch_cat`) requires a
> pass over `order_lines` and is deferred to v2 — see Roadmap.

### Stores
| Column | Type | Description |
|---|---|---|
| `lifetime_store_count` | INT64 | Distinct stores ever ordered from. Mean 1.4, max 89. |
| `lifetime_stores` | ARRAY&lt;STRUCT&lt;`store_id` INT64, `store_name` STRING, `orders` INT64, `last_order_date` DATE&gt;&gt; | Native repeated column, ordered **most-visited first**. `unnest()` it in SQL. |
| `primary_store_id` / `primary_store_name` | INT64 / STRING | First element of the array — the customer's home store. |
| `lifetime_store_names_json` | STRING | `["Zupas Murray","Zupas South Jordan",…]` — human-readable name list for Braze. |
| `lifetime_stores_json` | STRING | `[{"store_id":139,"store_name":"Zupas Murray","orders":3},…]` — ids + names + counts. |

Sample (real customer, 2026-07-28):

```json
[{"store_id":131,"store_name":"Zupas Spanish Fork","orders":42},
 {"store_id":109,"store_name":"Zupas Orem","orders":5},
 {"store_id":167,"store_name":"Zupas Saratoga Springs","orders":2}]
```

`store_name` is **1:1 with `store_id` across all history** (verified 2026-07-28 — no
`store_id` has ever had two names), so the array can be built straight off `order_customer`
with no `store_info` join and cannot fan out on a rename. If a store is ever renamed this
assumption breaks and the array will double-count that store — re-run the check.

### Trailing windows

Anchored on `attribute_asof_date`, inclusive of today: `business_date > asof_date - N`.

| Column | Type | Description |
|---|---|---|
| `orders_l30` / `orders_l90` / `orders_l365` | INT64 | Order count in the trailing 30 / 90 / 365 days. |
| `net_sales_l30` / `net_sales_l90` / `net_sales_l365` | FLOAT | Net sales over the same windows. |

These are the columns that force the daily full recompute.

### Housekeeping
| Column | Type | Description |
|---|---|---|
| `attribute_asof_date` | DATE | The date the windows are anchored to. Every row shares it. |
| `attribute_hash` | INT64 | `farm_fingerprint` over the *material* attributes, for Braze change detection. |
| `updated_at` | TIMESTAMP | Build time. |

**`attribute_hash` deliberately excludes `days_since_last_order` and `attribute_asof_date`.**
Both change every day for every customer; including them would make the hash useless and
force a full 1.37M-profile push to Braze daily. The export job should send only rows whose
hash moved since the last successful send, and let Braze compute recency from
`last_order_date`.

## Braze export contract (planned)

- **Key:** `braze_external_id`. 13% of rows (179,593) have no matching `braze.users`
  profile — decide whether the export creates them or skips them. Creating 180K profiles
  has billing implications.
- **Array cap:** Braze allows 25 elements per array attribute. Both JSON store columns are
  truncated to the top 25 stores by order count. 16 customers exceeded 25 stores on
  2026-07-28 (max 89), so this is a real but tiny truncation. Longest serialized value
  observed: 477 characters.
- **Nested objects:** `lifetime_stores_json` needs Braze **Nested Custom Attributes**
  enabled. `lifetime_store_names_json` (flat string array) does not — prefer it if nested
  attributes aren't turned on.
- **Delta sends:** use `attribute_hash`, not a full daily push.

## Validation (2026-07-28, SELECT body run against live data)

Aggregates reconcile **exactly** to `order_customer` under the same filters
(`business_date` 2018-08-07 → 2026-07-28, `store_id <> 1111`, `mapped_cust_id is not null`,
`customer_type = 'person'`):

| Measure | `customer_attribute` | `order_customer` | Match |
|---|---|---|---|
| Rows / distinct customers | 1,374,213 / 1,374,213 | 1,374,213 | ✅ |
| Total orders | 7,183,544 | 7,183,544 | ✅ |
| Total net sales | $214,469,109.31 | $214,469,109.31 | ✅ |
| Orders L30 | 210,167 | 210,167 | ✅ |
| Orders L365 | 2,717,354 | 2,717,354 | ✅ |

Also checked: zero rows with a null/zero `lifetime_store_count`, zero null
`first_order_revenue_category`, one row per customer (no join fan-out).

## Gotchas

- **NOT DEPLOYED.** See the banner. A commit to this repo does not create the table or the
  scheduled query.
- **Person-only by construction.** There is no `customer_type` column and no non-person
  rows. Don't reconstruct company-wide sales from this table — it excludes ~47% of orders
  (unidentified) plus all kiosk / internal / aggregator orders. **Sales totals still come
  from `order_customer`.**
- **`first_order_date` means "first identified order".** Customer identity capture starts
  effectively 2023-03-06; a customer may well have ordered anonymously before that. Say so
  when presenting tenure or acquisition-cohort numbers.
- **Catering is included** in every lifetime and window total. Net it out with
  `lifetime_catering_order_count` if the question excludes catering.
- **Windows are anchored on `attribute_asof_date`, not on query time.** If the build fails
  and the table goes stale, `orders_l30` is silently a window ending on a past date. Check
  `attribute_asof_date` before trusting the window columns — the equivalent of the
  `max(business_date)` check on the fact tables.
- **Build ordering matters.** This table must run after the 4am `order_customer` reload. If
  it runs during the reload window it will aggregate a partially-deleted table.
- 844 customers (0.06%) have no `mapped_email` — they're SessionM in-store scanners with no
  email on any order. They still get a row.
- The known `order_customer` grain defect (`brink_order_id` 2279778269187 has two rows)
  inflates one customer's lifetime count by 1. Clears on the next `order_customer` rebuild.

## Roadmap

- [ ] Deploy: create the scheduled query (5am MT proposed), then remove the DRAFT banner.
- [ ] v2 — **menu-category attributes** from `order_lines`: `first_purch_cat` /
      `last_purch_cat` in the existing `Bowls-Soups` style. Note the current Braze
      `first_purch_cat_update` feed covers only **497 users** — it's a pilot, and this table
      should absorb and supersede it. Requires settling the Try 2 Combo question (a combo's
      category depends on which line shape you count) — see the combo line taxonomy in the
      `sales-ops-orders` skill.
- [ ] v2 — pull existing `braze.users.custom_attributes` (`churn_factor`, `points_balance`,
      `points_to_expire_EOM`, `sessionM_userid`, `amperity_id`) onto the row so Braze has one
      source. Read with `lax_string()` / `lax_float64()`.
- [ ] Decide the Braze create-vs-skip policy for the 179,593 customers with no Braze profile.
- [ ] Build the export job + a `braze_export_log` holding last-sent `attribute_hash` per
      customer.
- [ ] Consider `lifecycle_status` (active / at-risk / lapsed) once the business agrees on the
      day thresholds — deliberately omitted from v1 rather than inventing cutoffs.
