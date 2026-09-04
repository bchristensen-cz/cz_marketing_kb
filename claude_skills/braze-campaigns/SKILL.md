---
name: braze-campaigns
description: How to query Braze marketing campaign data in BigQuery (dataset braze) — campaign/canvas activity by day and cross-channel customer engagement (email, push, SMS, RCS, banners, content cards, in-app). Use for ANY question about marketing campaigns, campaign sends, opens, clicks, engagement rates, journeys/canvases, or channel performance. Contains the canonical union templates and identity/machine-open rules so every session returns the same answer.
---

# Querying Braze Campaign Data

> **Freshness check:** this file must come from a clone of `https://github.com/bchristensen-cz/cz_marketing_kb` `main` pulled **this session**. If you're reading it from an installed skill package, a fork, or any saved copy, stop and re-clone first — it may be stale.

**Project:** `marketing-data-442316`  **Dataset:** `braze`

A reference for writing SQL against the Braze tables so that Claude and analysts produce **consistent, correct** cross-channel campaign queries without re-deriving the logic each time. It answers two recurring questions:

1. **What campaigns were running on which days?** (historical campaign activity, across all channels)
2. **How did customers engage with a campaign, and what's its engagement rate?** (cross-channel engagement)

The companion templates in this repo are the source of truth for the SQL:

- `sql/braze_campaign_daily_activity.sql` — normalized cross-channel **activity** (sends/exposures).
- `sql/braze_campaign_engagements.sql` — normalized cross-channel **engagement** (opens/clicks/replies) + engagement-rate example.

Both have been validated against BigQuery (dry run, zero errors). Use them as the starting point rather than rewriting the unions by hand — that's where errors creep in. Full column docs: `data_dictionaries/braze_data_dictionary.md` (refreshed 2026-09-03 from live `INFORMATION_SCHEMA` — all 119 tables / 2,651 columns including the streaming-era additions, each tagged Active/Empty with row counts; `.xlsx` twin alongside it).

## Workspaces (added with the 2026-07 streaming switch)

Every event table now carries a **`workspace`** column with two values:

- `cafe_zupas` — main workspace (~99% of volume)
- `cafe_zupas_catering` — separate catering workspace

**Canonical default: filter `workspace = 'cafe_zupas'`** on every base table. Include the catering workspace only when explicitly asked — and when you do, keep `workspace` in the grain, because campaign ids never cross workspaces. Always state which workspace(s) an answer covers when catering is in scope.

## The core idea: one campaign spans many channels and many tables

A single campaign can reach a customer through **email, push notification, SMS, RCS, an in-app message, an on-site/in-app Banner, or a Content Card**. Braze writes each channel's events to **separate tables**, and each event type (send, delivery, open, click, bounce, …) is also its own table. To reason about a campaign as a whole you must **union the relevant per-channel tables together** into one normalized shape, then aggregate.

Channel → table mapping used by the templates:

| Channel | Activity / exposure (campaign "running") | Engagement (opens/clicks/replies) |
|---|---|---|
| Email | `email_send` | `email_open`, `email_click` |
| Push | `pushnotification_send` | `pushnotification_open` |
| SMS | `sms_send` | `sms_shortlinkclick` (click), `sms_inboundreceive` (reply) |
| RCS † | `rcs_send` | `rcs_read` (≈open), `rcs_click`, `rcs_inboundreceive` (reply) |
| Content Card | `contentcard_send` | `contentcard_click` |
| Banner † | `banner_impression` * | `banner_click` |
| In-app message | `inappmessage_impression` * | `inappmessage_click` |

\* In-app messages and Banners have **no send event** in Braze Currents. The closest "the campaign was shown" signal is the **impression**, so the activity template tags these `activity_type = 'impression'` while everything else is `'send'`.

† Added with the 2026-07 streaming switch. **RCS now carries most text-message volume** (~4x SMS) — any "SMS/text campaign" question must include the `rcs_*` tables or it will badly undercount. `rcs_read` is a genuine device read receipt (treated as an open, never a machine open).

Other tables exist per channel (delivery, bounce, abort, unsubscribe, mark-as-spam, soft bounce, etc.) — see `data_dictionaries/braze_data_dictionary.md`. They aren't part of these two templates but follow the same column conventions, so you can add them the same way (e.g., swap `email_send` for `email_delivery` to switch the denominator to delivered).

