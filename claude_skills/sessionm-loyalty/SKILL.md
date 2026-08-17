---
name: sessionm-loyalty
description: How to query Cafe Zupas loyalty data in BigQuery — the claude.loyalty_* views over SessionM. Use for ANY question about points (balances, issued, redeemed, expiring), offers and rewards, redemption rates, loyalty campaign participation, achievements, member tiers, or catering vs individual loyalty programs. Contains canonical definitions, the point-expiration rules, join patterns to order data, and the traps that make raw SessionM tables unsafe.
---

# Querying Cafe Zupas Loyalty Data (SessionM)

> **Freshness check:** this file must come from a clone of `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**. If you're reading it from an installed skill package, a fork, or any saved copy, stop and re-clone first — it may be stale.

> **🆕 New 2026-07-28.** The `claude.loyalty_*` views are the first loyalty marts. Before this, loyalty questions had no approved table and were either unanswered or improvised from raw `sessionM.*`. Any query written against `sessionM.*` directly should be rewritten against these views.

Project: `marketing-data-442316`. Six approved views, all in the `claude` dataset:

| View | Grain | Use for |
|---|---|---|
| `claude.loyalty_points_balance` | 1 row per member per point account | "What's the current balance?", total outstanding liability |
| `claude.loyalty_points_expiring` | 1 row per member per expiry date | "What's about to expire?", expiration forecasting |
| `claude.loyalty_points_activity` | 1 row per point transaction | Points issued / redeemed / expired over time |
| `claude.loyalty_offer_usage` | 1 row per offer issued to a member | Offer and reward redemption rates |
| `claude.loyalty_campaign_participation` | 1 row per campaign event | Campaign participation, achievements earned, rewards awarded |
| `claude.loyalty_user` | 1 row per loyalty member | Identity spine, program membership, tiers |

Column docs in `data_dictionaries/`: one file per view. Read them before writing non-trivial queries.

## Hard rules (consistency guarantees)

1. **Never query `sessionM.*` directly** to answer a business question. The raw tables carry the traps listed under [Why the raw tables are unsafe](#why-the-raw-tables-are-unsafe) — a stored balance column that overstates by 32.7M points, a 24.8M-row bulk-provisioning artifact, a free-text field that looks like an enum, and a correlation table that is two months stale. These views handle all of them.
2. **Always bound `create_date` on `loyalty_campaign_participation`.** The underlying `sessionM.campaign_activity` is ~1.4 **billion** rows / 140 GB. It is partitioned on `create_date`; an unbounded query scans the lot. The other five views are small enough (11.6M–33M rows) that a date filter is good practice but not a cost cliff.
3. **Same metric, same definition.** Use the canonical definitions below verbatim.
4. **Catering vs individual comes from the tier system** — never from the point account, and never from the `cater_` email prefix. See [Program membership](#program-membership-catering-vs-individual) and [The `cater_` email prefix](#the-cater_-email-prefix-is-not-a-membership-flag).
5. **Split offers on `offer_kind` before quoting any redemption rate.** A blended rate is meaningless. See [Offers](#offers-and-redemption).
6. **All datasets are read-only.** If you need to materialize intermediate results, create them ONLY in `marketing-data-442316.scratch` (7-day auto-expiry).
7. Loyalty data loads on the same hourly ETL as the order marts. `etl_create_date` on `loyalty_points_activity` is the load partition; `activity_date` is the business date — **filter and group on `activity_date`**, not `etl_create_date`.

## Canonical metric definitions

| Metric | Definition |
|---|---|
| Current points balance | `sum(current_balance)` from `loyalty_points_balance`. This is the authoritative figure — it comes from SessionM's own account record |
| Outstanding points liability | `sum(current_balance)` from `loyalty_points_balance`, no filter. ~597M points as of 2026-07-28 |
| Lifetime points earned | `sum(lifetime_points)` from `loyalty_points_balance` |
| Points issued | `sum(points_issued)` from `loyalty_points_activity` |
| Points redeemed | `sum(points_redeemed)` from `loyalty_points_activity` (`activity_type = 'redeemed_or_deducted'`) |
| Points expired | `sum(points_expired)` from `loyalty_points_activity` (`activity_type = 'expired'`) |
| Points expiring in a window | `sum(points_expiring)` from `loyalty_points_expiring` where `expires_on between @start and @end` |
| Active loyalty member | a row in `loyalty_user` with `member_program is not null` |
| Members with a balance | `count(distinct user_id)` from `loyalty_points_balance` where `current_balance > 0` |
| Offers issued | `count(*)` from `loyalty_offer_usage`, **`and not is_bulk_provisioned_2023`** |
| Offers redeemed | `countif(is_redeemed)` from `loyalty_offer_usage` |
| Redemption rate | `countif(is_redeemed) / count(*)` **split by `offer_kind`** — never blended |
| Campaign participants | `count(distinct user_id)` from `loyalty_campaign_participation` where `action_category in ('achievement_earned','reward_awarded')` |

## Point expiration rules (business rules, steward 2026-07-28)

These are **business rules from the steward**, validated against actual sweep events (lots earned April 2025 were swept 2026-05-01, exactly as the rule predicts):

- **Individual (`Spendable Points`)** — expire **one year from the end of the month earned**. A member who earns on 2026-02-01 and one who earns on 2026-02-28 *both* expire on 2027-02-28.
  `expires_on = date_add(last_day(earned_date, month), interval 1 year)`
- **Catering (`Catering Spendable Points`)** — expire annually at **end of day November 30**.
- **SessionM sweeps on the day *after* `expires_on`** — a batch job on the 1st of the following month. So the ledger debit lands on `expires_on + 1 day`, exposed as `sessionm_sweep_date`. A row with `is_past_due_not_yet_swept = true` is due but not yet removed; it still counts in `current_balance`.

`loyalty_points_expiring` computes this by **FIFO-allocating debits against credit lots**, because SessionM exposes no per-lot expiry date. This reconciles to `current_balance` exactly for **99.46%** of members and to within **0.07%** in total. Do not try to rebuild it from `points_remaining` — see below.

> **Do not use the stored `sessionM.user_point_transactions.points_remaining`.** It is not reliably decremented: summed across credit lots it gives **628.6M** points against an actual balance of **595.9M** — a 32.7M (5.5%) overstatement. `sum(point_modification)` is the field that reconciles (99.8% of accounts). This is exactly the kind of trap the view exists to hide.

## Program membership (catering vs individual)

**Use `member_program` from `loyalty_user`, which derives from the SessionM tier system.** The two live systems:

| `tier_system_id` | Name | `member_program` | Members | Tier levels |
|---|---|---|---|---|
| `0B6461B8-B1D5-4D81-8C31-2F21A914DE1C` | Cafe Zupas VIP Program | `individual` | 1,684,999 | one flat level |
| `1D7B47AB-E3FE-4E62-916F-01973964B662` | Cafe Zupas Catering Program | `catering` | 89,940 | Silver / Gold / Diamond |
| `23755DBF-29D9-4A7B-AD2E-0E411EDF7815` | `[CATest]` test system | *excluded* | 10 | — |

Membership requires `exited_at is null` (current membership only) — the view already applies this.

**Why not the point account?** A member should never hold both point accounts, and it's *nearly* true — but the tier system is both cleaner and broader:

- Only **3** members sit in both tier systems, vs **264** holding both point accounts.
- **89,940** catering members by tier vs **43,030** holding a catering point account. The point account only materializes once a member has points, so the account undercounts membership by half.
- Tier and account agree for **99.8%** of members with a balance. Known disagreements: 259 catering-tier members hold a Spendable account, 14 individual-tier members hold a Catering account, ~1,930 balance-holders have no tier membership at all.

So: **`member_program` answers "who is a catering member"; `point_account_name` answers "which bucket are these points in."** They are not interchangeable. For points questions, group by `point_account_name`; for member questions, filter on `member_program`.

## The `cater_` email prefix is not a membership flag

SessionM enforces unique email addresses, so a guest needing both a personal and a catering account gets the catering one provisioned as `cater_<their address>`. 90,170 users carry it. It is tempting as a cheap catering flag — resist it.

Concordance with the catering tier system (2026-07-29):

| Segment | Users |
|---|---|
| Both `cater_` email and catering tier | 90,119 |
| `cater_` email only (never enrolled) | 51 |
| Catering tier only (plain email) | 5 |
| Tier row with no `users` record | 10 |

99.93% agreement — but agreement is not the point. **The prefix measures a different thing.** All **181** members who exited the catering tier still carry the prefix — 100% of them — because nothing rewrites the email on exit. `is_cater_email` therefore means *was ever provisioned as a catering account*, never *is a catering member*.

What that costs you if you use it as the definition:

- Catering member counts come out **232 too high** (181 exited + 51 never enrolled) and miss 5 live members who have plain emails.
- No timestamp lives in a string, so **every as-of-date, cohort, and lapse question becomes unanswerable**. Use `catering_first_joined_date` / `catering_last_exited_date` on `loyalty_user`.
- `email` is editable by support and by guests; tier membership is system-managed. A corrected address silently flips a prefix-derived flag, with no audit trail.

Cost is not a tiebreaker either — 45 MB for the prefix scan vs 136 MB for the tier read, on a 342 MB table. Both under a cent. The tier-derived flags are materialised as columns on `loyalty_user` precisely so the correct definition is also the cheap one.

**Use `is_catering_member` (current) and `was_ever_catering_member` (ever). Treat `is_cater_email` as a cross-check only.**

Two related traps:

- **`email_normalized` is never an identity key.** 39,500 of the 90,161 stripped catering addresses collide with a real individual account — the exact collision the prefix exists to prevent. Match on `email`; strip only for display and outbound comms.
- **`catering_last_exited_date` being non-null does not mean lapsed.** 2,869 members have an exit date but only 181 are currently out; the rest exited and rejoined. Lapsed = `was_ever_catering_member and not is_catering_member`.

## Offers and redemption

`offer_kind` splits two populations that behave nothing alike (Aug 2025 – Jul 2026):

| `offer_kind` | Source | Issued | Redeemed | Rate |
|---|---|---|---|---|
| `points_purchase` | member spends points from the reward store | 236,785 | 214,266 | **90.5%** |
| `promotional` | pushed to an audience, no points required | 2,117,210 | 67,386 | **3.2%** |

A points purchase is a deliberate member action, so it nearly always redeems (and `days_to_redeem` is ~0.1 — members redeem essentially immediately). A promotional offer is broadcast: *Birthday Free Dessert* was issued 347,121 times and redeemed 9,668 times (2.8%). **Reporting a single blended redemption rate across both is always wrong.**

The underlying field is `offers.reward_store`, which is a **boolean-as-string** (`'true'`/`'false'`), not a store name. `offer_kind` is the readable form; both are exposed.

## Campaign participation

`action_category` separates real participation from rules-engine noise:

| `action_category` | Meaning | Use it? |
|---|---|---|
| `achievement_earned` | member completed the achievement | ✅ yes — this is participation |
| `reward_awarded` | member was awarded an offer or points | ✅ yes |
| `rule_evaluated` | the rules engine merely *looked at* an event | ❌ **no** — massive noise |
| `reversed` | achievement forfeited / incentive revoked | for reversals |
| `error` | outcome errored | data-quality checks |

**`rule_evaluated` is not participation.** One campaign (`250619 | Automated | Custom | Push | Points_Earned_Points_Added`) fired 8.2M of these for 140k members in 27 days. Counting them as participation inflates by 30–60x.

Also note:
- The view **drops ~1.1B message-delivery rows** (`platform_processing`, `platform_processed`, `triggered`, `sent`, `platform_dropped`, `platform_deferred`). Message delivery and engagement is Braze's domain — **use the `braze-campaigns` skill**, not this one.
- `campaign_achievements.points` is **0 on all 1,508 rows** upstream, so it is deliberately not exposed. For points awarded by a campaign, use `loyalty_points_activity`.
- Even after filtering to `achievement_earned`, a member fires multiple events per campaign — **always `count(distinct user_id)`** for a participant count, not `count(*)`.

## Points activity classification

`activity_type` derives from `audit_type_bitmask`, which is the **only** reliable classifier:

| `audit_type_bitmask` | `activity_type` | Sign |
|---|---|---|
| 1 | `issued` | positive |
| 2 | `redeemed_or_deducted` | negative |
| 4 | `expired` | negative |
| 16 | `issued_adjustment` | positive, rare (43 rows / 707 points in a recent 2-month window) |

> **`reference_type` is free text, not an enum.** It is exposed as `reference_note` and contains campaign names (`July Protein Stacking Challenge`), support-agent personal names, and ticket reasons (`MISSING ITEMS`, `MADE WRONG`, `Due to a duplicate order incident at the POS…`). Never `group by` it expecting a stable category list, and never filter on it to classify a transaction — use `activity_type`.

Note that bitmask 2 mixes genuine reward redemptions with manual support deductions and fraud clawbacks, which is why the column is named `redeemed_or_deducted`. For redemptions specifically tied to a reward, join to `loyalty_offer_usage` on the member and date, or use `points_spent` on that view.

## SQL style (steward rule 2026-07-23, extended 2026-07-29 — MANDATORY)

Same as `sales-ops-orders` — read that section for the full rules and a worked example. In short: fully qualified table names with **backticks around the project only** (`` `marketing-data-442316`.claude.loyalty_user lu ``, never the whole path) **and** an alias on every single column reference (even in single-table queries); lowercase except where a schema name or compared literal needs case; leading commas, one column per line; `where 1=1` first, then one `and` per line; each join with `on` lined up beneath it and one extra indent per successive join. Fixed aliases: `order_customer` → `oc`, `order_lines` → `ol`.

## Join patterns

**Loyalty → order data.** The join key is `sm_external_user_id`, which every loyalty view carries and which matches `sales_ops.order_customer.sm_external_user_id` (verified 100% — 211,541 of 211,541 distinct ids in a two-month window):

```sql
select
  lb.member_program
