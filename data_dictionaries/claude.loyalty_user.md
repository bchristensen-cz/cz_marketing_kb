# `claude.loyalty_user`

**One row per SessionM loyalty member.** The identity spine for all `claude.loyalty_*` views — it resolves a SessionM `user_id` to the Cafe Zupas external id used by the order marts, and carries program membership and tier.

| | |
|---|---|
| Type | View (no partition column — 1.77M rows, full scans are cheap) |
| Grain | 1 row per `sessionM.users.user_id` |
| Upstream | `sessionM.users`, `sessionM.external_user_mappings`, `sessionM.tier_member_history`, `sessionM.tier_levels` |
| Build script | `sql/claude.loyalty_views.sql` |
| Created | 2026-07-28 |

## Columns

| Column | Type | Description |
|---|---|---|
| `user_id` | STRING | SessionM user id (GUID). Primary key. Join key for all other `loyalty_*` views |
| `sm_external_user_id` | INTEGER | Cafe Zupas external id. **Joins to `sales_ops.order_customer.sm_external_user_id`** — verified 100% match. Sourced from `external_user_mappings` where `external_user_id_type = 'cafezupas'`; the most recently updated mapping wins when a member has more than one |
| `player_id` | INTEGER | SessionM internal player id. **Not** the order-mart join key — only ~23% of order-mart ids match it. Present for upstream debugging only |
| `email` | STRING | Lowercased, trimmed. Populated for effectively every member |
| `email_domain` | STRING | Part after the `@` |
| `first_name` | STRING | |
| `last_name` | STRING | |
| `birthdate` | DATE | Self-reported. Drives the Birthday Free Dessert offer |
| `zip` | STRING | |
| `country` | STRING | |
| `registered_date` | DATE | From `users.registered_timestamp` — loyalty enrollment date |
| `loyalty_status` | FLOAT | Raw SessionM status code. Semantics undocumented; don't filter on it |
| `registered_application_id` | INTEGER | App the member signed up through. Join to `sessionM.applications` for the name |
| `member_program` | STRING | **`'individual'` / `'catering'` / `'both'` / NULL.** Derived from the tier system — the canonical catering-vs-individual split. NULL = registered but in no current tier system |
| `is_individual_member` | BOOLEAN | Current member of the Cafe Zupas VIP Program |
| `is_catering_member` | BOOLEAN | Current member of the Cafe Zupas Catering Program |
| `catering_tier_name` | STRING | `Silver` / `Gold` / `Diamond`. NULL for individual members |
| `catering_tier_rank` | INTEGER | Numeric rank of the catering tier |
| `catering_tier_joined_date` | DATE | When the member entered their current catering tier |
| `individual_joined_date` | DATE | When the member entered the VIP program |
| `created_date` | DATE | SessionM record creation |
| `updated_date` | DATE | SessionM record last update |

## Program membership

Membership is read from `tier_member_history` filtered to `exited_at is null` (current membership only):

| `tier_system_id` | Name | `member_program` | Members |
|---|---|---|---|
| `0B6461B8-B1D5-4D81-8C31-2F21A914DE1C` | Cafe Zupas VIP Program | `individual` | 1,684,999 |
| `1D7B47AB-E3FE-4E62-916F-01973964B662` | Cafe Zupas Catering Program | `catering` | 89,940 |
| `23755DBF-29D9-4A7B-AD2E-0E411EDF7815` | `[CATest]` test system | *excluded* | 10 |

Distribution as of 2026-07-28:

| `member_program` | Members | With `sm_external_user_id` |
|---|---|---|
| `individual` | 1,684,999 | 1,684,820 |
| `catering` | 89,940 | 89,931 |
| `both` | 3 | 3 |
| NULL | 766 | 629 |

## Gotchas

- **`member_program` is the catering/individual answer, not `point_account_name`.** The tier system is cleaner (3 members in both systems vs 264 holding both point accounts) and broader (89,940 catering members vs 43,030 with a catering point account — the account only appears once a member has points). See `claude.loyalty_points_balance.md` for the disagreement counts.
- **The VIP program has a single flat tier level** (`Tier Level 1`), so there is no individual-side tier hierarchy to report. Only catering has Silver/Gold/Diamond. Don't offer "tier breakdown" for individual members.
- **`member_program = 'both'` is a data-quality artifact**, not a real state (3 members). Exclude or call it out rather than reporting it as a segment.
- **6,791 members have more than one `cafezupas` external id.** The view picks the most recently updated. If exact identity matters, check `external_user_mappings` directly.
- **Only the `cafezupas` external id type is used** (steward, 2026-07-28). `external_user_mappings` also holds ~1.33M `amperity` rows; they are deliberately not exposed.
- `player_id` looks like a plausible join key and is not one — 48,064 of 211,541 order-mart ids match it by coincidence of range. Use `sm_external_user_id`.

## Open items

- [ ] `loyalty_status` semantics undocumented — get the code list from SessionM.
- [ ] Tier *progression* (movement between Silver/Gold/Diamond over time) needs the unfiltered `tier_member_history`; not yet exposed.