### Streaming-era tables (added 2026-07)

The switch to streaming ingestion (Currents → `braze_stream` → merged into `braze`) added 50 tables (119 total). Status as of 2026-09-03 (row counts from `__TABLES__`):

- **Active, in the templates**: `banner_impression` (135k), `banner_click` (5k), `rcs_send` (50k), `rcs_delivery` (44k), `rcs_read` (10k), `rcs_click` (6k), `rcs_inboundreceive` (2k).
- **Active, not in the templates** (operational / diagnostic): `rcs_rejection` (6k, `is_sms_fallback` marks RCS→SMS fallback), `rcs_abort`, `email_deferral` (806k), `inappmessage_abort`, `canvas_exit_matchedaudience`, `canvasstep_progression` (287M — granular journey flow), `pushnotification_tokenstatechange` (265k), `webhook_failure` (3.6M), `location` (524k).
- **Present but empty** (channels not in use): `line_*` (LINE), `whatsapp_*` (WhatsApp), `liveactivity_*`, `agentconsole_*`, `featureflag_impression`, `installattribution`, `sms_carriersend`, `pushnotification_iosforeground`, all `*_retry` (incl. `email_retry`), `banner_abort`/`banner_dismiss`, `contentcard_abort`/`contentcard_dismiss`. If these light up, extend the templates the same way.
- **Original-era tables changed too**: 42 of the 69 gained columns — `workspace` everywhere; `is_suspected_bot_click` + `suspected_bot_click_reason` on `email_click` / `sms_shortlinkclick` (and `rcs_click`); `is_sms_fallback` on `sms_delivery` / `sms_deliveryfailure` / `sms_rejection`; `push_token` on push send/bounce.
- **Plumbing — never query for analysis**: `currents_raw`, `load_watermark`, the whole `braze_stream` dataset, `stg_*`, `table_rec_cnt`.
- **Custom attribute feeds** (`bz_cid_*`, `cdi_*`, `users`, `global_holdout`, points/user-id sync tables): Cafe Zupas profile/attribute syncs, not campaign events — out of scope for this skill.

## Identity keys you must understand

Every event row carries both a Campaign identity and a Canvas identity, plus message/variation and dispatch keys. Pick the right grain for the question.

- **`campaign_id` / `campaign_name`** — a Braze *Campaign*. Populated when the message came from a campaign.
- **`canvas_id` / `canvas_name`** — a Braze *Canvas* (a multi-step, often multi-channel journey). Populated when the message came from a Canvas. When a Canvas sends, `campaign_*` is typically empty and `canvas_*` is set.
- **`is_canvas`** — `1` if the message originated from a Canvas, else `0`. Use it to label the source. **Streaming-era tables (`banner_*`, `rcs_*`) don't have this column** — derive it: `case when coalesce(canvas_id, '') <> '' then 1 else 0 end` (the templates already do).
- **`program_id` / `program_name`** (derived, not a real column) — the templates coalesce the two into a single identity so a "campaign" delivered as a Campaign *or* a Canvas lines up:

  ```sql
  case when is_canvas = 1 then 'canvas' else 'campaign' end as program_type
  , coalesce(nullif(campaign_id, ''), canvas_id) as program_id
  , coalesce(nullif(campaign_name, ''), canvas_name) as program_name
  ```

  Group by `program_id` for the broad "campaign or journey" view. If you only want true Campaigns, filter `is_canvas = 0` and group by `campaign_id`.

