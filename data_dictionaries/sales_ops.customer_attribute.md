# Data Dictionary: `marketing-data-442316.sales_ops.customer_attribute`

> ## ✅ LIVE since 2026-07-29 — but read the upstream defect warning first
>
> Deployed as a scheduled query running **daily at 5am MT**. The 2026-07-29 09:40 MT build was
> a one-off manual kickoff at deploy time; **the schedule's first automatic run is
> 2026-07-30 05:00 MT.** That build produced `attribute_asof_date = 2026-07-28`,
> 1,375,117 rows, 687 MB, and reconciles exactly to `order_customer` (see Validation).
>
> **✅ The upstream SessionM defect that corrupted recent days was fixed and verified
> 2026-07-29.** All affected dates are repaired. The table needs a rebuild to pick up the
> repaired data — the 2026-07-30 05:00 run does that automatically. See
> [Upstream defect](#-upstream-defect-sessionm-identity-loss-found-2026-07-29-fixed) for what
> happened and the two remaining mechanisms that move per-customer figures between builds.

**One row per customer** (`mapped_cust_id`), **person only**. Lifetime and trailing-window
aggregates. This is a *dimension* — a customer's current state — not a fact table.

Two consumers:

1. Analyst segmentation in BigQuery (LTV, frequency, lapsed cohorts, store affinity).
2. A daily push of `custom_attributes` to Braze, keyed on `braze_external_id`.

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per `mapped_cust_id` where `customer_type = 'person'` |
| Row count | **1,375,117** · 687 MB (build of 2026-07-29) |
| Partitioned by | none — it's a ~1.4M-row dimension, partitioning buys nothing |
| Clustered by | `mapped_cust_id` |
| Refresh | **Daily at 5am MT**, full `create or replace`. Deliberately after the 4am `order_customer` reload — see Gotchas. |
| Cost | ~3.8 GB scanned / ~985 slot-seconds per run ≈ $0.019/run |
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
- Its `lifetime_customer_order_count` was computed across **all** customer types, so it was
  wrong for the ~30 mixed ids (`19192` sat at ~2.48M). **That column was dropped 2026-07-29**
  precisely so `lifetime_order_count` here is the single unambiguous source.
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
| `mapped_email` | STRING | Most recent non-null email across the customer's orders. **100% populated** in the 2026-07-29 build. Was 844 NULLs on 2026-07-28, so this is not guaranteed to stay at zero — don't assume non-null without checking. |
| `mapped_email_domain` | STRING | Domain of the same order's email. |

### Lifetime volume
| Column | Type | Description |
|---|---|---|
| `lifetime_order_count` | INT64 | All person orders, store 1111 excluded, catering **included**. **The canonical lifetime-orders metric** as of 2026-07-29 — `order_sequence.lifetime_customer_order_count` was dropped in favour of this. Not identical to the old column (person-only, no store 1111, as-of yesterday); see `sales_ops.order_sequence.md`. |
| `lifetime_catering_order_count` | INT64 | Subset where `is_catering = true`, so downstream can net catering out. |
| `lifetime_guest_order_count` | INT64 | Subset where `is_guest_order = true` — a **first-party digital** order placed without a loyalty account. Rebuilt 2026-07-29 on the corrected `is_guest_order`; the previous values were derived from a column that actually meant "POS order" and were wrong for every customer. **Do not reconcile this against a naive `countif(is_guest_order)` over the whole mart** — see the gotcha. |

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

Anchored on `attribute_asof_date`: `business_date > attribute_asof_date - N`.

**`attribute_asof_date` is the day *before* the build runs** (steward decision 2026-07-28).
The job runs at 5am MT and stores don't open until ~10am, so anchoring on the run date would
make `orders_l30` cover 29 real business days plus an empty stub — and a mid-afternoon
re-run would silently produce different numbers. Anchoring to the last complete business day
makes every window whole-day and independent of run time. So a build on 2026-07-28 carries
`attribute_asof_date = 2026-07-27`, and `orders_l30` covers 2026-06-28 → 2026-07-27.

| Column | Type | Description |
|---|---|---|
| `orders_l30` / `orders_l90` / `orders_l365` | INT64 | Order count in the trailing 30 / 90 / 365 days. |
| `net_sales_l30` / `net_sales_l90` / `net_sales_l365` | FLOAT | Net sales over the same windows. |

These are the columns that force the daily full recompute.

### Housekeeping
| Column | Type | Description |
|---|---|---|
| `attribute_asof_date` | DATE | The last complete business day the windows are anchored to — **`run_date - 1`**, not the run date. Every row shares it. Check it to detect a stale build. |
| `attribute_hash` | INT64 | `farm_fingerprint` over the *material* attributes, for Braze change detection. |
| `updated_at` | TIMESTAMP | Build time. |

**`attribute_hash` deliberately excludes `days_since_last_order` and `attribute_asof_date`.**
Both change every day for every customer; including them would make the hash useless and
force a full 1.37M-profile push to Braze daily. The export job should send only rows whose
hash moved since the last successful send, and let Braze compute recency from
`last_order_date`.

## Braze coverage — why 179,593 customers have no profile (investigated 2026-07-28)

13% of person customers (179,593 of 1,374,213) have no matching `braze.users` row. This is
**not** a property of those customers — it's a sync boundary.

**Braze only began receiving non-loyalty customer profiles in November 2023.** Missing rate
for customers acquired in a given month, split by whether they ever enrolled in loyalty:

| First order month | Non-loyalty customers | % missing (non-loyalty) | % missing (loyalty) |
|---|---|---|---|
| 2023-03 | 3,374 | **98.8%** | 0.4% |
| 2023-04 | 9,744 | **99.2%** | 0.8% |
| 2023-05 | 21,496 | **98.0%** | 0.5% |
| 2023-06 | 29,282 | 79.9% | 0.3% |
| 2023-07 | 36,110 | 59.0% | 0.3% |
| 2023-08 | 41,921 | 55.8% | 0.2% |
| 2023-09 | 33,081 | 67.6% | 0.2% |
| 2023-10 | 33,360 | 34.5% | 0.2% |
| **2023-11** | 28,072 | **0.2%** | 0.2% |
| 2023-12 | 23,853 | 0.7% | 4.5% |
| 2024-01 → 2024-06 | ~51,000 | 0.6–1.3% | 4.3–6.2% |

Loyalty members were synced from the start (~0.2–0.8% missing through 2023). Non-loyalty
digital customers were not, and the pre-November-2023 backlog was **never backfilled**. That
one cohort — 2023, no loyalty — accounts for **136,243 of the 179,593 gap (76%)**; the
single-order slice alone is 123,390.

Two consequences:

- The gap is **static and shrinking as a share**, not growing. Post-2023 acquisition is
  95–99% covered. Don't model it as ongoing leakage.
- **A second, opposite problem starts in December 2023**: *loyalty* member coverage degrades
  from ~0.2% missing to a steady **4–6%**, and it persists through 2026 (2026 loyalty
  cohorts are 3.6–7.3% missing). Post-2023, a loyalty member is *more* likely to be missing
  from Braze than a non-loyalty customer. That inversion is unexplained and is probably a
  profile merge/deletion or sync defect — it is a live issue, unlike the 2023 backlog.
  Logged as its own Asana task.

Rejected hypotheses: account age alone (2024/2025/2026 are all ~4.5%, flat), zero-order
customers (every row here has ≥1 order), and SessionM-only identity (99.5% of the 263,716
SessionM-only customers *are* in Braze — only 1,227 are missing).

## Braze export contract (planned)

- **Key:** `braze_external_id`. 179,593 rows (13%) have no matching `braze.users` profile —
  decide whether the export creates them or skips them. Creating 180K profiles has billing
  implications. See the coverage section above: 76% of them are one stale 2023 cohort, and
  123,390 are single-order customers who last ordered years ago — a strong argument for
  *skipping* rather than creating.
- **Array cap:** Braze allows 25 elements per array attribute. Both JSON store columns are
  truncated to the top 25 stores by order count. 16 customers exceeded 25 stores on
  2026-07-28 (max 89), so this is a real but tiny truncation. Longest serialized value
  observed: 477 characters.
- **Nested objects:** `lifetime_stores_json` needs Braze **Nested Custom Attributes**
  enabled. `lifetime_store_names_json` (flat string array) does not — prefer it if nested
  attributes aren't turned on.
- **Delta sends:** use `attribute_hash`, not a full daily push.

## Validation

### Post-deploy, against the live table (2026-07-29)

The deployed table reconciles **exactly** to `order_customer` under the same filters
(`business_date` 2018-08-07 → `attribute_asof_date`, `store_id <> 1111`,
`mapped_cust_id is not null`, `customer_type = 'person'`):

| Measure | `customer_attribute` | `order_customer` | Match |
|---|---|---|---|
| Rows / distinct customers | 1,375,117 / 1,375,117 | 1,375,117 | ✅ |
| Total orders | 7,181,272 | 7,181,272 | ✅ |
| Total net sales | $214,426,387.42 | $214,426,387.42 | ✅ |
| Orders L30 | 207,895 | 207,895 | ✅ |
| Orders L365 | 2,715,082 | 2,715,082 | ✅ |

Also confirmed: `attribute_asof_date = 2026-07-28` (yesterday — the anchor rule works), one
row per customer, zero null/zero `lifetime_store_count`, zero null `primary_store_name`,
schema matches the build script exactly (38 columns, clustered on `mapped_cust_id`).

**Re-run this reconciliation any time the table is rebuilt after an `order_customer`
change** — it's a two-query check and it's the only thing that catches a silent aggregation
break.

### Reconciliation query

```sql
select
  count(*) as orders
, count(distinct oc.mapped_cust_id) as customers
, round(sum(oc.net_sales), 2) as net_sales
, countif(oc.business_date > date_sub(date '2026-07-28', interval 30 day)) as orders_l30
, countif(oc.business_date > date_sub(date '2026-07-28', interval 365 day)) as orders_l365
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date between date '2018-08-07' and date '2026-07-28'   -- = attribute_asof_date
and oc.store_id <> 1111
and oc.mapped_cust_id is not null
and oc.customer_type = 'person'
```

## ✅ Upstream defect: SessionM identity loss (found 2026-07-29, FIXED)

**This is why the build-to-build numbers moved, and it was not benign restatement.** The first
explanation offered — "the 8-day reload restates history, working as designed" — was wrong.
Investigating the drift found a real `order_customer` defect.

> **Resolved 2026-07-29.** `header_trans` now uses `create_date >= start_date`. Repaired counts
> match the pre-fix reproduction exactly (7/21: 7,927 · 7/27: 7,657 · 7/28: 7,868).
> **This table still holds the corrupted figures until its next build** — the 2026-07-30 05:00
> run picks up the repaired data. Full pipeline audit:
> `design/sessionm_identity_pipeline_audit.md`.

`order_customer` is landing whole business dates with `sm_external_user_id` NULL. Since
`mapped_cust_id = coalesce(pulse_customer_id, sm_external_user_id)`, every in-store loyalty
scanner on those days loses their identity and drops out of the person population:

| `business_date` | All orders | SessionM-linked | Person orders |
|---|---|---|---|
| Normal (2026-07-22) | 26,986 | 8,341 | 9,088 |
| 2026-07-21 | 25,955 | **0** | **5,337** |
| 2026-07-27 | 25,100 | **74** | **5,143** |
| 2026-07-28 | 26,258 | **0** | **5,369** |

Only 3 such days exist in all of 2026, and all 3 are in the last nine days — so this is new
or newly frequent. Root causes (Asana 1216993827082929 and 1216993694612234):

1. `header_trans` filters `h.create_date > start_date`. `create_date` is a **DATE**, so `>`
   drops the whole boundary day. Proven: with `start_date = 2026-07-21`, 7/21 links **0** rows
   under `>` and **7,927** under `>=`.
2. Intraday runs set `start_date = run_date`, making `create_date > start_date` match nothing
   — so every intraday run writes today with zero SessionM identity. Why the following 4am
   reload didn't repair 7/27–7/28 is still open; the data was provably linkable (7,657 and
   7,868) when it ran.

