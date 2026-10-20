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
| `debit_class` | STRING | **Added 2026-10-20.** Why a bitmask-2 debit happened: `reward_store_redemption` / `in_cart_redemption` / `earn_reversal_pos_refund` / `earn_reversal_void` / `fraud_clawback` / `migration_correction` / `batch_correction` / `test_entry` / `manual_support_deduction`. NULL on every non-debit row. See "Debit classification" |
| `is_reward_redemption` | BOOLEAN | **Added 2026-10-20.** `debit_class in ('reward_store_redemption', 'in_cart_redemption')`. Never NULL (false on non-debit rows) |
| `points_reward_redeemed` | FLOAT | **Added 2026-10-20.** `abs(points)` where `is_reward_redemption`, else 0. **This is the "points redeemed" measure**; `points_redeemed` is the older redeemed-or-deducted total kept for continuity |
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

## Debit classification (`debit_class`, added 2026-10-20)

Bitmask 2 is every debit that is not an expiration, so it mixes member redemptions with system reversals and manual corrections. `debit_class` separates them with closed rules applied in this precedence order (the view holds the SQL; the order matters because several classes carry a Pulse order id in `reference_id`):

| Precedence | `debit_class` | Rule | What it is |
|---|---|---|---|
| 1 | `reward_store_redemption` | `reference_note = 'REWARD_STORE'` | Member bought a reward in the app reward store. `reference_id` is a GUID that matches **none** of `user_offers.user_offers_id`, `offer_id` or `root_offer_id` (checked 2026-10-20), so it cannot be tied to the offer from this view; use `loyalty_offer_usage` for which reward |
| 2 | `earn_reversal_pos_refund` | `pos_transaction_id is not null` | SessionM reversing points it had **earned** on a POS transaction that was refunded. Notes are `INCENT.Outcomes`, `INCENT.Outcomes (Refund)`, `Behavior (Refund)`. Small (avg ~127 points) |
| 3 | `fraud_clawback` | note = `Account flagged for fraudulent activity` | Manual clawback on a flagged account |
| 4 | `migration_correction` | note = `Operator Migration Deduct` | Balance correction from the Punchh → SessionM migration (3,951 rows before FY2026, 325 in FY2026, still trickling) |
| 5 | `batch_correction` | note = `Catering Users Without Points Reset`, `End of Year Points Adjustments on …`, `Year End Adjustment` | Steward / vendor batch adjustments; the Oct–Nov 2025 end-of-year batch is 633 rows |
| 6 | `earn_reversal_void` | note starts `Order was voided in Brink` or contains `duplicate order` | System reversal of earned points after a void |
| 7 | `in_cart_redemption` | `reference_id` is a **7 or 8 digit** number | Pay-with-points at digital checkout. `reference_id` is the Pulse order id (98.9% match `pulse.orders.id`; the rest are since-deleted orders). **The note is the member's own name**, which is why name-based "agent" detection fails on this class |
| 8 | `test_entry` | note is `test`, `testing`, `tester`, `tst`, `teest`, `iiii`, `aa`, `as`, `asa`, `asas` (word-bounded) | Internal test accounts. Only 9 members in FY2026 but 202,813 points, enough to show in a monthly series |
| 9 | `manual_support_deduction` | everything else | Support-tool deductions: ticket reasons (`MISSING ITEMS`, `MADE WRONG`, `ORDER NOT DELIVERED`, `OTHER` …), agent names, `Manual Point Adjustment(Deduct)`, `Order refund NNN`, `Points were deducted against a refund issued (Order Id: N)`, `Too many points added`, point transfers between accounts |

Measured 2026-10-20 on the full ledger, Spendable + Catering accounts combined:

| `debit_class` | FY2026 (2025-10-01 → 2026-09-30) txns | points | share of debited points | All earlier history txns | points |
|---|---|---|---|---|---|
| `reward_store_redemption` | 398,111 | 282.7M | 62.03% | 425,709 | 336.4M |
| `in_cart_redemption` | 170,614 | 169.9M | 37.27% | 247,691 | 242.9M |
| `earn_reversal_pos_refund` | 8,390 | 1.07M | 0.23% | 10,096 | 1.58M |
| `fraud_clawback` | 280 | 578,772 | 0.13% | 214 | 564,407 |
| `migration_correction` | 325 | 439,729 | 0.10% | 3,951 | 3.73M |
| `manual_support_deduction` | 1,174 | 431,058 | 0.09% | 626 | 2.09M |
| `batch_correction` | 714 | 350,569 | 0.08% | 1 | 320 |
| `test_entry` | 47 | 202,813 | 0.04% | 458 | 862,051 |
| `earn_reversal_void` | 414 | 101,214 | 0.02% | 146 | 28,675 |