, count(distinct lb.user_id) as members
, round(sum(lb.current_balance)) as points_balance
, round(sum(oc.net_sales), 2) as net_sales
from `marketing-data-442316`.claude.loyalty_points_balance lb
	join `marketing-data-442316`.sales_ops.order_customer oc
	on oc.sm_external_user_id = lb.sm_external_user_id
where 1=1
and oc.business_date between @start and @end
and oc.customer_type = 'person'
group by 1
```

> `external_user_mappings` also holds `amperity` ids, but Cafe Zupas uses **only** the `cafezupas` type (steward, 2026-07-28). The views expose only that one; don't reintroduce amperity.

**Balance → expiring** (same grain on member + account):

```sql
select
  lb.user_id
, lb.current_balance
, sum(le.points_expiring) as expiring_next_90d
from `marketing-data-442316`.claude.loyalty_points_balance lb
	left join `marketing-data-442316`.claude.loyalty_points_expiring le
	on le.user_id = lb.user_id
	and le.point_account_name = lb.point_account_name
	and le.expires_on between current_date('America/Denver')
		and date_add(current_date('America/Denver'), interval 90 day)
where 1=1
and lb.current_balance > 0
group by 1,2
```

## Validated query templates

**Points expiring by month:**

```sql
select
  pe.point_account_name
