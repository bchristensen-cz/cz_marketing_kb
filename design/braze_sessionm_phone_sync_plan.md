# Braze → SessionM Phone Sync — Pre-flight Analysis & Proposed Plan

**Status:** RULES CONFIRMED by Brent 2026-09-04; API semantics verified on one test profile (§4a); plan tables built in `scratch` and checks passed (§5). No batch writes yet — awaiting Brent's review of the sample. Measured 2026-09-04 (steward: Brent).
**Query:** `sql/analysis/braze_sessionm_phone_sync_preflight.sql` (read-only, produces the action plan at SessionM-user grain).
**API:** `PUT https://api-cafezupas.ent-sessionm.com/priv/v1/apps/{SESSIONM_API_KEY_V1}/users/{sessionm user_id}` with a `user.phone_numbers[]` body. Credentials in `.env.local.gitignore` (now gitignored — it was untracked and unignored before this session).

## 1. Goal

Push one clean phone number per customer from Braze into SessionM. SessionM refuses a phone number that already exists on another profile, so before any push we (a) strip junk numbers, (b) collapse phones shared by several profiles down to one owner, and (c) sequence the writes so the number is removed from the old holder before it lands on the new one.

## 2. Rules used (assumptions — confirm or change before execution)

| Rule | Decision |
|---|---|
| Normalization | digits only; 10 digits kept; 11 digits starting with `1` → drop the `1`; anything else invalid. Braze stores no `+1` E.164 values (0 rows), 5,243 are 11-digit. |
| Junk | all one digit (`9999999999`, `8888888888` …), `1234567890`, `0123456789`, `1231231234`, or first digit `0`/`1` (impossible NANP area code). Junk is **removed**, never pushed. |
| Braze scope | profiles with a **numeric** `external_id` only. 46 UUID-keyed profiles carry a phone; they have no SessionM identity and are skipped. |
| Primary owner when several Braze profiles share a phone | most recent activity (latest of `customer_attribute.last_order_date` and last human Braze engagement in 365d) → `lifetime_net_sales` desc → human engagements 365d desc → lowest `external_id`. Recency first because the phone should follow the person who is active now, not the profile with the biggest lapsed history. |
| Engagement definition | human only, 365d: `email_open` (not machine), `email_click` / `sms_shortlinkclick` / `rcs_click` (not bot), `pushnotification_open`, `rcs_read`. Same rules as `braze-campaigns`. |
| Braze → SessionM identity | `sessionM.external_user_mappings` where `external_user_id_type = 'cafezupas'`, latest `updated_at` per `external_user_id` (585 external ids map to >1 SessionM user; latest wins). |
| SessionM current phones | `user_phone_numbers`, latest row per `(phone_number_id, user_id)`, `deleted_at is null`. The raw table has 14,795 `phone_number_id`s appearing under several `user_id`s — the id is per **number**, not per row, so shared numbers show up as one id on many users. |
| Losing Braze profiles | phone **cleared in Braze** too (so the two systems agree and the next sync doesn't resurrect the conflict). Not counted as SessionM calls. |
| Payload | `phone_type = 'mobile'`, `preference_flags = ['primary']`, `verified_ownership = false`. `user.first_name` / `last_name` / `user_profile` **omitted** — phone only. |

## 3. The numbers

### SessionM today
| Measure | Value |
|---|---|
| Active (user, phone) rows | **396,466** |
| Users with a phone | 396,416 (32 users hold 2–3 phones) |
| Distinct phone numbers | 374,379 |
| Junk rows to remove | **6,605** (6,390 of them are `9999999999` — one number on 6,390 profiles) |
| Clean phones held by >1 user | 14,443 phones on 30,108 users → **15,665 surplus holder rows** |
| …of which Braze can decide the owner | 14,119 phones; **324** phones have no Braze signal on any holder (fall back to most recently updated holder) |
| Users left with a clean phone after cleanup | ≈ 389,818 → 374,153 |

### Braze today
| Measure | Value |
|---|---|
| Profiles | 4,329,733 (1 NULL `external_id`) |
| Profiles with any phone | 1,257,944 |
| …valid 10-digit after normalization (numeric ext id) | 1,257,433 |
| …junk numbers to clear | **10,406** |
| Clean phone profiles | 1,247,027 holding **1,131,899 distinct phones** |
| Profiles sharing a phone | 219,743 profiles across 104,615 phones (max 144 profiles on one number) |
| Primary owners (winners) | **1,131,899** |
| Losers — phone to clear in Braze | **115,128** |
| Winners chosen with **no** sales or engagement signal (contested phones only) | 1,159 — falls to lowest `external_id`; worth a spot check |

### Braze → SessionM push (winners only)
| Outcome | SessionM users | Notes |
|---|---|---|
| Winner's `external_id` has **no** SessionM mapping | **31,077** | cannot push — no loyalty account |
| Winners mapped to SessionM | 1,100,822 → **1,100,787** users (69 rows collapsed where 2 Braze profiles map to one SessionM user; lowest ext id kept) | |
| ① Already correct — no-op | **343,775** | |
| ② SessionM has it plus an extra phone to drop | **18** | |
| ③ SessionM has no phone → **add** | **756,161** | the bulk of the work |
| ④ SessionM has a different phone → **replace** | **833** | |
| Conflicts inside ③/④: winner's phone currently sits on **another** SessionM user | **11,561** winners / **12,090** holder rows | must be removed from the other user **before** the PUT or SessionM rejects it |

**PUT calls with a phone change: ≈ 756,994** (③ + ④), plus ≈ 12,090 removal PUTs for conflict holders, plus 6,605 junk removals and the residual SessionM-internal surplus not already covered by the conflict set. Order of operations per number: remove from losers → PUT to winner → verify.

Tie-out: 343,775 + 18 + 756,161 + 833 = 1,100,787 ✓.

## 4a. API test on the Ashley profile (2026-09-04) — verified

Test subject: SessionM user `61af8800-016d-11f1-8e6c-443aac110010` (external id 12520552), baseline phone `8016689089`, restored to that exact state at the end.

| Step | Call | Result |
|---|---|---|
| Baseline | `GET /users/{id}` | 200; `phone_numbers` = [8016689089 mobile/primary/unverified], matches BigQuery |
| Idempotency | `PUT` same number | 200, list unchanged |
| **Replace vs append** | `PUT` a single different number (`8015550100`, reserved 555-01xx, verified absent from both systems) | 200; **the old number was gone** — `PUT` **replaces** the whole `phone_numbers` list |
| **Removal** | `PUT` `{"user":{"phone_numbers":[]}}` | 200; list empty — the empty array is the remove call |
| Restore | `PUT` original number | 200; GET confirms baseline |

Consequences for the design: one call shape covers add, replace and remove; the "drop extras" case (②) is just a PUT with the winner alone; conflict holders are cleared with the empty array. The response body echoes the resulting `phone_numbers`, so the worker can verify from the PUT response and only needs a GET on non-200s.

**Not yet tested — conflict behaviour.** Attempting to PUT a number that another SessionM user currently holds was not run: the only candidate second profile was a real customer's, and the auto-mode classifier blocked the call. Needs a second profile Brent controls. Until then the design assumes SessionM rejects the PUT (Brent's statement), and the worker treats any non-200 on a PUT as "stop, log, do not retry blindly".