- **`canvas_step_id` / `canvas_step_name`** — which step of a Canvas produced the event (a Canvas's email step vs SMS step).
- **`message_variation_id` / `message_variation_name`** — the A/B variant.
- **`send_id`** — groups all messages from one send; useful for send-level analytics. Note `sms_shortlinkclick`, `sms_inboundreceive`, `rcs_read`, and the `banner_*` tables have **no `send_id`** (the templates null it); `banner_*` tables also lack `dispatch_id`.
- **`dispatch_id`** — one dispatch batch to a user; usable to tie an engagement back to a specific send.
- **`external_user_id`** — the **Cafe Zupas customer ID**. This is the join key to customers and to other datasets (e.g., `sales_ops`). `user_id` is Braze's internal `braze_id`.

> **`campaign_*` vs `cmpgn_*`:** the export includes both naming styles for the same attributes; `cmpgn_*` is a legacy duplicate. Use `campaign_*`.

## Time columns

- **`event_date`** (DATE, **America/Denver local date**) — the **partition column**. Always filter it (`where event_date between @start_date and @end_date`) in every base table for cost control. This is the date to group by for "by day". It is the Denver-local calendar day of the event, not the UTC date (measured 2026-09-03: `event_date = date(event_timestamp)` on 100% of `email_send` rows every day sampled; the UTC date `date(timestamp_seconds(time))` only matches ~97–99% — the late-evening rows roll to the next UTC day).
- **`event_timestamp`** (DATETIME, **America/Denver wall-clock, follows US Mountain DST**) — precise event time in Mountain time. **It is NOT UTC**, despite earlier revisions of this file saying so. `extract(hour from event_timestamp)` is already a Mountain-time hour. Never wrap it in `cast(... as timestamp)`, `timestamp(...)`, or `datetime(cast(... as timestamp), 'America/Denver')` — all three assert UTC on a local value and land 6–7 hours early.
- **`time`** (INT64, Unix epoch seconds, **true UTC**) — the only unambiguous UTC clock on the event tables. **For a UTC instant use `timestamp_seconds(<alias>.time)`.** This is the Braze side of every cross-source comparison to `order_timestamp_utc`.
- **`local_event_datetime`** — event time in the *user's* zone (`timezone` column; differs from `event_timestamp` for out-of-Mountain users); not present on every table. Use for user-local daypart only.

> **🚨 Verified 2026-09-03 — `event_timestamp` is Denver local, not UTC (Asana 1217708981759181, 1218166682517918).** Measured against `timestamp_seconds(time)` on `email_send`: the gap is exactly **−7 h on a January day** and **−6 h on every summer day** sampled March → September, 100% of rows, both workspaces, pre-streaming history included — zero variance, so it is a clock definition, not drift, and the DST step confirms the zone. An earlier 2026-08-20 pass found the same 360-minute offset on 16.8M events across 8 tables (`canvas_entry`, `email_send`, `email_open`, `pushnotification_send`, `inappmessage_impression`, `inappmessage_click`, `campaigns_enrollincontrol`, `rcs_send`). Verification query (leading commas, lowercase, partition-bounded):
>
> ```sql
> select
> es.event_date
> , es.workspace
> , datetime_diff(es.event_timestamp, datetime(timestamp_seconds(es.time)), hour) as ts_minus_utc_hours
> , countif(es.event_date = date(es.event_timestamp)) / count(*) as pct_event_date_is_local_date
> , countif(es.event_date = date(timestamp_seconds(es.time))) / count(*) as pct_event_date_is_utc_date
> , count(distinct es.id) as sends
> from `marketing-data-442316`.braze.email_send es
> where 1=1
> and es.event_date in (date '2026-01-15', date '2026-03-05', date '2026-03-10', date '2026-06-15', date '2026-09-03')
> group by es.event_date, es.workspace, ts_minus_utc_hours
> order by es.event_date, es.workspace
> ```
>
> Expected: `ts_minus_utc_hours` = −7 before 2026-03-08 and −6 after; `pct_event_date_is_local_date` = 1.0; `pct_event_date_is_utc_date` < 1.0.
>
> **Practical damage.** A session that followed the previous revision converted an already-local value with `datetime(cast(event_timestamp as timestamp), 'America/Denver')` and looked 6 hours early — a 4:42pm broadcast appeared not to have loaded ("data stops at 4:02pm") when the whole 4–6pm send was present. Any hour-of-day / daypart cut built on the old guidance is off by 6–7 h, and any Braze↔orders window built on `cast(event_timestamp as timestamp)` vs `order_timestamp_utc` puts the exposure 6–7 h *before* it happened — an "order after exposure" test silently sweeps in orders that preceded the message, and a 72-hour window is really −6 h → +66 h. This is the same asserts-UTC-on-a-local-value anti-pattern the order-side section below documents for `timestamp(order_datetime)`, now on the Braze side — and because both errors push their clock *earlier* by a similar amount, they partially cancel on Mountain-time stores, which is likely why neither surfaced for a month.

## Conventions these templates follow (team SQL style)

- All lower case; fully-qualified table names with backticks around **the project only** (`` `marketing-data-442316`.braze.table ``, never `` `marketing-data-442316.braze.table` ``).
- **Steward SQL layout (mandatory 2026-07-23, extended 2026-07-29, 2026-08-20 and 2026-08-21, applies to ALL generated SQL):** select list one column per line with **leading commas followed by one space**; **the first field is flush with `select`, not indented**; **`from` / `group by` / `order by` keep their values on the keyword line** (`group by oc.business_date, oc.store_id`) — only the select list is stacked; column aliases use `as` with **exactly one space before it — never padded or column-aligned**; **a `case` with one `when` stays inline, two or more break with `case` / `end` flush and each `when` / `else` indented one tab — no alignment padding either way**; **indentation appears in exactly two places: successive joins with their `on` lines, and multi-branch `case` branches — nothing else**; **every column reference carries its table alias — no bare column names anywhere, even in single-table queries**; CTEs chained `with a as (...)`, `, b as (...)`; `where 1=1` as the first condition, then one `and ...` per line; each join on its own line with `on ...` on the next line lined up beneath the join, **one extra indent per successive join**; short lowercase table aliases (fixed: `order_customer` → `oc`, `order_lines` → `ol`). See the "SQL style" section of `claude_skills/sales-ops-orders/SKILL.md` for the source of truth — **not** the build scripts in `sql/`, which predate the 2026-08-20 layout rules and stay unreformatted so the repo remains diffable against deployed scheduled-query text.
- **All datasets are read-only.** Materialize intermediate results ONLY in `marketing-data-442316.scratch` (the single writable dataset; 7-day auto-expiry). Use `create table`, not views over heavy unions.
- **Early partition filtering** on `event_date` in every base CTE.
- Select only the columns needed.
- No `sales_ops` filters here. `storeid = 1111` exclusion and `iscatering = 0` apply to **order** tables, not Braze.

---

## Pattern 1 — Which campaigns ran on which days

Full template: **`sql/braze_campaign_daily_activity.sql`**.

It unions the seven activity tables (email, push, SMS, RCS, content card, banner, in-app) into a CTE `activity`, then exposes a normalized row per event with `workspace` / `program_id` / `program_name` / `channel` / `activity_type`. Build the "by day" answer on top:

```sql
-- after the normalized select (call it activity_norm):
select
an.event_date
, an.program_type
, an.program_id
, an.program_name
, array_agg(distinct an.channel order by an.channel) as channels_active
, count(distinct an.channel) as channel_count
, count(*) as activity_events
, count(distinct an.external_user_id) as users_reached
from activity_norm an
where 1=1
and an.program_id is not null
group by
an.event_date
, an.program_type
, an.program_id
, an.program_name
order by
an.event_date
, an.program_name;
```

This gives one row per campaign per day, with the channels it ran on and how many customers it reached — the historical "what was live when" view that later analysis builds on. Drop `event_date` from the grain for a per-campaign lifetime summary, or add `channel` to the grain for a day × campaign × channel matrix.

## Pattern 2 — Customer engagement and engagement rate

Full template: **`sql/braze_campaign_engagements.sql`**.

It unions the engagement tables into a CTE `engagements`, normalized to one row per open/click/reply with `program_id`, `channel`, `engagement_type`, the two non-human flags `is_machine_open` and `is_suspected_bot_click`, and their combination **`is_human`** (`not is_machine_open and not is_suspected_bot_click`).

**Did a customer engage with a campaign?** Group the normalized set by `external_user_id` + `program_id` (filter `is_human` for true human engagement). See *Example A* in the template.

**Engagement rate (default denominator = SENT):** the template's *Example B* builds a `sent` base from the send/impression tables and an `engaged` base from the engagement union, then divides distinct engaged users by distinct sent users per `program_id`:

```text
engagement_rate = distinct engaged users / distinct sent users   (per program_id)
```

It reports two variants side by side:

- **`engagement_rate_human`** — `is_human` only: excludes machine opens and suspected bot clicks. Use this as the headline rate.
- **`engagement_rate_all`** — every open/click including machine opens and bot clicks.

Add `channel` to both the `sent` and `engaged` grains for a per-channel engagement-rate breakdown of the same campaign.

### Machine opens (Apple Mail Privacy Protection)

Email `email_open` rows include proxy/"machine" opens (notably Apple MPP) that fire automatically and are **not** human actions. Only `email_open` can be a machine open; the template computes:

```sql
coalesce(lower(machine_open) = 'true', false) as is_machine_open
```

and sets `is_machine_open = false` on all non-email engagements. Default to the human-only metric; keep the all-opens metric available for reconciliation against Braze's dashboard, which counts all opens.

### Bot clicks (added 2026-09-03)

Braze now flags suspected bot / security-scanner clicks with **`is_suspected_bot_click`** (plus a `suspected_bot_click_reason`) on `email_click`, `sms_shortlinkclick`, and `rcs_click`. The template carries it through as `coalesce(is_suspected_bot_click, false)` on those three tables and `false` elsewhere, then folds it with machine opens into `is_human`. Treat bot clicks like machine opens: excluded from the headline rate, retained in the all-events metric.

### Why "sent" as the denominator (and how to switch to delivered)

We default to **sent** because it's consistent across every channel (in-app/banner have no "delivered" event — impressions are the exposure base). It slightly overstates the denominator vs delivered. To switch to a **delivered**-based rate, swap the send tables in the `sent_base` for the delivery tables — `email_delivery`, `sms_delivery`, `rcs_delivery`, and push sends minus `pushnotification_bounce` — and keep impressions for in-app/banner. The rest of the query is unchanged.

## Attribution note (precise vs campaign-level)

These templates attribute an engagement to a campaign by matching `program_id` on both sides — correct at campaign / campaign-day grain. For **stricter** attribution (e.g., this open belongs to this exact send), additionally join engagements to sends on `dispatch_id` (and `external_user_id`), available on most tables. For most reporting, `program_id`-level is the right and simpler choice.

## Caveats

- **Dedup:** events can repeat (a user opens an email twice). Use `count(distinct external_user_id)` for unique-user metrics, as the templates do. For **total event** counts use `count(distinct id)`, **not** `count(*)` — the Currents merge can emit duplicate `id` rows. See "Currents ingestion integrity" below.
- **Nulls:** filter `program_id is not null` to drop transactional/API messages with no campaign or Canvas attached.
- **Replies:** `sms_inboundreceive` and `rcs_inboundreceive` include `STOP`/`HELP` and other inbound texts. They're tagged `engagement_type = 'reply'` — include or exclude per analysis; don't treat all replies as positive engagement.
- **In-app/banner have no send or delivery** — impressions are the exposure base; keep that asymmetry in mind when comparing rates across channels.
- **Cost:** always keep the `event_date` partition filter. The tables are large. Measured 2026-08-12: a `canvas_experimentstep_splitentry` name-search (`where canvas_name like '%…%'` with **no** `event_date` bound) billed **24.0 GB** in one MCP query; the same session's bounded version of the search cost under 1 GB. "When did this canvas run?" is still a partition-bounded question — start from a recent window and widen in steps rather than dropping the bound to search all history.
- **Workspaces (added 2026-07-22):** event tables carry a `workspace` column — `'cafe_zupas'` (retail) or `'cafe_zupas_catering'` — backfilled for full history. Catering campaign events live in the *same* tables; filter `workspace = 'cafe_zupas'` for retail-only analyses and state which workspace(s) an answer includes.
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
  >
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

## Currents ingestion integrity (steward findings 2026-07-28)

The `braze` dataset is built by a `currents_merge` job that MERGEs `braze_stream` into the event tables. Four things about that pipeline change how you should write queries.

### 1. `id` is the event dedupe key — use it for event counts

Every Currents table carries an `id`. It is the row's unique event identifier, and the merge can emit duplicates. For any **event-level** count, count distinct ids:

```sql
count(distinct ce.id) as events   -- not count(*)
```

`count(distinct external_user_id)` (the existing unique-user guidance) was never affected by this — the exposure is specifically `count(*)` metrics: sends, opens, impressions, clicks.

Health check the steward runs across all 89 tables — use it on any table you're about to report from:

```sql
select
count(*) - count(distinct id) as extra_rows
from `marketing-data-442316`.braze.email_send
where 1=1
and event_date >= date_sub(current_date('America/Denver'), interval 3 day)
and id is not null
```

**Duplicates are real and recent.** `canvas_entry` had duplicate ids under investigation on 2026-07-28 (a new merge image went live ~19:56 UTC that day). Treat late-July event counts as provisional until the merge fix is confirmed. `canvas_entry.create_datetime` is `current_datetime()` at insert (UTC civil time), so it dates when a row *landed* rather than when the event happened — useful for isolating rows from one bad load.

### 2. `load_watermark` is a lock, not just a freshness marker

A **future-dated** watermark means the merge job is holding the lock and is mid-write. Don't trust reads taken in that state:

```sql
select
lw.job_name
, lw.watermark
, lw.updated_at
, lw.watermark > current_timestamp() as lock_currently_held
from `marketing-data-442316`.braze.load_watermark lw
where 1=1
order by
lw.job_name
```

Check this alongside the ~2-day event maturation rule below. `watermark` is already a TIMESTAMP — see the caveat about not casting it.

### 3. There is a `__NULL__` event_date partition

Rows with `event_date is null` exist. The mandatory `where event_date between @start and @end` filter **silently drops them**. That's normally the right trade (they can't be placed on a timeline), but say so if a total needs to reconcile to a Braze dashboard figure.

