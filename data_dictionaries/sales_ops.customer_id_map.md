# Data Dictionary: `marketing-data-442316.sales_ops.customer_id_map`

> ## 🚧 DRAFT — NOT DEPLOYED (2026-07-28)
>
> No table and no scheduled query exist. The build script is at
> `sql/sales_ops.customer_id_map.sql`; the strategy it implements is
> `design/crm_identity_hygiene_plan.md`. The SELECT logic has been validated against live
> data (see Validation) but nothing has been written and **no Braze profile has been
> touched**. Do not answer customer-count questions from this table until this banner is gone.

**One row per `mapped_cust_id` ever seen** (person only). Maps each source customer id to the
single canonical id that represents that human. This is the deduplication layer — without it
every customer count, frequency, repeat-rate and LTV number is inflated by ~7%.

Three companion tables:

| Table | Purpose |
|---|---|
| `sales_ops.customer_id_map_history` | Append-only lineage. Every `cust_id → canonical_cust_id` assignment with `valid_from` / `valid_to`. **This is what guarantees we never lose that 124 was mapped to 123.** |
| `sales_ops.braze_identity_action_log` | Every Braze API call attempt: action, payload, HTTP status, response, attempt #. |
| `sales_ops.braze_uuid_profile_map` | UUID-keyed Braze `external_id`s and the integer id they resolve to. |

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per `cust_id` where `customer_type = 'person'` |
| Expected rows | **1,373,206** → resolving to **1,275,485** canonical ids (validated 2026-07-28) |
| Partitioned by | none — 1.4M-row dimension |
| Clustered by | `cust_id`, `canonical_cust_id` |
| Refresh | Daily **incremental MERGE** at 05:30 MT, after the 04:00 `order_customer` reload. **Never `create or replace`** — see below. |
| Upstream | `sales_ops.order_customer` only |
| Downstream | `claude` views, `sales_ops.customer_attribute`, the Braze identity worker |

## Why incremental MERGE and not a full rebuild

`customer_attribute` is a deliberate full daily rebuild because it holds *derived measures*.
This table holds *decisions already executed against an external system*. A canonical id that
has been acted on in Braze is a published fact — Braze merges are irreversible, so if the
canonical id drifts between builds we fire contradictory merges and cannot walk them back.
**Do not convert this to a `create or replace`.**

## Columns

### Mapping
| Column | Type | Description |
|---|---|---|
| `cust_id` | INT64 | Source `mapped_cust_id`. Primary key. |
| `canonical_cust_id` | INT64 | The surviving id. **Always itself a canonical row** — chains are resolved recursively at build. |
| `is_canonical` | BOOL | `cust_id = canonical_cust_id`. Singletons are TRUE. |
| `match_key` | STRING | `'email'` or `'singleton'`. |
| `match_email` | STRING | Normalized email (`lower(trim())`) that formed the cluster. |
| `cluster_size` | INT64 | Ids resolving to this `canonical_cust_id`. |
| `survivor_reason` | STRING | `'earliest_first_order'`, `'sticky_existing_canonical'`, `'singleton'`. |

### Facts used to elect the survivor
| Column | Type | Description |
|---|---|---|
| `first_order_date` | DATE | Earliest `business_date` on this `cust_id`. The survivor rule. |
| `last_order_date` | DATE | Latest `business_date`. |
| `lifetime_orders` | INT64 | Distinct `brink_order_id`, store 1111 excluded, catering included. |

### Braze + audit
| Column | Type | Description |
|---|---|---|
| `braze_state` | STRING | `'pending'`, `'renamed'`, `'merged_away'`, `'not_required'`, `'failed'`. Maintained by the worker, not the build. |
| `braze_state_at` | TIMESTAMP | When `braze_state` last changed. |
| `map_version` | INT64 | Increments each time `canonical_cust_id` changes for this id. Carried on queue rows for idempotency. |
| `first_mapped_at` / `mapping_changed_at` / `updated_at` | TIMESTAMP | Entered the map / mapping last changed / last build touch. |

## Canonical rules (use verbatim — do not invent alternates)