### What this does to *this* table

- `lifetime_order_count`, `lifetime_net_sales` and the store arrays are **understated** for
  in-store loyalty customers whose orders fell on an affected day.
- `orders_l30` / `l90` / `l365` are understated, and `days_since_last_order` is **overstated**.
- **This is actively dangerous for the Braze win-back use case.** A customer who ate in-store
  yesterday can present as lapsed and get a "we miss you" message. Do not launch a
  recency-triggered campaign off this table until the upstream fix lands and the affected
  dates are rebuilt.
- New in-store-only loyalty customers acquired on an affected day get **no row at all**.

**Run the detector in `sales_ops.order_customer.md` before trusting any recent-window figure
from this table.** Healthy is ~28–33% `pct_sm_linked`; under 15% means the date is corrupted.

### Falsifiable prediction for the first scheduled run (2026-07-30 05:00 MT)

If the boundary-day diagnosis is right, this is what tomorrow does — and it's the cheapest way
to confirm or kill the theory:

- 2026-07-30 is a **Thursday**, so the 4am `order_customer` job takes the 8-day branch:
  `start_date = date_sub('2026-07-30', interval 8 day)` = **2026-07-22**.
- `create_date > start_date` will therefore drop every SessionM header created on 7/22, and
  **business_date 2026-07-22 will go from 8,341 SessionM links to ~0** — a day that is
  currently healthy.