### 4. Never bound `event_date` with a possibly-NULL value

`where event_date >= @some_null_var or event_date is null` defeats partition pruning entirely and scans the whole table — the exact failure mode observed on `contentcard_send`. If a bound can be NULL, `coalesce` it to a real date first. The "always filter `event_date`" rule only saves money when the bound is a genuine date literal or parameter.

## Writing attributes OUT — Braze CDI and Google Ads offline conversions

Everything above is about reading Braze. Four builds push *out* of the warehouse: `braze.bz_cid_bgnbd_palive_churn`, `braze.bz_cid_weather_flag`, `braze.cdi_order_attributes` (Braze custom attributes) and `shared_datasets.google_offline_conversions` (Google Ads). All four were migrated off the dropped `sales_ops.OrderCustomer` on 2026-08-21 and reviewed then. **Outbound builds fail differently from queries: nobody reads the output, so a wrong value lands in a targeting segment or an ad platform and stays there.** The four defects found in that review are all of the same shape — the SQL compiles, runs, and produces something plausible.

### 1. 🚨 `%Ez` on a DATETIME emits the literal string `%Ez`

`format_timestamp('%Y-%m-%dT%H:%M:%S%Ez', oc.order_datetime_local)` — the argument is a **DATETIME**, and the `%Ez` (UTC-offset) specifier is not honoured. Measured 2026-08-18, one order per state:

| written | produced |
|---|---|
| `format_timestamp('…%Ez', order_datetime_local)` | `2026-08-18T11:07:46%Ez` |
| `format_timestamp('…%Ez', order_timestamp_utc, 'UTC')` | `2026-08-18T15:07:46+00:00` |

Every row carries an unparseable timestamp — a DATETIME has no offset to print, so the specifier passes through as text. It does not error. **And even with the format fixed, `order_datetime_local` is store-local**, so the value would be 4–7 hours early across the nine states (Ohio 4, IL/MN/TX/WI 5, ID/UT 6, AZ/NV 7). This is the `timestamp(order_datetime)` anti-pattern documented above, reappearing inside a different function — which is why the rule is written as *"never build a UTC order timestamp yourself,"* not *"never call `timestamp()`."*

**Rule: on anything leaving the warehouse, format `order_timestamp_utc` with an explicit `'UTC'` argument.** Verify by eye that the output string ends in an offset (`+00:00`), because a malformed one looks fine in a spot check.

### 2. Hashed phone identifiers must be E.164 *before* hashing

`to_hex(sha256('+' || cast(i.Phone as string)))` produces `+8015551234`. Google requires E.164, which for US numbers is `+1` + 10 digits. Measured on `sales_ops.cust_info`: **977,569 of 977,606 non-null phones are exactly 10 digits** (11 are 11-digit, and the minimum length is 1, so junk exists). So essentially every phone identifier hashes to something that can never match, silently, forever — a hash mismatch is indistinguishable from "no such user."