, format_date('%Y-%m', pe.expires_on) as expiry_month
, count(distinct pe.user_id) as members
, round(sum(pe.points_expiring)) as points_expiring
from `marketing-data-442316`.claude.loyalty_points_expiring pe
where 1=1
and pe.expires_on between current_date('America/Denver')
	and date_add(current_date('America/Denver'), interval 6 month)
group by 1,2
order by 1,2
```

**Points issued vs redeemed vs expired by month:**

```sql
select
  format_date('%Y-%m', pa.activity_date) as month
, pa.point_account_name
, round(sum(pa.points_issued)) as points_issued
, round(sum(pa.points_redeemed)) as points_redeemed
, round(sum(pa.points_expired)) as points_expired
, count(distinct pa.user_id) as active_members
from `marketing-data-442316`.claude.loyalty_points_activity pa
where 1=1
and pa.activity_date between @start and @end
group by 1,2
order by 1,2
```

**Offer redemption, correctly split:**

```sql
select
  ou.offer_kind
, ou.offer_name
, ou.points_required
, count(*) as times_issued
, countif(ou.is_redeemed) as times_redeemed
, round(100 * countif(ou.is_redeemed) / count(*), 1) as redemption_rate_pct
, countif(ou.is_expired_unredeemed) as expired_unredeemed
from `marketing-data-442316`.claude.loyalty_offer_usage ou
where 1=1
and ou.issued_date between @start and @end
and not ou.is_bulk_provisioned_2023
group by 1,2,3
order by times_redeemed desc
```

**Campaign participation (noise excluded, date-bounded):**

```sql
select
  cp.campaign_name