## 4. Open questions for Brent (blocking execution)

1. ~~Replace or append?~~ **Resolved — replace (§4a).** Remaining: run the conflict test on a second profile Brent owns, to learn the exact error code/body.
2. **Rate limit / batch size** for the v1 users endpoint — not documented in the KB. Plan: 5 req/s with retry, ~757K calls ≈ 42 h at that pace; confirm the ceiling with SessionM.
3. **Clear the phone on the 115,128 losing Braze profiles?** Assumed yes (via `/users/track` with `phone: null`). Otherwise the next Braze→SessionM run re-creates every conflict.
4. **Household numbers.** The owner rule gives the number to one profile. `crm_identity_hygiene_plan.md` §7.4 deliberately keeps phone out of merge logic for this reason; here we are not merging, just choosing who carries the phone in SessionM. Confirm that is acceptable for SMS consent purposes.
5. **Ordering with the identity cleanup.** Many of the 219,743 Braze phone-sharers are the same human under guest-checkout duplicate ids (`customer_id_map`). Running the phone sync first is fine, but the winner rule should later be re-derived on `canonical_cust_id` so a merge doesn't move the phone back.

## 5. Execution tables — BUILT in `scratch` 2026-09-04 (dry run, no API calls)

Build script: `sql/scratch.sessionm_phone_sync_plan.sql`. Checks: `sql/checks/sessionm_phone_sync_plan_checks.sql`. Steward chose `scratch` over `sales_ops` for all of these.