- **Match key is normalized email only:** `lower(trim(mapped_email))`, taking each id's most
  recent non-null email ordered by `order_datetime desc, brink_order_id desc` (same tie-break
  as `order_sequence` and `customer_attribute`, so all three agree on "most recent").
- **No** Gmail dot-stripping, `+tag` removal, domain aliasing, phone matching, or name fuzzing
  in tier 1. Phone is a review queue, never an auto-merge key — households share numbers and a
  bad Braze merge is unrecoverable.
- **Survivor:** earliest `first_order_date`, tie-break lowest `cust_id`.
- **Sticky:** an existing canonical always wins over a fresh election. New ids join the
  existing cluster regardless of dates.
- **Cluster collision** (an id's latest email changes into another cluster): older canonical
  wins, loser's whole cluster is re-pointed, history reason `'cluster_absorbed'`.
- **`braze_state = 'merged_away'` blocks promotion.** Once Braze has collapsed an id into
  someone else it can never become canonical again.

## How to use it

```sql
-- Correct: customer counts on the canonical id
select count(distinct coalesce(m.canonical_cust_id, oc.mapped_cust_id)) as customers
from `marketing-data-442316.sales_ops.order_customer` oc
left join `marketing-data-442316.sales_ops.customer_id_map` m on m.cust_id = oc.mapped_cust_id
where oc.business_date between '2026-06-01' and '2026-06-30'
  and oc.store_id <> 1111
  and oc.customer_type = 'person';
```

Or read `sales_ops.v_order_customer_canonical`, which is `order_customer` plus a
`canonical_cust_id` column.

## Validation (2026-07-28, first-run SELECT body against live data)

`business_date` 2023-03-01 → 2026-07-25, `store_id <> 1111`, `customer_type = 'person'`,
`mapped_cust_id is not null`:

| Check | Result |
|---|---|
| Rows / distinct `cust_id` | 1,373,206 / 1,373,206 (no fan-out) ✅ |
| Canonical + loser = total | 1,275,485 + 97,721 = 1,373,206 ✅ |
| Distinct `canonical_cust_id` = canonical rows | 1,275,485 ✅ |
| Emails with >1 canonical (split clusters) | 0 ✅ |
| Ids pointing at a non-canonical id (chains) | 0 ✅ |
| Independent duplicate count (separate query) | 73,037 clusters / 97,721 surplus ids ✅ agrees |

Braze action split over the 97,721 surplus ids: **54,469 rename**, **5,869 merge**,
37,383 no action. See the design doc §7.2.

## Gotchas

- **NOT DEPLOYED.** A commit to this repo creates neither the table nor the scheduled query.
- **Braze merges are invisible in `braze.*`.** Braze documents that merges are not reflected
  in Currents, and `braze.*` comes from Currents. `braze.email_open` and friends will carry the
  loser's `external_user_id` **forever**. Any engagement query must join through this table to
  roll up to the canonical id. This is the whole reason the lineage lives in BigQuery.
- **Braze merge does not recompute custom attributes** — the target keeps its own values and
  only gains ones it was missing. The attribute export must re-push any canonical id whose
  cluster changed, or the survivor keeps stale values.
- **`customer_attribute` currently aggregates on `mapped_cust_id`**, so until it is repointed at
  `canonical_cust_id` its customer-level rows are still duplicated.
- **`order_customer` does not and must not join this table** — the map is derived from it, so
  that would be circular. Canonicalization is a layer up.
- **The emailless-singleton branch is currently dead code.** Verified 2026-07-28: across
  2025-06 → 2026-07 there are **zero** person orders with a NULL `mapped_email`, because
  `customer_type` is itself derived by matching the order's email. It is kept as a safety net.
  Note this contradicts the "844 customers with no `mapped_email`" figure in
  `sales_ops.customer_attribute.md` — **reconcile before deploy** (likely a pre-2025 cohort or
  a difference in the email fallback).
- **The `order_customer` grain defect** (`brink_order_id` 2279778269187 has two rows, two
  different customers) means one cluster may be slightly wrong until the next full rebuild.
  `lifetime_orders` uses `count(distinct brink_order_id)` to blunt it.
- **Window starts 2023-03-01.** Customer identity capture effectively begins 2023-03-06; there
  are no person customers with a first order before then.