Normalize and reject the junk before hashing, e.g. `'+1' || phone` for the 10-digit case and NULL below 10 digits. (`cust_info` itself is clean 1:1 on `mapped_cust_id` — 1,208,682 rows, 1,208,682 distinct — so joining it fans nothing out.)

### 3. 🚨 A null-unsafe change-detection filter can only *update* an attribute, never *initialise* it

The pattern that makes these builds cheap is "only send rows whose value differs from what Braze already holds." Written naively:

```sql
-- ANTI-PATTERN
where json_value(u.custom_attributes.risk_band) <> p.risk_band
```

`NULL <> 'healthy'` is NULL, which is not TRUE, so **every user who does not already have the attribute is dropped.** Measured on `braze.users` 2026-08-21: **3,767,646 of 4,286,702 profiles have no `risk_band` at all** (519,056 have one). A newly-scored guest is therefore locked out permanently — the attribute can only ever be revised, never first written, and on a fresh attribute the build sends **zero rows** while succeeding.

```sql
-- CORRECT
where coalesce(json_value(u.custom_attributes.risk_band), '') <> p.risk_band
```

`cdi_order_attributes` already does this correctly with `coalesce(lax_int64(...), 0)` / `coalesce(timestamp(lax_string(...)), current_timestamp)` on all eight of its comparisons — copy that build's shape. Same family as the `col <> 'X'` null-unsafe filter rule; the twist here is that the dropped rows are exactly the population you most want to reach.

