# Data Dictionary: `marketing-data-442316.holdout`

Owned holdout assignment for Braze messaging (ledger D-052). Replaces the Braze Global Control Group and Braze-drawn flight holdouts with a draw keyed on the person, not the Braze profile. **Steward-owned. Hashes and Braze ids only, no raw email or phone.** Reporting reads `assignment`; Braze attributes are only the enforcement switch.

Built 2026-11-04. Build scripts: `sql/holdout.ddl.sql` (objects), `sql/holdout.refresh_profile_anchor.sql` (nightly anchor refresh, not yet scheduled).

## The rule

`bucket = mod(int(first 8 hex of sha256('<seed>|<anchor_key>')), 10000)`, 0 to 9999. Holdout when `bucket < holdout_pct * 100`.

- **Seed** = `layer_register.layer_code`: the flight code for a flight (`2611_cottage_cheese`, the same text as the `fl:` name token), `global_<year>` for the global holdout. A different seed per layer makes layers independent (measured 2026-10-30 on 6.9M keys: 5% x 20% overlap 0.996% vs 1.0% expected).
- **Anchor key** (phase 1, email first): `em:` + `to_hex(sha256(lower(trim(email))))`; else `ph:` + sha256 of `+1XXXXXXXXXX`; else `bz:` + braze_id. `em:` anchors equal `concat('em:', claude.order_customer.mapped_email_hash)`, which is how outcomes join.
- Python reference: `int(hashlib.sha256(f"{seed}|{anchor_key}".encode()).hexdigest()[:8], 16) % 10000`. `holdout.bucket('global_fy27', 'em:abc123')` = 1226 in both.

## Objects

| Object | Type | Grain / purpose |
|---|---|---|
| `bucket(seed, anchor_key)` | function | The rule above |
| `email_anchor(email)` | function | `em:` anchor, NULL when blank or no `@` |
| `phone_anchor(phone)` | function | `ph:` anchor; 10 digits get a leading 1, 11 must start with 1; placeholders (`9999999999`, `0000000000`, `1111111111`, `1234567890`, `5555555555`) return NULL |
| `layer_register` | table | One row per layer (global or flight): seed, %, status, dates, audience. `layer_code` never changes once status leaves `planned` |
| `profile_anchor` | table | One row per Braze profile: `braze_id`, `external_id`, `anchor_key`, `anchor_type`. Sticky: set at first sight, upgraded only from `bz`/`ph` to `em` (logged) |
| `anchor_change_log` | table | Every anchor change after first sight |
| `assignment` | table | Append-only: layer x anchor, bucket, arm, `assigned_at`, `released_at`. The record of truth for reporting |
| `braze_feed_desired` | view | Desired Braze state for active layers: `cz_global_holdout`, `cz_program_holdouts` (array of flight codes). Only profiles with a holdout appear |

## Initial load (2026-11-04, from `braze.users`, 4,425,540 profiles)

| anchor_type | Profiles | Anchors | Anchors on 2+ profiles | Profiles sharing an anchor | Max profiles per anchor |
|---|---|---|---|---|---|
| `em` | 1,959,319 | 1,859,149 | 82,339 | 182,509 | 29 |
| `bz` | 2,465,803 | 2,465,803 | 0 | 0 | 1 |
| `ph` | 418 | 417 | 1 | 2 | 2 |

- **182,509 profiles share an email with another profile.** Braze's per-profile draws can split these; the owned draw cannot.
- **`bz` profiles are mostly unmatchable**: 2,152,500 carry a numeric (Pulse) external_id with no email or phone in Braze, and only 2,555 of those map to an email hash through `claude.order_customer.pulse_customer_id` (the backdated-id problem, D-021); 313,295 are web SDK UUIDs. They get a profile-level draw so in-app and banner holdouts stay consistent, but they never enter a read because their orders can't be joined.
- Preview of a 5% `global_2027` draw: `em` 4.98%, `bz` 5.01%.
- `global_2027` is registered as `planned`; nothing is assigned and nothing reaches Braze until it is `active`.

## Gotchas

- **Read outcomes on `em` anchors only**, joined `concat('em:', mapped_email_hash) = anchor_key`. A `bz` or `ph` anchor has no order link.
- **Never change a seed after the freeze.** A one-character change reshuffles everyone.
- **Phone linking is phase 2 and not built.** Two different emails tied by one phone currently get two anchors. Measure the share before building it.
- `braze_feed_desired` is a view of intent, not a sync log. The Braze CDI feed and its change tracking are added when the first custom attribute is created.
