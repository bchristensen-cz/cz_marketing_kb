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

> ## 📱 App-user definition REVISED 2026-09-22: a session alone is no longer an app user; `app_purchase_mode` added
>
> Steward decision 2026-09-22. **`is_app_user` is now the 12-month purchase test only** (app order or
> in-store scan); a native-app session without a purchase does not qualify. `app_user_type` lost its
> `session_only` value (now `purchase_and_session` / `purchase_only` / NULL) and a new column
> **`app_purchase_mode`** (`app_orders_and_scans` / `app_orders_only` / `scans_only` / NULL) splits the
> purchase test into its two halves. Session columns (`is_app_session_user`, `app_session_days_l90`,
> `last_app_session_date`) are unchanged and still populated; they are descriptive, not qualifying.
> Effect on the 2026-09-21 build: 27,512 `session_only` rows flip to `is_app_user = false`, 417,691
> purchasers are unchanged; `attribute_hash` moves once for every app user (new struct field) and for
> the flipped rows. `app_purchase_mode` is exposed on `claude.order_customer` (75 columns). Details
> under [App usage](#app-usage-new-2026-09-18-revised-2026-09-22). The 2026-09-18 note below is kept
> for history; read "or a native-app session" there as superseded.
>
> ## 📱 App-user flag added 2026-09-18 (steward decision 2026-09-17)
>
> Ten **app usage** columns landed on the table on **2026-09-17 23:04 MT** (scheduled query `sales_ops customer_attribute`, config `6a7bb56c-0000-2ccb-aeca-94eb2c09e074`, text replaced with `bq update --transfer_config --flagfile`; manual run `6af29e7f` DONE in 30 s / 3.6 GB, `attribute_asof_date` 2026-09-16, live counts identical to the scratch validation below; first scheduled run with the flag 2026-09-18 05:20 MT). `is_app_user` is the canonical
> App User definition (app order **or** in-store scan in the trailing 12 months, **or** a native-app
> session in the trailing 90 days), materialised once a day. Full column list under
> [App usage](#app-usage-new-2026-09-18); tie-out under Validation; the definition itself lives in
> `claude_skills/sales-ops-orders/SKILL.md`. **`is_app_user` and `app_user_type` are exposed on
> `claude.order_customer` since 2026-09-17 23:20 MT**, and `gender` / `birthday` / `age` since 23:40 MT
> the same evening (the other ten app-usage columns remain `sales_ops`-only) and `attribute_hash` now
> moves with the flag.

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
| Refresh | **Daily at 05:20 MT** (moved from 05:00 on 2026-09-08), full `create or replace`. Deliberately after the **05:02** `order_customer` + `order_sequence` full rebuild, which itself follows the 04:07 SessionM merge — see Gotchas and `sales_ops.order_customer.md` § "SessionM loads once per day". |
| Cost | ~3.6 GB scanned / ~1,840 slot-seconds on the 2026-09-18 test build (the Braze session CTE adds ~0.45 GB; the `event_date` filter on the scripting variable prunes correctly, verified by bytes billed) ≈ $0.02/run |
| Source build script | `sql/sales_ops.customer_attribute.sql` |
| Upstream | `claude.order_customer` (the view) since 2026-09-08 — it supplies `mapped_cust_id` / `customer_type` from `sales_ops.order_sequence` after the identity rework moved those columns off `sales_ops.order_customer`. Before 2026-09-08: `sales_ops.order_customer` only. **Since 2026-09-18 also `braze.app_sessionstart`** (trailing 90 days, `workspace = 'cafe_zupas'`, `platform in ('ios', 'android')`) for the app-user columns, and `pulse.customers` for the demographics. |

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

> **2026-09-08 update.** `mapped_cust_id` and `customer_type` moved from `sales_ops.order_customer` to
> `sales_ops.order_sequence`, so the build now reads **`claude.order_customer`**, the view that joins the
> two (and `loyalty_user`, and this table itself — a self-reference that is fine in a `create or replace`
> because the view reads the previous snapshot). The reasoning below about *why order_sequence alone is
> not enough* still holds; the base is just the joined view now. Refresh moved to 05:20 MT so it runs after
> the 05:02 full rebuild of both tables. First run on the new chain: 2026-09-09 05:20, `attribute_asof_date`
> 2026-09-08, 1,331,693 rows.

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

### Demographics — new 2026-09-15, **exposed on `claude.order_customer` since 2026-09-17**
| Column | Type | Description |
|---|---|---|
| `gender` | STRING | Closed two-value domain, **lowercase**: `female` / `male`. There is no `other` / `unknown` sentinel — absent is NULL. Measured 2026-09-16 on the 2026-09-15 build (1,335,690 rows): `female` **796,462 (59.63%)**, `male` **323,341 (24.21%)**, NULL **215,887 (16.16%)**. Quote gender splits on the **populated base**, not on all customers, or the 16% NULL silently shrinks both shares. |
| `birthday` | DATE | **20.9%** populated (279,164 on the 2026-09-16 build). **Year `1950` is the app's placeholder for "year not provided"** (steward confirmation 2026-09-17): **151,258 rows, 54% of all birthdays**, spread across every month and day (759 on 01-01, then ~400 to ~520 per day), so **month and day are real and the year is not**. Birthday-month campaigns can use the whole column; anything needing the year must exclude `extract(year from birthday) = 1950`, or just use `age`. The remaining 127,906 real-year birthdays run **1877-08-19 → 2022-10-13**, unvalidated at both ends. |
| `age` | INT64 | **9.6%** populated (127,906 on the 2026-09-16 build). ✅ **The gap is explained (2026-09-17):** the build nulls `age` when `extract(year from birthday) = 1950`, and 1950 is the placeholder year above, so `age` is populated on **exactly** the real-year birthdays: 127,906 real birthdays, 127,906 ages, 0 real birthdays without an age. The earlier "149,026 birthdays with a NULL age, reason not established" note described the placeholder rows. Still not range-validated: 127,867 of the 127,906 fall in a plausible 13 to 100; the rest inherit the 1877 → 2022 edges. Never derive an age from `birthday` yourself. |

> **✅ Exposed on `claude.order_customer` 2026-09-17 23:40 MT (steward call).** Between 09-15 and
> 09-17 the three columns were `sales_ops`-only: the view folds this table in through a **select
> list**, not `select *`, so the adds did not propagate until the redeploy (same select-list-view
> lesson as 2026-08-13 and 2026-08-17: **adds, renames and drops all require the redeploy**). They
> are passed through unchanged, including the 1950 placeholder year, so the `claude` dictionary
> carries the same three warnings. Coverage on the order view, week ending 2026-09-16: `gender` on
> 79% of identified person orders, `birthday` on 43%, `age` on 28%.

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
| `first_order_datetime` | DATETIME | Earliest `order_datetime_local` (store-local). |
| `last_order_datetime` | DATETIME | Latest `order_datetime_local`. |

> **⚠️ `days_since_last_order` is a customer-level constant, not a per-order gap** (measured 2026-08-21).
> It is "days since this customer's most recent order, as of the build" and repeats **identically on
> every row** of that customer. The per-order interval is **`days_since_prev_order`**. Verified on
> `claude.order_customer` for `mapped_cust_id` 6357228 over 2026-08-01 → 08-18:
>
> | business_date | `customer_order_count` | `days_since_prev_order` | `days_since_last_order` |
> |---|---|---|---|
> | 2026-08-07 | 233 | 7 | 2 |
> | 2026-08-10 | 234 | 3 | 2 |
> | 2026-08-13 | 235 | 3 | 2 |
> | 2026-08-15 | 236 | 2 | 2 |
> | 2026-08-18 | 237 | 3 | 2 |
>
> So **`avg(days_since_last_order)` over a customer's orders returns that constant**, not their
> cadence — averaging a repeated value is a no-op that looks like an aggregate. Found live in
> `braze.cdi_order_attributes`, whose `l90_avg_days_btwn_orders` publishes "days since last order"
> under an average-gap name. Use `avg(days_since_prev_order)`, and exclude rather than zero-fill the
> NULL on a customer's first-ever order.
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
| `catering_orders_l30` / `_l90` / `_l365` | INT64 | **Added 2026-09-18.** Subset of the matching `orders_lN` where `is_catering`. 0, never NULL. |
| `catering_net_sales_l30` / `_l90` / `_l365` | FLOAT | **Added 2026-09-18.** Subset of the matching `net_sales_lN` where `is_catering`. Ex-catering spend = `net_sales_lN - catering_net_sales_lN`. Not part of `attribute_hash` (it already moves with the parent columns). |

These are the columns that force the daily full recompute. `orders_l365`, `net_sales_l365`,
`catering_orders_l365` and `catering_net_sales_l365` are exposed on `claude.order_customer`
since 2026-09-18 (the 30/90 pairs are `sales_ops`-only).

### App usage (new 2026-09-18, revised 2026-09-22)

The canonical **App User** definition (steward decision 2026-09-17, revised 2026-09-22), materialised.
**An app user is a person customer with an app order or an in-store scan in the trailing 12 months.
Opening the app without buying does not qualify** (revision 2026-09-22; before that a native-app
session in the trailing 90 days also qualified). Windows anchor on `attribute_asof_date` and are
inclusive of it (`business_date > asof - 12 month`, `event_date > asof - 90 day and <= asof`), which
is the same window the KB's canonical query writes as `>= current_date - N` when it runs the morning
after. An in-store scan counts as an app purchase by the steward's stated assumption that the scan
is made with the app.

| Column | Type | Description |
|---|---|---|
| `lifetime_app_order_count` | INT64 | Person orders with `order_source in ('iOS', 'Android')`, full history. |
| `lifetime_in_store_scan_count` | INT64 | Person orders with `in_store_scan = 1`, full history. |
| `app_orders_l12m` | INT64 | App orders in the trailing 12 months. |
| `in_store_scans_l12m` | INT64 | In-store scans in the trailing 12 months. |
| `last_app_order_date` | DATE | Most recent app order; NULL if never. |
| `last_in_store_scan_date` | DATE | Most recent in-store scan; NULL if never. |
| `app_session_days_l90` | INT64 | Distinct `event_date`s with a native-app `app_sessionstart` (ios/android, `cafe_zupas` workspace) in the trailing 90 days. **0, never NULL.** |
| `last_app_session_date` | DATE | Most recent native-app session day in the window; NULL if none. |
| `is_app_purchaser` | BOOL | `app_orders_l12m + in_store_scans_l12m > 0`. Never NULL. Since 2026-09-22 identical to `is_app_user`; kept for anything written against it. |
| `is_app_session_user` | BOOL | Had a native-app session in the trailing 90 days. Never NULL. **Descriptive only since 2026-09-22**: it no longer feeds `is_app_user`. |
| `is_app_user` | BOOL | **The canonical flag.** Since 2026-09-22: `is_app_purchaser` (app order or in-store scan in the trailing 12 months). 2026-09-18 to 09-21 it was `is_app_purchaser or is_app_session_user`. Never NULL. |
| `app_user_type` | STRING | `purchase_and_session` / `purchase_only`; **NULL when not an app user.** `purchase_only` is bought-or-scanned-but-no-native-session-in-90-days (lapsing or uninstalled). The `session_only` value was **retired 2026-09-22**: browsers who have not bought are not app users. To find them use `is_app_session_user and not is_app_user` (27,512 on the 2026-09-21 build; a further ~23k session users have no row here at all). |
| `app_purchase_mode` | STRING | **New 2026-09-22.** How the app user buys: `app_orders_and_scans` (both in the 12 months), `app_orders_only`, `scans_only`; **NULL when not an app user.** Mutually exclusive. On the value analysis to 2026-09-14 (`claude/app-segments-value-2026-09-22.md` in the Analysis project): both 107k customers at 9.5 orders / $220 a year ex catering, app-orders-only 140k and scans-only 170k both at ~4 orders / $92-97 a year; 81% of scans-only have never placed an app order in their lifetime. Exposed on `claude.order_customer`. |

Three things to know before using them:

- **Grain gap, mostly closed by the 2026-09-22 revision.** This table only holds customers with at
  least one identified person order. Under the 2026-09-18 definition a Braze session user who had
  never placed an identified order was an app user with no row here (**23,092** on 2026-09-16:
  467,775 by the canonical query vs 444,683 flagged). Since a purchase is now required, every app
  user has an identified order and therefore a row; the table and the canonical query should agree
  exactly. Session-only users still have no row unless they have ordered some other way.
- **Braze `platform` is the whole game.** `app_sessionstart` also logs the web SDK and landing
  pages (web is ~4x the native user count); the build filters `platform in ('ios', 'android')`.
  Do not "widen" that filter.
- **The scan-as-app assumption has a measurable edge.** Of customers who scanned in-store in the
  trailing 90 days (2026-09-17), **8.1%** had no native-app session in the same window, against a
  **1.3%** no-session rate for customers who placed an app order (the Braze identification
  baseline). So roughly 7 points of scanners, ~7,000 people, scan without the app being visible in
  Braze. The definition counts them as app users on purpose; say so if the number matters.

### Housekeeping
| Column | Type | Description |
|---|---|---|
| `attribute_asof_date` | DATE | The last complete business day the windows are anchored to — **`run_date - 1`**, not the run date. Every row shares it. Check it to detect a stale build. |
| `attribute_hash` | INT64 | `farm_fingerprint` over the *material* attributes, for Braze change detection. **Since 2026-09-18 includes `is_app_user` and `app_user_type`, since 2026-09-22 also `app_purchase_mode`**, so a customer becoming or ceasing to be an app user, or changing how they buy, is a pushable change. Every row's hash moved once on the first build with the flag (2026-09-18); every app user's and every former session-only row's hash moved again on the first build with the revision (2026-09-22). |
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

### App-user revision and `app_purchase_mode`, test build vs live (2026-09-22, `attribute_asof_date` 2026-09-21)

Built into `scratch.customer_attribute_app_mode_test` from the revised script before touching the
live table (3.6 GB, dropped afterwards). Same 1,337,254 rows as the live 09-21 build.

| Measure | Live 09-21 build (old text) | Test build (new text) |
|---|---|---|
| `is_app_user` | 445,203 | **417,691** (the 27,512 `session_only` rows flipped) |
| `is_app_session_user and not is_app_user` | 27,512 | 27,512 |
| `app_user_type = 'session_only'` | 27,512 | 0 (retired) |
| `app_purchase_mode = 'app_orders_and_scans'` | 107,049 (derived) | 107,049 |
| `app_purchase_mode = 'app_orders_only'` | 138,121 (derived) | 138,121 |
| `app_purchase_mode = 'scans_only'` | 172,521 (derived) | 172,521 |
| app users with NULL mode / non-app users with a mode / `is_app_user != is_app_purchaser` | n/a | 0 / 0 / 0 |

`purchase_and_session` moved by 4 (258,727 to 258,731) because `app_sessionstart` backfilled
between the 05:20 build and the test; expected. Note the 09-21 window still carries the Pulse
stall (app orders for 09-15 to 09-21 read as unidentified), so `app_orders_only` is a few
thousand light and `scans_only` correspondingly heavy until the 09-24 build.

### App-user columns, test build vs canonical query (2026-09-18, `attribute_asof_date` 2026-09-16)

Built into `scratch.customer_attribute_app_user_test` before touching the live table. All
pre-existing measures identical to the live 05:20 build (1,336,019 rows, 7,584,114 orders,
$227,074,813.71 net, `orders_l30` 237,937, `orders_l365` 2,769,122, 1,119,864 gender populated).
Against the canonical query with both windows closed on 2026-09-16:

| Measure | canonical query | `customer_attribute` | Note |
|---|---|---|---|
| App purchasers (12m) | 417,711 | 417,711 | ✅ exact |
| Purchase-only | 159,104 | 159,104 | ✅ exact |
| Session users (90d) | 308,671 | 285,579 | 23,092 have no identified order, so no row here |
| Session-only | 50,064 | 26,972 | same 23,092 |
| App users | 467,775 | 444,683 | same 23,092 |
| In table but not flagged | 0 | | ✅ |

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
  `lifetime_catering_order_count` if the question excludes catering. **Since 2026-09-18 the
  window columns have a catering counterpart too**: `catering_orders_l30/l90/l365` and
  `catering_net_sales_l30/l90/l365`, same windows, same inclusivity, so ex-catering =
  `net_sales_l365 - catering_net_sales_l365`. Added after an analyst re-aggregated
  `order_customer` (1.5 GiB) for 364-day spend tiers because the table could not honour the
  catering exclusion (Asana 1218627569715877). **Do not call the catering share "small"**: on the
  2026-09-18 build catering is **$20.10M of $86.38M `net_sales_l365` (23.3%)** across 22,698
  customers with a catering order in the window, out of 676,555 active. Customers *mixing* the
  two are rare (277) because catering and individual are separate identity populations, but the
  dollar share is not — a spend tier that includes catering puts catering accounts in every top
  band.
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

- [x] **App-user flag** (`is_app_user`, `app_user_type` and eight supporting columns), deployed
      2026-09-18 per steward decision 2026-09-17. Repo `sql/` copy also re-synced with the
      deployed text: the 2026-09-15 demographics block was deployed but never committed, and a
      stray `and ca.lifetime_order_count > 0` on the `pulse.customers` join predicate (always true)
      was dropped.
- [x] **`is_app_user` / `app_user_type` exposed through `claude.order_customer`** — steward call
      2026-09-17, view redeployed 23:20 MT; `gender` / `birthday` / `age` followed at 23:40 MT (70
      columns). The other ten app-usage columns stay `sales_ops`-only.
- [x] **App-user definition revised and `app_purchase_mode` added** (steward decision 2026-09-22):
      `is_app_user` = purchase test only, `app_user_type` drops `session_only`, `app_purchase_mode`
      materialised and exposed on `claude.order_customer` (75 columns). Deployed the same day via
      `bq update --transfer_config --flagfile` + manual run; hash moved for every app user once.
- [ ] `birthday` placeholder year: consider nulling the **year** at source rather than leaving 1950 in
      the column (a DATE cannot hold month/day alone, so this means either a separate
      `birthday_month_day` STRING or accepting the sentinel). Until decided, the 1950 rule above is
      the contract.
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
