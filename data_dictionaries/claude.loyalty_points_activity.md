# `claude.loyalty_points_activity`

**One row per point transaction.** The points ledger — issued, redeemed, expired, adjusted — with each transaction classified.

| | |
|---|---|
| Type | View |
| Grain | 1 row per `sessionM.user_point_transactions.point_transaction_id` (~11.6M rows) |
| Upstream | `sessionM.user_point_transactions`, `sessionM.point_accounts`, `sessionM.point_sources`, `claude.loyalty_user` |
| Build script | `sql/claude.loyalty_views.sql` |
| Created | 2026-07-28 |

## Columns

| Column | Type | Description |
|---|---|---|
| `point_transaction_id` | STRING | Primary key (GUID) |
| `user_id` | STRING | SessionM user id |
| `sm_external_user_id` | INTEGER | Joins to `sales_ops.order_customer.sm_external_user_id` |
| `email` | STRING | |
| `point_account_name` | STRING | `Spendable Points` or `Catering Spendable Points` |
| `point_account_id` | STRING | |
| `activity_date` | DATE | **Business date of the transaction** (from `time_of_occurrence`). Filter and group on this |
| `time_of_occurrence` | TIMESTAMP | Full timestamp |
| `etl_create_date` | DATE | Upstream **load** partition (`create_date`). Not the business date — don't report on it |
| `activity_type` | STRING | `issued` / `redeemed_or_deducted` / `expired` / `issued_adjustment` / `unknown` |
| `audit_type_bitmask` | INTEGER | Raw classifier: 1 / 2 / 4 / 16 |
| `points` | FLOAT | Signed change. Positive = credit, negative = debit |
| `points_issued` | FLOAT | `points` when positive, else 0 |
| `points_removed` | FLOAT | `abs(points)` when negative, else 0 — all debits regardless of reason |
| `points_redeemed` | FLOAT | `abs(points)` where `audit_type_bitmask = 2`, else 0 |
| `points_expired` | FLOAT | `abs(points)` where `audit_type_bitmask = 4`, else 0 |
| `reference_note` | STRING | **Free text**, from `reference_type`. See gotchas — never treat as an enum |
| `reference_id` | STRING | Upstream reference key |
| `pos_transaction_id` | STRING | Brink/POS transaction id when the points came from a purchase |
| `point_source_name` | STRING | From `point_sources` (8 rows) |
| `member_program` | STRING | `individual` / `catering` / `both` / NULL |
| `catering_tier_name` | STRING | Catering members only |

## `activity_type` classification

`audit_type_bitmask` is the **only** reliable classifier:

| Bitmask | `activity_type` | Sign | Volume (Jun–Jul 2026) |
|---|---|---|---|
| 1 | `issued` | positive | 531,963 txns / +136.4M |
| 2 | `redeemed_or_deducted` | negative | 89,886 txns / −68.8M |
| 4 | `expired` | negative | 159,199 txns / −52.3M |
| 16 | `issued_adjustment` | positive | 43 txns / +707 |

Recent monthly shape (Spendable Points):

| Month | Issued | Redeemed | Expired | Active members |
|---|---|---|---|---|
| 2026-05 | 75.4M | 39.1M | 28.2M | 258,709 |
| 2026-06 | 75.6M | 38.6M | 28.0M | 254,285 |

## Gotchas

- **`reference_note` is free text, not a category.** It contains campaign names (`July Protein Stacking Challenge`, `lsm_100_points`), support-agent personal names (`Meaghan Muise`, `Steve Orgill`), and ticket reasons (`MISSING ITEMS`, `MADE WRONG`, `ORDERED FROM WRONG LOCATION`, `Due to a duplicate order incident at the POS, the order has been voided.`). Hundreds of unstable distinct values. **Never `group by` it as a category and never filter on it to classify a transaction** — use `activity_type`. It's useful for reading individual transactions and for finding campaign-attributed points ad hoc.
- **`redeemed_or_deducted` is deliberately a compound name.** Bitmask 2 mixes genuine reward redemptions with manual support deductions, profile-update corrections, fraud clawbacks (`Account flagged for fraudulent activity`) and migration deducts. Do **not** report `points_redeemed` as "reward redemptions" without saying so. For reward-specific redemption, use `loyalty_offer_usage.points_spent`.
- **`amount_spent` and `amount_expired` are not exposed** because they're unreliable: `amount_expired` sums to only 142,918 over a 13-month window against 354M of actual expiration debits. Use the bitmask-4 debits instead.
- **Filter on `activity_date`, not `etl_create_date`.** They usually agree but `etl_create_date` is the load partition and drifts on backfills.
- Bitmask 4 (`expired`) appears only in monthly batches — on the 1st for Spendable, 12-01 for Catering. A daily expiration series will be all zeros with monthly spikes. That's correct, not a gap.
- `point_sources` has only 8 rows and `point_source_name` is frequently NULL. Low value; don't build reporting on it.
- Only active point accounts are included; `[CATest]`/`[SMTest]` are excluded.

## Open items

- [ ] Split bitmask 2 into true redemptions vs manual adjustments. `point_offer_mapper` (`user_offers_id` → `point_transaction_id`) is the likely path but its coverage is unverified.
- [ ] Confirm what bitmask 16 represents (43 transactions, 707 points — trivial volume, currently labelled `issued_adjustment` as a guess).
