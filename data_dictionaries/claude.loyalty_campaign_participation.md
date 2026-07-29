# `claude.loyalty_campaign_participation`

**One row per SessionM campaign event.** Achievement and reward participation in loyalty campaigns.

| | |
|---|---|
| Type | View |
| Grain | 1 row per `sessionM.campaign_activity` event (behaviour/reward events only) |
| Partition | **`create_date` — ALWAYS filter it.** Underlying table is ~1.4 **billion** rows / 140 GB |
| Upstream | `sessionM.campaign_activity`, `campaign_attributes`, `campaign_achievements`, `campaign_activity_units`, `applications`, `claude.loyalty_user` |
| Build script | `sql/claude.loyalty_views.sql` |
| Created | 2026-07-28 |

## ⚠️ Cost warning

`sessionM.campaign_activity` is the largest table in the warehouse. A single unbounded query over it scans **140 GB**. The view drops the ~1.1B message-delivery rows, but BigQuery still prunes by partition only if **you filter `create_date`**. Every query must bound it:

```sql
where 1=1
and create_date between @start and @end
```

## Columns

| Column | Type | Description |
|---|---|---|
| `create_date` | DATE | **Partition column. Always filter.** Event date |
| `user_id` | STRING | SessionM user id |
| `sm_external_user_id` | INTEGER | Joins to `sales_ops.order_customer.sm_external_user_id` |
| `email` | STRING | |
| `campaign_id` | INTEGER | |
| `campaign_name` | STRING | Internal name, e.g. `250619 \| Automated \| Custom \| Push \| Points_Earned_Points_Added` |
| `campaign_external_name` | STRING | Guest-facing name |
| `campaign_type` | STRING | `promotion` or `messaging` |
| `campaign_starts_at` | DATE | |
| `campaign_ends_at` | DATE | |
| `campaign_optin_required` | BOOLEAN | |
| `action` | STRING | Raw SessionM action string |
| `action_category` | STRING | **`achievement_earned` / `reward_awarded` / `rule_evaluated` / `reversed` / `error` / `other`** |
| `creative_type` | STRING | `behavior`, `cpa-instant-reward`, `messaging` |
| `achievement_id` | INTEGER | |
| `achievement_name` | STRING | |
| `achievement_type` | STRING | `behavior` or `goal` |
| `unit_id` | INTEGER | Campaign activity unit |
| `activity_unit_name` | STRING | |
| `message_type` | STRING | |
| `application_id` | INTEGER | |
| `application_name` | STRING | |
| `application_platform` | STRING | |
| `pos_transaction_id` | STRING | Brink/POS transaction that triggered the event, where applicable |
| `created_at` | TIMESTAMP | |
| `member_program` | STRING | `individual` / `catering` / `both` / NULL |
| `catering_tier_name` | STRING | Catering members only |

## `action_category` — participation vs noise

| `action_category` | Raw `action` values | Use it? |
|---|---|---|
| `achievement_earned` | `goal:achievement:earned`, `composite:achievement:earned` | ✅ real participation |
| `reward_awarded` | `outcome:awarded:offer`, `outcome:awarded:incentives`, `eligible_offer_issued`, `eligible_offer_added` | ✅ real |
| `rule_evaluated` | `goal:achievement:event`, `composite:achievement:event` | ❌ **noise** |
| `reversed` | `*:forfeited`, `composite:achievement:regress`, `outcome:revoked:incentives` | reversals only |
| `error` | `outcome:error:*` | data-quality checks |

**`rule_evaluated` is the rules engine merely looking at an event, not the member doing anything.** Campaign `250619 | Automated | Custom | Push | Points_Earned_Points_Added` fired **8.2M** of these for 140,537 members in 27 days. Including them inflates participation by 30–60x.

## What's excluded

The view keeps `creative_type in ('behavior','cpa-instant-reward','messaging')`, which drops ~1.1B message-delivery rows:

| Dropped action | Rows (all time) |
|---|---|
| `platform_processing` | 499.0M |
| `platform_processed` | 483.5M |
| `triggered` | 64.0M |
| `sent` | 64.0M |
| `platform_dropped` | 14.4M |
| `platform_deferred` | 1.1M |

**Message delivery and engagement is Braze's domain — use the `braze-campaigns` skill.** SessionM's copy is a partial mirror and mixing the two will double-count.

## Gotchas

- **Always `count(distinct user_id)` for participants.** Even within `achievement_earned` a member fires many events per campaign — e.g. 140,537 members generated 4,120,681 `achievement_earned` events in 27 days on one campaign (~29 each). `count(*)` is an event count, never a member count.
- **`campaign_achievements.points` is 0 on all 1,508 rows** upstream, so it is deliberately **not exposed**. For points awarded by a campaign, use `loyalty_points_activity` (the `reference_note` there often carries the campaign name).
- **`campaign_name` is an internal naming convention**, not guest-facing: `d:260626 | st:automated | a:new_accounts | ch:sm | cm:$5_first_orders`. Prefer `campaign_external_name` for anything a stakeholder reads, falling back to `campaign_name` when it's NULL.
- Some campaigns are clearly test artifacts — `issued_offer_listener_test - ISSUED_OFFER` produced 7.1M events for 46,283 members in 27 days. Sanity-check names before reporting a campaign leaderboard.
- `campaign_type = 'messaging'` campaigns still appear (e.g. `VIP User Tier Assignment`) because their *behaviour* events are participation. Not a contradiction with the exclusion above, which is about `action`, not `campaign_type`.
- 818 campaigns exist in `campaign_attributes`; only ~535 have activity.

## Open items

- [ ] Reconcile SessionM campaign ids against Braze campaign ids so cross-platform campaign reporting is possible.
- [ ] Decide whether a pre-aggregated daily participation summary in `claude` is worth it, given the partition-filter discipline this view demands.
- [ ] Identify and flag test campaigns so they can be excluded automatically.