| Table | Grain | Rows |
|---|---|---|
| `scratch.braze_phone_ranked` | 1 row per clean Braze phone profile, `rn = 1` is the owner | 1,247,027 |
| `scratch.sessionm_phone_sync_plan` | 1 row per SessionM user whose phone list changes; `request_body` is the exact PUT payload | **790,523** |
| `scratch.braze_phone_clear_plan` | 1 row per Braze profile whose phone should be cleared | 126,068 (10,871 junk + 115,197 losers) |
| `scratch.sessionm_phone_sync_log` | 1 row per API call attempt (empty until the first live batch) | 0 |
| `scratch.sessionm_phone_sync_review_sample` | up to 40 rows per action group for eyeballing; exported to `artifacts/phone_sync/…review_sample_2026-09-04.xlsx` | 258 |

### Desired-state model
Instead of listing individual add/remove operations, the plan holds each user's **current** and **desired** phone list and derives the PUT from the desired list (PUT replaces, so one call shape covers everything). Desired list = `[winner phone]` for a Braze-winner target; for everyone else, their current clean phones minus junk, minus any number a winner claims, minus numbers where another non-target holder was updated more recently.

### Phases (a number is always freed before it is granted)
| Phase | Meaning | Rows |
|---|---|---|
| 1 | pure removals — junk (6,333), conflict holders for a Braze winner (26,553), SessionM-internal duplicate losers (559), winners dropping an extra (18) | 33,463 |
| 2 | replace — SessionM has a different number than the Braze winner | 832 |
| 3 | pure adds — SessionM has no phone | 756,228 |

The conflict-holder count is larger than §3's 12,090 because it also includes holders of numbers whose Braze winner *already* has the number in SessionM (the no-op winners) — those are the SessionM-internal duplicates that Braze happens to resolve.

### Integrity checks (all passed 2026-09-04)
Final state has **0** phones on more than one user, **0** junk numbers, **0** adds whose current holder is not scheduled to release the number in an earlier phase, and **0** users left holding more than one phone.

### Batch 001 — first live run, 2026-09-04 19:38 MT ✅
50 phase-1 `junk_only` users (all `[9999999999]` → `[]`), run by Brent from `scripts/sessionm_phone_sync_batch.ps1`. Dry run first (GET-only): 50/50 still matched the plan snapshot, no drift. Live: **50/50 succeeded, 0 stale, 0 failed, 22.9 s sequential**. Timings from the response log: GET avg 152 ms (max 392), PUT avg 300 ms (max 381), no throttling signs. Results loaded to `scratch.sessionm_phone_sync_log` (`batch_label = 'batch_001'`) and the 50 plan rows set to `succeeded`.

Two observations for the worker: after a clear, SessionM echoes `phone_numbers: null`, not `[]` — compare as empty, not literally. And a sequential worker doing GET+PUT runs at ~2.2 users/s; PUT-only would be ~3.3/s. Extrapolated single-threaded: phase 1+2 (~34K) ≈ 3–4 h, phase 3 (756K) ≈ 63 h. Concurrency is the lever — test 4 and 8 parallel workers on batch 002 and watch for 429s.

`*_results.jsonl` files are gitignored: the raw PUT response is the full user object (email, name), which does not belong in the repo.

### SMSync test t1 — 2026-09-04 21:33 MT ✅ (SM Sync job 90035, input file 92954, template 6)
20-row `_user_update.csv` (Ashley + 19 real phase-3 adds), files in `artifacts/phone_sync/smsync_test/`. Job status `success`, file state `split`, no error; created 03:33:51 UTC, completed 03:34:25 — **34 s end to end for 20 rows**, all 20 profiles stamped `updated_at` 03:34:10–11. Verified by API GET on every row: exactly the one number each, `mobile` / `primary` / `verified_ownership=false` carried through. Logged as `batch_label = 'smsync_t1'`; the 19 real plan rows are `succeeded`.

