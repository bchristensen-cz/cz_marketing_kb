# `sales_ops.order_customer` — build and ingestion notes (companion)

> **Read this when** you are changing or debugging the build (`sql/sales_ops.order_marts.sql`) or the SessionM load schedule, or yesterday's `pct_sm_linked` reads under 15% after ~05:15 MT, or `pulse_order_id` goes to 0 on recent days. Analysts answering business questions do not need it; read [`sales_ops.order_customer.md`](sales_ops.order_customer.md). Moved verbatim from that file on 2026-10-14.

## SessionM ingestion schedule (was inside the gotcha "SessionM loads ONCE PER DAY")

  **SessionM ingestion is THREE separately scheduled steps, not one job.** Moving one without the
  others silently makes `sessionM.*` a day stale (it happened 2026-09-05 → 09-08, below). Verified
  2026-09-09 on `JOBS_BY_PROJECT`, Cloud Scheduler and the Storage Transfer / DTS APIs:

  | Step | Mechanism | Schedule | Observed 2026-09-09 |
  |---|---|---|---|
  | 1. S3 → `gs://sessionm/prod_datadumps/<yyyy_mm_dd>/` | Storage Transfer job `9198078639943003749` from `amperity-sessionm/SessionM/prod_datadumps/` (47 files ≈ 8 GB) | **09:45 UTC** daily (UTC — does not drift at DST) | lands 03:45–03:50 MDT |
  | 2. GCS → `staging.sm_*` | Cloud Run job `sessionm-bq-loader`, Cloud Scheduler `sessionm-bq-loader-scheduler-trigger`, 47 `LOAD` jobs, WRITE_TRUNCATE | **`55 3 * * *` America/Denver** | 03:56–04:01 |
  | 3. `staging.sm_*` → `sessionM.*` | BigQuery scheduled query "sessionM Daily Refresh" (DTS config `68b830ae-0000-26c9-896c-14c14eea4130`, runs as `bigquery-loader-sa`): full-load `create or replace` for the small tables, 15 `MERGE`s, then 40 `TRUNCATE`s of staging | **04:07 MT** (`every 24 hours`) | 04:07–04:14, 0 failures |

  The vendor finishes writing S3 between **09:03 and 09:30 UTC** (S3 mtimes preserved as GCS
  `customTime`, 40+ days checked), so step 1 must never start before ~09:40 UTC. Steps 2 and 3
  are on Denver time and shift an hour against step 1 at each DST change — still safe (in MST the
  transfer lands 02:45–02:50), but the gap between 1 and 2 grows to ~65 min rather than 5.

  **Downstream chain (all verified firing in this order on 2026-09-09):** SessionM merge 04:07 →
  `claude.loyalty_user` **04:30** → `order_customer` + `order_sequence` **full-history rebuild
  05:02–05:08** (`when run_hour = 5 then '2018-08-07'`, deployed 2026-09-08 in the combined
  `sql/sales_ops.order_marts.sql` config `6b28c7a5…`) → `customer_attribute` **05:20**
  (`attribute_asof_date = run_date - 1`, moved from 05:00 on 2026-09-08). The intraday branch is
  **today only** again (`when run_hour between 8 and 23 then run_date`, hours 0–4 and 6–7 exit
  via the `start_date is null` guard) — yesterday no longer depends on it, because the 05:02
  rebuild runs after the merge. The 2026-09-04 `run_date - 1` workaround is retired.

  **Regression signature, and how it happened (2026-09-05 → 09-08).** The transfer (step 1) and
  the merge (step 3) were moved to 03:45 / 03:50 but the loader (step 2) stayed at 05:20. Each
  morning the merge consumed the *previous* day's staging load, truncated it, and the 05:22 load
  then sat unmerged for 24 h: `sessionM.*` ran one file behind, on 09-05 every `MERGE` touched 0
  rows and the full-load tables (`privacy_requests` included) were rebuilt **empty**, and
  yesterday's `pct_sm_linked` read **0.0%** on 09-07 and 09-08 instead of ~31%. If yesterday reads
  under 15% after ~05:15 MT: (a) check the three steps' ORDER on `JOBS_BY_PROJECT`
  (`user_email like 'bigquery-loader-sa@%'`, group by `job_type, statement_type` — `LOAD` must
  precede `MERGE`; 0 inserted rows across all 15 merges = merge ran on empty staging), then (b)
  read the deployed `order_customer` job text. Staging ahead of `sessionM.*` on
  `date(transaction_date)` row counts is the one-query proof of a lag.

  **DTS scheduling trap:** with `every 24 hours`, editing only the start *time* of a scheduled
  query does not move the next run — the saved form showed 04:07 for four days while
  `nextRunTime` stayed 09:50Z. Re-saving with the start **date** moved to a future day re-anchors
  it. Always confirm with `nextRunTime` (console list column, or `GET transferConfigs/<id>`).

## Pulse orders feed outage 2026-09-15 → 09-22 (was a gotcha)