, cp.campaign_type
, cp.action_category
, count(distinct cp.user_id) as members
from `marketing-data-442316`.claude.loyalty_campaign_participation cp
where 1=1
and cp.create_date between @start and @end
and cp.action_category in ('achievement_earned','reward_awarded')
group by 1,2,3
order by members desc
```

## Pre-query clarification protocol

Settle these before running a loyalty query. Don't ask about items already fixed by the question.

1. **Individual or catering?** These are separate programs with separate expiration rules and wildly different sizes (1.68M vs 90k members). If the question doesn't say, ask — or report both split by `member_program` / `point_account_name` and say so.
2. **Current or ever, for catering membership?** `is_catering_member` = in the tier today (89,943); `was_ever_catering_member` = ever (90,124). For "how many catering customers do we have" the answer is current. Say which you used.
3. **Date range.** Never assume. For balances, "current" means as-of-now (the views read the live account record).
4. **Offers: which kind?** If someone asks for "redemption rate," ask whether they mean reward-store purchases, promotional offers, or both split out. Never return a blended number.
5. **"Points expiring" — by when?** Anchor the window explicitly. Also state whether you're including `is_past_due_not_yet_swept` rows.
6. **"Members" — which population?** All registered (`loyalty_user`), those with a balance, or those with recent activity? These differ by hundreds of thousands.

## Why the raw tables are unsafe

Documented so nobody re-derives them the hard way:

| Trap | Detail |
|---|---|
| `points_remaining` overstates | Sums to 628.6M vs an actual 595.9M balance (+5.5%). Not reliably decremented |
| `user_offers` 2023 bulk load | 24.8M of 33.1M rows landed in 2023 when the catalog was mass-provisioned to every member. Flagged as `is_bulk_provisioned_2023` |
| `user_offers` mixes DATE and TIMESTAMP | **`create_date` is DATE; `acquire_date`, `redeem_date`, `redemption_start_date`, `redemption_end_date`, `created_at`, `last_updated_at` are all TIMESTAMP** (verified 2026-08-17). `date_diff(redeem_date, create_date, day)` fails with `No matching signature for function DATE_DIFF … Unable to coerce type TIMESTAMP to expected type DATE` — the steward's own session burned three attempts on it 2026-08-15, and the two failing variants read as correct. Days-to-redeem is `date_diff(date(uo.redeem_date), uo.create_date, day)`: wrap the TIMESTAMP in `date()`, and put it **first** so the argument order matches the answer you want (later minus earlier). Also note `select *` on this table bills **8.4 GiB** — name your columns |
| `reference_type` looks like an enum | Free text: agent names, ticket reasons, campaign names. Hundreds of distinct values, unstable |
| `reward_store` is not a store | Boolean-as-string separating two populations with 90.5% vs 3.2% redemption |
| `point_operation_correlation` is stale | Max `created_at` is 2026-05-28 for Deposit/Spend, 2026-05-01 for Expiration — roughly two months behind. Do not use it for recent periods. The views don't depend on it |
| `campaign_activity` is 1.4B rows / 140 GB | ~1.1B of it is message delivery that duplicates Braze. Always partition-filter |
| `campaign_achievements.points` is dead | 0 on all 1,508 rows |
| Test objects in reference tables | `[CATest]` / `[SMTest]` point accounts and a `[CATest]` tier system. All excluded by the views |
| Duplicate account rows | 9 user/point-account pairs have >1 row in `user_point_accounts`. The view sums them and flags via `is_duplicate_source_row` |
| `tier_member_history` tombstone id | `00000000-0000-0000-DEAD-000000000000` carries 61 catering tier events and is not a person. Excluded by `loyalty_user`; exclude it anywhere you join tier history directly |
| Tier rows with no user | 9 real `user_id`s (Apr–Jun 2026) have catering tier rows but no row in `sessionM.users`. Not ingestion lag — newest is 2026-05-31. Upstream referential gap, same class as pulse customer 19192 |

## Known gaps / not yet answerable

- **Store-level loyalty attribution.** `user_offers.store_id` is a SessionM retailer store id, not a Brink store number, and the mapping through `sessionM.retailer_stores` (92 rows) is undocumented. Don't answer store-level loyalty questions yet.
- **Which reward a bitmask-2 debit paid for.** `loyalty_points_activity` can tell you points were redeemed but not always for what. `point_offer_mapper` links `user_offers_id` → `point_transaction_id` and would close this, but its coverage is unverified.
- **Tier progression history.** `loyalty_user` now exposes catering *lifecycle* (`was_ever_catering_member`, `catering_first_joined_date`, `catering_last_exited_date`, added 2026-07-29), so joins, exits and lapses are answerable. The Silver → Gold → Diamond *movement path* still is not — that needs `sessionM.tier_member_history` unfiltered at tier-level grain.
- **Transaction-level loyalty spend.** `sessionM.transaction_headers` / `transaction_items` / `transaction_discounts` / `transaction_payments` are undocumented. Brink remains the sole financial source of truth — don't compute sales from SessionM.
- **Referral and incentive rule detail.** `incentive_outcomes` has an entirely generic schema (`entity_decimal_1`, `entity_id_1`, `discriminator`) with no dictionary. Out of scope.

Found a gap or a new gotcha? **Don't edit the repo** — log it as an Asana task on the **Claude Data** board titled `KB finding: <short title>` with the query and proposed change.
