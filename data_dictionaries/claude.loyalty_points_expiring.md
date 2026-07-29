# `claude.loyalty_points_expiring`

**One row per member per expiry date.** Unspent points bucketed by the date they will expire, derived by FIFO-allocating debits against credit lots.

| | |
|---|---|
| Type | View (no partition column) |
| Grain | 1 row per `user_id` × `point_account_name` × `expires_on` |
| Upstream | `sessionM.user_point_transactions`, `sessionM.point_accounts`, `claude.loyalty_user` |
| Build script | `sql/claude.loyalty_views.sql` |
| Created | 2026-07-28 |

## Columns

| Column | Type | Description |
|---|---|---|
| `user_id` | STRING | SessionM user id |
| `sm_external_user_id` | INTEGER | Joins to `sales_ops.order_customer.sm_external_user_id` |
| `email` | STRING | |
| `point_account_name` | STRING | `Spendable Points` or `Catering Spendable Points` — determines which expiration rule applies |
| `expires_on` | DATE | **The business expiration date.** The last day the points are usable |
| `sessionm_sweep_date` | DATE | `expires_on + 1 day` — when SessionM's batch actually removes them |
| `days_until_expiry` | INTEGER | `expires_on` minus today (America/Denver). Negative = past due |
| `is_past_due_not_yet_swept` | BOOLEAN | TRUE = `expires_on` has passed but the sweep hasn't run. These points still count in `current_balance` |
| `points_expiring` | FLOAT | Points expiring on that date |
| `earliest_earned_date` | DATE | Oldest lot in the bucket |
| `latest_earned_date` | DATE | Newest lot in the bucket |
| `lot_count` | INTEGER | Number of credit lots rolled into the bucket |
| `member_program` | STRING | `individual` / `catering` / `both` / NULL |
| `catering_tier_name` | STRING | Catering members only |

## Expiration rules (steward, 2026-07-28)

| Account | Rule | `expires_on` |
|---|---|---|
| `Spendable Points` | One year from the **end of the month earned** | `date_add(last_day(earned_date, month), interval 1 year)` |
| `Catering Spendable Points` | Annually at **end of day November 30** | `date(year, 11, 30)`, rolling to the next year for December earnings |

A member earning on 2026-02-01 and one earning on 2026-02-28 **both** expire 2027-02-28.

**Validated:** lots earned 2025-04-02 and 2025-04-18 were both swept on 2026-05-01 — exactly `last_day(2025-04) + 1 year + 1 day`. Observed sweeps land on the 1st of the month for Spendable and 12-01 for Catering, matching the rule.

## How it's built (and why)

SessionM exposes **no per-lot expiration date**, so the view reconstructs lot survival:

1. Total all debits per member/account.
2. Order credit lots oldest-first, running a cumulative credit total.
3. Debits consume the oldest lots first (FIFO). A lot survives where its cumulative total exceeds total debits; the surviving amount is `least(lot_points, cumulative_credits - total_debits)`.
4. Apply the account's expiration rule to each surviving lot's earn date.

> **The stored `user_point_transactions.points_remaining` is NOT used and must not be.** Summed across credit lots it gives **628.6M** points against an actual balance of **595.9M** — a **32.7M (5.5%) overstatement**, because it isn't reliably decremented. `sum(point_modification)` reconciles (99.8% of accounts), which is what the FIFO runs on.

## Validation (2026-07-28)

| Check | Result |
|---|---|
| Per-member exact match to `current_balance` | **99.46%** (763,997 of 768,137) |
| Total expiring vs total balance | 596.79M vs 597.20M — **0.07%** gap |
| Members expiring without a balance row | 103 |
| Balance rows with no expiring row | 2,818 (zero-balance members) |

Forecast sanity check — projected monthly expirations (25–35M) track observed actuals (24–31M/month over the prior year).

## Gotchas

- **This is a forecast for future dates and a reconstruction for past ones.** It is not a SessionM-supplied field. If a number must match a guest-facing communication exactly, check what Braze was sent (`points_to_expire_EOM`).
- **`expires_on` vs `sessionm_sweep_date` — pick deliberately.** Points expiring "in July" by business rule are removed from the balance on August 1. Say which you mean.
- **Rows with `is_past_due_not_yet_swept = true` still count in `current_balance`.** Including them in "expiring soon" double-counts against a balance snapshot; excluding them understates what the member is about to lose. State the choice.
- **Catering buckets are lumpy by design** — every catering member's points land on a single Nov 30 date, so a "next 6 months" query shows one large catering row (16,737 members / 12.4M points for 2026-11-30) and smooth monthly individual rows.
- **The September spike is real, not a bug.** ~67.9M points across 242,802 members expire 2026-09-30 because September 2025 was an unusually large earning month (the `auto top-off` campaigns launched 2025-09-19).
- Members with a zero or fully-consumed balance produce no rows. Use a `left join` from `loyalty_points_balance` if you need every member.
- Full-scan cost is ~2 GB per query because the FIFO window function reads the whole ledger. Fine interactively; if you're running it repeatedly in a loop, materialize to `scratch` first.

## Open items

- [ ] Cross-check a sample against Braze's `points_to_expire_EOM` so guest-facing comms and internal reporting provably agree.
- [ ] Investigate the 103 members with expiring points but no balance row.