So **real redemptions are 99.3% of debited points in FY2026** and the four classes the compound name warned about (support, fraud, migration, batch) are 0.4% together. The split matters for counts, member lists and any month where a batch lands, not for the headline points figure.

Validation: June 2026 `in_cart_redemption` on the ledger = 15,189 debits / 14.80M points vs 11,477 `In-cart Points Redemption` discount lines / 14.48M points on `sales_ops.order_line_discount_detail` (stores 1111/999 excluded) — points agree within 2.3%; the row counts differ because a ledger debit is per order and a discount line is per item line. June 2026 Spendable `points_redeemed` = 38.55M (the 38.6M quoted above), of which 38.35M is `points_reward_redeemed`.

Rules for using it:

- **"Points redeemed" = `sum(points_reward_redeemed)`**, or `where is_reward_redemption`. Quote `points_redeemed` only as "redeemed or deducted".
- **Report the two redemption classes separately when asked how points are used**: reward store vs in-cart are different member behaviours (62/37 split by points in FY2026) and tie to different POS discount types (`Reward Redemption` vs `In-cart Points Redemption` on `order_line_discount_detail`).
- **`earn_reversal_*` are not deductions in the support sense**; they net against `points_issued`. For a clean "points earned" figure subtract them: `sum(points_issued) - sum(if(debit_class like 'earn_reversal%', points_removed, 0))`.
- **Exclude `test_entry`** from any member-facing or trend series; say so.
- **A month with `batch_correction` or `migration_correction` volume should be footnoted**, not smoothed away.
- The class list is closed as of 2026-10-20 but the support tool is free text; a new note that matches no rule lands in `manual_support_deduction`, which is the safe default. If a new systematic note appears (hundreds of rows, one wording), log a `KB finding:` so the rule list can grow.
- **`point_offer_mapper` is not the path and never was.** 489,074 of its 489,075 `point_transaction_id`s do not exist in `user_point_transactions` (max `etl_timestamp` 2026-10-20, so it is being loaded; its ids simply belong to another id space). The earlier open item pointing at it is closed.

## Gotchas

- **`reference_note` is free text, not a category.** It contains campaign names (`July Protein Stacking Challenge`, `lsm_100_points`), support-agent personal names (`Meaghan Muise`, `Steve Orgill`), and ticket reasons (`MISSING ITEMS`, `MADE WRONG`, `ORDERED FROM WRONG LOCATION`, `Due to a duplicate order incident at the POS, the order has been voided.`). Hundreds of unstable distinct values. **Never `group by` it as a category and never filter on it to classify a transaction** — use `activity_type`. It's useful for reading individual transactions and for finding campaign-attributed points ad hoc.
- **`redeemed_or_deducted` is deliberately a compound name.** Bitmask 2 mixes member redemptions with system earn reversals, fraud clawbacks, migration and batch corrections, test entries and manual support deductions. Since 2026-10-20 `debit_class` separates them: use `points_reward_redeemed` for redemptions and keep `points_redeemed` for the all-debits total. **Correction (2026-10-20):** an earlier version of this note listed "profile-update corrections" as a bitmask-2 class. Notes like `Alex Update Profile` are in-cart redemptions by members whose last name is literally the placeholder `Update Profile` (2,150 of 2,551 such rows still carry it in `sessionM.users`; the rest renamed since) — the note on an in-cart debit is the member's name. There is no profile-update deduction class.
- **`amount_spent` and `amount_expired` are not exposed** because they're unreliable: `amount_expired` sums to only 142,918 over a 13-month window against 354M of actual expiration debits. Use the bitmask-4 debits instead.
- **Filter on `activity_date`, not `etl_create_date`.** They usually agree but `etl_create_date` is the load partition and drifts on backfills.
- Bitmask 4 (`expired`) appears only in monthly batches — on the 1st for Spendable, 12-01 for Catering. A daily expiration series will be all zeros with monthly spikes. That's correct, not a gap.
- `point_sources` has only 8 rows and `point_source_name` is frequently NULL. Low value; don't build reporting on it.
- Only active point accounts are included; `[CATest]`/`[SMTest]` are excluded.

## Open items

- [x] Split bitmask 2 into true redemptions vs manual adjustments — **done 2026-10-20** as `debit_class` (see above). `point_offer_mapper` was checked and is unusable (its ids are not in the ledger).
- [ ] Identify what the `REWARD_STORE` GUID in `reference_id` keys to; it is not `user_offers_id`, `offer_id` or `root_offer_id`. Not blocking: `loyalty_offer_usage.points_spent` already answers "which reward".
- [ ] Confirm what bitmask 16 represents (43 transactions, 707 points — trivial volume, currently labelled `issued_adjustment` as a guess).