- The 5am `customer_attribute` build reads through `attribute_asof_date = 2026-07-29`, so it
  will **bake that fresh damage in**, and ~3,700 person orders will disappear from 7/22.

Check it the moment the run lands:

```sql
select
  oc.business_date
, countif(oc.sm_external_user_id is not null) as sm_linked
, countif(oc.customer_type = 'person') as person_orders
from `marketing-data-442316`.sales_ops.order_customer oc
where 1=1
and oc.business_date between date '2026-07-20' and date '2026-07-29'
and oc.store_id <> 1111
group by 1
order by 1
```

**If 7/22 collapses, the `>` → `>=` fix is confirmed and should ship immediately.** If 7/22
survives, the boundary-day theory is wrong and both defects trace to whatever is breaking
7/27–7/28 — reopen Asana 1216993827082929 with that finding.

Either way this table's first scheduled build should be treated as **provisional** until the
check is done.

### Drift between builds — the honest version

Pre-deploy (2026-07-28): 1,374,213 customers / 7,183,544 orders / $214,469,109.31.
Live build (2026-07-29): 1,375,117 customers / 7,181,272 orders / $214,426,387.42.

- The **+904 customers** is genuine and expected: 2026 acquisition runs ~925 new identified
  customers/day, so this is almost exactly one day. Cohort counts for 2023, 2024 and 2025 are
  **byte-identical** across the two runs (delta exactly 0 for each), which proves identity is
  **not** being restated retroactively — a real reassurance about historical stability.
