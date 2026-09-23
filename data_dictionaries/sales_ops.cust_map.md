# Data Dictionary: `marketing-data-442316.sales_ops.cust_map`

> # ⚠️ Will fail at its next run (04:15 MT 2026-09-24) unless the config is patched — pulse types changed 2026-09-23
>
> The deployed build compares `pulse.orders.is_catering = false`, `pulse.customers.is_catering = false` and `oc.is_loyalty_user = true`. All three raw columns became **INT64 (0/1)** in the 2026-09-23 Pulse feed reload (landed between 07:02 and 08:02 MT, after this table's 04:15 run had already succeeded). A dry run of the deployed body against the new schema fails with `No matching signature for operator = for argument types: INT64, BOOL`. Because the build is `create or replace`, a failed run leaves the **previous day's table** in place, so the 05:00 order marts keep running on a one-day-stale identity map until the fix lands. Required edits (three lines): `po.is_catering = 0`, `c.is_catering = 0`, `o.is_loyalty_user = 1`. `sql/sales_ops.cust_map.sql` holds the deployed (unpatched) text on purpose — the repo mirrors production; patch the console config first, then sync.

**One row per distinct email.** Resolves an email address (the one a guest typed on a digital order, or the one on a Pulse account) to **one** Pulse customer id, `acct_id`. Steward-owned identity helper, **not a reporting table** — it exists to feed `sales_ops.order_sequence.mapped_cust_id` (see that dictionary for the five-branch coalesce that consumes it). Rewritten by the steward 2026-09-09 ("v2": three explicit tiers, single `acct_id`); the repo caught up with the deployed text 2026-09-23.

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per `email` (lower-trimmed) |
| Partitioned by | — (not partitioned; ~1.85M rows / ~200 MB) |
| Clustered by | `email`, `acct_id` |
| Refresh | Scheduled query, `create or replace`, daily **04:15 America/Denver** — before the 5am full-history refresh of the order marts that reads it |
| Source build script | `sql/sales_ops.cust_map.sql` (verbatim deployed text, synced 2026-09-23) |
| Upstream | `pulse.orders`, `pulse.order_customers`, `pulse.customers` — **non-catering only** (`is_catering` filter on both `pulse.orders` and `pulse.customers`); catering identity is resolved separately in `order_sequence` (branch 1) |
| Access | `sales_ops` — steward only. Standard users never need it; its output reaches them through `claude.order_customer.mapped_cust_id` |

## Columns

| Column | Type | Description |
|---|---|---|
| `email` | STRING | `lower(trim(...))` of either a `pulse.order_customers.email` (order email) or a `pulse.customers.email` (account email). Join key from `order_customer.email`, `order_customer.acct_email` and `order_customer.sm_email` — `order_sequence` joins the table three times. System order emails (`%@guest.doordash.com`, `%@itsacheckmate.com`, `support@doordash.com`, `%outdoor%@cafezupas.com`) are excluded from the order-derived tiers; system account emails (`checkmate_user@cafezupas.com`, `%outdoor%@cafezupas.com`) are excluded from tiers 1 and 2. |
| `acct_id` | INTEGER | **The answer.** The one Pulse customer id this email resolves to: `coalesce(tier1, tier2, tier3)` below. Never NULL (rows with no resolution are dropped). |
| `acct_email` | STRING | The Pulse account email behind `acct_id` (from the winning tier; tier 3 looks the customer up in `pulse.customers`). NULL when the tier-3 customer has no account row. |
| `map_source` | STRING | Which tier won: `authenticated_order`, `account_email`, `order_max`. Use it to reason about mapping quality. |
| `auth_acct_id_count` | INTEGER | Tier 1 diagnostic: how many distinct accounts ever authenticated on an order carrying this email. >1 means the same address was typed on orders by more than one signed-in account. NULL when tier 1 did not fire. |
| `acct_by_email_id` | INTEGER | Tier 2 candidate (the account whose own email is this address), whether or not it won. |
| `order_max_cust_id` | INTEGER | Tier 3 candidate (`max(customer_id)` over the email's orders), whether or not it won. |
| `order_count` | INTEGER | Number of non-catering digital orders carrying this email. NULL for account-only emails. |
| `max_acct_id` | INTEGER | **Deprecated alias of `acct_id`** (identical value). Kept until nothing downstream reads it; `order_sequence` has read `acct_id` since 2026-09-09. |
| `final_acct_id` | INTEGER | **Deprecated alias of `acct_id`** (identical value). Same status as `max_acct_id`. |

## How it is built (deployed text, `sql/sales_ops.cust_map.sql`)

Three tiers, first non-null wins, per `email`:

1. **`authenticated_order`** — an account that was **signed in** (`is_loyalty_user`) on an order carrying this email, non-system account only. Tiebreak: an order whose account email equals the order email first, then the latest order, then the highest customer id. This is the tier the 2026-09-09 rewrite added, so a guest checkout lands on the account the same person later (or earlier) signed in with, even when that account's `pulse.customers.email` is a different address.
2. **`account_email`** — a `pulse.customers` row whose own email is this address (live row preferred, then highest id), whether or not it ever ordered.
3. **`order_max`** — the highest `customer_id` on the email's orders. Guest-only emails end here, where Pulse mints a new customer id per guest order, so this tier is a heuristic and can move as new guest orders arrive.

The email universe is the union of every non-system order email and every non-system account email; a row is kept only when some tier resolved.

## Gotchas

- **Steward table.** Do not query it to answer business questions; read identity off `claude.order_customer` (`mapped_cust_id`, `customer_type`) instead.
- **Non-catering only by construction.** A catering account's email will not appear unless it also placed non-catering orders. `order_sequence` handles catering identity before it consults this table.
- **`map_source = 'order_max'` is a heuristic** ("highest id ever seen with this address"), chosen by the steward for guest checkouts (see `design/crm_identity_hygiene_plan.md`). It is not a merge decision.
- **Deployed vs proposed text differ by one tiebreak.** `sql/analysis/sales_ops.cust_map_v2_proposed.sql` (untracked working file) orders tier 1 by `created_at desc` only; production adds `o.acct_email = o.email desc` in front. Production is canonical.
- **Timing.** 04:15 build, consumed by the 05:00 full refresh of the order marts. A same-day intraday run of the marts uses the map as of 04:15.
- **Type fragility (2026-09-23).** See the header. Any raw Pulse boolean this build touches is now INT64.
