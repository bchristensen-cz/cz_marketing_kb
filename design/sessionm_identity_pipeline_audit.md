# Audit: SessionM identity pipeline into `sales_ops.order_customer`

**Date:** 2026-07-29 · **Scope:** the six `sessionM.*` tables feeding `sm_external_user_id`
(and therefore `mapped_cust_id`) in `sql/sales_ops.order_customer.sql`.

Chain under audit: `user_point_transactions` + `transaction_discounts` +
`transaction_payments` → `all_trans_users` → `user_trans` → joined to
`transaction_headers` (`header_trans`) and `external_user_mappings` ⨝ `users`
(`sm_external_user_map`) → `cust_trans` → `order_customer.sm_external_user_id`.

## Re-verification after the 2026-07-29 full-history rebuild ✅

Brent deployed the `>=` fix plus `lower()` normalization throughout and rebuilt the whole table.
Re-audited post-rebuild — **everything verified clean:**

| Check | Result |
|---|---|
| SessionM link rate, every business day 7/15–7/28 | **28.2 – 31.7%** — all healthy, no residual bad days |
| Monthly link rate, 2025-08 → 2026-07 | **30.4 – 33.6%** — no gaps anywhere in history |
| `mapped_email` / `email` / `mapped_email_domain` not lowercase | **0 / 0 / 0** |
| `distinct mapped_email` vs `distinct lower(mapped_email)` | **1,029,384 = 1,029,384** — the 17,943 phantom identities are gone |
| **Grain: total rows vs distinct `brink_order_id`** | **50,315,908 = 50,315,908 — 0 duplicates.** The long-standing pulse fan-out defect is resolved |
| Null `business_date` / `net_sales` / `store_id` | 0 / 0 / 0 |
| History span | 2018-08-07 → 2026-07-29, continuous |
| `customer_type` drift from the case-insensitive aggregator change | **None** — person +441, aggregator +2, both from new orders. Reclassified nothing, exactly as predicted. The change was purely defensive |
| Fan-out risk from `lower(u.user_id)` with a raw-partitioned QUALIFY | **None** — `external_user_mappings.user_id` is already 100% lowercase, so `lower()` is a no-op and 0 duplicate lowered keys survive |

Fixes applied in that deploy: `create_date >= start_date`; `lower()` on `user_id` in all three
`all_trans_users` branches and in `sm_external_user_map`; `lower()` on `mapped_email`, `email`,
`cust_trans.email`; and all five `customer_type` branches normalized to lowercase comparison.

**Resolved by this deploy:** findings #1 (boundary day) and #3 (casing asymmetry), plus the
`pulse.orders` grain defect. **Still open:** #4 (`user_trans` tiebreak ignores resolvability),
#5 (ambiguous multi-external-id mappings), #6 (`header_trans` dedupe partitions on the raw key).

### ⚠️ Two doc/code mismatches introduced or left in the deployed script

1. **`order_sequence`'s header comment now contradicts its code.** The comment claims
   *"Restricted to `customer_type = 'person'`"*, but the SQL filters only
   `mapped_cust_id is not null`. Verified: the table holds 2,517,397 aggregator rows, 785,364
   kiosk, 23,684 internal — and `lifetime_customer_order_count` reaches **2,494,884 on `person`
   rows**. A reader who trusts the comment skips the mandatory filter *and* believes the
   lifetime counts are per-person. Both wrong. **Fix the comment, not the code** — the code
   matches the 2026-07-27 steward decision.
2. **Pulse tiebreak direction was mis-documented.** Deployed code is
   `order by po.id desc` — **highest** pulse id wins. `sales_ops.order_customer.md` said
   "lowest pulse id wins". Dictionary corrected 2026-07-29.

### Residual structural note

`sm_external_user_map` now selects `lower(u.user_id)` while its QUALIFY still partitions on the
**raw** `u.user_id`. Harmless today (source is 100% lowercase) but it is the same latent shape as
finding #6: if SessionM ever emits a mixed-case `user_id`, two rows would survive the dedupe with
identical lowered keys and `cust_trans` would fan out, duplicating orders. Partitioning on the
lowered value would close it permanently.

---

## Original audit (pre-fix, 2026-07-29)

## Verdict

