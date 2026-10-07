# Caveats

> Part of the `braze-campaigns` skill. Read `../SKILL.md` first; this file is loaded on demand. **Read it when:** before EVERY Braze answer — the per-channel and per-table traps.
> Content moved verbatim from `SKILL.md` on 2026-10-07 (progressive-disclosure restructure); the rules and dates inside are unchanged.

## Caveats

- **Dedup:** events can repeat (a user opens an email twice). Use `count(distinct external_user_id)` for unique-user metrics, as the templates do. For **total event** counts use `count(distinct id)`, **not** `count(*)` — the Currents merge can emit duplicate `id` rows. See "Currents ingestion integrity" below.
- **Nulls:** filter `program_id is not null` to drop transactional/API messages with no campaign or Canvas attached.
- **Replies:** `sms_inboundreceive` and `rcs_inboundreceive` include `STOP`/`HELP` and other inbound texts. They're tagged `engagement_type = 'reply'` — include or exclude per analysis; don't treat all replies as positive engagement.
- **In-app/banner have no send or delivery** — impressions are the exposure base; keep that asymmetry in mind when comparing rates across channels.
- **Cost:** always keep the `event_date` partition filter. The tables are large. Measured 2026-08-12: a `canvas_experimentstep_splitentry` name-search (`where canvas_name like '%…%'` with **no** `event_date` bound) billed **24.0 GB** in one MCP query; the same session's bounded version of the search cost under 1 GB. "When did this canvas run?" is still a partition-bounded question — start from a recent window and widen in steps rather than dropping the bound to search all history.
- **Workspaces (added 2026-07-22):** event tables carry a `workspace` column — `'cafe_zupas'` (retail) or `'cafe_zupas_catering'` — backfilled for full history. Catering campaign events live in the *same* tables; filter `workspace = 'cafe_zupas'` for retail-only analyses and state which workspace(s) an answer includes.
- **`app_sessionstart` is not app-only (measured 2026-09-17).** The web SDK and landing pages log to the same table: trailing 90 days in the `cafe_zupas` workspace, `platform` splits **web 1,132,440 users** vs ios 257,285 / android 63,241 / landing_page 3,454. Any native-app question must filter `platform in ('ios', 'android')` (lowercase here, unlike the order mart's `'iOS'` / `'Android'`). The canonical **App user** customer definition lives in the sales-ops-orders skill; since 2026-09-22 it is a purchase test only (app order or in-store scan in 12 months), and `app_sessionstart` feeds the descriptive `is_app_session_user` / `app_user_type` split, not the flag itself.
- **Freshness / event maturation (steward rule 2026-07-23):** event tables (`email_send`, `email_open`, clicks, `app_sessionstart`, etc.) keep backfilling for **~2 days** — same-day reads have run **20–25% low**. Treat the most recent 1–2 event days as partial: label them as immature in any answer, and never compare a just-loaded day against matured days (day-over-day on fresh data will always look like a drop). Check `braze.load_watermark` (`watermark`, `updated_at`) before treating recent events as complete.
- **`event_timestamp` is DATETIME, not TIMESTAMP** — comparing it directly to a TIMESTAMP column (e.g., order timestamps when joining Braze events to `sales_ops` orders) fails with `No matching signature for operator > for argument types: TIMESTAMP, DATETIME`. **Do not fix this with `cast(event_timestamp as timestamp)`** — an earlier revision of this file recommended exactly that ("it's UTC, so the cast is safe"), and it is **retracted**: `event_timestamp` is America/Denver local, so the cast asserts UTC on a local value and is 6–7 h early. Use the epoch column instead: **`timestamp_seconds(<alias>.time)`** is a true-UTC TIMESTAMP with no cast and no zone literal. Type error observed tripping analyst MCP sessions 2026-07-23; the wrong fix corrected 2026-09-03.

  > **⚠️ But "cast the Braze side to TIMESTAMP" is only half a rule, and following it alone reproduces the same error backwards** (observed 2026-08-17). **`claude.order_customer.order_datetime` is a DATETIME**, not a TIMESTAMP — so is `order_lines.order_datetime` and `order_customer.opened_time`. An analyst session that did everything else right (`claude` views, `customer_type = 'person'`, partition filters, a matured-cohort bound) failed on
  >
  > ```
  > No matching signature for operator <= for argument types: TIMESTAMP, DATETIME
  > ```
  >
  > because it compared a correctly-TIMESTAMP-cast Braze value to `min(oc.order_datetime)`. **Braze is also internally mixed:** the *event* tables carry DATETIME `event_timestamp`, while `braze.users` profile columns (`push_opted_in_at`, `email_unsubscribed_at`) are genuine **TIMESTAMP**, and `json_value(apps, '$.first_used')` becomes TIMESTAMP the moment you wrap it in `timestamp()` per the app-adoption pattern below. So a single query can hold three different types for "when".
  >
  > **Canonical pairing — use the UTC column on BOTH sides, never a cast (revised 2026-09-03):**
  >
  > | Braze side | Order side | Why |
  > |---|---|---|
  > | **`timestamp_seconds(e.time)`**, or any `braze.users` `*_at` column as-is | **`oc.order_timestamp_utc`** (TIMESTAMP) | ✅ Types match **and** both are true UTC — no cast, no zone literal |
  > | `cast(event_timestamp as timestamp)` / `timestamp(event_timestamp)` | `oc.order_timestamp_utc` | 🚨 Compiles, **6–7 h early** — asserts UTC on a Denver-local value. Was the documented pairing until 2026-09-03; **retracted** |
  > | raw `event_timestamp` (DATETIME) | `oc.order_datetime_local` (DATETIME) | ⚠️ Compiles, silently wrong — Denver clock vs each store's own clock, off by 0–2 h depending on the store's state |
  >
  > The last two rows are the traps worth more than the type error: `order_datetime_local` is **store-local business time** and Braze `event_timestamp` is **Denver-local time**, so neither is UTC and a DATETIME-to-DATETIME comparison type-checks cleanly while being wrong for every store outside Mountain time. In a "did the email precede the order?" or "first app use within 30 days of first order" test, that silently reclassifies every event inside the offset window. **Reach for `order_timestamp_utc` on any cross-source time comparison; keep `order_datetime` for reporting a local time to a human.**
  >
  > Generalisable lesson: a type error is loud and gets fixed in seconds; the timezone error underneath it is silent and survives. When a cross-source join errors on types, pick the column pair that fixes **both** problems rather than casting until it compiles.

  > **✅ 2026-08-20 — the local column was RENAMED to make this mistake visible.** On `claude.order_customer` and `claude.order_lines` it is now **`order_datetime_local`**; `order_datetime` no longer exists there and selecting it errors. `sales_ops.*` keeps the old name. The pairing table above therefore reads: Braze ↔ `order_timestamp_utc` for any comparison, `order_datetime_local` for local reporting only. **If you are wrapping either column in `timestamp()` or `datetime()`, you have picked the wrong one.**

  > **🚨 `timestamp(order_datetime)` is the bare cast, and it is the single most common wrong "fix" for the type error above — observed in 73 of one analyst's 160 queries on 2026-08-19, with `order_timestamp_utc` appearing in **zero** of them.** `timestamp(DATETIME)` with no second argument assumes the value is **UTC**. `order_datetime` is store-local, so the cast produces a timestamp that is *earlier than reality by the store's UTC offset* — and it compiles, runs, and returns a plausible number.
  >
  > **The offset is not a constant, so it cannot be corrected downstream.** Measured on `claude.order_customer`, 2026-08-01 → 08-16, 355,700 orders, `timestamp_diff(order_timestamp_utc, timestamp(order_datetime), hour)`:
  >
  > | True offset | Orders | States |
  > |---|---|---|
  > | 4 h | 7,518 | Ohio |
  > | 5 h | 101,855 | Illinois, Minnesota, Texas, Wisconsin |
  > | 6 h | 159,691 | Idaho, Utah |
  > | 7 h | 78,406 | Arizona, Nevada |
  > | *NULL* | 8,230 | see the NULL box below |
  >
  > The chain spans **four** live offsets, so `timestamp(oc.order_datetime, 'America/Denver')` — which an earlier revision of this file recommended as the explicit fallback, and which is now **retracted** — is wrong for 187,779 of those 355,700 orders (52.8%). There is no single timezone literal that is correct for Cafe Zupas. The bias is also one-directional: every order looks earlier than it happened, so an *order-after-exposure* test **under-attributes** and a *pre-exposure* test over-counts.
  >
  > **Rule: never build a UTC order timestamp yourself.** `order_timestamp_utc` already applies each store's own `timezone_name`. If a `timestamp(` wrapping `order_datetime` appears anywhere in a cross-source query, that query's attribution is wrong.
  >
  > **✅ Update 2026-08-21 — the bare cast now fails loudly on every canonical object, and that closes this hole by construction.** The base-table-wide `order_datetime` → `order_datetime_local` rename (overnight 2026-08-20 → 08-21) means `timestamp(oc.order_datetime)` no longer compiles on `sales_ops.order_customer`, `sales_ops.order_lines`, `claude.order_customer` or `claude.order_lines`. A rename shipped for naming clarity retired a silent-wrong-answer bug as a side effect — worth remembering the next time a rename looks like churn.
  >
  > **🚨 But it survives in one place, and there the cast rule does not even apply.** On the retired `sales_ops.OrderCustomer`, `order_datetime` is a **TIMESTAMP that holds store-local wall-clock time**. Measured 2026-08-21 on BusinessDate 2026-08-15, 26,412 orders, store 1111 excluded: it equals `order_timestamp_utc` on **0** of them, and `timestamp_diff(order_timestamp_utc, order_datetime, hour)` spans **4 to 7 hours** — the same four offsets. So the anti-pattern on that table has **no cast to spot**:
  >
  > ```sql
  > -- ANTI-PATTERN on the legacy table, and there is nothing to grep for
  > and o.order_datetime > timestamp(l.ts)   -- TIMESTAMP vs TIMESTAMP: compiles, runs, off by 4-7 h
  > ```
  >
  > Braze `event_timestamp` cast to TIMESTAMP compared against a TIMESTAMP-typed local clock type-checks perfectly. Observed in 40 queries across two analysts on 2026-08-20. The legacy table carries a correct `order_timestamp_utc` right beside it, used in none of them. **On a cross-source time comparison the review question is "which table?" before "which cast?"** — and the answer for the legacy table is: don't (Asana 1217553975515537).
  >
  > **Why the bad version passes review: the two casts look symmetric and only one is a no-op.** The pattern in the log is
  >
  > ```sql
  > -- ANTI-PATTERN, do not copy
  > , timestamp(order_datetime) as odt                              -- order side
  > ...
  > and timestamp(e.event_timestamp) between c.first_dt              -- Braze side
  >     and timestamp_add(c.first_dt, interval 14 day)
  > ```
  >
  > Identical syntax on both sides, which reads as consistent — and **both are wrong** (correction 2026-09-03: this paragraph previously called the Braze side "a pure relabel" because `event_timestamp` was believed to be UTC; it is Denver-local, so `timestamp(e.event_timestamp)` is 6–7 h early exactly as `timestamp(order_datetime)` is 4–7 h early). Because the two errors run the same direction they *partially cancel* on Mountain-time stores, which is how this shape survived review. The fix is the same on both sides: use the column that is already UTC — `timestamp_seconds(e.time)` and `oc.order_timestamp_utc` — and never wrap a wall-clock DATETIME in `timestamp()`.
  >
  > **Measured damage on the shape that actually runs here** — a per-customer relative window anchored on the first order (`first_dt` → `first_dt + 14 days`) used for onboarding-engagement reporting. The bad anchor is 4–7 h early, so the window is **displaced, not widened**: it imports events from just before the first order and drops an equal slice off day 14. Measured 2026-08-20 on the 2026-07-01 → 07-14 first-order cohort (person, non-catering) against `braze.email_send`:
  >
  > | Relative to the TRUE first-order instant | Email sends | Customers |
  > |---|---|---|
  > | 7 h **before** (imported by the bad anchor) | **2,584** | 2,467 |
  > | first 7 h after | 108 | 108 |
  > | rest of the 14 days | 42,164 | 10,945 |
  >
  > So the displaced window inflates in-window sends by up to **2,584 / 42,272 = +6.1%**, touching **~22% of the cohort**. And the imported events are the worst possible ones for this metric: they are **pre-first-order acquisition sends** — quite plausibly the email that caused the order — being counted as post-first-order onboarding engagement. The number is modest; the attribution is backwards.
  >
  > ⚠️ **A finding inside the finding, and it inverts the obvious guess.** The 7 hours *after* a first order are nearly empty (108 sends) while the 7 hours *before* are ~24x denser. Welcome-series sends do **not** cluster immediately after the first order — these customers were already being emailed before they first ordered. Either they are long-standing subscribers who only just converted, or identity is attaching late (guest checkout / `mapped_cust_id` churn) and the "first order" is not their first. Worth a look on its own; do not assume the welcome flow fires on order.

  > **✅ RESOLVED 2026-08-20 — `order_timestamp_utc` was NULL for stores whose `store_info.timezone_name` was missing, and new stores failed silently** (Asana 1217684772713570). It is built as `timestamp(order_datetime, s.timezone_name)`, and `timestamp()` returns NULL on a NULL timezone rather than erroring — so a newly-opened store was **invisible in every Braze attribution and UTC-windowed analysis** instead of throwing.
  >
  > Fixed in three parts: the six timezone-less stores were populated, the `store_info` build now derives `timezone_name` from `store_state` with an assert, and the **10,771 already-materialized orders ($211,336.89 net) were repaired in place** rather than by mart reload — `order_timestamp_utc = timestamp(order_datetime, timezone_name)` is the build formula exactly, so a targeted UPDATE is provably equivalent and avoids exposing `order_customer`'s untransacted delete+insert to readers.
  >
  > **Two things to carry forward.**
  >
  > **(1) A dimension fix does not repair a materialized fact column.** `order_timestamp_utc` lives in the mart, so populating `timezone_name` changed nothing about existing rows; the daily reload only restates 8 days. Any derived column built from a dimension attribute needs an explicit backfill decision, and "I fixed the dimension" is not the same claim as "the data is right."
  >
  > **(2) It will never be 100% populated, and that's not this bug.** `order_datetime` itself is NULL when an order has no `ClosedTime` — unclosed orders at build time. Measured 2026-08-20 after the repair: **1,374 remaining NULLs over 2026-08-01 → 08-20, all 1,374 explained by a NULL `order_datetime`**, and the great majority are the current day's still-open orders, which resolve themselves. So the health check is not `countif(order_timestamp_utc is null) = 0` — it is `countif(order_timestamp_utc is null and order_datetime_local is not null) = 0`. Anything in that second bucket is a real timezone gap.
- **`braze.users` is not partitioned** — every query against it is a full scan. Touch it once per analysis (or wait for the planned user-dim mart), not inside repeated CTE runs.
- **`braze.users` join key is `external_id`, NOT `external_user_id`** — the event tables call the customer id `external_user_id`; the user dimension calls the same id `external_id`, and there is no `external_user_id` column on it (an MCP query failed on exactly this 2026-08-03: `Name external_user_id not found inside u`). Join `on u.external_id = es.external_user_id`. Its nested columns (`custom_attributes`, `apps`, `devices`, `user_aliases`, …) are all **native JSON** — no `parse_json`, see the `json_keys` note above. App-adoption pattern (mined from working analyst SQL 2026-08-03): one row per user with platform and first-use time via

  ```sql
  select
  u.external_id
  , max(case
        when json_value(a, '$.platform') in ('iOS', 'Android')
         and json_value(a, '$.first_used') is not null
        then timestamp(json_value(a, '$.first_used'))
      end) as app_first_used
  from `marketing-data-442316`.braze.users u
  	left join unnest(json_query_array(u.apps)) a
  	on true
  where 1=1
  and u.external_id is not null
  group by 1
  ```
- **`time` is INT64 epoch seconds on every event table — `extract(hour from time)` fails** with `No matching signature for EXTRACT … FROM INT64` (hit 2026-08-03 on `subscriptiongroup_statechange`; the retry guessed a column called `occurred_at`, which doesn't exist on any Braze table). For hour-of-day use `extract(hour from event_timestamp)` — that is **already a Mountain-time hour** (`event_timestamp` is America/Denver local, see Time columns), so do **not** convert it again; or `local_event_datetime` for the user's own zone. `timestamp_seconds(time)` is the way to get a true-UTC TIMESTAMP and is the column to use in any cross-source comparison — it is *not* optional there (corrected 2026-09-03; this bullet previously called it "never necessary").
- **Subscription-state changes live in `subscriptiongroup_statechange`** (verified schema 2026-08-03): `channel` (`'sms'`, …), `subscription_group_id`, `subscription_status` (`'Subscribed'`/`'Unsubscribed'`), `state_change_source`, plus the standard campaign/canvas identity and time columns, partitioned by `event_date`. This is the table for "why did SMS unsubs spike" questions. No recipe in the templates yet — logged as a KB gap 2026-08-03.
- **`canvas_experimentstep_splitentry` has NO `campaign_*` columns** — it carries `canvas_*`, `canvas_step_*`, `experiment_step_id` and `experiment_split_id`/`experiment_split_name` (plus `in_control_group`) only; `select campaign_name` fails with `Unrecognized name: campaign_name` (hit by an analyst MCP session 2026-08-07). Experiment splits are a Canvas-only feature, so identify the test by `canvas_name` + `experiment_split_name`. Experiment/holdout **lift** analyses (exposed vs control legs joined forward to orders) are a recurring demand shape with no template yet — logged as a KB gap 2026-08-10 (Asana 1217335407819497); until one lands, remember the order-side join must use the marts, never `pulse.*` or legacy `OrderCustomer`, and long canvas windows are expensive (a six-month `canvas_entry` scan bills ~45 GB per run — materialize to `scratch` instead of re-running).
- **🔁 "What campaigns/canvases are currently live?" is the single most-repeated question in this dataset, and answering it by scanning the event tables is the expensive way** (query-log review 2026-08-17). One analyst ran the same discovery set — `select distinct canvas_name from canvas_entry`, `distinct campaign_name from inappmessage_impression`, and `distinct coalesce(campaign_name, canvas_name)` from `sms_send` / `pushnotification_send` / `contentcard_send`, all over a trailing 14 days — on **three separate days** in one four-day window. The `canvas_entry` leg alone billed 3.41, 3.55, 3.67 and 4.14 GiB on successive runs; the whole window's name-discovery came to **~19 GiB to produce a list of names**. Note the cost asymmetry that makes this counterintuitive: `inappmessage_impression` and `sms_send` return the same shape of answer for **0.01 GiB**, because the driver is table size, not the date filter — `event_date` is already pruning correctly, `canvas_entry` is simply enormous. Two consequences:
  - **Discover names on the cheapest table that carries them**, not on `canvas_entry`. If you only need to know whether a canvas is sending, a channel event table (`pushnotification_send`, `contentcard_send`) answers it for a fraction of the bytes.
  **Now four days in five** — the same discovery set ran again 2026-08-17 (`canvas_entry` 4.93 GiB, `campaigns_enrollincontrol` 0.01 GiB), so this is a standing habit rather than a one-off exploration and the directory below is the fix, not an optimisation.
  **And again on BOTH weekend days 2026-08-29 and 2026-08-30** (query-log review 2026-08-31): the full discovery set ran three more times, `canvas_entry` legs billing 3.71–10.26 GiB each, and the weekend's experiment-leg pulls off `canvas_experimentstep_splitentry` (`smsdownload` canvas) added 4.87–13.79 GiB per run — **~50 GiB across the weekend, most of it re-deriving the same name list and leg roster**. Materialize the experiment leg roster to `scratch` once per session (the ~45 GB canvas_entry note above applies to splitentry too).
  **2026-09-02: 4 × ~50 GiB in seven seconds (200.7 GiB).** Two welcome-series lift queries (`canvas_entry`, `event_date between '2026-02-01' and current_date()`, four `d:260209 | a:new | ...` canvas names, joined via `braze.users.email` to an order cohort) each executed twice within 7 s — a saved template firing two loads. 68% of the day's 296 GiB. Same fix: one `scratch` roster per session, and a template that reads it. The cheap discovery legs ran too (`canvas_entry` distinct names, 14 days: 3.40 GiB; `inappmessage_impression`: 0.01 GiB) — the asymmetry above still holds exactly.
  - **Materialize the directory instead of re-deriving it.** A `claude`-layer message directory — one row per campaign/canvas per channel with `first_event_date`, `last_event_date`, `users` — would replace this whole set with a sub-GiB lookup and give every session the same name list. Logged as demand evidence on the campaign-mart task (Asana 1216968637623391); until it exists, run the discovery **once** per session and reuse the result rather than re-scanning per channel.
- **The splitentry rule generalizes: the table prefix tells you which identity columns exist** (hit again 2026-08-10 — an analyst MCP session ran `coalesce(canvas_name, campaign_name)` on `canvas_conversion` and failed with `Unrecognized name: campaign_name`). Three families, verified against the dictionary 2026-08-11: tables prefixed **`canvas_*`** carry canvas identity only (no `campaign_*` columns anywhere); tables prefixed **`campaigns_*`** carry campaign identity only (no `canvas_*` columns); **channel event tables** (`email_send`, `push_send`, `inappmessage_impression`, `subscriptiongroup_statechange`, …) carry *both*, NULL on whichever side didn't send the message. So "all conversions" is a `union all` of `canvas_conversion` and `campaigns_conversion` (note the plural `campaigns_` prefix) with a source label — no single conversion table holds both.
- **`external_user_id` is STRING; `order_customer.mapped_cust_id` is INT64** — joining them raw fails with `No matching signature for operator = for argument types: INT64, STRING` (hit again by an analyst MCP session 2026-07-27). Cast the Braze side.
- **Use `safe_cast`, not `cast` — this is now mandatory, not conditional (upgraded 2026-07-28).** The workspace *does* contain non-numeric `external_user_id` values: `cast(external_user_id as int64)` failed on 2026-07-27 with `Bad int64 value: 05d0a59b-ab22-46d8-b1fa-1577681b…` — a UUID-shaped id. A plain `cast` aborts the whole query the moment one such row is in scope, and which rows are in scope changes with the date window, so a query that worked yesterday can fail today. Always:

  ```sql
  and safe_cast(ce.external_user_id as int64) = oc.mapped_cust_id
  ```

  `safe_cast` yields NULL for the non-numeric ids, which then simply don't join. If you need to know how many you dropped, count them: `countif(safe_cast(external_user_id as int64) is null)`.

  > **🚨 In an experiment, that count is mandatory and it must be PER ARM — the drop is not uniform** (measured 2026-08-27, query-log review). The "count them if you need to know" wording above was too soft for lift analysis: on `canvas_experimentstep_splitentry`, 2026-06-01 → 08-27, **111,867 of 1,884,833 distinct `external_user_id` values (5.9%) are non-numeric** and vanish on the cast. Within one canvas the rate differs by leg:
  >
  > | Canvas | Split | Distinct ids | Dropped by `safe_cast` | % |
  > |---|---|---|---|---|
  > | `d:260824 \| … \| cm:fuel_your_fun_salad_&_bowl` | Control | 175,503 | 10,928 | **6.23%** |
  > | same | Path 1 | 1,583,421 | 100,775 | **6.36%** |
  > | same | Path 2 | 189,932 | 0 | **0.00%** |
  > | `250926 \| … \| Points_Top_Off` | Path 1 | 110,187 | 0 | 0.00% |
  > | same | Path 2 | 6,348 | 0 | 0.00% |
  >
  > Control vs Path 1 happen to drop at nearly the same rate, so a two-arm comparison of *those two* is roughly safe. **Path 2 of the same canvas drops nobody** — it is a structurally different population (UUID-keyed website-SDK profiles are absent from it entirely), so any three-arm rollup silently compares two thinned arms against one intact one. Some canvases drop nothing at all, which is exactly why you cannot reason about this from a single prior measurement.
  >
  > **Rule: emit `countif(safe_cast(external_user_id as int64) is null)` grouped by `experiment_split_name` alongside every lift number, and say the rates in the answer.** A silent drop is only harmless when it is symmetric, and symmetry is a per-canvas empirical fact, not a property of the cast. Observed 2026-08-27: an analyst ran arm-level lift on the salad canvas with no drop count of any kind (and, one query earlier, hit `No matching signature for operator = for argument types: INT64, STRING` — the cast was added to make it compile, not because the dropped population had been considered). Root cause of the non-numeric ids is the website SDK writing UUID-keyed profiles (Asana 1216991762039447 / 1216991653920144); until that lands, this asymmetry is permanent.

  > **🚨 The recurring violation is not the cast — it is bridging Braze to orders through `lower(email)` instead of the id at all** (counted 2026-08-17: **~15 of one analyst's 82 MCP queries**, every one shaped `bu as (select lower(email) em, any_value(external_id) ext from braze.users …)` then `join orders on o.em = bu.em`). Three separate defects ride along with it:
  >
  > 1. **It re-introduces the identity-fragmentation problem the KB exists to route around.** `mapped_cust_id` is the canonical person key; email is not. An email bridge silently merges the duplicate-id clusters the CRM hygiene project is chartered to resolve, and post-2026-07 guest checkout made those clusters the majority of new ids.
  > 2. **Braze merges are not reflected in Currents**, so a merged profile keeps its losing `external_user_id` in `braze.*` forever. An email join papers over that inconsistently — matching whichever profile happens to hold that address today.
  > 3. **It costs a full `braze.users` scan** (the table is unpartitioned) to build a bridge that `external_id` already provides for free.
  
  > **Exception (steward, 2026-09-21): the `braze` dashboard tab bridges on email.** Production keeps no
  > change history of `pulse.customers.id` and backdates it, so Braze holds orphaned `external_user_id`s
  > that no longer exist in `order_customer.mapped_cust_id`. Measured on 60 days of `email_send`
  > (1,014,185 ids): 71.3% match a customer by id, 75.7% by email; the email bridge recovers 48,538 ids
  > (4.8%) the id join loses and drops 4,355 (0.4%) it keeps. For `dashboard.braze_send_day` and the
  > Braze effectiveness tab only, join `lower(es.email_address) = oc.mapped_email` (email sends carry the
  > address on the row); push, SMS and RCS sends bridge through a nightly `dashboard.braze_user_dim`
  > built once from `braze.users`, never a per-query `users` scan. The fragmentation objection above is
  > accepted and does not apply here: the tab counts sends, orders and dollars, not people, so folding a
  > person's duplicate ids onto one address is the intended behaviour. The rule above still holds for
  > customer counts, ad hoc analysis, and anything keyed on `external_id`.  
  
  > Join `safe_cast(<event table>.external_user_id as int64) = oc.mapped_cust_id` directly, and use `braze.users` only for attributes you actually need (app adoption, subscription state) — never as an id translation layer. If someone's saved template does the email bridge, that is a rewrite, not a caveat.
- **`braze.load_watermark.watermark` is already a TIMESTAMP** — it is not epoch seconds. `timestamp_seconds(cast(watermark as int64))` fails with `Invalid cast from TIMESTAMP to INT64` (observed 2026-07-27). Select `watermark` and `updated_at` as-is.
- **`customevent` payloads** — `properties` is a JSON *string*; read fields with `json_value(properties, '$.field')`. Filter `name = '<event>'` **and** the `event_date` partition. `local_event_datetime` gives the user-local time if you need daypart.

  **Verified payload keys (2026-07-23 → 07-29, enumerated not assumed):**

  | Event | Keys actually present | Events |
  |---|---|---|
  | `guest_email_from_order` | `order_id`, `customer_id`, `source_event`, `store_name` | 2,523 |
  | `protein_amount_tracked` | `protein_amount` **only** | 28,813 |

  > **⚠️ Correction 2026-07-31 — `protein_amount_tracked` has NO `$.order_id`.** This skill
  > previously documented one, and it does not exist: **zero** of the 28,813 events in that week
  > carried the key. So the Braze protein event **cannot be attributed to an order, item, or store** —
  > it is a per-user running total and nothing more. Any "protein by order / by store / by daypart"
  > question is unanswerable from `braze.customevent`, and an analyst who trusts the old note will
  > write a join that silently returns nothing. Per-order protein is being rebuilt by the steward from
  > `staging.pulse_item_protein` + `pulse.order_items` (Asana 1216935355461779); until that lands
  > there is no supported source. `guest_email_from_order` is the opposite case — it carries **three
  > more keys than were documented**, including `customer_id` and `store_name`.

  **Discovering what keys an event carries — use `json_keys`, and note the exact spelling.**
  Two separate analyst sessions failed on this on the same day (2026-07-30) by inventing a
  namespace: `bql.json_keys(...)` and `bigquery.json_keys(...)` both error with
  `Function not found`. The function is **bare `json_keys`**, it takes **parsed JSON** (so wrap the
  string in `safe.parse_json`), and the depth argument is **required**:

  ```sql
  select
  e.name as event_name
  , k as property_key
  , count(*) as events
  from `marketing-data-442316`.braze.customevent e
    cross join unnest(json_keys(safe.parse_json(e.properties), 2)) as k
  where 1=1
  and e.event_date between @start and @end
  and e.name = '<event>'
  group by 1, 2
  order by 1, 3 desc
  ```

  Depth `1` gives top-level keys; `2` reaches one level of nesting. Run this **before** writing any
  `json_value` path — it is cheap, and it is the only way to know a documented key still exists.

  > **⚠️ On `braze.users.custom_attributes`, DROP the `parse_json` wrapper** (corrected 2026-08-03).
  > `customevent.properties` is a JSON **STRING**, but `users.custom_attributes` is a native **JSON**
  > column (verified via `INFORMATION_SCHEMA.COLUMNS`), so `safe.parse_json(u.custom_attributes)`
  > errors with `No matching signature` — the previous note here said "the same pattern works," and
  > it doesn't. Use `unnest(json_keys(u.custom_attributes, 2))` directly. A third invented namespace
  > (`bigfunctions.us.json_keys`) failed on this table 2026-08-01 for exactly this type mismatch.
  > `json_value(u.custom_attributes, '$.key')` accepts JSON directly and needs no change. Remember
  > `braze.users` is unpartitioned — full scan every touch, so key-discover once, not per-CTE.
- **The DATETIME/TIMESTAMP trap above is still catching people** — an analyst MCP session hit it again on 2026-07-24 (`order_timestamp_utc` vs a Braze event datetime) despite being documented since 2026-07-23, and again on 2026-08-04 (`min(event_timestamp)` from `canvas_entry` compared `<` to an order TIMESTAMP). If a session is failing on this, it is probably not reading a fresh clone of `main`.
