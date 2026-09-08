# Data Dictionary: `marketing-data-442316.sales_ops.cust_map`

**One row per distinct order email.** Resolves the address a guest typed on a digital order to a Pulse customer account. Steward-owned identity helper, **not a reporting table** — it exists to feed `sales_ops.order_sequence.mapped_cust_id` (see that dictionary for the seven-branch coalesce that consumes it). Documented 2026-09-08 from the deployed scheduled-query text; the steward's design notes are not yet written up.

## Table facts

| Property | Value |
|---|---|
| Grain | 1 row per `email` (lower-trimmed order email) |
| Partitioned by | — (not partitioned; small) |
| Clustered by | `email`, `acct_email`, `max_acct_id`, `final_acct_id` |
| Refresh | Scheduled query, `create or replace`, daily **04:00 America/Denver** — an hour before the 5am full-history refresh of the order marts that reads it |
| Source build script | `sql/sales_ops.cust_map.sql` (verbatim deployed text) |
| Upstream | `pulse.orders`, `pulse.order_customers`, `pulse.customers` — **non-catering only** (`is_catering = false` on both `pulse.orders` and `pulse.customers`); catering identity is resolved separately in `order_sequence` (branch 2) |
| Access | `sales_ops` — steward only. Standard users never need it; its output reaches them through `claude.order_customer.mapped_cust_id` |

## Columns

| Column | Type | Description |
|---|---|---|
| `email` | STRING | `lower(trim(pulse.order_customers.email))` — the ORDER email. Join key from `order_customer.email` (and, separately, from `order_customer.sm_email`). Rows whose order email is a system address (`%@guest.doordash.com`, `%@itsacheckmate.com`, `support@doordash.com`, `%outdoor%@cafezupas.com`) are excluded from the order-derived half of the map. |
| `acct_email` | STRING | The Pulse **account** email associated with that order email: the account on the most recent order carrying it (preferring non-system accounts, then accounts that have an email), falling back to a `pulse.customers` row whose own email equals the order email. |
| `max_acct_id` | INTEGER | `max(pulse.orders.customer_id)` over every order that carried this order email. Used for **guest checkouts** (`order_sequence` branch 3) — a guest order is attributed to the highest customer id ever seen with that address. NULL when the email only exists as an account email with no orders. |
| `final_acct_id` | INTEGER | The `pulse.customers.id` whose email equals `acct_email` (highest id wins on duplicate emails), else the customer whose email equals the order `email`. Used when the order email is a person's but the order's account is a system account (branch 5), and for SessionM-email resolution (branch 6). |

## How it is built (deployed text, `sql/sales_ops.cust_map.sql`)

Two candidate sets are unioned and the winner per `email` is chosen by `priority`:

1. **priority 1 — `cust_final`:** every non-catering `pulse.customers` row with an email, deduped to the highest `id` per `lower(trim(email))`. `acct_email = email`, `acct_id = id`.
2. **priority 2 — `map_orders`:** every non-catering digital order (`pulse.orders` deduped to the latest `id` per `brink_order_id`, `brink_order_id > 0`) joined to its `pulse.order_customers` row and account; system order emails dropped; one row per order email ordered by `is_sys_acct_email asc, has_acct_email desc, created_at desc`; `max_acct_id` windowed over the email.

So an address that is itself an account email resolves to that account; an address only ever typed on orders resolves to the account most recently behind it. The final select then looks `acct_email` up in `cust_final` again to produce `final_acct_id`, falling back to the order email's own account.

## Gotchas

- **Steward table.** Do not query it to answer business questions; read identity off `claude.order_customer` (`mapped_cust_id`, `customer_type`) instead.
- **Non-catering only by construction.** A catering account's email will not appear unless it also placed non-catering orders. `order_sequence` handles catering identity before it consults this table.
- **`max_acct_id` is a heuristic** ("highest id ever seen with this address"), chosen by the steward for guest checkouts, where Pulse mints a new customer id per order (see `design/crm_identity_hygiene_plan.md`). It is not a merge decision and can move day to day as new guest orders arrive.
- **Timing.** 04:00 build, consumed by the 05:00 full refresh of the order marts. A same-day intraday run of the marts uses the map as of 04:00.
- **Relationship to `sales_ops.customer_id_map`:** that table (DRAFT, not deployed, `sql/sales_ops.customer_id_map.sql`) was the 2026-07-28 design for a sticky canonical-id crosswalk. `cust_map` is the steward's shipped, non-sticky, email-keyed alternative. The two are not reconciled in the KB yet.