**Data is flowing correctly.** The boundary-day defect is fixed and confirmed. Three
lower-severity issues remain, all quantified below; the largest costs ~155 loyalty links per
month, versus the ~7,900/day the fixed bug was costing.

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | `create_date > start_date` dropped the reload boundary day | 🔴 was critical | ✅ **FIXED & verified** |
| 2 | `lower()` applied to only one of three union branches | 🟡 minor | Open — one-line fix |
| 3 | `user_trans` tiebreak can pick a non-resolving row over a resolving one | 🟡 minor | Open |
| 4 | 6,095 `user_id`s carry multiple `external_user_id`s; winner can flip between runs | 🟡 minor | Open — causes silent customer migration |
| 5 | `header_trans` QUALIFY dedupe is currently a no-op | ⚪ informational | Note only |
| — | `transaction_id` casing across all four tables | ✅ verified | Uniformly uppercase — do **not** normalise |
| — | `user_point_transactions.transaction_id` 23.5% NULL | ✅ verified | Non-purchase point activity; correctly excluded |

## 1. Boundary-day defect — FIXED AND VERIFIED ✅

The `>` → `>=` change on `header_trans.create_date` is deployed and the previously corrupted
dates are fully repaired. The repaired counts match the pre-fix reproduction **exactly**,
which confirms the diagnosis rather than merely improving the numbers:

| `business_date` | Before fix | Predicted with `>=` | After fix | Match |
|---|---|---|---|---|
| 2026-07-21 | 0 | 7,927 | **7,927** | ✅ exact |
| 2026-07-27 | 74 | 7,657 | **7,657** | ✅ exact |
| 2026-07-28 | 0 | 7,868 | **7,868** | ✅ exact |

`pct_sm_linked` is now 28.2–30.9% on every business day 7/18–7/28 — inside the healthy band.

**This also resolved the intraday-run symptom**, which had looked like a second independent
defect. It was the same predicate: an intraday run sets `start_date = run_date`, so
`create_date > start_date` matched nothing and wrote today with zero identity. `>=` fixes both.
No separate fix is needed.

## 2. Freshness and volume — all six tables healthy

| Table | Rows | Max updated (UTC) | Note |
|---|---|---|---|
| `transaction_headers` | 26,869,486 | 2026-07-29 09:01:31 | Current |
| `transaction_payments` | 26,683,604 | 2026-07-29 09:01:31 | Current |
| `user_point_transactions` | 11,607,161 | 2026-07-29 09:01:31 | Current |
| `transaction_discounts` | 1,736,092 | 2026-07-29 09:01:07 | Current |
| `external_user_mappings` | 3,115,403 | 2026-07-29 07:57:04 | Current (1,782,178 are `cafezupas`) |
| `users` | 1,775,708 | 2026-07-29 00:00:00 | **Date-granular** — daily snapshot, `updated_at` is always midnight UTC |

All history starts 2023-03-05 (transactions) / 2023-05-08 (mappings, users). **None of these
are stale** — contrast `sessionM.point_operation_correlation`, which is ~2 months behind and is
a known separate issue (it is not in this chain).

`users.updated_at` being midnight-only matters if anyone ever tries to filter it by timestamp
for incremental logic — it has no intraday resolution.

### End-to-end link rate is stable

Of `transaction_headers` created each day, the share resolving all the way to a `cafezupas`
`external_user_id`, 7/13–7/28: **26.2% – 28.5%**, with no dips. Weekday variation only
(Saturdays run ~26%, midweek ~28%).

Once a header matches a transaction user at all, it resolves to an external id **99.9%** of the
time (e.g. 7/13: 8,134 matched → 8,129 resolved). The ~72% that don't match are non-loyalty
transactions with no SessionM user — expected, not a gap.

## 3. `lower()` is applied to only one of three union branches — OPEN 🟡

`all_trans_users` applies `lower(d.user_id)` to **`transaction_discounts` only**.
`user_point_transactions` and `transaction_payments` pass `user_id` through raw. The join
target does not tolerate this:

| Table | Rows (30d) | NOT lowercase | `lower()` applied? |
|---|---|---|---|
| `external_user_mappings` (join target) | 1,782,178 | **0 — 100% lowercase** | — |
| `transaction_discounts` | 43,518 | 34,077 (78%) | ✅ yes |
| `transaction_payments` | 729,275 | **169** | ❌ **no** |
| `user_point_transactions` | 637,610 | **26** | ❌ **no** |

The `lower()` on discounts is **necessary** — 78% of that table's user_ids are uppercase, so
removing it would break the join catastrophically. The bug is that the other two branches
didn't get it.

**Measured impact (30 days):** of 419,336 transactions, 484 winning rows fail to resolve to a
mapping. **155 of those fail purely because of casing** (154 from payments, 1 from points).
The remaining 329 are genuinely unmapped user_ids — a separate, possibly legitimate population.

