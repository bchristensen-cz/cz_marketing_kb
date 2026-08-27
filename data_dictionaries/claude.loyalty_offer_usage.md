# `claude.loyalty_offer_usage`

**One row per offer issued to a member.** Offer issuance and redemption, with offer definition attributes joined on.

| | |
|---|---|
| Type | View |
| Grain | 1 row per `sessionM.user_offers.user_offers_id` (~33.1M rows) |
| Upstream | `sessionM.user_offers`, `sessionM.offers`, `claude.loyalty_user` |
| Build script | `sql/claude.loyalty_views.sql` |
| Created | 2026-07-28 |

## Columns

| Column | Type | Description |
|---|---|---|
| `user_offers_id` | STRING | Primary key (GUID) |
| `user_id` | STRING | SessionM user id |
| `sm_external_user_id` | INTEGER | Joins to `sales_ops.order_customer.sm_external_user_id` |
| `email` | STRING | |
| `offer_id` | STRING | Specific offer version |
| `root_offer_id` | STRING | Parent offer — group on this to combine versions of the same offer (1,715 offers roll up to 896 roots) |
| `offer_name` | STRING | e.g. `Try 2 Combo`, `Birthday Free Dessert`, `Regular Drink` |
| `offer_kind` | STRING | **`points_purchase` / `promotional` / `unknown`. Always split redemption rates on this** |
| `reward_store` | STRING | Raw upstream `'true'`/`'false'`. A boolean-as-string, **not** a store name. `offer_kind` is the readable form |
| `points_required` | FLOAT | Points to redeem. Populated for `points_purchase` only |
| `discount_amount` | FLOAT | Fixed dollar discount |
| `percent_off` | FLOAT | Percentage discount |
| `fixed_price` | FLOAT | Fixed-price override |
| `pos_discount_id` | STRING | Brink discount id — the bridge to POS discount lines |
| `issued_date` | DATE | When the offer row was created (upstream partition column) |
| `acquire_date` | DATE | When the member acquired it |
| `redeem_date` | DATE | When redeemed. NULL = never redeemed |
| `is_redeemed` | BOOLEAN | `redeem_date is not null` |
| `redemption_start_date` | DATE | Redemption window opens |
| `redemption_end_date` | DATE | Redemption window closes |
| `is_expired_unredeemed` | BOOLEAN | Window closed in the past and never redeemed |
| `days_to_redeem` | INTEGER | `redeem_date - acquire_date`. NULL if unredeemed |
| `points_spent` | FLOAT | Points actually spent. **The reliable "points redeemed for rewards" measure** |
| `quantity` | INTEGER | |
| `user_offer_status` | INTEGER | Raw status: 1 (99.4%) or 2. Semantics unconfirmed — **does not mean redeemed**; use `is_redeemed` |
| `store_id` | STRING | SessionM retailer store id — **not** a Brink store number. See gotchas |
| `pos_offer_id` | INTEGER | |
| `additional_description` | STRING | |
| `is_bulk_provisioned_2023` | BOOLEAN | TRUE = part of the 2023 catalog mass-provisioning. **Exclude from issuance counts** |
| `member_program` | STRING | `individual` / `catering` / `both` / NULL |
| `catering_tier_name` | STRING | Catering members only |

## `offer_kind` — the split that matters most

Aug 2025 – Jul 2026, excluding the 2023 bulk load:

| `offer_kind` | `reward_store` | Issued | Redeemed | Rate | Distinct offers |
|---|---|---|---|---|---|
| `points_purchase` | `'true'` | 236,785 | 214,266 | **90.5%** | 40 |
| `promotional` | `'false'` | 2,117,210 | 67,386 | **3.2%** | 239 |

A points purchase is a deliberate member action — they nearly always redeem, and `days_to_redeem` averages ~0.1 (essentially immediate). A promotional offer is broadcast to a large audience and mostly ignored.

Top offers by redemption (same window):

| Offer | Kind | Points | Issued | Redeemed | Rate |
|---|---|---|---|---|---|
| 50% Off Try 2 Combo | points_purchase | 975 | 57,947 | 55,042 | 95.0% |
| Try 2 Combo | points_purchase | 1,950 | 28,071 | 27,332 | 97.4% |
| Regular Drink | points_purchase | 450 | 31,154 | 26,396 | 84.7% |
| Protein Bowl | points_purchase | 1,900 | 13,369 | 12,796 | 95.7% |
| Birthday Free Dessert | promotional | — | 347,121 | 9,668 | 2.8% |
| $1 Happy Hour Mocktail | promotional | — | 227,507 | 8,962 | 3.9% |
| Team Member Meal | promotional | — | 27,589 | 7,718 | 28.0% |

**Reporting a single blended redemption rate across both kinds is always wrong.** Blending the two above gives ~12%, which describes no real population.

## Gotchas

- **The 2023 mass-provisioning artifact.** 24.8M of the 33.1M rows landed in 2023, when the reward catalog was bulk-issued to every member (769,358 members × ~32 offers). Volume by year: 2023 = 24.8M, 2024 = 3.9M, 2025 = 2.7M, 2026 YTD = 1.7M. **Always add `and not is_bulk_provisioned_2023`** to issuance counts, or any year-over-year comparison will show a catastrophic fake decline.
- **`reward_store` is not a store.** It's a boolean-as-string flag distinguishing reward-store purchases from pushed offers. Someone will eventually try to `group by reward_store` expecting locations.
- **`user_offer_status` is not redemption status.** Status 1 covers 32.9M rows including both redeemed and unredeemed; status 2 covers 187,875 with *zero* redemptions. Use `is_redeemed`.
- **`total_uses` / `remaining_uses` are NULL throughout** and are not exposed.
- **`store_id` is a SessionM retailer store id**, not a Brink store number. The mapping via `sessionM.retailer_stores` (92 rows) is undocumented, so **store-level loyalty attribution is not yet answerable**. Don't guess it.
- `offer_name` comes from the `offers` join and is NULL where an offer definition is missing. Left join is intentional — don't drop rows.
- **NULL identity columns mean the user is missing upstream, not that the offer is bad.** `sm_external_user_id`, `email`, `member_program` and `catering_tier_name` all come from the `loyalty_user` left join. **688 `user_id`s / 5,011 offer rows** have no row in `sessionM.users` at all (measured 2026-08-27, `create_date < current_date() -1`), so those columns are NULL and **an inner join or an email/program filter silently drops the rows**. Verified against the GCS source dumps: the users are absent from the `users` extract itself, not lost in load (0 drops across 30,155 ids in the 2026-08-17→08-27 dumps). They are real members — 523 hold tier history, 500 hold point accounts — but none has an `external_user_mappings` row, so none will ever acquire an `sm_external_user_id`. Count them, don't filter them: `countif(sm_external_user_id is null)`.
- Group on `root_offer_id` to combine offer versions; `offer_id` alone splits the same promotion across reissues.
- `points_spent` here is the trustworthy reward-redemption measure; `loyalty_points_activity.points_redeemed` (bitmask 2) also includes support deductions and clawbacks.

## Open items

- [ ] Map SessionM `store_id` → Brink store number via `sessionM.retailer_stores` so store-level loyalty reporting becomes possible.
- [ ] Confirm `user_offer_status` semantics with SessionM.
- [ ] Verify `pos_discount_id` joins cleanly to `sales_ops.order_discount` (itself undocumented) to tie offer redemption to actual order discounts.