What t1 proves: the importer accepts our column shape, keys on `external_id` by default, and the **add** path (phase 3) works by file. **t2 PASSED 2026-09-04 21:49 MT (job 90037, file 92956):** Ashley → [8015550101] replaced [8015550100]; the importer **replaces** the whole list, same as the API → phase-2 replaces (832) can go by file. **t3 PASSED 2026-09-04 22:53 MT (job 90042, file 92961):** Ashley → `[]` cleared the list (`updated_at` 04:53:10). **All three action shapes — add, replace, remove — work by file, so every phase can go through SMSync.** **t4 RESULT 2026-09-04 23:21 MT (job 90045, file 92964) — SessionM does NOT enforce phone uniqueness.** Row: Brent (cafezupas 6860889) → [8015550102] while Ashley held it. Job `success`, file `Error` empty — and **both profiles ended up holding 8015550102**. No rejection, no report, no move: a silent duplicate. Then probed the REST API the same way (PUT Ashley's real number onto Brent): **HTTP 200, duplicate created.** Neither channel rejects a number another profile holds. Both profiles restored (Brent → 8016995272, Ashley → 8016689089).

Consequences:
1. **"One phone per number" is not enforced by SessionM at write time** — it is a rule *we* must guarantee. The 14,443 already-shared numbers in `user_phone_numbers` are consistent with this. Whatever breaks downstream when a number is shared (phone lookup at POS, SMS routing) is what the constraint protects; the write path won't save us.
2. **A green job is not evidence of a correct outcome.** Per-row failures — if they exist at all — are invisible in the console. Every phase must be verified from the next morning's `sessionM.user_phone_numbers` load with the checks in `sql/checks/sessionm_phone_sync_plan_checks.sql` (0 phones on >1 user, 0 junk) before the next phase drops.
3. The plan's own integrity checks are now the *only* uniqueness guarantee. They passed (0 duplicates in the final state) — keep them mandatory after every rebuild.
4. Phasing (remove → replace → add) is no longer needed to avoid rejections, but keep it: it is cheap and it avoids a window where two live profiles share a number.
5. The 585 external ids mapped to several SessionM users and the 69 SessionM users with two Braze winners are now real duplicate risks, not theoretical — the plan already resolves both deterministically; verify they came out single-owner after phase 3.

Also learned: the REST `user.external_id` returns the most recently updated mapping (an **amperity UUID** for 708,169 of 790,454 plan users); SMSync resolves `external_id` against **any** mapping (18 of t1's 19 real users were amperity-latest and all landed on the cafezupas id). Files stay keyed on the cafezupas id. The admin console at *Admin & Rights 2.0 → All SM Sync Jobs* answers the "is it done yet" question and shows a per-file `Error` column; whether per-**row** rejections surface there is what t4 will tell us.

### Bulk delivery — decided 2026-09-04 23:40 MT: two SMSync files, no phasing
Brent's call after t4: since SessionM rejects nothing, phases buy no acceptance benefit. `scratch.sessionm_phone_sync_file` holds one row per planned user with the cafezupas `external_id` to key on and the final `phone_numbers` JSON. Keying rule: the Braze winner's id when it maps to exactly one SessionM user, else the user's lowest cafezupas id that does; **95 users have no unambiguous id (13 none, 82 shared) — `file_no = 0`, held out for API-by-user_id later.**

| file_no | Rows | Contents |
|---|---|---|
| 1 (pilot) | 10,000 | stratified: 700 junk-only + 700 conflict-holder + 555 SM-duplicate removals, all 830 replaces, 18 drop-extras, 7,197 adds |
| 2 | 780,359 | everything else (748,984 adds, 25,812 conflict-holder removals, 5,575 junk-only) |

File 1 built 2026-09-04 by paging the connector (3,000 rows/call); file 2 must be exported by Brent (`EXPORT DATA` to `gs://sessionm/phone_sync_exports/…` — the classifier blocks the automated session from writing customer phones to GCS). Files with customer numbers are gitignored. Verify each file by GET sample after the job, then the full check against the next morning's `user_phone_numbers` load before file 2 drops.

### File 1 (pilot) — dropped 2026-09-04 23:52 MT ✅ with two findings
SM Sync job **90048**, input file 92967, importer job 546884: **10,000 records, Num Failed 0, 100%**, 05:52:50 → 06:01:45 UTC = **8 min 55 s ≈ 19 rows/s** (file 2 at that rate ≈ 11.5 h). The expanded console view (Job → Input File → Importer Jobs) is where the per-row `Records Count` / `Num Failed` live — the job-level page hides them.

GET sample of 138 users stratified across all six action types (`scripts/verify_sample.ps1`): **137 match**, every removal / replace / drop-extras case correct. The one miss is a **deleted user** — SessionM returns `user_not_found`, and `sessionM.privacy_requests` shows a completed deletion from 2025-03-14 — yet the importer counted it as neither failed nor errored.

Two consequences:
1. **Deleted users were in the plan.** The BigQuery `users` / `external_user_mappings` snapshots retain profiles SessionM has erased. 1,402 such users (1,401 completed + 1 in-progress request) were in file 2 → moved to `file_no = 0`, `status = 'held_out_privacy_request'`. 30 were already in file 1: **check tomorrow's load for any NEW user carrying their cafezupas external_id** — if the importer upserted, it resurrected erased profiles with a phone number and they must be deleted again. The build script now needs a `privacy_requests` exclusion.
2. **`Num Failed` does not count unknown users** (nor, from t4, conflicts). It will catch malformed rows; it will not catch semantic problems. The BQ-load verification stays mandatory.

Plan rows for file 1 are `sent_smsync_file1_job90048` (not `succeeded`) until the full load check passes. File 2 is now **778,957 rows**.

### File 1 full verification — 2026-09-05 12:20 MT ✅ 9,988 / 10,000
All 10,000 file-1 users GET-checked against the live API (`scripts/verify_sample.ps1`, ~2 h sequential). **9,988 match exactly**; every drop-extras (18/18), conflict-holder (700/700) and SessionM-duplicate (555/555) removal landed. 12 mismatches: **10 are `user_not_found`** — all among the 30 users flagged with a privacy request, i.e. genuinely deleted in SessionM (the other 20 flagged users still exist and were updated, so not every privacy request is an erasure). **2 `junk_only` users still hold `9999999999`** (`0de07a7a…`, `fa425e48…`): both have two cafezupas ids, we keyed on a unique one, the importer reported no failure and did nothing visible. Open question whether it silently created a *new* user for that external_id — check the next good BQ load for new `users` rows carrying `1799484` / `2184236`, and for the 10 deleted users' ids. Plan statuses: 10,057 `succeeded`, 10 `user_deleted_in_sessionm`, 2 `file_row_not_applied_investigate`.

**Mart verification was impossible today:** the SessionM loader ran at 03:50 MT Sat but rewrote every table with Thursday's data (row counts identical, `etl_time` still 2026-09-04 02:38) and left `privacy_requests` **empty**. Loader defect — the Cloud Run job needs a look before the mart can be trusted for file-2 verification. API GET sampling is the fallback.

### Worker (not built)
Cloud Run job draining the plan in `(phase, action_id)` order: write the log row, PUT `request_body`, compare the echoed `phone_numbers` to `desired_phones`, mark `succeeded` / `failed` / `conflict`. Non-200 on a PUT = stop the batch and inspect; never blind-retry. Dry run on 50 users → 5,000 → the rest. Braze side: `/users/track` with `phone: null` for every row in `braze_phone_clear_plan`, after the SessionM phases complete.

## 6. Gotchas recorded this session

- `sessionM.user_phone_numbers.phone_number_id` is keyed by the **number**, not the row: 14,795 ids appear under several `user_id`s. Always dedupe on `(phone_number_id, user_id)`.
- `9999999999` sits on **6,390** SessionM profiles and `9999999999`/`8888888888`-style junk on 10,406 Braze profiles — any phone-keyed join must strip junk first or it fans out by thousands.
- `braze.users.phone` is never E.164 (`+1`) — 1,252,237 are 10 digits, 5,243 are 11 digits with a leading `1`, 465 are unparseable.
- 585 `external_user_id`s in `external_user_mappings` (type `cafezupas`) map to more than one SessionM `user_id`; and 69 SessionM users receive two Braze winners. Both are small but must be handled deterministically.
- `sessionM.user_phone_numbers` has rows with a NULL `phone_number`; they are excluded from the plan (an array with a NULL element fails the build).
- `gcloud` auth on the Windows machine had expired 2026-09-04 (`bq` needs `gcloud auth login`); the review sample was exported through the MCP connector instead.
- `.env.local.gitignore` was **not** ignored by git despite its name (`.gitignore` only listed `CLAUDE.md`). Added `.env.local.gitignore` and `.env*` to `.gitignore` 2026-09-04.