**Fix:** wrap `t.user_id` and `tp.user_id` in `lower()` to match the discounts branch. Recovers
~155 loyalty links/month at zero cost. Low volume, but it is the same class of silent identity
loss as the bug just fixed — invisible in totals, only visible per-customer.

### ⚠️ Fix by ADDING `lower()` to two branches — never by REMOVING it from the third

The asymmetry reads like a leftover, and "make the three branches consistent" can be satisfied
in either direction. Deleting the `lower()` is the smaller-looking edit and it is catastrophic.
Measured over 30 days, by which branch wins the `user_trans` dedupe:

| Winning branch | Transactions won | Resolve as built | Resolve if `lower()` removed | Links lost |
|---|---|---|---|---|
| `points` | 411,213 | 410,895 | 410,895 | 0 |
| `discounts` | 6,034 | **6,017** | **0** | **−6,017** |
| `payments` | 2,089 | 1,940 | 1,940 | 0 |

**Every single one of the 6,017 links the discounts branch produces depends on that `lower()`.**
Not 78% of them — all of them.

**And the daily detector would not catch it.** The discounts branch wins only 1.4% of
transactions, so losing all of its links drops `pct_sm_linked` from ~30% to ~29.2% — comfortably
inside the healthy 28–33% band. Roughly 6,000 customers a month would silently lose loyalty
identity while the health check read green.

This is the audit's most important operational caveat: **the detector is tuned to catch
whole-day collapses, not steady low-grade identity leakage.** Findings #3, #4 and #5 are all
below its resolution. That is why they need the targeted queries in this document rather than
relying on the daily check.

### `transaction_id` casing — verified safe ✅

`transaction_id` is a **different** join key (`user_trans` → `header_trans`) and the build never
normalises it. Checked because `user_id` casing was inconsistent; this one is not:

| Table | Rows (30d) | NOT uppercase | Mixed case |
|---|---|---|---|
| `transaction_headers` | 731,353 | **0** | 0 |
| `transaction_payments` | 729,275 | **0** | 0 |
| `user_point_transactions` | 637,610 | **0** | 0 |
| `transaction_discounts` | 43,518 | **0** | 0 |

All four are uppercase hex UUIDs (e.g. `000018F7-D55D-4605-B810-D88CDC390B7F`). **No
normalisation needed and none should be added** — wrapping `transaction_id` in `lower()` would
break every join in this chain. The casing problem is confined to `user_id`.

### `user_point_transactions.transaction_id` is 23.5% NULL — correctly excluded ✅

Found while verifying the above. 149,977 of 637,610 rows (30d) have a NULL `transaction_id`, and
**all 149,977 carry a `user_id`** — so the build's `transaction_id is not null` filter drops
rows that do have an identifiable customer. That looks alarming; it isn't. Breaking down by
`reference_type`:

| `reference_type` | Rows (30d) | % NULL `transaction_id` |
|---|---|---|
| `INCENT.Outcomes` (points earned on a purchase) | 196,163 | **0%** |
| `Point Expiration` | 74,132 | 1.3% |
| `July Protein Stacking Challenge` | 36,371 | 100% |
| `REWARD_STORE` (redemptions) | 31,752 | 100% |
| `auto top-off to 1050` / `to 450` | 39,683 | 100% |
| `Behavior` | 11,684 | 60.8% |
| `Expired Reward`, manual adjustments, support credits, fraud flags | ~2,400 | 100% |

The NULLs are **non-purchase point activity** — challenges, reward redemptions, auto top-offs,
manual adjustments. They have no POS transaction to reference, so they cannot contribute to
order identity and excluding them is correct. Crucially, `INCENT.Outcomes` — the actual
"earned points on this order" type — is **0% NULL**. The filter is right.

Note for anyone reading `all_trans_users`: `Point Expiration` rows *do* carry a
`transaction_id`, and their `last_updated_at` is the expiry date, not the purchase date. So a
recent expiry can outrank the original earning row in the `user_trans` recency tiebreak. Both
rows point at the same user, so identity is unaffected — but it means `updated_date` in
`user_trans` is not a reliable proxy for when the transaction happened.

## 4. `user_trans` tiebreak can discard a resolvable identity — OPEN 🟡

```sql
qualify row_number() over(partition by u.transaction_id order by u.updated_date desc) = 1
```

One row wins per `transaction_id`, chosen purely by recency. It does **not** consider whether
the winning `user_id` actually resolves to a mapping.

