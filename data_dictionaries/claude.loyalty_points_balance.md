# `claude.loyalty_points_balance`

**One row per member per active point account.** The authoritative current points balance — it reads SessionM's own account record rather than re-deriving from the ledger.

| | |
|---|---|
| Type | View (no partition column — 1.26M rows) |
| Grain | 1 row per `user_id` × `point_account_id` |
| Upstream | `sessionM.user_point_accounts`, `sessionM.point_accounts`, `claude.loyalty_user` |
| Build script | `sql/claude.loyalty_views.sql` |
| Created | 2026-07-28 |

## Columns

| Column | Type | Description |
|---|---|---|
| `user_id` | STRING | SessionM user id. Join key to other `loyalty_*` views |
| `sm_external_user_id` | INTEGER | Joins to `sales_ops.order_customer.sm_external_user_id` |
| `email` | STRING | |
| `point_account_name` | STRING | `Spendable Points` (individual) or `Catering Spendable Points`. Which **bucket the points sit in** |
| `point_account_id` | STRING | GUID of the point account |
| `current_balance` | FLOAT | **Canonical current balance.** Spendable points available now |
| `lifetime_points` | FLOAT | Lifetime points ever credited to this account |
| `points_used_or_expired_lifetime` | FLOAT | `lifetime_points - current_balance`. Combined spend + expiry; not separable here — use `loyalty_points_activity` to split |
| `member_program` | STRING | `individual` / `catering` / `both` / NULL, from the tier system |
| `catering_tier_name` | STRING | `Silver` / `Gold` / `Diamond`, catering members only |
| `registered_date` | DATE | Loyalty enrollment date |
| `account_created_date` | DATE | When the point account was created |
| `account_updated_date` | DATE | Last balance change |
| `is_account_rule_violation` | BOOLEAN | TRUE = this member holds **both** point accounts, which should never happen. 264 members |
| `is_duplicate_source_row` | BOOLEAN | TRUE = upstream had >1 row for this member/account pair; the view summed them. 9 pairs |

## Point accounts

Only the two active accounts are included. The inactive `[CATest]` and `[SMTest]` test accounts are excluded.

| `point_account_name` | Members with a balance | Total balance (2026-07-28) |
|---|---|---|
| `Spendable Points` | 1,215,375 | ~585.7M |
| `Catering Spendable Points` | 43,226 | ~12.9M |

Total outstanding points liability: **~597.2M points**.

## Gotchas

- **`point_account_name` ≠ `member_program`.** The account says which bucket the points are in; the program says which loyalty program the member belongs to. They agree for 99.8% of balance-holders but are not interchangeable — a catering *member* may hold no catering *account* until they earn points. Disagreements:

  | `member_program` | `point_account_name` | Members |
  |---|---|---|
  | `individual` | Spendable Points | 1,213,366 |
  | `catering` | Catering Spendable Points | 43,030 |
  | NULL (no tier) | Spendable Points | 1,750 |
  | `catering` | **Spendable Points** | 259 |
  | NULL (no tier) | Catering Spendable Points | 180 |
  | `individual` | **Catering Spendable Points** | 14 |
  | `both` | either | 3 |

- **A member should never hold both accounts — 264 do.** `is_account_rule_violation` flags them; only 11 have a nonzero balance in both. Exclude or call out rather than silently double-counting a member.
- **`current_balance` is authoritative; don't recompute it from the ledger.** `sum(point_modification)` on `loyalty_points_activity` matches for 99.8% of accounts but not all. If a number has to tie to what a guest sees in the app, use `current_balance`.
- **`current_balance` includes points that are past due but not yet swept.** SessionM sweeps monthly on the 1st, so between `expires_on` and the sweep the points still count. Cross-reference `loyalty_points_expiring.is_past_due_not_yet_swept`.
- **`lifetime_points` is credits only**, so `lifetime_points - current_balance` mixes redemptions, manual deductions, fraud clawbacks and expirations together. Split them with `loyalty_points_activity.activity_type`.
- Members with a *zero* balance still appear. Filter `current_balance > 0` for "members with points."

## Validation (2026-07-28)

- 1,257,412 user/account pairs; 1,258,602 rows after the active-account filter.
- Total `current_balance` 597,269,753 vs ledger `sum(point_modification)` 595,989,863 — a 0.21% gap, concentrated in the 0.2% of accounts where the two disagree.
- FIFO-derived `loyalty_points_expiring` totals reconcile to within 0.07%.

## Open items

- [ ] Explain the 0.2% of accounts where `current_balance` ≠ ledger net. Likely historical migrations (`Operator Migration Deposit` / `Deduct` reference notes).
- [ ] Consider a `points_expiring_next_30d` convenience column once the expiring view is proven in use.
