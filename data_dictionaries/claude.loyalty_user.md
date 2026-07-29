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
| `email` | STRING | Lowercased, trimmed. Populated for effectively every member. **This is the identity key — not `email_normalized`** |
| `email_domain` | STRING | Part after the `@` |
| `email_normalized` | STRING | `email` with a leading `cater_` stripped. **Display and outbound comms only — never an identity or join key.** See the catering-alias gotcha |
| `is_cater_email` | BOOLEAN | `email` starts with `cater_`. A *provisioning* artifact, **not** a membership flag — use `is_catering_member` for that |
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
| `was_ever_catering_member` | BOOLEAN | Has *any* catering tier row, current or exited. 90,124 members vs 89,943 current |
| `catering_first_joined_date` | DATE | First-ever catering tier join, across all stints |
| `catering_last_exited_date` | DATE | Most recent catering tier exit. **Non-null does not mean lapsed** — 2,869 members have an exit date but only 181 are currently out; the rest exited and rejoined. For lapsed use `was_ever_catering_member and not is_catering_member` |
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

## Catering account aliases — the `cater_` email prefix

SessionM enforces unique email addresses, so a guest who needs both a personal and a catering account gets the catering one provisioned as `cater_<their address>`. 90,170 users carry the prefix.

It looks like a free, cheap catering flag. **It is not the canonical one.** Concordance against the catering tier system, measured 2026-07-29:

| Segment | Users |
|---|---|
| Both `cater_` email and catering tier | 90,119 |
| `cater_` email only (never enrolled) | 51 |
| Catering tier only (plain email) | 5 |
| Tier row with no `users` record | 10 |
| Neither | 1,685,533 |

99.93% agreement — but the disagreements are not the reason to avoid it. **The prefix measures a different thing.** All 181 members who exited the catering tier still carry the prefix (100%), because nobody rewrites the email on exit. So `is_cater_email` means *was ever provisioned as a catering account*, never *is a catering member*.

Consequences:

- Counting catering customers by prefix **overstates by 232** (181 exited + 51 never enrolled) and misses 5 live members on plain emails.
- The prefix holds no timestamp, so it cannot answer any as-of-date, cohort, or lapse question. Use `catering_first_joined_date` / `catering_last_exited_date`.
- `email` is user-editable in SessionM; tier membership is system-managed. A support agent correcting an address silently flips a prefix-derived flag with no audit trail.

Cost is not a reason to prefer it either: the prefix scan is 45 MB vs 136 MB for the tier read — 3x on a table that is only 342 MB total, both well under a cent. That is why the tier-derived flags are materialised as columns here: the correct definition is now also the cheap one.

**Rule: `is_catering_member` is canonical. `is_cater_email` is a cross-check and an exploration convenience.**

## Gotchas

- **Never use `email_normalized` as a match or join key.** 39,500 of the 90,161 stripped catering addresses collide with an existing individual account — that collision is precisely what the prefix exists to prevent. Feeding it into the CRM identity match (key = normalized email) would merge 39,500 catering accounts into personal ones and collapse the two loyalty programs into one person id. Strip for display, match on `email`.
- **Strip the prefix with an anchored regex, never `replace()` or `ltrim()`.** `replace(email,'cater_','')` mangles a legitimate `pat_cater_smith@x.com`; `ltrim(email,'cater_')` strips a *character set*, turning `cater_tracy@x.com` into `y@x.com`. Only `regexp_replace(email, r'^cater_', '')` is safe. Verified: 0 emails contain `cater_` anywhere but the start, 0 double prefixes, 0 prefixed rows missing an `@`.
- **`00000000-0000-0000-DEAD-000000000000` is a tombstone sentinel in `tier_member_history`, not a person.** It carries 61 catering tier events. Excluded in this view; exclude it anywhere you join tier history directly.
- **`member_program` is the catering/individual answer, not `point_account_name`.** The tier system is cleaner (3 members in both systems vs 264 holding both point accounts) and broader (89,940 catering members vs 43,030 with a catering point account — the account only appears once a member has points). See `claude.loyalty_points_balance.md` for the disagreement counts.
- **The VIP program has a single flat tier level** (`Tier Level 1`), so there is no individual-side tier hierarchy to report. Only catering has Silver/Gold/Diamond. Don't offer "tier breakdown" for individual members.
- **`member_program = 'both'` is a data-quality artifact**, not a real state (3 members). Exclude or call it out rather than reporting it as a segment.
- **6,791 members have more than one `cafezupas` external id.** The view picks the most recently updated. If exact identity matters, check `external_user_mappings` directly.
- **Only the `cafezupas` external id type is used** (steward, 2026-07-28). `external_user_mappings` also holds ~1.33M `amperity` rows; they are deliberately not exposed.
- `player_id` looks like a plausible join key and is not one — 48,064 of 211,541 order-mart ids match it by coincidence of range. Use `sm_external_user_id`.

## Open items

- [ ] `loyalty_status` semantics undocumented — get the code list from SessionM.
- [ ] Tier *progression* (movement between Silver/Gold/Diamond over time) needs the unfiltered `tier_member_history`; catering join/exit dates are now exposed, but the Silver→Gold→Diamond path is not.
- [ ] 51 accounts carry the `cater_` prefix but were never enrolled in the catering tier. 26 are a Nov 2023 bulk-load artifact; the remaining 25 trickle in at 1–4/month through Jul 2026, so something still occasionally provisions the alias without enrolling the tier. All have `loyalty_status = 0` — possibly abandoned registrations. Worth a dev-team question.
- [ ] 10 catering tier rows point at `user_id`s absent from `sessionM.users` — 1 is the DEAD sentinel, 9 are real UUIDs from Apr–Jun 2026. Same class of upstream referential gap as pulse customer 19192. Not ingestion lag (newest is 2026-05-31).
- [ ] 5 members sit in the catering tier with a plain (unprefixed) email, one of which is `test_duplicae@gmail.com`. Confirm whether the other 4 are intentional.
