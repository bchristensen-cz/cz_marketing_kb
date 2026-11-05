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
| `layer_audience` | table | Append-only: who is eligible for each layer before the draw. Global = every `em`/`ph` anchor; flights = the audience snapshot at `freeze_date` |
| `nightly_refresh()` | procedure | The nightly job, see below |
| `refresh_braze_feed()` | procedure | Step 4 of the nightly job: records only changed attribute values in `braze_cdi_state`, payload holding only the changed keys (`sql/holdout.braze_feed.sql`) |
| `braze_cdi_state` | table | One row per Braze profile ever written: last values sent (`synced_global`, `synced_codes`), `payload`, `updated_at`. Flight codes are only ever added |
| `braze_cdi_feed_v` | view | **Braze CDI source**: `updated_at`, `braze_id`, `payload` |
| `write_assignments(layer_code)` | procedure | Appends `assignment` rows for audience anchors that have none yet; rerunning adds nothing. Smoke-tested 2026-11-04 (20,000 anchors at 30%: 30.05% holdout, 0 arm errors, second call added 0 rows) |
| `assignment` | table | Append-only: layer x anchor, bucket, arm, `assigned_at`, `released_at`. The record of truth for reporting |
| `braze_feed_desired` | view | Desired Braze state for active layers: `cz_global_holdout`, `cz_program_holdouts` (array of flight codes). Only `em`/`ph` profiles with a holdout appear; `bz` profiles are never written |

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

## Nightly job

Scheduled query **`holdout nightly refresh`** (config `6b11698d-0000-2513-988d-94eb2c1f3230`, every day 13:30 UTC = 06:30 MST / 07:30 MDT, owner bchristensen@, created 2026-11-04 through the Data Transfer API). It runs `call holdout.nightly_refresh()` (`sql/holdout.nightly_refresh.sql`), which:

1. refreshes `profile_anchor` from `braze.users` (new profiles in, `bz`/`ph` anchors upgraded to `em`),
2. for every `active` layer, appends new audience anchors to `layer_audience`: the global layer takes every `em`/`ph` anchor; a flight runs its `layer_register.audience_sql` for business dates `greatest(start_date, yesterday - 2)` to yesterday (3-day lookback for late identity),
3. calls `write_assignments` for that layer,
4. calls `refresh_braze_feed`, which writes a `braze_cdi_state` row only when a profile's attribute value changes (smoke-tested: 592 profiles on the first run, 0 rewritten on the second; sample payload `{"cz_program_holdouts":["zz_smoke_flight"]}`).

It creates no tables; it appends to `profile_anchor`, `anchor_change_log`, `layer_audience`, `assignment` and `braze_cdi_state`. Every step is rerun-safe (smoke-tested twice in a row on a throwaway active flight 2026-11-04: 5,113 anchors over 3 days, 30.43% holdout, no duplicates, 1,733 Braze profiles behind the holdout anchors; about 1.5 GB per run). Braze reads `braze_cdi_feed_v` through a Cloud Data Ingestion sync keyed on `BRAZE_ID`, scheduled after this job.

**To launch a flight:** set `status = 'active'` and `start_date` = the automation's launch date in `layer_register`. Buyers from that date are drawn the next morning, days before their day-7 email.

## Layers (decisions 2026-11-04)

| layer_code | Type | Holdout | Status | Dates | Braze writes |
|---|---|---|---|---|---|
| `global_2027` | global | 5% | planned | FY2027: 2026-12-28 to 2027-12-26; quarterly reads at fiscal quarter ends | `cz_global_holdout` on `em`/`ph` holdout profiles only: about 97,657 on first load (123,470 `bz` profiles skipped). Write and sync by 2026-12-21, then turn off the Braze Global Control Group after exporting it (the existing scheduled query `create or replace global holdout` copies Braze's export into `braze.global_holdout` and rebuilds it every 24 hours, so snapshot it to a permanent table first) |
| `2611_item_followup` | flight, automated, no end date | **10%** | **active from 2026-11-05** (automation live 10:00 MT that day) | Email 7 days after purchase unless they bought again recently, so the first emails go out around 2026-11-12 and the Braze attribute must be synced before then | Audience (`audience_sql`, also in `sql/holdout_flights/2611_item_followup.audience.sql`): identified person buyers in `claude.order_lines` of Athlete Bowl, Fall Bacon Grilled Cheese or Italian Sausage Gnocchi Soup, no card-match credit. About 16K buyers a week in October, so roughly 1.6K Braze writes a week at 10%. `cz_program_holdouts` written once per held-out person, never removed. The email step must use "Validate audience at message send". Read per person: entry = qualifying purchase, outcome days 7 to 35, rebuyers in days 1 to 7 dropped from both arms. **Kickoff broadcast to every past buyer is part of this flight**: all-time identified buyers backfilled 2026-11-04 (102,900 people, all history in the order mart through 2026-11-03; 10,292 held out = 10.0%; 11,304 Braze profiles to write), `start_date` moved to 2026-11-04 so the nightly lookback picks up Nov 4. The draft canvas `repeat_buyer_athlete_bowl` (`8516606c`) carries its own Braze Control variant, experiment Control path and `hold out` step; all three must come out before it joins this flight |

**Data point rules that shaped this** (Braze, legacy data point billing): each attribute set costs a data point even when the value is unchanged; setting a whole array costs one; removing or nulling also costs one. So: write only holdout members, sync only changes, never remove flight codes.