- The **−2,272 orders** is the defect above, not restatement. 7/28 shed ~3,400 person orders
  versus a normal Tuesday. Since 7/28 was a *partial* day pre-deploy and a *complete* day in
  the build, the true loss is larger than the net figure suggests.

### Every known reason `lifetime_order_count` changes without a new order

Audited 2026-07-29. In rough order of how much they move the number:

1. **Reload restatement.** The 4am `order_customer` job rewrites the last 8 days (5 weeks on
   Mondays, ~13 months on the 1st) and **recomputes `customer_type` and `mapped_cust_id` for
   every rewritten row**. An order can gain or lose identity, or reclassify person ↔ aggregator,
   changing two customers' counts at once. This is by design.
2. **Voided orders leave entirely.** The build keeps only orders with item gross or net > 0, so
   an order fully voided after the fact disappears rather than going to zero.
3. **Ambiguous SessionM mappings flipping.** 6,095 SessionM `user_id`s carry more than one
   `cafezupas` `external_user_id`, and `sm_external_user_map` picks the winner by
   `max(updated_at)`. If a mapping's `updated_at` moves, orders **migrate wholesale from one
   `mapped_cust_id` to another**. Exposure: 17,269 orders · 2,913 customers · $472,797 net over
   365 days, of which 7,236 have no `pulse_customer_id` fallback. Fix proposed in the audit doc.
4. **Upstream defects** like the one above — the only category that is outright wrong rather
   than merely unstable.
5. **`attribute_asof_date` advancing** shifts the trailing windows (not lifetime counts).

Items 1–3 mean lifetime figures are **stable in aggregate but not guaranteed identical
per-customer** between builds. Don't promise a specific customer's count will tie to a prior
report, and **don't reach for restatement as the explanation without running the detector
first** — that's the mistake made here.

## Gotchas

- **Person-only by construction.** There is no `customer_type` column and no non-person
  rows. Don't reconstruct company-wide sales from this table — it excludes ~47% of orders
  (unidentified) plus all kiosk / internal / aggregator orders. **Sales totals still come
  from `order_customer`.**
- **`first_order_date` means "first identified order".** Customer identity capture starts
  effectively 2023-03-06; a customer may well have ordered anonymously before that. Say so
  when presenting tenure or acquisition-cohort numbers.
- **Catering is included** in every lifetime and window total. Net it out with
  `lifetime_catering_order_count` if the question excludes catering.
- **⚠️ Reconciling this table against `order_customer` requires the build's WHERE clause
  verbatim** — `customer_type = 'person'` **and** `store_id <> 1111`, over
  `business_date between '2018-08-07' and attribute_asof_date`. Omit either filter and you
  manufacture phantom mismatches.

  Worked example (2026-07-29): a check that skipped both filters reported 43 customers whose
  `lifetime_guest_order_count` was short by 1,268 orders, all concentrated in 2023 — which
  looked convincingly like a history-window cutoff. It wasn't. `customer_type` is
  **order-level** (see `sales_ops.order_customer.md`), so aggregating with
  `max(customer_type)` labels a customer `person` while the guest orders being counted sit on
  their *non-person* orders. The 2023 clustering is simply where those mixed-type orders live.

  With the build's filters applied: **1,377,496 customers, 0 guest mismatches, 0 order-count
  mismatches, totals identical at 329,567.** Ready-made query:
  `sql/checks/customer_attribute_guest_reconciliation.sql` (query A reproduces the false
  alarm, query B is the correct check).