- **🔑 The Pulse orders feed can stop on its own while every other `pulse.*` table keeps loading**
  (observed 2026-09-15 05:51 MT → stalled through 09-21; **backfill merged 2026-09-22 07:57 MT**, 75,213 rows inserted into `pulse.orders` by a manual SA run of the old loader; marts heal on the 09-23 05:02 full-history run, `customer_attribute` healed the same morning (it fires at 05:20, after the 05:02 run finished at 05:07:35; job-log verified 2026-09-23); re-run the identified-% check before quoting identity figures for 09-15 onward). Settled-day identification fell from
  ~55% to ~14% because only the SessionM arm was left: 09-15 / 16 / 17 carried 4,072 / 4,063 / 4,051
  `sm_external_user_id` orders and 167 / 0 / 0 `pulse_order_id` orders; `order_source` was NULL on all
  but 167 of 87,606 orders, `is_guest_order` NULL everywhere, `is_catering` fine (Brink-side).
  Distinguish from the SessionM failure above by the columns: SessionM outage → `sm_external_user_id`
  ≈ 0, Pulse outage → `pulse_order_id` = 0. Root cause sat upstream of BigQuery: the compute SA
  loader (`286373888726-compute@developer.gserviceaccount.com`, nightly ~01:35 MT) ran the
  `orders_stg` LOAD + `orders` MERGE on 09-13/14/15 and then did not submit either job at all on
  09-16/17/18 (no `error_result`; 85 destination tables per night instead of 87), while
  `order_customers`, `order_items`, `customers` merged normally. (A separate, older failure in the
  same run — `customer_rewards_stg` parquet `discount_amount` INT32 type mismatch — fails every night
  and is unrelated.) Recovery is automatic: once `pulse.orders` is backfilled the 5am full-history
  reload re-identifies the gap days; verify with the daily `identified_pct` query and re-quote.

## Build-script notes

**2026-09-08:** the deployable text is now `sql/sales_ops.order_marts.sql` (section 1 of the chained query); `sql/sales_ops.order_customer.sql` is a retired pointer. The notes below describe CTEs that are unchanged in the chained script except where dated otherwise.

Migrated here 2026-08-17 when `sql/sales_ops.order_customer.sql` was cut down to the **deployable
console text, verbatim** (the convention set for `order_line_discount_detail` the same day). The
repo script now carries no prose, so a diff against the console shows real drift and nothing else.
That convention immediately earned itself: the repo copy of `sql/claude.order_customer.sql` had
silently drifted from the deployed view in two places (missing `store_id not in (1111, 999)`,
missing the `business_date` predicate on the `order_sequence` join), both in the safe direction,
both invisible until a redeploy was attempted from the repo copy.

- **`brink_order` dedupes the raw table.** `brink.brinkOrder` holds more than one row per order id;
  the build keeps one per `id` ordered by `insertionjob`. Never read `brinkOrder` without it.
- **`cust_trans` resolves identity before deduping** (rewritten 2026-07-29). The earlier two-stage
  shape picked one user per `transaction_id` by recency and only *then* checked whether that user
  resolved to a mapping, so resolvability was incidental to the ordering. Now the inner joins run
  first and the dedupe happens once, at `pos_transaction_key` — the grain the final SELECT joins on.
  Only resolvable users can win, structurally. Verified output-equivalent over 30 days (203,855 rows
  both ways, 0 links changed): a robustness change, not a recovery. Safe because
  `pos_transaction_key` ↔ `transaction_id` is 1:1 after `header_trans` (731,353 rows, 731,353
  distinct of each, 0 reuse).
- **`sm_external_user_map` partitions on the RAW `u.user_id` while selecting `lower(u.user_id)`.**
  Harmless today — the source is 100% lowercase — and `cust_trans`'s dedupe caps any fan-out.
  Partitioning on `lower(u.user_id)` would close it properly (Asana 1216995170178886). Its inner
  join to `sessionM.users` drops nothing: 0 of 1,782,178 `cafezupas` mapping rows lack a users row
  (verified 2026-07-27, re-verified 2026-07-29 with 0 null emails).
- **`pulse_orders` scoping is safe.** `po.business_date >= start_date` cannot orphan an in-window
  Brink order: verified across June 2026, of the 55 orders where pulse and Brink business dates
  disagree, pulse is always the **later** date (lag −1 to −42 days), never earlier.
- **Dead branches in the store-50 destination CASE (2026-08-17, cosmetic).** Both the
  `destination_id` and `destination` CASE expressions open with `when bo.FKStoreId = 50`, then
  repeat the same predicate in two further branches (`642414069` / `'Catering Online Delivery'`,
  `642414070` / `'Catering Online Takeout'`). The first branch always wins, so the other two are
  unreachable — confirmed in the data: all 808 store-50 orders in the trailing 30 days carry
  `999999999` / `'Middleton Mobile Catering'` and none carry the catering-online ids. **Store 50 has
  no delivery/takeout split.** Left in the repo because the repo mirrors the console; flagged to the
  steward 2026-08-17.
- **The fee proxy would not have worked anyway.** An earlier revision of this build split catering
  destinations into Delivery vs Takeout on `total_fees_amount > 0`. `total_fees_amount` counts any
  item whose name matches `\bfee\b`, and the live set is `CZ Fee`, `Service Fee`, `Delivery Fee`,
  `Catering Delivery Fee`. Measured 2026-08-17 over the trailing 30 days: **zero** catering orders
  carried a `Delivery Fee` or `Catering Delivery Fee` item — every "Delivery" classification came
  from a `Service Fee` or `CZ Fee`. It agreed with the real Brink destination ~99% of the time by
  correlation, not by construction, and would have flipped silently the first time fee configuration
  changed. Don't rebuild it on this proxy.