- **56** transactions (30d) carry more than one distinct `user_id` — so the choice rarely matters.
- **26** transactions (30d) lose their link because the newest row doesn't resolve while an
  older row on the same transaction **would have**.

**Fix:** order by resolvability first, e.g. rank rows that exist in `sm_external_user_map`
ahead of those that don't, then by `updated_date desc`. Recovers ~26 links/month. Combined with
finding #3, ~181 links/month.

## 5. 6,095 `user_id`s carry multiple `external_user_id`s — OPEN 🟡

```sql
qualify row_number() over(partition by u.user_id order by u.updated_at desc) = 1
```

`sm_external_user_map` keeps one `external_user_id` per SessionM `user_id`, picked by
`max(updated_at)`. But **6,095 of 1,775,387 user_ids (0.34%) have more than one** `cafezupas`
external id. For those, which CZ customer id the orders land on is a tiebreak decision that
**can change between runs if a mapping's `updated_at` moves.**

**This is a second, previously undocumented mechanism by which `lifetime_order_count` changes
without the customer ordering** — and unlike restatement, it doesn't just adjust a count, it
migrates orders wholesale from one `mapped_cust_id` to another.

Exposure over the last 365 days:

| Measure | Value |
|---|---|
| Orders on ambiguously-mapped ids | **17,269** |
| Customers affected | **2,913** |
| Net sales exposed | **$472,797.35** |
| Orders where SessionM is the *only* identity (`pulse_customer_id is null`) | **7,236** |

Those 7,236 are the dangerous subset — with no pulse id to fall back on, a flip moves the whole
order to a different customer.

Also found: **582 `external_user_id`s map to multiple `user_id`s** (max 3). That's the reverse
direction — one CZ customer id spanning several SessionM users — and it belongs with the
[CRM identity hygiene work](crm_identity_hygiene_plan.md).

**Recommended fix:** replace the recency tiebreak with a deterministic one (lowest
`external_user_id`, or earliest `updated_at`) so the assignment is *stable* even if it isn't
provably correct. A stable-but-arbitrary key beats one that silently churns.

## 6. `header_trans` dedupe is a no-op — informational ⚪

```sql
qualify row_number() over(partition by h.pos_transaction_key order by h.last_updated_at desc) = 1
```

Over a 30-day window: 731,353 header rows, **731,353 distinct raw keys, 731,353 distinct cast
keys, 0 uncastable, 0 duplicates, 0 cast collisions.** The dedupe removes nothing.

It is also *structurally* mismatched — it partitions on the **raw** `pos_transaction_key` while
the SELECT emits `safe_cast(... as int64)`. If two raw values ever cast to the same int64
(whitespace, leading zeros, `'123'` vs `'123.0'`), the dedupe would miss and `cust_trans` would
fan out. Currently harmless, and the same shape as the `partition by po.id` no-op found in the
pulse CTE on 2026-07-27.

**Recommendation:** leave it in as defensive, but partition on the cast value so it would
actually catch the case it's guarding against.

Also noted: **4** `cafezupas` mappings have an `external_user_id` that fails
`safe_cast(... as int64)`. They silently become NULL and never link. Immaterial, documented for
completeness.

## 7. `external_user_mappings` ⨝ `users` inner join — SAFE ✅

The 2026-07-27 change added an inner join to `sessionM.users` to pick up the loyalty email. An
inner join here is a latent risk: any mapping without a `users` row would be **silently
dropped**, costing identity.

Re-verified 2026-07-29: **0 of 1,782,178** `cafezupas` mappings lack a `users` row, and **0**
have a null email. The build's comment still holds. Worth re-checking whenever `users` loading
changes, since the failure mode is silent.

## Monitoring recommendation

The detector in `data_dictionaries/sales_ops.order_customer.md` (daily `pct_sm_linked`, healthy
28–33%) catches finding #1's class of failure — a whole-day collapse.

**Know its blind spot.** It does **not** catch findings #3–#5, which are all too small to move
the daily rate. The worked example above is the clearest case: deleting one `lower()` would cost
~6,000 customers a month their loyalty identity and move `pct_sm_linked` by 0.8pp, well inside
the healthy band. A green detector means "no day collapsed", not "identity resolution is
correct". Steady low-grade leakage needs the targeted queries in this document, re-run
periodically.

Suggested cadence: fold the `pct_sm_linked` check into the daily query-log review, and re-run
this full audit after any change to the SessionM CTEs or upstream loading.