- **Windows are anchored on `attribute_asof_date`, not on query time.** If the build fails
  and the table goes stale, `orders_l30` is silently a window ending on a past date and the
  numbers still *look* fine. Check `attribute_asof_date` before trusting the window columns
  — the equivalent of the `max(business_date)` check on the fact tables. Expected value is
  yesterday; anything older means the build didn't run.
- **`days_since_last_order` is measured from `attribute_asof_date`, not from today.** On a
  healthy build that's off by one day from "now"; on a stale build it's off by however long
  the build has been broken.
- **Build ordering matters — 5am is not arbitrary.** `order_customer`'s 4am job runs
  `delete … where business_date >= start_date` then `insert`. A build that lands inside that
  window aggregates a partially-deleted table and silently undercounts recent orders with no
  error. If the 4am job ever slows down or the 5am slot moves earlier, this breaks quietly.
  The reconciliation query above is the detector.
- **`order_customer` restates history, so this table's numbers move.** The 4am reload
  rewrites the last 8 days (5 weeks on Mondays, ~13 months on the 1st). A customer's
  `lifetime_order_count` can therefore change without them ordering. Don't cache these values
  downstream and expect them to tie.
- The known `order_customer` grain defect (`brink_order_id` 2279778269187 has two rows)
  inflates one customer's lifetime count by 1. Clears on the next `order_customer` rebuild.

## Roadmap

- [x] Deploy the scheduled query — **done 2026-07-29**, daily 5am MT (2026-07-29 09:40 build
      was a manual kickoff; first scheduled run is 2026-07-30 05:00).
- [ ] **Check the first scheduled run (2026-07-30 05:00 MT) against the prediction below.**
- [ ] **Rebuild the dates affected by the SessionM defect** once the upstream `>=` fix lands,
      then re-run the reconciliation.
- [ ] v2 — **menu-category attributes** from `order_lines`. **Decided 2026-07-28: carry
      BOTH `item_type` and `rev_center_name`**, and resolve Try 2 Combos down to their
      component rev centers rather than leaving them as `Combos`. Evidence, measured on
      June 2026 (`line_item_type = 'item'`,
      store 1111 excluded, top line per order by `item_gross_sales`, junk types dropped):
      - **`item_type` is too coarse to segment on.** 72.7% of orders resolve to `Entree` and
        17.2% to `Combos` — 90% in two buckets. The full list is `Entree`, `Combos`,
        `Desserts` (6.7%), `Beverage` (1.2%), `Kids Meals` (0.9%), `Party Trays & Food`,
        `Box Lunches`, `Sides/Misc Items`, `Cater Desserts`, `Cater Beverages`, plus
        `Non Food/Bev Mis` and `Modifiers` (both must be excluded — `Non Food/Bev Mis` is
        587K lines at $0 gross).
      - **`Combos` is an artifact, not a preference.** A Try 2 Combo order's top line is
        `item_type = 'Combos'`, which says nothing about what the guest ate. The dish is one
        level down: `rev_center_name` splits `Entree` into `Sandwiches` (353K lines),
        `Soups` (318K), `Salads` (285K), `Bowls` (280K), `Kids Meals` (121K) — and that is
        also the grain the existing Braze `first_purch_cat` uses (`Bowls-Soups`,
        `Soups-Sandwiches`). Recommend carrying **both** `item_type` and `rev_center_name`,
        and resolving combos down to their component rev centers.
      - The Braze `first_purch_cat_update` feed covers only **497 users** — it's a pilot, and
        this table should absorb and supersede it.
      - Still requires settling which combo line shape to count — see the combo line
        taxonomy in the `sales-ops-orders` skill.
- [ ] v2 — pull existing `braze.users.custom_attributes` (`churn_factor`, `points_balance`,
      `points_to_expire_EOM`, `sessionM_userid`, `amperity_id`) onto the row so Braze has one
      source. Read with `lax_string()` / `lax_float64()`.
- [ ] Decide the Braze create-vs-skip policy for the 179,593 customers with no Braze profile.
- [ ] Build the export job + a `braze_export_log` holding last-sent `attribute_hash` per
      customer.
- [ ] Consider `lifecycle_status` (active / at-risk / lapsed) once the business agrees on the
      day thresholds — deliberately omitted from v1 rather than inventing cutoffs.