### 4. A priority table that is joined but never ordered by

`bz_cid_weather_flag` defines an explicit precedence — `snow` 1, `rain` 2, `hot` 3, `cold` 4 — joins it, and then picks the winner with:

```sql
qualify row_number() over (partition by oc.mapped_cust_id order by c.weather_flag) = 1   -- ANTI-PATTERN
```

That orders the flag **alphabetically**: `cold` → `hot` → `rain` → `snow`. So `cold` always wins and `snow` always loses — precisely inverted from the declared intent, and the `sort_order` column is never referenced. The join makes the CTE look load-bearing, so the table reads as if the priority were applied. Fix: `order by o.sort_order`.

**Generalisable:** when a lookup table exists to express an *ordering*, check that its rank column appears in an `ORDER BY` and not only in a join predicate. A join gives you the filter; only the `ORDER BY` gives you the precedence. Related: a filter and a breakout are different controls, and this is the same confusion between "restrict the set" and "rank the set."

### Two lower-priority notes from the same review

- **`current_date` is UTC.** Three of these builds anchor on bare `current_date` / `current_date()` (the churn model's `ref_date`, the weather build's `weather_date = current_date`, the L90/L180/L365 windows). After 18:00 MT it is already tomorrow in UTC. Use `current_date('America/Denver')`, which `google_offline_conversions` already does.
- **The internal-traffic exclusion was lost in the migration.** `cdi_order_attributes` carries `--and oc.mapped_domain NOT IN ('cafezupas.com', 'tkxel.com')`, commented out because `mapped_domain` was the legacy name (it is `mapped_email_domain` now). The churn build *does* exclude `cafezupas.com`. So two Braze attribute builds disagree about whether employees are guests — pending the open steward decision on ratifying that exclusion.

## Files

| File | What it is |
|---|---|
| `claude_skills/braze-campaigns/SKILL.md` | This guide. |
| `sql/braze_campaign_daily_activity.sql` | Normalized cross-channel activity union + campaigns-by-day rollup. |
| `sql/braze_campaign_engagements.sql` | Normalized cross-channel engagement union + engagement-by-customer and engagement-rate examples. |
| `data_dictionaries/braze_data_dictionary.md` | Full table & column dictionary for the `braze` dataset — all 119 tables / 2,651 columns, Active/Empty status and row counts, refreshed 2026-09-03 from live `INFORMATION_SCHEMA`. |
| `data_dictionaries/braze_data_dictionary.xlsx` | Same content as a filterable workbook (Read Me, Tables, Data Dictionary, Custom PAYLOAD Fields). |

## When done

If you learned something new about the Braze tables during the session (new gotcha, new canonical definition, data quality issue), do **not** edit this skill or any local copy — only the data steward commits to the repo, and session copies are discarded. Instead, create an Asana task on the **Claude Data** board (workspace cafezupas.com, project `1216769551099591`) titled `KB finding: <short title>`, describing what you observed (include the query that surfaced it) and the proposed change. The steward reviews and merges vetted findings; the next session's fresh clone benefits automatically.
